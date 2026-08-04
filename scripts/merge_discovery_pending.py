#!/usr/bin/env python3
"""
Merge discovery_pending.opml "done" feeds into production OPMLs.

Reads discovery_pending.opml, cross-references with the parquet for status="done"
feeds, and merges them directly into the appropriate topic OPMLs (not country OPMLs,
since these feeds lack country assignments). Topic OPMLs provide global visibility.

Mapping:
  youtubersme    → Music & Audio / YouTube Discovery
  watch_history  → General Interests / Watch History
  newspapers     → News & Current Affairs / Discovery
  artist_candidates → Arts & Culture / Artist Discovery

Usage:
  python scripts/merge_discovery_pending.py --dry-run
  python scripts/merge_discovery_pending.py --write
"""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

import pandas as pd

try:
    from scripts.catalog_identity import canonical_url, compute_source_id
except ModuleNotFoundError:
    from catalog_identity import canonical_url, compute_source_id

REPO_ROOT = Path(__file__).resolve().parents[1]
PENDING_OPML = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "discovery_pending.opml"
PARQUET_PATH = REPO_ROOT / "feeds_corpus_sources.parquet"
TOPICS_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds"

# Map pending sections → (topic OPML dir, subcategory, media_kind)
SECTION_CONFIG = {
    "youtubersme": {
        "topic_dir": "16_Music_&_Audio",
        "topic_name": "Music & Audio",
        "subcategory": "YouTube Discovery",
        "media_kind": "video",
        "nature": "periodic",
        "quality": "55",
        "activity": "quiet",
        "default_enabled": "true",
    },
    "watch_history": {
        "topic_dir": "17_General_Interests",
        "topic_name": "General Interests",
        "subcategory": "Watch History",
        "media_kind": "video",
        "nature": "personal",
        "quality": "50",
        "activity": "quiet",
        "default_enabled": "false",
    },
    "newspapers": {
        "topic_dir": "01_News_&_Current_Affairs",
        "topic_name": "News & Current Affairs",
        "subcategory": "Discovery",
        "media_kind": "text",
        "nature": "current-sensitive",
        "quality": "50",
        "activity": "active",
        "default_enabled": "true",
    },
    "artist_candidates": {
        "topic_dir": "02_Arts_&_Culture",
        "topic_name": "Arts & Culture",
        "subcategory": "Artist Discovery",
        "media_kind": "mixed",
        "nature": "personal",
        "quality": "55",
        "activity": "active",
        "default_enabled": "true",
    },
}


def normalize_url(url: str) -> str:
    return canonical_url(url)


def source_id(url: str) -> str:
    return compute_source_id(url)


def indent_xml(elem: ET.Element, level: int = 0) -> None:
    indent = "\n" + "  " * level
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = indent + "  "
        if not elem.tail or not elem.tail.strip():
            elem.tail = indent
        for sub in elem:
            indent_xml(sub, level + 1)
        if not elem[-1].tail or not elem[-1].tail.strip():
            elem[-1].tail = indent
    else:
        if level and (not elem.tail or not elem.tail.strip()):
            elem.tail = indent


def collect_existing_urls(body: ET.Element) -> set[str]:
    urls = set()
    for el in body.iter("outline"):
        u = el.get("xmlUrl", "")
        if u:
            urls.add(normalize_url(u))
    return urls


def build_feed_element(feed_info: dict, config: dict) -> ET.Element:
    url = feed_info["xml_url"]
    title = feed_info.get("title") or feed_info.get("feed_title") or url
    cat_tag = config["subcategory"].lower().replace(" ", ", ")

    elem = ET.Element("outline")
    elem.set("text", str(title)[:200])
    elem.set("title", str(title)[:200])
    elem.set("type", "rss")
    elem.set("xmlUrl", url)
    elem.set("description", f"Discovered feed — {config['subcategory']}.")
    elem.set("language", "")
    elem.set("category", cat_tag)
    elem.set("feedmineSourceId", source_id(url))
    elem.set("feedmineTopic", config["topic_name"])
    elem.set("feedmineSubcategory", config["subcategory"])
    elem.set("feedmineNature", config["nature"])
    elem.set("feedmineActivity", config["activity"])
    elem.set("feedmineArticlesFetched", str(feed_info.get("articles_fetched", "0") or 0))
    elem.set("feedmineQualityScore", config["quality"])
    elem.set("feedmineDefaultEnabled", config["default_enabled"])
    elem.set("feedmineMediaKind", config["media_kind"])

    html = feed_info.get("site_url", "")
    if html and pd.notna(html) and str(html).strip():
        elem.set("htmlUrl", str(html)[:500])

    return elem


