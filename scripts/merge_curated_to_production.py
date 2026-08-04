#!/usr/bin/env python3
"""
Merge curated feeds from the Parquet corpus into production 90_countries/ OPMLs.

Reads the sources + memberships Parquet files, maps each source to its country,
and inserts it into the correct 90_countries/ OPML under the appropriate topic
category. Skips feeds already present (URL dedup).

Usage:
    python scripts/merge_curated_to_production.py --dry-run
    python scripts/merge_curated_to_production.py --write
"""

from __future__ import annotations

import hashlib, sys
from pathlib import Path
from collections import defaultdict
import xml.etree.ElementTree as ET

try:
    from scripts.catalog_identity import compute_source_id
except ModuleNotFoundError:
    from catalog_identity import compute_source_id

REPO_ROOT = Path(__file__).resolve().parents[1]
PRODUCTION = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"
SOURCES_PARQUET = REPO_ROOT / "feeds_corpus_sources.parquet"
MEMBERSHIPS_PARQUET = REPO_ROOT / "feeds_corpus_source_memberships.parquet"


def _indent_xml(elem: ET.Element, level: int = 0) -> None:
    indent = "\n" + "  " * level
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = indent + "  "
        if not elem.tail or not elem.tail.strip():
            elem.tail = indent
        for sub in elem:
            _indent_xml(sub, level + 1)
        if not elem[-1].tail or not elem[-1].tail.strip():
            elem[-1].tail = indent
    else:
        if level and (not elem.tail or not elem.tail.strip()):
            elem.tail = indent


def main():
    import pandas as pd

    write_mode = "--write" in sys.argv
    if not write_mode:
        print("🔍 DRY RUN — use --write to apply\n")

    # Load sources
    sources = pd.read_parquet(SOURCES_PARQUET)
    memberships = pd.read_parquet(MEMBERSHIPS_PARQUET)

    # Only process "done" sources
    done = sources[sources["status"] == "done"].copy()
    print(f"Sources done: {len(done)} / {len(sources)}")

    # Join with memberships to get country
    merged = done.merge(memberships, on="source_id", how="inner")
    # Keep only country feeds (from 90_countries, _staging, _archived_countries, countries)
    country_feeds = merged[merged["collection"].isin(
        ["90_countries", "_staging", "_archived_countries", "countries"]
    )].copy()

    country_feeds["country_slug"] = country_feeds["claimed_country"].apply(
        lambda x: str(x).replace("-", "_") if isinstance(x, str) and x else ""
    )
    country_feeds = country_feeds[country_feeds["country_slug"] != ""]

    print(f"Country feeds: {len(country_feeds)}")
    print(f"Unique countries: {country_feeds['country_slug'].nunique()}")

    if len(country_feeds) == 0:
        print("No country feeds to merge. Run the fetcher first.")
        return

    total_added = 0
    countries_updated = 0
    skipped_duplicate = 0

    for country_slug, group in country_feeds.groupby("country_slug"):
        prod_opml = PRODUCTION / country_slug / f"{country_slug}.opml"
        if not prod_opml.exists():
            continue

        # Parse production OPML
        try:
            p_tree = ET.parse(str(prod_opml))
        except ET.ParseError:
            continue
        p_root = p_tree.getroot()
        p_body = p_root.find("body")
        if p_body is None:
            continue

        # Collect existing URLs
        existing = set()
        for o in p_body.iter("outline"):
            u = o.get("xmlUrl", "")
            if u:
                existing.add(u.strip().rstrip("/").lower())

        # Track URLs added this batch to prevent self-duplicates
        added_this_batch = set()

        country_written = 0

        for _, row in group.iterrows():
            url = row.get("xml_url", "")
            if not url:
                continue
            url_norm = url.strip().rstrip("/").lower()
            if url_norm in existing or url_norm in added_this_batch:
                skipped_duplicate += 1
                continue

            title = row.get("source_title", "") or row.get("feed_title", "") or url
            # For staging feeds, the raw membership topic is the country slug.
            # Use "General Interests" — the curator classifies topics properly.
            topic = "General Interests"

            # Find or create topic category in production OPML
            topic_elem = None
            for child in p_body:
                if child.get("text") == topic:
                    topic_elem = child
                    break
            if topic_elem is None:
                topic_elem = ET.SubElement(p_body, "outline")
                topic_elem.set("text", topic)
                topic_elem.set("title", topic)

            # Find or create "Curated Feeds" subcategory
            subcat = None
            for child in topic_elem:
                if child.get("text") == "Curated Feeds" and child.get("xmlUrl") is None:
                    subcat = child
                    break
            if subcat is None:
                subcat = ET.SubElement(topic_elem, "outline")
                subcat.set("text", "Curated Feeds")
                subcat.set("title", "Curated Feeds")

            # Build feed element
            sid = compute_source_id(url)
            elem = ET.SubElement(subcat, "outline")
            elem.set("text", str(title)[:200])
            elem.set("title", str(title)[:200])
            elem.set("type", "rss")
            elem.set("xmlUrl", url)

            desc = row.get("ai_description", "")
            if desc and not pd.isna(desc) and str(desc).strip():
                elem.set("description", str(desc)[:500])

            lang = row.get("feed_reported_language", "")
            if lang and not pd.isna(lang):
                elem.set("language", str(lang))

            tags = row.get("ai_tags", "")
            if tags and not pd.isna(tags) and str(tags).strip():
                elem.set("category", str(tags))

            elem.set("feedmineSourceId", sid)
            elem.set("feedmineTopic", str(topic))
            elem.set("feedmineSubcategory", "Curated Feeds")
            elem.set("feedmineNature", "current-sensitive")
            elem.set("feedmineActivity", "active")
            elem.set("feedmineArticlesFetched", str(int(row.get("articles_fetched", 0) or 0)))
            elem.set("feedmineQualityScore", "60" if desc and str(desc).strip() else "50")
            elem.set("feedmineDefaultEnabled", "true")

            media = "mixed"
            ct = str(row.get("content_type", "")).lower()
            if "audio" in ct: media = "audio"
            elif "video" in ct: media = "video"
            elif "text" in ct or "rss" in ct or "xml" in ct or "html" in ct: media = "text"
            elem.set("feedmineMediaKind", media)

            site = row.get("site_url", "")
            if site and not pd.isna(site):
                elem.set("htmlUrl", str(site))

            country_written += 1
            added_this_batch.add(url_norm)

        if write_mode and country_written > 0:
            _indent_xml(p_root)
            raw = ET.tostring(p_root, encoding="unicode")
            prod_opml.write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                + raw.split("?>", 1)[-1].lstrip(),
                encoding="utf-8",
            )

        if country_written > 0:
            total_added += country_written
            countries_updated += 1
            status = "✅" if write_mode else "🔧"
            print(f"  {status} {country_slug}: +{country_written} feeds")

    print(f"\n{'='*60}")
    print(f"Countries updated: {countries_updated}")
    print(f"Feeds added:       {total_added:,}")
    print(f"Duplicates skipped:{skipped_duplicate:,}")
    if not write_mode:
        print("\n🔍 DRY RUN complete. Use --write to apply.")
    else:
        print("✅ Merge complete.")


if __name__ == "__main__":
    main()
