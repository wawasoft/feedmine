#!/usr/bin/env python3
"""
Integrate discovered radio podcasts into country OPML files.

Reads scripts/feed_discovery/data/radio_podcasts_by_country.json and adds
radio podcast feeds to each country's OPML under a new subcategory
"Radio & Local Podcasts" within "News & Current Affairs".

Usage:
  python scripts/integrate_radio_podcasts.py           # dry-run
  python scripts/integrate_radio_podcasts.py --write   # apply changes
  python scripts/integrate_radio_podcasts.py --write --country br  # single
"""

from __future__ import annotations

import hashlib
import json
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

try:
    from scripts.catalog_identity import compute_source_id
except ModuleNotFoundError:
    from catalog_identity import compute_source_id

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_ROOT / "scripts/feed_discovery/data"
FEEDS_DIR = PROJECT_ROOT / "feedmine/Resources/Feeds/90_countries"
INPUT_PATH = DATA_DIR / "radio_podcasts_by_country.json"


def source_id(url: str) -> str:
    return compute_source_id(url)


def indent_xml(elem: ET.Element, level: int = 0) -> None:
    """Pretty-print XML with 2-space indentation."""
    indent = "\n" + "  " * level
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = indent + "  "
        if not elem.tail or not elem.tail.strip():
            elem.tail = indent
        for child in elem:
            indent_xml(child, level + 1)
        if not child.tail or not child.tail.strip():
            child.tail = indent
    else:
        if level and (not elem.tail or not elem.tail.strip()):
            elem.tail = indent


def integrate_country(
    slug: str,
    candidates: list[dict],
    opml_path: Path,
    dry_run: bool = True,
) -> dict:
    """Add radio podcast feeds to a country's OPML file."""
    if not opml_path.exists():
        return {"slug": slug, "status": "missing_opml", "added": 0, "skipped": 0}

    # Parse OPML
    tree = ET.parse(str(opml_path))
    root = tree.getroot()
    body = root.find("body")
    if body is None:
        return {"slug": slug, "status": "no_body", "added": 0, "skipped": 0}

    # Find or create the "Radio & Local Podcasts" category
    # We add it under "News & Current Affairs" topic
    TOPIC = "News &amp; Current Affairs"
    SUBCATEGORY = "Radio &amp; Local Podcasts"

    # Find the News & Current Affairs topic
    news_topic = None
    for outline in body.findall("outline"):
        if outline.get("text") == TOPIC:
            news_topic = outline
            break

    if news_topic is None:
        # Create the topic if it doesn't exist
        news_topic = ET.SubElement(body, "outline")
        news_topic.set("text", TOPIC)
        news_topic.set("title", TOPIC)

    # Find or create the Radio subcategory
    radio_subcat = None
    for outline in news_topic.findall("outline"):
        if outline.get("text") == SUBCATEGORY:
            radio_subcat = outline
            break

    if radio_subcat is None:
        radio_subcat = ET.SubElement(news_topic, "outline")
        radio_subcat.set("text", SUBCATEGORY)
        radio_subcat.set("title", SUBCATEGORY)

    # Get existing URLs to avoid duplicates
    existing_urls: set[str] = set()
    for outline in body.iter("outline"):
        xml_url = outline.get("xmlUrl", "")
        if xml_url:
            existing_urls.add(xml_url)

    added = 0
    skipped = 0

    for candidate in candidates:
        url = candidate.get("url", "")
        if not url or not url.startswith("http"):
            skipped += 1
            continue

        if url in existing_urls:
            skipped += 1
            continue

        title = candidate.get("title", "") or "Radio Podcast"
        city = candidate.get("city", "")
        source = candidate.get("source", "")
        genre = candidate.get("genre", "")

        # Build description
        if city:
            desc = f"Local radio podcast from {city}"
        else:
            desc = f"Radio station podcast"
        if genre:
            desc += f" covering {genre}"

        # Extract language and category from candidate or use defaults
        language = "en"
        category = f"radio,podcast,{slug.replace('_', ' ')}"
        if city:
            category += f",{city.lower()}"

        # Create outline element
        feed = ET.SubElement(radio_subcat, "outline")
        feed.set("text", title)
        feed.set("title", title)
        feed.set("type", "rss")
        feed.set("xmlUrl", url)
        feed.set("description", desc)
        feed.set("language", language)
        feed.set("category", category)
        feed.set("feedmineSourceId", source_id(url))
        feed.set("feedmineTopic", TOPIC)
        feed.set("feedmineSubcategory", SUBCATEGORY)
        feed.set("feedmineNature", "current-sensitive")
        feed.set("feedmineActivity", "active")
        feed.set("feedmineArticlesFetched", "0")
        feed.set("feedmineQualityScore", "70")
        feed.set("feedmineDefaultEnabled", "true")
        feed.set("feedmineMediaKind", "audio")

        # Add htmlUrl if we have the station website
        station_website = candidate.get("station_website", "")
        if station_website:
            feed.set("htmlUrl", station_website)

        existing_urls.add(url)
        added += 1

    if dry_run:
        return {"slug": slug, "status": "dry_run", "added": added, "skipped": skipped}

    # Write updated OPML
    indent_xml(root)
    # Fix the XML declaration
    xml_str = ET.tostring(root, encoding="unicode")
    # Fix escaped ampersands in topic/subcategory names
    xml_str = xml_str.replace("&amp;amp;", "&amp;")
    declaration = '<?xml version="1.0" encoding="utf-8"?>\n'
    if not xml_str.startswith("<?xml"):
        xml_str = declaration + xml_str

    opml_path.write_text(xml_str, encoding="utf-8")
    return {"slug": slug, "status": "written", "added": added, "skipped": skipped}


def main():
    write_mode = "--write" in sys.argv
    target_country = None

    for i, arg in enumerate(sys.argv):
        if arg == "--country" and i + 1 < len(sys.argv):
            target_country = sys.argv[i + 1]

    if not INPUT_PATH.exists():
        print(f"❌ Input file not found: {INPUT_PATH}")
        print("   Run discover_radio_podcasts.py --write first.")
        sys.exit(1)

    data = json.loads(INPUT_PATH.read_text(encoding="utf-8"))
    countries_data = data.get("countries", {})

    if target_country:
        countries_data = {target_country: countries_data.get(target_country, {})}

    if not write_mode:
        print("DRY RUN — use --write to apply changes\n")

    total_added = 0
    total_skipped = 0
    results = []

    for slug, result in sorted(countries_data.items()):
        candidates = result.get("candidates", [])
        count = result.get("count", 0)
        if count == 0:
            continue

        opml_path = FEEDS_DIR / slug / f"{slug}.opml"

        print(f"📻 {result.get('country_name', slug)} ({slug}): {count} candidates")

        outcome = integrate_country(slug, candidates, opml_path, dry_run=not write_mode)
        results.append(outcome)
        total_added += outcome["added"]
        total_skipped += outcome["skipped"]

        status = outcome["status"]
        if status == "written":
            print(f"   ✅ {outcome['added']} added, {outcome['skipped']} skipped")
        elif status == "dry_run":
            print(f"   🔍 Would add {outcome['added']}, skip {outcome['skipped']}")
        elif status == "missing_opml":
            print(f"   ⚠️ OPML file not found")
        else:
            print(f"   ❌ {status}")

    print(f"\n{'='*60}")
    print(f"SUMMARY: {total_added} feeds added, {total_skipped} duplicates skipped")
    print(f"Countries processed: {len(results)}")


if __name__ == "__main__":
    main()
