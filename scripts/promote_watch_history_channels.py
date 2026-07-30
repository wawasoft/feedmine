#!/usr/bin/env python3
"""Promote YouTube channels from watch_history_new_channels.json into production OPMLs.

Reads channels from the staging JSON, fetches their YouTube RSS feeds for content
samples, enriches metadata via DeepSeek LLM, and inserts <outline> elements into
the correct existing OPML files based on editorial category.

Only channels NOT already in production are processed.

Usage:
    python3 scripts/promote_watch_history_channels.py --dry-run       # count + report only
    python3 scripts/promote_watch_history_channels.py                 # full run
    python3 scripts/promote_watch_history_channels.py --min-score 4   # score >= 4 only
    python3 scripts/promote_watch_history_channels.py --limit 10      # test first 10
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
import time
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit

import feedparser
import httpx

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent
FEEDS_ROOT = ROOT / "feedmine" / "Resources" / "Feeds"
STAGING_JSON = ROOT / "editorial" / "feed-curation" / "staging" / "watch_history_new_channels.json"
PROGRESS_PATH = ROOT / "build" / "watch_history_promotion_progress.json"
REPORT_PATH = ROOT / "build" / "watch_history_promotion_report.md"

# ---------------------------------------------------------------------------
# LLM config
# ---------------------------------------------------------------------------

DEEPSEEK_MODEL = "deepseek-v4-flash"
DEEPSEEK_URL = "https://api.deepseek.com/v1/chat/completions"
MAX_TOKENS = 512
TEMPERATURE = 0.3
LLM_DELAY = 0.3

# ---------------------------------------------------------------------------
# HTTP config
# ---------------------------------------------------------------------------

REQUEST_TIMEOUT = 30.0
MAX_RETRIES = 3
USER_AGENT = "FeedMine/2.0 watch-history-promoter"

# ---------------------------------------------------------------------------
# Category → OPML folder mapping
# (folder_name, topic, subcategory)
# ---------------------------------------------------------------------------

CATEGORY_TO_OPML: dict[str, tuple[str, str | None, str | None]] = {
    "Tech / Programming / AI":          ("04_Technology_&_Science", "Technology & Science", "Software & Computing"),
    "News / Current Events":            ("01_News_&_Current_Affairs", "News & Current Affairs", "General News"),
    "Science / Education":              ("11_Education_&_Knowledge", "Education & Knowledge", "Science & Research"),
    "Sports":                           ("07_Sports", "Sports", "General Sports"),
    "Maker / DIY / Engineering":        ("04_Technology_&_Science", "Technology & Science", "Gadgets & Engineering"),
    "Sailing / Travel":                 ("10_Travel_&_Transport", "Travel & Transport", "Travel"),
    "Nature & Animals":                ("15_Nature_&_Animals", "Nature & Animals", "Wildlife & Nature"),
    "Food & Drink":                     ("08_Food_&_Drink", "Food & Drink", "Food & Cooking"),
    "Health & Wellness":                ("06_Health_&_Wellness", "Health & Wellness", "Health & Fitness"),
    "Brazilian High-Quality (PT-BR)":   ("90_countries/brazil", "News & Current Affairs", "Brazilian Content"),
    "Brazilian / Portuguese Content":   ("90_countries/brazil", "News & Current Affairs", "Brazilian Content"),
    "Arts & Culture":                   ("02_Arts_&_Culture", "Arts & Culture", "Visual Arts"),
    "Travel & Transport":              ("10_Travel_&_Transport", "Travel & Transport", "Travel"),
    "Education & Knowledge":            ("11_Education_&_Knowledge", "Education & Knowledge", "Online Learning"),
    "Film / Media Analysis":            ("03_Entertainment", "Entertainment", "Film & Media"),
    "Society & Identity":              ("12_Society_&_Identity", "Society & Identity", "Society & Culture"),
    "Philosophy / Essays":              ("12_Society_&_Identity", "Society & Identity", "Philosophy & Ideas"),
    "Tech Reviews / Gadgets":           ("04_Technology_&_Science", "Technology & Science", "Gadgets & Engineering"),
    "AI / ML Deep Dives":              ("04_Technology_&_Science", "Technology & Science", "Software & Computing"),
    "Podcasts / Talk Shows":            ("16_Music_&_Audio", "Music & Audio", "Podcasts & Talk Shows"),
    "Art / Museum / Culture":           ("02_Arts_&_Culture", "Arts & Culture", "Museums & Galleries"),
    "Education / Language":             ("11_Education_&_Knowledge", "Education & Knowledge", "Language Learning"),
    "Travel / Sailing / Canada":        ("90_countries/canada", "Travel & Transport", "Travel"),
    "Other":                            ("17_General_Interests", "General Interests", "Other"),
}


# ---------------------------------------------------------------------------
# Helpers — identity
# ---------------------------------------------------------------------------

def compute_source_id(url: str) -> str:
    """Canonical SHA-256 identity matching curate_opml_catalog.py."""
    parsed = urlsplit(url)
    canonical = urlunsplit(
        (parsed.scheme.lower(),
         parsed.hostname.lower() if parsed.hostname else "",
         parsed.path, parsed.query, "")
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


# ---------------------------------------------------------------------------
# Helpers — OPML I/O
# ---------------------------------------------------------------------------

def load_opml(path: Path) -> tuple[ET.ElementTree, ET.Element]:
    """Parse OPML file, return (tree, body_element). Creates backup."""
    tree = ET.parse(str(path))
    body = tree.find("body")
    if body is None:
        raise ValueError(f"No <body> in {path}")
    return tree, body


def save_opml(tree: ET.ElementTree, path: Path) -> None:
    """Save OPML with backup."""
    backup = path.with_suffix(".opml.bak")
    if path.exists():
        shutil.copy2(path, backup)
    # Pretty-print with minimal whitespace
    ET.indent(tree, space="      ", level=0)
    tree.write(str(path), encoding="utf-8", xml_declaration=True)


def find_or_create_subcategory(body: ET.Element, topic: str | None, subcategory: str | None) -> ET.Element:
    """Find existing subcategory <outline> in body, or create it.

    For topic-based OPMLs: body contains <outline text="Subcategory"> elements.
    For country OPMLs (90_countries): body contains topic first, then subcategory.

    Returns the parent <outline> where new feed outlines should be added.
    """
    if subcategory is None:
        return body

    path: list[str] = []
    if topic:
        path.append(topic)
    if subcategory and subcategory != topic:
        path.append(subcategory)

    current = body
    for segment in path:
        found = None
        for child in current:
            if child.tag == "outline" and child.get("text") == segment:
                found = child
                break
        if found is None:
            found = ET.SubElement(current, "outline", {"text": segment, "title": segment})
        current = found

    return current


def build_outline(channel: dict[str, Any], enrichment: dict[str, Any] | None) -> ET.Element:
    """Build an <outline> element from channel data + enrichment results."""
    cid = channel["channel_id"]
    rss_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}"
    html_url = f"https://www.youtube.com/channel/{cid}"
    source_id = compute_source_id(rss_url)

    title = channel["title"]
    language = channel.get("language", "en")
    nature = channel.get("nature", "evergreen")
    media_kind = channel.get("media_kind", "video")

    # Build attributes
    attrs: dict[str, str] = {
        "text": title,
        "title": title,
        "type": "rss",
        "xmlUrl": rss_url,
        "language": language,
        "feedmineSourceId": source_id,
        "feedmineNature": nature,
        "feedmineMediaKind": media_kind,
        "htmlUrl": html_url,
    }

    if enrichment:
        attrs["description"] = enrichment.get("description", "")
        attrs["category"] = enrichment.get("tags", "")
        attrs["feedmineActivity"] = enrichment.get("activity", "active")
        attrs["feedmineQualityScore"] = str(enrichment.get("quality_score", 75))
        attrs["feedmineArticlesFetched"] = str(enrichment.get("articles_fetched", 5))
        latest = enrichment.get("latest_item_at")
        if latest:
            attrs["feedmineLatestItemAt"] = latest
        attrs["feedmineDefaultEnabled"] = "true"
    else:
        # Placeholder — will be filled by enrichment pipeline later
        attrs["description"] = ""
        attrs["category"] = ""
        attrs["feedmineActivity"] = "dormant"
        attrs["feedmineQualityScore"] = "50"
        attrs["feedmineArticlesFetched"] = "0"
        attrs["feedmineDefaultEnabled"] = "false"

    # Topic / subcategory assignment
    category = channel.get("category", "Other")
    folder, topic, subcategory = CATEGORY_TO_OPML.get(category,
        ("17_General_Interests", "General Interests", "Other"))

    if topic:
        attrs["feedmineTopic"] = topic
    if subcategory:
        attrs["feedmineSubcategory"] = subcategory

    # Note: country-specific OPML path resolution (e.g. 90_countries/brazil)
    # is handled by get_opml_path(), not here. The outline's topic/subcategory
    # are set above and may differ from the physical file's root topic.

    return ET.Element("outline", attrs)


# ---------------------------------------------------------------------------
# HTTP fetch
# ---------------------------------------------------------------------------

def fetch_feed(rss_url: str) -> dict[str, Any] | None:
    """Fetch and parse a YouTube RSS feed. Returns dict with metadata or None on failure."""
    headers = {"User-Agent": USER_AGENT}
    for attempt in range(MAX_RETRIES):
        try:
            resp = httpx.get(rss_url, headers=headers, timeout=REQUEST_TIMEOUT, follow_redirects=True)
            if resp.status_code != 200:
                if attempt < MAX_RETRIES - 1:
                    time.sleep(2 ** attempt)
                    continue
                return None

            content = resp.text
            feed = feedparser.parse(content)
            entries = feed.entries

            if not entries:
                return None

            # Extract post samples
            samples = []
            for entry in entries[:15]:
                samples.append({
                    "title": entry.get("title", ""),
                    "summary": entry.get("summary", "")[:500],
                    "published": entry.get("published", ""),
                })

            # Determine latest item
            latest = None
            if entries:
                published = entries[0].get("published_parsed") or entries[0].get("updated_parsed")
                if published:
                    latest = time.strftime("%Y-%m-%d %H:%M:%S%z", published)

            return {
                "samples": samples,
                "articles_fetched": len(entries),
                "latest_item_at": latest or "",
                "title_from_feed": feed.feed.get("title", ""),
            }
        except Exception:
            if attempt < MAX_RETRIES - 1:
                time.sleep(2 ** attempt)
            else:
                return None
    return None


# ---------------------------------------------------------------------------
# LLM enrichment
# ---------------------------------------------------------------------------

ENRICH_PROMPT = """You are an editorial curator for a feed reader catalog. Analyze this YouTube channel and return a JSON object with exactly these keys:

- "description": A 1-2 sentence description in English of what this channel covers. Be specific and factual.
- "tags": 5-10 comma-separated tags in English describing the content topics.
- "quality_score": Integer 0-100 rating editorial quality (production value, accuracy, originality).
- "activity": One of "prolific" (daily+ posts), "active" (weekly), "quiet" (monthly), "dormant" (rare/sporadic).

Channel title: {title}
Category: {category}
Sample posts:
{posts}

Return ONLY valid JSON, no other text. Example:
{{"description": "...", "tags": "tag1, tag2, tag3", "quality_score": 85, "activity": "prolific"}}"""


def enrich_with_llm(title: str, category: str, samples: list[dict]) -> dict[str, Any] | None:
    """Call DeepSeek to generate description, tags, quality score, activity."""
    api_key = os.environ.get("DEEPSEEK_API_KEY")
    if not api_key:
        print("  ⚠️  DEEPSEEK_API_KEY not set — skipping LLM enrichment")
        return None

    posts_text = "\n".join(
        f"- {s['title']}: {s['summary'][:200]}" for s in samples[:8]
    )
    prompt = ENRICH_PROMPT.format(title=title, category=category, posts=posts_text)

    payload = {
        "model": DEEPSEEK_MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE,
        "response_format": {"type": "json_object"},
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }

    for attempt in range(MAX_RETRIES):
        try:
            import urllib.request
            req = urllib.request.Request(
                DEEPSEEK_URL,
                data=json.dumps(payload).encode(),
                headers=headers,
            )
            with urllib.request.urlopen(req, timeout=60) as resp:
                result = json.loads(resp.read())
            content = result["choices"][0]["message"]["content"]
            return json.loads(content)
        except Exception as e:
            if attempt < MAX_RETRIES - 1:
                time.sleep(2 ** attempt)
            else:
                print(f"  ⚠️  LLM call failed after {MAX_RETRIES} attempts: {e}")
                return None
    return None


# ---------------------------------------------------------------------------
# Activity classification (from fetch, when LLM is unavailable)
# ---------------------------------------------------------------------------

def classify_activity(articles_fetched: int, latest_item_at: str | None) -> str:
    """Fallback activity classification without LLM."""
    if articles_fetched == 0:
        return "dormant"
    if not latest_item_at:
        return "quiet"
    try:
        # Parse various date formats
        from email.utils import parsedate_to_datetime
        latest = parsedate_to_datetime(latest_item_at)
        age_days = (datetime.now(timezone.utc) - latest).days
        if age_days <= 7:
            return "prolific"
        elif age_days <= 30:
            return "active"
        elif age_days <= 90:
            return "quiet"
        else:
            return "dormant"
    except Exception:
        return "quiet" if articles_fetched > 5 else "dormant"


# ---------------------------------------------------------------------------
# Category → folder resolution
# ---------------------------------------------------------------------------

def get_opml_path(category: str, region: str) -> Path:
    """Return the OPML file path where this channel should be inserted."""
    # Country-specific channels
    if region.startswith("countries/"):
        country = region.split("/")[-1]
        country_path = FEEDS_ROOT / "90_countries" / country / f"{country}.opml"
        if country_path.exists():
            return country_path

    # Topic-based
    folder, _, _ = CATEGORY_TO_OPML.get(category,
        ("17_General_Interests", "General Interests", "Other"))

    # Handle folders with slashes (e.g. "90_countries/canada")
    parts = folder.split("/")
    opml_path = FEEDS_ROOT.joinpath(*parts) / f"{parts[-1]}.opml"
    if opml_path.exists():
        return opml_path

    # Fallback: try the folder name as the OPML file name
    return FEEDS_ROOT / parts[0] / f"{parts[0]}.opml"


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def load_progress() -> set[str]:
    """Return set of channel_ids already processed."""
    if PROGRESS_PATH.exists():
        with open(PROGRESS_PATH) as f:
            data = json.load(f)
            return set(data.get("processed", []))
    return set()


def save_progress(processed: set[str]) -> None:
    """Save progress for resume."""
    PROGRESS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = PROGRESS_PATH.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump({"processed": sorted(processed)}, f)
    tmp.replace(PROGRESS_PATH)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true", help="Report only, no changes")
    parser.add_argument("--min-score", type=int, default=0, help="Minimum score (default: 0 = all)")
    parser.add_argument("--limit", type=int, default=0, help="Process at most N channels")
    parser.add_argument("--skip-enrichment", action="store_true", help="Skip LLM enrichment")
    parser.add_argument("--reset", action="store_true", help="Ignore saved progress")
    args = parser.parse_args()

    # Load staging data
    if not STAGING_JSON.exists():
        print(f"❌ Staging JSON not found: {STAGING_JSON}")
        return 1

    with open(STAGING_JSON) as f:
        all_channels: list[dict[str, Any]] = json.load(f)

    print(f"📂 Loaded {len(all_channels)} channels from {STAGING_JSON.name}")

    # Filter: only truly new (not in production)
    # We check by computing source_id from rss_url and checking if it exists in OPMLs
    print("🔍 Checking which channels are already in production OPMLs...")
    # Build set of existing source_ids from production OPMLs
    existing_source_ids: set[str] = set()
    for opml_file in FEEDS_ROOT.rglob("*.opml"):
        try:
            tree = ET.parse(str(opml_file))
            for el in tree.iter("outline"):
                sid = el.get("feedmineSourceId")
                if sid:
                    existing_source_ids.add(sid)
        except ET.ParseError:
            pass
    print(f"   Found {len(existing_source_ids):,} existing source IDs in production")

    new_channels = []
    already_in = []
    for ch in all_channels:
        cid = ch["channel_id"]
        rss_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}"
        source_id = compute_source_id(rss_url)
        if source_id in existing_source_ids:
            already_in.append(ch)
        else:
            new_channels.append(ch)

    print(f"   Already in production: {len(already_in)}")
    print(f"   TRULY NEW: {len(new_channels)}")

    # Apply score filter
    if args.min_score > 0:
        before = len(new_channels)
        new_channels = [c for c in new_channels if c.get("score", 0) >= args.min_score]
        print(f"   After score >= {args.min_score} filter: {len(new_channels)} (removed {before - len(new_channels)})")

    if not new_channels:
        print("✅ No new channels to process!")
        return 0

    # Score distribution
    scores = Counter(c.get("score", 0) for c in new_channels)
    print(f"\n📊 Channels to process:")
    for s, cnt in sorted(scores.items(), reverse=True):
        print(f"   ⭐{s}: {cnt}")

    cats = Counter(c.get("category", "?") for c in new_channels)
    print(f"\n📂 By category:")
    for cat, cnt in cats.most_common(10):
        print(f"   {cnt:>4}  {cat}")

    if args.dry_run:
        print(f"\n🏁 DRY RUN — {len(new_channels)} channels would be processed. No changes made.")
        return 0

    # Resume from progress
    processed = set() if args.reset else load_progress()
    todo = [c for c in new_channels if c["channel_id"] not in processed]
    if args.limit > 0:
        todo = todo[:args.limit]

    print(f"\n🚀 Processing {len(todo)} channels ({len(processed)} already done)...")

    results: list[dict] = []
    enriched_count = 0
    failed_count = 0

    for i, ch in enumerate(todo):
        cid = ch["channel_id"]
        title = ch["title"]
        rss_url = f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}"
        category = ch.get("category", "Other")
        score = ch.get("score", 0)

        print(f"\n[{i+1}/{len(todo)}] ⭐{score} {title[:60]}")

        # Step 1: Fetch feed
        print(f"   📡 Fetching {rss_url[:80]}...")
        feed_data = fetch_feed(rss_url)

        result: dict[str, Any] = {
            "channel_id": cid,
            "title": title,
            "category": category,
            "score": score,
            "fetched": feed_data is not None,
            "articles_fetched": feed_data["articles_fetched"] if feed_data else 0,
        }

        # Step 2: Enrich
        enrichment = None
        if feed_data and not args.skip_enrichment:
            print(f"   🤖 Enriching via LLM...")
            enrichment = enrich_with_llm(title, category, feed_data["samples"])
            if enrichment:
                enrichment["articles_fetched"] = feed_data["articles_fetched"]
                enrichment["latest_item_at"] = feed_data.get("latest_item_at", "")
                result["enriched"] = True
                enriched_count += 1
            else:
                # Fallback without LLM
                enrichment = {
                    "description": feed_data.get("title_from_feed", ""),
                    "tags": "",
                    "quality_score": 65 if score >= 4 else 50,
                    "activity": classify_activity(
                        feed_data["articles_fetched"],
                        feed_data.get("latest_item_at"),
                    ),
                    "articles_fetched": feed_data["articles_fetched"],
                    "latest_item_at": feed_data.get("latest_item_at", ""),
                }
                result["enriched"] = False
        elif feed_data:
            enrichment = {
                "description": feed_data.get("title_from_feed", ""),
                "tags": "",
                "quality_score": 65 if score >= 4 else 50,
                "activity": classify_activity(
                    feed_data["articles_fetched"],
                    feed_data.get("latest_item_at"),
                ),
                "articles_fetched": feed_data["articles_fetched"],
                "latest_item_at": feed_data.get("latest_item_at", ""),
            }
            result["enriched"] = False

        # Step 3: Build outline
        outline = build_outline(ch, enrichment)

        # Step 4: Insert into OPML
        if enrichment:
            region = ch.get("region", "global")
            opml_path = get_opml_path(category, region)
            print(f"   📝 Inserting into {opml_path.relative_to(ROOT)}")

            try:
                tree, body = load_opml(opml_path)
                _, topic, subcategory = CATEGORY_TO_OPML.get(category,
                    ("17_General_Interests", "General Interests", "Other"))
                parent = find_or_create_subcategory(body, topic, subcategory)
                parent.append(outline)
                save_opml(tree, opml_path)
                result["inserted"] = True
                print(f"   ✅ Inserted into {subcategory or 'body'}")
            except Exception as e:
                print(f"   ❌ Failed to insert: {e}")
                result["inserted"] = False
                failed_count += 1
        else:
            result["inserted"] = False
            if not feed_data:
                print(f"   ❌ Fetch failed — skipping")
                failed_count += 1

        results.append(result)
        processed.add(cid)
        save_progress(processed)

        # Rate limit
        time.sleep(0.5)

    # -----------------------------------------------------------------------
    # Report
    # -----------------------------------------------------------------------
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    inserted = [r for r in results if r.get("inserted")]
    not_inserted = [r for r in results if not r.get("inserted")]

    lines = [
        "# Watch History Channel Promotion Report",
        f"\n**Date:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
        f"\n## Summary",
        f"\n| Metric | Count |",
        f"|--------|-------|",
        f"| Total processed | {len(results)} |",
        f"| ✅ Inserted into OPMLs | {len(inserted)} |",
        f"| ❌ Failed | {len(not_inserted)} |",
        f"| 🤖 LLM-enriched | {enriched_count} |",
        f"| Already in production (skipped) | {len(already_in)} |",
        f"\n## Inserted — by category",
    ]

    inserted_by_cat = Counter(r["category"] for r in inserted)
    for cat, cnt in inserted_by_cat.most_common():
        lines.append(f"- {cat}: {cnt}")

    if not_inserted:
        lines.append(f"\n## Failed ({len(not_inserted)})")
        for r in not_inserted:
            lines.append(f"- ⭐{r['score']} **{r['title']}** ({r['category']}) — fetch={'✅' if r['fetched'] else '❌'}")

    lines.append(f"\n## Top inserted by score")
    for r in sorted(inserted, key=lambda x: x["score"], reverse=True)[:20]:
        lines.append(f"- ⭐{r['score']} **{r['title']}** → {r['category']}")

    with open(REPORT_PATH, "w") as f:
        f.write("\n".join(lines) + "\n")

    print(f"\n{'='*60}")
    print(f"✅ DONE — {len(inserted)} inserted, {len(not_inserted)} failed")
    print(f"📄 Report: {REPORT_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