def main():
    write_mode = "--write" in sys.argv
    if not write_mode:
        print("🔍 DRY RUN — use --write to apply\n")

    # --- Load parquet ---
    df = pd.read_parquet(PARQUET_PATH)
    print(f"Parquet: {len(df):,} rows")

    # Index parquet by URL for quick lookup
    parquet_by_url = {}
    for _, row in df.iterrows():
        url = row.get("xml_url", "")
        if pd.notna(url) and row["status"] == "done":
            parquet_by_url[normalize_url(url)] = row

    print(f"Parquet done feeds: {len(parquet_by_url):,}")

    # --- Parse discovery_pending ---
    tree = ET.parse(PENDING_OPML)
    body = tree.find("body")

    sections = {}
    for outline in body.findall("outline"):
        section = outline.get("text", "unknown")
        feeds = []
        for f in outline.findall("outline"):
            u = f.get("xmlUrl", "")
            feeds.append({
                "xml_url": u,
                "title": f.get("title") or f.get("text", ""),
            })
        sections[section] = feeds

    # --- Process each section ---
    grand_total = 0
    grand_added = 0

    for section, config in SECTION_CONFIG.items():
        if section not in sections:
            continue

        topic_dir = TOPICS_DIR / config["topic_dir"]
        opml_path = topic_dir / f"{config['topic_dir']}.opml"

        if not opml_path.exists():
            print(f"  ❌ OPML not found: {opml_path}")
            continue

        # Parse topic OPML
        try:
            topic_tree = ET.parse(str(opml_path))
        except ET.ParseError:
            print(f"  ❌ Parse error: {opml_path}")
            continue

        topic_root = topic_tree.getroot()
        topic_body = topic_root.find("body")
        if topic_body is None:
            topic_body = ET.SubElement(topic_root, "body")

        existing_urls = collect_existing_urls(topic_body)

        # Find done feeds for this section
        pending_feeds = sections[section]
        new_feeds = []

        for feed in pending_feeds:
            url = feed["xml_url"]
            n = normalize_url(url)
            if not n or n in existing_urls:
                continue

            row = parquet_by_url.get(n)
            if row is None:
                continue  # not done yet, skip

            # Enrich with parquet data
            feed_info = {
                "xml_url": url,
                "title": feed["title"] or row.get("feed_title", "") or row.get("source_title", ""),
                "feed_title": row.get("feed_title", ""),
                "site_url": row.get("site_url", ""),
                "articles_fetched": row.get("articles_fetched", 0),
            }
            new_feeds.append(feed_info)
            existing_urls.add(n)

        if not new_feeds:
            print(f"  {section}: 0 new (all in topic OPML or not done)")
            continue

        # Find or create subcategory
        subcat = None
        for child in topic_body:
            if child.get("text") == config["subcategory"] and child.get("xmlUrl") is None:
                subcat = child
                break

        if subcat is None:
            subcat = ET.SubElement(topic_body, "outline")
            subcat.set("text", config["subcategory"])
            subcat.set("title", config["subcategory"])

        # Add feeds
        for feed_info in new_feeds:
            elem = build_feed_element(feed_info, config)
            subcat.append(elem)

        if write_mode:
            indent_xml(topic_root)
            raw = ET.tostring(topic_root, encoding="unicode")
            opml_path.write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                + raw.split("?>", 1)[-1].lstrip(),
                encoding="utf-8",
            )

        status = "✅" if write_mode else "🔧"
        print(f"  {status} {section}: +{len(new_feeds)} → {config['topic_dir']}/{config['subcategory']}")

        grand_total += len(pending_feeds)
        grand_added += len(new_feeds)

    print(f"\n{'='*60}")
    print(f"Pending feeds in sections: {grand_total:,}")
    print(f"Newly merged (done):      {grand_added:,}")
    if not write_mode:
        print("🔍 DRY RUN complete. Use --write to apply.")
    else:
        print("✅ Merge complete.")


if __name__ == "__main__":
    main()
