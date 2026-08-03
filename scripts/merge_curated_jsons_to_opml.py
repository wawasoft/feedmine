#!/usr/bin/env python3
"""
Merge curated JSON feeds into production 90_countries/ OPMLs.

Reads curated JSONs from scripts/feed_discovery/data/curated/{artists,museums,universities}/
and inserts new feeds into production OPMLs under the correct topic + subcategory.

Rules:
  - artists  → Arts & Culture / Artist Blogs     (is_live=True verified)
  - museums  → Arts & Culture / Museums           (YouTube channels, always work)
  - universities → Education & Knowledge / Universities (YouTube channels)

Skips feeds already present (URL dedup, normalized).
Idempotent — safe to run multiple times.

Usage:
  python scripts/merge_curated_jsons_to_opml.py --dry-run
  python scripts/merge_curated_jsons_to_opml.py --write
  python scripts/merge_curated_jsons_to_opml.py --write --category artists
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

REPO_ROOT = Path(__file__).resolve().parents[1]
CURATED_DIR = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "curated"
PRODUCTION = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"

# Maps curated category → (OPML topic, OPML subcategory, nature, quality)
CATEGORY_CONFIG = {
    "artists": {
        "topic": "Arts & Culture",
        "subcategory": "Artist Blogs",
        "nature": "personal",
        "quality": "65",
        "activity": "active",
        "media_kind": "text",
        "default_enabled": "true",
    },
    "museums": {
        "topic": "Arts & Culture",
        "subcategory": "Museums",
        "nature": "evergreen",
        "quality": "55",
        "activity": "quiet",
        "media_kind": "video",
        "default_enabled": "true",
    },
    "universities": {
        "topic": "Education & Knowledge",
        "subcategory": "Universities",
        "nature": "evergreen",
        "quality": "55",
        "activity": "quiet",
        "media_kind": "video",
        "default_enabled": "true",
    },
}


def normalize_url(url: str) -> str:
    """Normalize URL for dedup comparison."""
    if not url:
        return ""
    return url.strip().rstrip("/").lower().replace("https://", "").replace("http://", "").replace("www.", "")


def source_id(url: str) -> str:
    return hashlib.sha256(url.encode()).hexdigest()


def indent_xml(elem: ET.Element, level: int = 0) -> None:
    """Pretty-print XML with 2-space indentation."""
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


def resolve_country_dir(country_slug: str) -> Path | None:
    """
    Find the country directory under 90_countries/.
    Handles hyphen → underscore conversion in directory names.
    """
    prod_base = PRODUCTION

    # Try with underscore (filesystem convention)
    us_slug = country_slug.replace("-", "_")
    us_path = prod_base / us_slug
    if us_path.is_dir() and (us_path / f"{us_slug}.opml").exists():
        return us_path

    # Try with original hyphen
    hy_path = prod_base / country_slug
    if hy_path.is_dir() and (hy_path / f"{country_slug}.opml").exists():
        return hy_path

    # Search by normalizing
    if prod_base.exists():
        for d in sorted(prod_base.iterdir()):
            if d.is_dir() and d.name.replace("_", "-") == country_slug:
                opml = d / f"{d.name}.opml"
                if opml.exists():
                    return d

    return None


def collect_existing_urls(body: ET.Element) -> set[str]:
    """Collect all normalized feed URLs already in the OPML."""
    urls = set()
    for el in body.iter("outline"):
        u = el.get("xmlUrl", "")
        if u:
            urls.add(normalize_url(u))
    return urls


def build_feed_element(feed: dict, config: dict, country_slug: str, country_name: str) -> ET.Element:
    """Build an <outline> element for a curated feed."""
    url = feed.get("url", "")
    title = feed.get("title", "") or url
    genre = feed.get("genre", "") or config["subcategory"]
    source_page = feed.get("source_page", "") or ""
    category_tag = feed.get("category", "") or genre

    elem = ET.Element("outline")
    elem.set("text", str(title)[:200])
    elem.set("title", str(title)[:200])
    elem.set("type", "rss")
    elem.set("xmlUrl", url)
    elem.set("description", f"{genre} from {country_name}.")
    elem.set("language", "")
    elem.set("category", str(category_tag)[:300])
    elem.set("feedmineSourceId", source_id(url))
    elem.set("feedmineTopic", config["topic"])
    elem.set("feedmineSubcategory", config["subcategory"])
    elem.set("feedmineNature", config["nature"])
    elem.set("feedmineActivity", config["activity"])
    elem.set("feedmineArticlesFetched", "0")
    elem.set("feedmineQualityScore", config["quality"])
    elem.set("feedmineDefaultEnabled", config["default_enabled"])
    elem.set("feedmineMediaKind", config["media_kind"])

    if source_page:
        elem.set("htmlUrl", source_page)

    return elem


def merge_category(
    category: str,
    write_mode: bool = False,
    countries_filter: list[str] | None = None,
) -> tuple[int, int]:
    """
    Merge all feeds from a curated category into production OPMLs.

    Returns (countries_updated, feeds_added).
    """
    config = CATEGORY_CONFIG[category]
    cat_dir = CURATED_DIR / category

    if not cat_dir.is_dir():
        print(f"  ❌ Directory not found: {cat_dir}")
        return (0, 0)

    # Load countries metadata for name mapping
    countries_json = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "countries.json"
    with open(countries_json, encoding="utf-8") as f:
        countries_meta = json.load(f)

    total_added = 0
    countries_updated = 0
    skipped_duplicate = 0
    skipped_no_country = 0
    skipped_no_opml = 0

    json_files = sorted(cat_dir.glob("*.json"))
    json_files = [f for f in json_files if f.name != ".progress"]

    for json_path in json_files:
        country_slug = json_path.stem  # e.g. "brazil"

        if countries_filter and country_slug not in countries_filter:
            continue

        # Load feeds
        try:
            feeds = json.loads(json_path.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"  ⚠️  {country_slug}: failed to load JSON: {e}")
            continue

        if not isinstance(feeds, list) or not feeds:
            continue

        # Resolve country OPML
        country_dir = resolve_country_dir(country_slug)
        if country_dir is None:
            skipped_no_opml += len(feeds)
            continue

        country_name = country_dir.name  # filesystem name
        opml_path = country_dir / f"{country_name}.opml"

        # Also look up display name from countries.json
        display_name = countries_meta.get(country_slug, {}).get("name", country_slug.title())

        # Parse OPML
        try:
            tree = ET.parse(str(opml_path))
        except ET.ParseError:
            print(f"  ⚠️  {country_slug}: XML parse error, skipping")
            continue

        root = tree.getroot()
        body = root.find("body")
        if body is None:
            body = ET.SubElement(root, "body")

        existing_urls = collect_existing_urls(body)

        # Filter to new feeds
        new_feeds = []
        for feed in feeds:
            if not isinstance(feed, dict):
                continue
            url = feed.get("url", "")
            if not url:
                continue
            if normalize_url(url) in existing_urls:
                skipped_duplicate += 1
                continue
            new_feeds.append(feed)
            existing_urls.add(normalize_url(url))  # prevent self-dupes

        if not new_feeds:
            continue

        # --- Find or create topic section ---
        topic_elem = None
        for child in body:
            if child.get("text") == config["topic"] and child.tag == "outline":
                topic_elem = child
                break

        if topic_elem is None:
            topic_elem = ET.SubElement(body, "outline")
            topic_elem.set("text", config["topic"])
            topic_elem.set("title", config["topic"])

        # --- Find or create subcategory ---
        subcat_elem = None
        for child in topic_elem:
            if child.get("text") == config["subcategory"] and child.get("xmlUrl") is None:
                subcat_elem = child
                break

        if subcat_elem is None:
            subcat_elem = ET.SubElement(topic_elem, "outline")
            subcat_elem.set("text", config["subcategory"])
            subcat_elem.set("title", config["subcategory"])

        # --- Add feeds ---
        for feed in new_feeds:
            elem = build_feed_element(feed, config, country_slug, display_name)
            subcat_elem.append(elem)
            total_added += 1

        # --- Write back ---
        if write_mode:
            indent_xml(root)
            raw = ET.tostring(root, encoding="unicode")
            opml_path.write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                + raw.split("?>", 1)[-1].lstrip(),
                encoding="utf-8",
            )

        countries_updated += 1
        status = "✅" if write_mode else "🔧"
        print(f"  {status} {country_slug}: +{len(new_feeds)} {category} feeds")

    print(f"\n  Category: {category}")
    print(f"  Countries updated: {countries_updated}")
    print(f"  Feeds added:       {total_added:,}")
    print(f"  Duplicates skipped: {skipped_duplicate:,}")
    print(f"  Skipped (no OPML):  {skipped_no_opml:,}")

    return (countries_updated, total_added)


def main():
    import argparse
    p = argparse.ArgumentParser(description="Merge curated JSON feeds into production OPMLs")
    p.add_argument("--dry-run", action="store_true", default=True,
                   help="Preview only (default)")
    p.add_argument("--write", action="store_true",
                   help="Apply changes to OPML files")
    p.add_argument("--category", choices=list(CATEGORY_CONFIG.keys()),
                   help="Process a single category")
    p.add_argument("--country", help="Process a single country slug")
    args = p.parse_args()

    write_mode = args.write

    if not write_mode:
        print("🔍 DRY RUN — use --write to apply changes\n")
    else:
        print("✍️  WRITE MODE — will modify production OPMLs\n")

    categories = [args.category] if args.category else list(CATEGORY_CONFIG.keys())
    countries_filter = [args.country] if args.country else None

    grand_countries = 0
    grand_feeds = 0

    for cat in categories:
        print(f"{'='*60}")
        print(f"📂 {cat.upper()}")
        print(f"{'='*60}")
        countries, feeds = merge_category(cat, write_mode, countries_filter)
        grand_countries += countries
        grand_feeds += feeds

    print(f"\n{'='*60}")
    print(f"🏁 TOTAL: {grand_feeds:,} feeds across {grand_countries} countries")
    if not write_mode:
        print("🔍 DRY RUN complete. Use --write to apply.")
    else:
        print("✅ Merge complete.")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
