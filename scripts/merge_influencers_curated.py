#!/usr/bin/env python3
"""
Merge influencers_curated.json into production country OPMLs.

Each influencer has country_slugs — adds the feed to ALL listed countries.
Places feeds under "General Interests → Global Influencers".

Usage:
  python scripts/merge_influencers_curated.py --dry-run
  python scripts/merge_influencers_curated.py --write
"""

from __future__ import annotations

import hashlib, json, os, sys
from pathlib import Path
import xml.etree.ElementTree as ET

REPO_ROOT = Path(__file__).resolve().parents[1]
INFLUENCERS_JSON = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "influencers_curated.json"
PRODUCTION = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"


def normalize_url(url: str) -> str:
    if not url: return ""
    return url.strip().rstrip("/").lower().replace("https://", "").replace("http://", "").replace("www.", "")


def source_id(url: str) -> str:
    return hashlib.sha256(url.encode()).hexdigest()


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


def resolve_country_dir(country_slug: str) -> Path | None:
    us_slug = country_slug.replace("-", "_")
    us_path = PRODUCTION / us_slug
    if us_path.is_dir() and (us_path / f"{us_slug}.opml").exists():
        return us_path
    hy_path = PRODUCTION / country_slug
    if hy_path.is_dir() and (hy_path / f"{country_slug}.opml").exists():
        return hy_path
    if PRODUCTION.exists():
        for d in sorted(PRODUCTION.iterdir()):
            if d.is_dir() and d.name.replace("_", "-") == country_slug:
                opml = d / f"{d.name}.opml"
                if opml.exists():
                    return d
    return None


def collect_existing_urls(body: ET.Element) -> set[str]:
    urls = set()
    for el in body.iter("outline"):
        u = el.get("xmlUrl", "")
        if u: urls.add(normalize_url(u))
    return urls


def main():
    write_mode = "--write" in sys.argv
    if not write_mode:
        print("🔍 DRY RUN — use --write to apply\n")

    # Load influencers
    data = json.loads(INFLUENCERS_JSON.read_text(encoding="utf-8"))
    entries = data["entries"]
    print(f"Loaded {len(entries)} influencers\n")

    # Index existing country OPMLs
    country_feeds = {}  # country_slug → set of normalized URLs
    country_trees = {}  # country_slug → (tree, body)

    for country_dir in sorted(PRODUCTION.iterdir()):
        if not country_dir.is_dir(): continue
        slug = country_dir.name
        opml = country_dir / f"{slug}.opml"
        if not opml.exists(): continue
        try:
            tree = ET.parse(str(opml))
            body = tree.find("body")
            if body is None: continue
            urls = collect_existing_urls(body)
            country_feeds[slug] = urls
            country_trees[slug] = (tree, body)
        except ET.ParseError:
            pass

    print(f"Indexed {len(country_feeds)} country OPMLs\n")

    # Process each influencer
    total_added = 0
    countries_updated = set()
    skipped_already = 0

    for entry in entries:
        url = entry.get("feed_url", "").strip()
        if not url: continue
        title = entry.get("title", "") or url
        genre = entry.get("genre", "") or "influencer"
        html_url = entry.get("html_url", "") or ""
        media = entry.get("media_kind", "video")
        country_slugs = entry.get("country_slugs", [])

        norm = normalize_url(url)

        for cs in country_slugs:
            # Resolve filesystem slug
            fs_slug = cs.replace("-", "_")
            urls = country_feeds.get(fs_slug)
            if urls is None:
                continue  # country OPML not found

            if norm in urls:
                skipped_already += 1
                continue

            tree, body = country_trees[fs_slug]

            # Find or create topic
            topic_elem = None
            for child in body:
                if child.get("text") == "General Interests":
                    topic_elem = child
                    break
            if topic_elem is None:
                topic_elem = ET.SubElement(body, "outline")
                topic_elem.set("text", "General Interests")
                topic_elem.set("title", "General Interests")

            # Find or create subcategory
            subcat = None
            for child in topic_elem:
                if child.get("text") == "Global Influencers" and child.get("xmlUrl") is None:
                    subcat = child
                    break
            if subcat is None:
                subcat = ET.SubElement(topic_elem, "outline")
                subcat.set("text", "Global Influencers")
                subcat.set("title", "Global Influencers")

            # Build feed element
            elem = ET.SubElement(subcat, "outline")
            elem.set("text", str(title)[:200])
            elem.set("title", str(title)[:200])
            elem.set("type", "rss")
            elem.set("xmlUrl", url)
            elem.set("description", f"Global influencer — {genre}")
            elem.set("language", entry.get("language", ""))
            elem.set("category", str(genre)[:300])
            elem.set("feedmineSourceId", source_id(url))
            elem.set("feedmineTopic", "General Interests")
            elem.set("feedmineSubcategory", "Global Influencers")
            elem.set("feedmineNature", "periodic")
            elem.set("feedmineActivity", "prolific")
            elem.set("feedmineArticlesFetched", "0")
            elem.set("feedmineQualityScore", str(entry.get("quality", "60")))
            elem.set("feedmineDefaultEnabled", "true")
            elem.set("feedmineMediaKind", media)
            if html_url:
                elem.set("htmlUrl", html_url)

            urls.add(norm)  # prevent double-add for same country
            total_added += 1
            countries_updated.add(fs_slug)

    # Write back
    if write_mode:
        for fs_slug in countries_updated:
            tree, body = country_trees[fs_slug]
            indent_xml(tree.getroot())
            raw = ET.tostring(tree.getroot(), encoding="unicode")
            opml_path = PRODUCTION / fs_slug / f"{fs_slug}.opml"
            opml_path.write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                + raw.split("?>", 1)[-1].lstrip(),
                encoding="utf-8",
            )
        status = "✅"
    else:
        status = "🔧"

    print(f"{status} Influencers: {len(entries)} total")
    print(f"{status} Feeds added: {total_added:,} (across {len(countries_updated)} countries)")
    print(f"{status} Already in OPML: {skipped_already:,}")
    if not write_mode:
        print("\n🔍 DRY RUN complete. Use --write to apply.")
    else:
        print("✅ Merge complete.")


if __name__ == "__main__":
    main()
