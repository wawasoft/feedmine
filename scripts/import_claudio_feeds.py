#!/usr/bin/env python3
"""Import validated Claudio feeds into Feedmine OPML tree with enrichment.

Usage:
    # First, generate JSON of validated feeds:
    swift scripts/import-opml.swift claudio-feeds.opml --validate --json > /tmp/claudio-validated.json

    # Then, import into Feedmine:
    python3 scripts/import_claudio_feeds.py \
        --input /tmp/claudio-validated.json \
        --feeds-root feedmine/Resources/Feeds \
        [--dry-run]

The script:
1. Reads validated feeds from JSON (output of import-opml.swift --validate --json)
2. Scans existing OPML files to build dedup set of canonical URLs
3. Maps each feed to the correct Feedmine topic/subcategory
4. Generates all enrichment attributes
5. Appends feeds as new subcategory sections in target OPML files
6. Outputs a summary report
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import shutil
import unicodedata
import urllib.parse
import xml.etree.ElementTree as ET
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence

try:
    from scripts.catalog_identity import canonical_url, compute_source_id
except ModuleNotFoundError:
    from catalog_identity import canonical_url, compute_source_id

# ═══════════════════════════════════════════════════════════════════════════════
# Enrichment formulas — exact ports from curate_opml_catalog.py
# ═══════════════════════════════════════════════════════════════════════════════

CURRENT_SENSITIVE = (
    "news", "current events", "politics", "government", "election", "geopolitics",
    "markets", "stock market", "financial news", "sports", "weather", "gossip",
    "celebrity", "entertainment news", "local news", "journalism",
)
PERSONAL_SENSITIVE = ("personal blog", "diary", "personal stories", "celebrity")
EVERGREEN = (
    "history", "astronomy", "science", "education", "literature", "poetry",
    "philosophy", "architecture", "art", "museums", "archives", "research",
    "recipes", "crafts", "woodworking", "photography", "nature",
)

TAG_ALIASES: dict[str, str] = {
    "ai": "artificial intelligence", "a.i": "artificial intelligence",
    "tech": "technology", "sci-fi": "science fiction", "scifi": "science fiction",
    "tv": "television", "film reviews": "movies", "book review": "book reviews",
    "podcasting": "podcasts", "podcast episodes": "podcasts",
    "current affairs": "current events", "world affairs": "international relations",
    "cats and kittens": "cats", "dog": "dogs", "cat": "cats",
    "php": "php", "wordpress": "wordpress", "javascript": "javascript",
    "react": "react", "vue": "vue", "css": "css", "html": "html",
}


def clean_text(value: object) -> str:
    if value is None:
        return ""
    return re.sub(r"\s+", " ", str(value)).strip()


def ascii_fold(value: str) -> str:
    return unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")


def phrase_present(haystack: str, needle: str) -> bool:
    return bool(re.search(rf"(?<![a-z0-9]){re.escape(needle)}(?![a-z0-9])", haystack))


def normalize_tag(value: str) -> str:
    value = ascii_fold(clean_text(value)).lower()
    value = re.sub(r"[&/]", " and ", value)
    value = re.sub(r"[^a-z0-9+#.-]+", " ", value)
    value = re.sub(r"\s+", " ", value).strip(" .-")
    return TAG_ALIASES.get(value, value)


def parse_tags(raw: str) -> list[str]:
    if not clean_text(raw):
        return []
    try:
        values = next(csv.reader([raw]))
    except (csv.Error, StopIteration):
        values = raw.split(",")
    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        tag = normalize_tag(value)
        if len(tag) < 2 or tag in seen:
            continue
        seen.add(tag)
        result.append(tag)
    return result[:8]


def classify_nature(title: str, description: str, tags: Sequence[str]) -> str:
    text = " | ".join([normalize_tag(title), normalize_tag(description), *tags])
    if any(phrase_present(text, keyword) for keyword in PERSONAL_SENSITIVE):
        return "personal"
    if any(phrase_present(text, keyword) for keyword in CURRENT_SENSITIVE):
        return "current-sensitive"
    if any(phrase_present(text, keyword) for keyword in EVERGREEN):
        return "evergreen"
    if any(phrase_present(text, keyword) for keyword in ("archive", "archives", "historical collection")):
        return "archive"
    return "periodic"


def quality_score(description: str, tags: Sequence[str], articles: int, activity: str) -> int:
    score = 35
    score += min(20, len(description) // 12)
    score += min(20, len(tags) * 4)
    score += min(15, articles // 2)
    score += {"prolific": 10, "active": 7, "quiet": 3, "dormant": 0, "unknown": -5}[activity]
    return max(0, min(100, score))


def media_kind_for(url: str, tags: Sequence[str]) -> str:
    lower = url.lower()
    if "youtube.com/feeds" in lower or "video" in tags or "youtube" in tags:
        return "video"
    if any(host in lower for host in ("anchor.fm", "podbean.com", "spreaker.com", "libsyn.com")) or "podcasts" in tags:
        return "audio"
    if "reddit.com/r/" in lower or "forum" in tags:
        return "forum"
    return "text"


# ═══════════════════════════════════════════════════════════════════════════════
# Category Mapping
# ═══════════════════════════════════════════════════════════════════════════════

CATEGORY_MAP: dict[str, tuple[str, str, str]] = {
    "Webdesign / Webdev":  ("04_Technology_&_Science", "Technology & Science", "Web Development"),
    "WordPress":           ("04_Technology_&_Science", "Technology & Science", "WordPress"),
    "Design & Art":        ("02_Arts_&_Culture", "Arts & Culture", "Architecture & Design"),
    "Fotografie":          ("02_Arts_&_Culture", "Arts & Culture", "Visual Arts"),
    "Comics":              ("02_Arts_&_Culture", "Arts & Culture", "Books & Literature"),
    "Blogs":               ("17_General_Interests", "General Interests", "General"),
    "Inspiration":         ("17_General_Interests", "General Interests", "General"),
    "Personal Feeds":      ("12_Society_&_Identity", "Society & Identity", "Personal Voices"),
    "Podcasts":            ("16_Music_&_Audio", "Music & Audio", "Podcasts & Audio"),
    "SEO, Analytics etc.": ("04_Technology_&_Science", "Technology & Science", "Software & Computing"),
}


def xml_escape(s: str) -> str:
    return (s.replace("&", "&amp;")
             .replace("<", "&lt;")
             .replace(">", "&gt;")
             .replace('"', "&quot;")
             .replace("'", "&apos;"))


def build_outline_xml(feed: dict, topic: str, subcategory: str) -> str:
    """Build a single <outline> element string with all Feedmine attributes."""
    url = feed["xmlUrl"]
    title = feed.get("title", "")
    description = feed.get("description") or ""
    html_url = feed.get("htmlUrl") or ""
    language = feed.get("language") or "und"
    raw_tags = feed.get("category_attr") or ""

    tags = parse_tags(raw_tags)
    media = media_kind_for(url, tags)
    nature = classify_nature(title, description, tags)
    activity = "active"  # confirmed reachable via HTTP 200
    quality = quality_score(description, tags, articles=0, activity=activity)
    source_id = compute_source_id(url)
    default_enabled = "true"  # all reachable feeds enabled

    # Build tags string
    tags_str = ", ".join(tags)

    attrs = []
    attrs.append(f'text="{xml_escape(title)}"')
    attrs.append(f'title="{xml_escape(title)}"')
    attrs.append('type="rss"')
    attrs.append(f'xmlUrl="{xml_escape(url)}"')

    if description:
        attrs.append(f'description="{xml_escape(description)}"')
    else:
        attrs.append('description=""')

    if html_url:
        attrs.append(f'htmlUrl="{xml_escape(html_url)}"')

    if tags_str:
        attrs.append(f'category="{xml_escape(tags_str)}"')

    lang = language.strip()
    if lang and lang != "und":
        attrs.append(f'language="{xml_escape(lang)}"')
    else:
        attrs.append('language="und"')

    # Feedmine custom attributes
    attrs.append(f'feedmineSourceId="{source_id}"')
    attrs.append(f'feedmineTopic="{xml_escape(topic)}"')
    attrs.append(f'feedmineSubcategory="{xml_escape(subcategory)}"')
    attrs.append(f'feedmineNature="{nature}"')
    attrs.append(f'feedmineActivity="{activity}"')
    attrs.append(f'feedmineArticlesFetched="0"')
    attrs.append(f'feedmineQualityScore="{quality}"')
    attrs.append(f'feedmineDefaultEnabled="{default_enabled}"')
    attrs.append(f'feedmineMediaKind="{media}"')

    return "        <outline " + "\n                 ".join(attrs) + "/>"


# ═══════════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════════

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Import validated Claudio feeds into Feedmine OPML tree"
    )
    parser.add_argument("--input", required=True, help="JSON file of validated feeds")
    parser.add_argument("--feeds-root", required=True, help="Path to feedmine/Resources/Feeds")
    parser.add_argument("--dry-run", action="store_true", help="Print what would happen, don't modify files")
    parser.add_argument("--no-backup", action="store_true", help="Skip backup (only for re-runs)")
    args = parser.parse_args()

    feeds_root = Path(args.feeds_root)
    input_path = Path(args.input)

    if not feeds_root.is_dir():
        raise SystemExit(f"Feeds root not found: {feeds_root}")

    # 1. Read validated feeds
    with open(input_path) as f:
        content = f.read()
    # Handle case where JSON is embedded in report text
    idx = content.rfind("\n[")
    if idx >= 0:
        content = content[idx:].strip()
    feeds: list[dict] = json.loads(content)
    print(f"📖 Read {len(feeds)} validated feeds from {input_path.name}")

    # 2. Scan existing OPML files for dedup
    print("\n🔍 Scanning existing OPMLs for duplicates...")
    existing_urls: dict[str, str] = {}  # canonical_url -> filename
    total_existing = 0
    for opml_path in sorted(feeds_root.rglob("*.opml")):
        try:
            tree = ET.parse(str(opml_path))
            for elem in tree.iter("outline"):
                xml_url = elem.get("xmlUrl")
                if xml_url:
                    key = canonical_url(xml_url)
                    if key not in existing_urls:
                        existing_urls[key] = str(opml_path.relative_to(feeds_root))
                    total_existing += 1
        except ET.ParseError as e:
            print(f"  ⚠️  Parse error in {opml_path.relative_to(feeds_root)}: {e}")
    print(f"  Found {total_existing} existing feed entries ({len(existing_urls)} unique canonical URLs)")

    # 3. Check duplicates
    new_feeds: list[dict] = []
    duplicates: list[tuple[str, str, str]] = []
    for feed in feeds:
        key = canonical_url(feed["xmlUrl"])
        if key in existing_urls:
            duplicates.append((feed["title"], feed["xmlUrl"], existing_urls[key]))
        else:
            new_feeds.append(feed)
            existing_urls[key] = "NEW"  # prevent self-duplicates within Claudio feeds

    print(f"\n🔄 Dedup results:")
    print(f"  New feeds to add:  {len(new_feeds)}")
    print(f"  Duplicates:        {len(duplicates)}")
    if duplicates:
        for title, url, location in duplicates[:10]:
            print(f"    ⚠️  \"{title}\" already in {location}")
        if len(duplicates) > 10:
            print(f"    ... and {len(duplicates) - 10} more")

    if not new_feeds:
        print("\n✅ Nothing to import — all feeds already exist in Feedmine.")
        return

    # 4. Group new feeds by target OPML
    grouped: dict[str, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    unmapped = []
    for feed in new_feeds:
        cat = feed.get("category", "")
        if cat in CATEGORY_MAP:
            dir_name, topic, subcategory = CATEGORY_MAP[cat]
            grouped[dir_name][subcategory].append(feed)
        else:
            unmapped.append(feed)

    if unmapped:
        print(f"\n⚠️  {len(unmapped)} feeds with unmapped categories:")
        from collections import Counter
        for cat, n in Counter(f["category"] for f in unmapped).items():
            print(f"    '{cat}': {n}")

    # 5. Summary
    print(f"\n📊 Distribution by OPML file:")
    grand_total = 0
    for dir_name in sorted(grouped):
        total = sum(len(v) for v in grouped[dir_name].values())
        grand_total += total
        parts = [f"{subcat}: {len(feeds)}" for subcat, feeds in sorted(grouped[dir_name].items())]
        print(f"  {dir_name}/ ({total} feeds)")
        for part in parts:
            print(f"    {part}")

    if args.dry_run:
        print(f"\n🏁 DRY RUN — {grand_total} feeds would be imported. No files modified.")
        return

    # 6. Backup
    if not args.no_backup:
        backup_root = feeds_root.parent / f"{feeds_root.name}.backup.import"
        if backup_root.exists():
            shutil.rmtree(backup_root)
        shutil.copytree(str(feeds_root), str(backup_root))
        print(f"\n💾 Backup: {backup_root.relative_to(feeds_root.parent)}")

    # 7. Append feeds to OPML files
    print(f"\n✍️  Writing {grand_total} new feeds...")
    written = 0
    for dir_name, subcategories in sorted(grouped.items()):
        opml_path = feeds_root / dir_name / f"{dir_name}.opml"
        raw_xml = opml_path.read_text(encoding="utf-8")

        for subcategory, sub_feeds in sorted(subcategories.items()):
            topic = CATEGORY_MAP.get(sub_feeds[0]["category"], ("", "", ""))[1]

            # Build outline entries for these feeds
            outlines = []
            for feed in sorted(sub_feeds, key=lambda f: f.get("title", "").lower()):
                outlines.append(build_outline_xml(feed, topic, subcategory))
            new_content = "\n".join(outlines)

            # Check if this subcategory group already exists
            # Look for <outline text="Subcat" title="Subcat"> (no xmlUrl = group node)
            escaped_name = xml_escape(subcategory)
            group_pattern = f'<outline text="{escaped_name}" title="{escaped_name}">'

            if group_pattern in raw_xml:
                # Existing subcategory — insert feeds before its closing </outline>
                group_pos = raw_xml.find(group_pattern)
                # Find the matching </outline> — we need to track nesting
                # Simple approach: search for the NEXT </outline> after the group
                close_tag = "</outline>"
                close_pos = raw_xml.find(close_tag, group_pos + len(group_pattern))
                if close_pos < 0:
                    print(f"  ❌ Could not find closing </outline> for {subcategory} in {dir_name}")
                    continue
                # Insert before the closing tag, with indentation
                indent = "\n            "
                indented_feeds = indent + new_content.replace("\n", indent)
                raw_xml = raw_xml[:close_pos] + indented_feeds + "\n        " + raw_xml[close_pos:]
                written += len(sub_feeds)
                print(f"  + {dir_name}/  {subcategory}: {len(sub_feeds)} feeds (merged into existing)")
            else:
                # New subcategory — create group before </body>
                body_close_pos = raw_xml.rfind("</body>")
                if body_close_pos < 0:
                    print(f"  ❌ No </body> tag found in {dir_name}")
                    continue
                subcat_block = (
                    f'\n        <outline text="{escaped_name}" title="{escaped_name}">\n'
                    + new_content
                    + "\n        </outline>"
                )
                raw_xml = raw_xml[:body_close_pos] + subcat_block + "\n" + raw_xml[body_close_pos:]
                written += len(sub_feeds)
                print(f"  + {dir_name}/  {subcategory}: {len(sub_feeds)} feeds (new group)")

        # Write back
        opml_path.write_text(raw_xml, encoding="utf-8")

    print(f"\n✅ Import complete: {written} feeds written to {len(grouped)} OPML files")
    print(f"   Backup saved to: Feeds.backup.import/")


if __name__ == "__main__":
    main()
