#!/usr/bin/env python3
"""
Convert all discovered artist feeds from internal caches into proper
Candidate JSON files for the feed_discovery pipeline.

Reads from:
  - scripts/feed_discovery/data/artist_cache_v3/   (v3 URL construction)
  - scripts/feed_discovery/data/artist_fast/       (DDG fast)
  - scripts/feed_discovery/data/artist_batch/      (DDG batch)
  - scripts/feed_discovery/data/artist_zero/       (zero-search)

Outputs to:
  scripts/feed_discovery/data/artist_candidates/{slug}.json

Each file: [Candidate, ...]  as dicts matching feed_discovery.models.Candidate
"""

import json, re, hashlib, sys
from pathlib import Path
from dataclasses import asdict

# Add parent to path to import feed_discovery models
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.feed_discovery.models import Candidate

REPO_ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = REPO_ROOT / "scripts" / "feed_discovery" / "data"
COUNTRIES_JSON = DATA_DIR / "countries.json"
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"
OUT_DIR = DATA_DIR / "artist_candidates"

# Which cache dirs to read
CACHE_DIRS = [
    "artist_cache_v3",
    "artist_v4",
    "artist_batch",
    "artist_broad",
    "artist_cache_v2",
    "artist_fast",
    "artist_zero",
]

# YouTube category → genre mapping
TOPIC_MAP = {
    "News & Current Affairs": "News &amp; Current Affairs",
    "Arts & Culture": "Arts &amp; Culture",
    "Entertainment": "Entertainment",
    "Music & Audio": "Music &amp; Audio",
}


def feedmine_topic(entry: dict) -> str:
    """Determine pipeline category from entry metadata."""
    name = (entry.get("name") or entry.get("title") or "").lower()
    known = (entry.get("known_for") or "").lower()
    source = (entry.get("source") or "").lower()

    if "youtube" in source or "socialblade" in source:
        return "YouTube"

    music_words = {"singer", "musician", "rapper", "band", "song", "composer",
                   "music", "cantor", "cantante", "chanteur", "sänger", "musica",
                   "música", "musique", "dj", "producer", "guitar", "piano", "drum"}
    actor_words = {"actor", "actress", "film", "director", "filmmaker",
                   "cinema", "tv", "television", "hollywood", "bollywood"}

    if any(w in name or w in known for w in music_words):
        return "Music"
    if any(w in name or w in known for w in actor_words):
        return "Movies"
    return "Culture"


def load_existing_opml_urls(slug: str) -> set[str]:
    """Get all feed URLs already in a country's OPML."""
    urls: set[str] = set()
    for dir_name in {slug, slug.replace("-", "_")}:
        opml = COUNTRIES_DIR / dir_name / f"{dir_name}.opml"
        if opml.exists():
            try:
                for m in re.finditer(r'xmlUrl="([^"]+)"', opml.read_text(encoding="utf-8")):
                    urls.add(m.group(1).strip().rstrip("/").lower())
            except Exception:
                pass
    return urls


def main():
    with open(COUNTRIES_JSON, encoding="utf-8") as f:
        countries = json.load(f)

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # Collect all feeds from all caches, dedup by URL
    by_slug: dict[str, list[dict]] = {}
    seen_urls: set[str] = set()

    for cache_name in CACHE_DIRS:
        cache_path = DATA_DIR / cache_name
        if not cache_path.exists():
            continue
        for fname in cache_path.iterdir():
            if not fname.name.endswith("_feeds.json"):
                continue
            slug = fname.name.replace("_feeds.json", "")
            if slug not in countries:
                continue

            try:
                feeds = json.loads(fname.read_text(encoding="utf-8"))
            except Exception:
                continue

            for feed in feeds:
                url = (feed.get("url") or "").strip().rstrip("/")
                if not url or not url.startswith("http"):
                    continue
                norm = url.lower()
                if norm in seen_urls:
                    continue
                seen_urls.add(norm)

                entry = dict(feed)
                entry.setdefault("title", entry.get("feed_title") or entry.get("name") or url)
                entry.setdefault("source", cache_name)
                by_slug.setdefault(slug, []).append(entry)

    # Also add YouTube SocialBlade feeds
    sb_path = DATA_DIR / "youtube_channels_socialblade.json"
    if sb_path.exists():
        with open(sb_path, encoding="utf-8") as f:
            sb = json.load(f)
        for sb_slug, channels in sb.get("by_country", {}).items():
            if sb_slug not in countries:
                continue
            for ch in channels:
                feed_url = ch.get("feed_url", "")
                if not feed_url:
                    continue
                norm = feed_url.lower().rstrip("/")
                if norm in seen_urls:
                    continue
                seen_urls.add(norm)
                entry = {
                    "url": feed_url,
                    "title": ch.get("channel_name", feed_url),
                    "name": ch.get("channel_name", ""),
                    "source": "socialblade",
                    "known_for": "youtube",
                }
                by_slug.setdefault(sb_slug, []).append(entry)

    # Convert to Candidate objects per country
    total_candidates = 0
    total_new = 0

    for slug in sorted(by_slug.keys()):
        meta = countries[slug]
        entries = by_slug[slug]
        existing_urls = load_existing_opml_urls(slug)

        candidates: list[dict] = []
        new_count = 0

        for entry in entries:
            url = entry["url"]
            norm = url.lower().rstrip("/")
            is_new = norm not in existing_urls

            cand = Candidate(
                url=url,
                category=feedmine_topic(entry),
                title=entry.get("title") or entry.get("name") or url,
                genre="Artist Blogs" if "youtube" not in entry.get("source", "") else "YouTube Artists",
                source_page=entry.get("page_url") or entry.get("website") or "",
                national=True,
                national_reason=f"discovered for {meta['name']} via {entry.get('source', 'unknown')}",
                is_live=True,  # already validated during discovery
                status_code=200,
                is_new=is_new,
            )
            candidates.append(asdict(cand))
            if is_new:
                new_count += 1

        # Save
        out_file = OUT_DIR / f"{slug}.json"
        out_file.write_text(json.dumps(candidates, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"📝 {meta['name']:25s} ({slug:22s}): {len(candidates)} candidates, {new_count} new")
        total_candidates += len(candidates)
        total_new += new_count

    print(f"\n{'='*60}")
    print(f"Total: {total_candidates} candidates ({total_new} new) across {len(by_slug)} countries")
    print(f"Output: {OUT_DIR}")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
