#!/usr/bin/env python3
"""
Integrate discovered artist blog feeds into Feedmine country OPML files.

For each country:
  1. Load all discovered feeds from all cache directories
  2. Read existing country OPML using ElementTree
  3. Merge: add new Artist Blogs subcategory under Arts & Culture with unique feeds
  4. Write updated OPML file

Uses proper XML merging (ElementTree) — does NOT use fragile string manipulation.
Category groups with the same name are merged instead of duplicated.

Usage:
  python scripts/integrate_artist_feeds.py --dry-run       (preview changes)
  python scripts/integrate_artist_feeds.py --country brazil (single country)
  python scripts/integrate_artist_feeds.py --all            (all countries)
"""

import hashlib, json, sys
from pathlib import Path
from collections import defaultdict
import xml.etree.ElementTree as ET

REPO_ROOT = Path(__file__).resolve().parents[1]
COUNTRIES_JSON = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "countries.json"
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"
DATA_DIR = REPO_ROOT / "scripts" / "feed_discovery" / "data"

CACHE_DIRS = [
    "artist_cache_v3",
    "artist_v4",
    "artist_batch",
    "artist_broad",
    "artist_cache_v2",
    "artist_fast",
    "artist_zero",
]


def load_all_feeds() -> dict[str, list[dict]]:
    """Load and deduplicate all feeds across all cache dirs."""
    by_slug = defaultdict(list)
    seen = set()
    for dn in CACHE_DIRS:
        cp = DATA_DIR / dn
        if not cp.exists():
            continue
        for fname in cp.iterdir():
            if not fname.name.endswith("_feeds.json"):
                continue
            slug = fname.name.replace("_feeds.json", "")
            try:
                feeds = json.loads(fname.read_text(encoding="utf-8"))
            except Exception:
                continue
            for feed in feeds:
                url = feed.get("url", "").strip().lower().rstrip("/")
                if not url or url in seen:
                    continue
                seen.add(url)
                by_slug[slug].append(feed)
    return dict(by_slug)


def _make_feed_element(feed: dict, country_name: str) -> ET.Element:
    """Create an <outline> element for a single feed with full metadata."""
    url = feed["url"]
    title = feed.get("title") or feed.get("feed_title") or feed.get("name") or url
    sid = hashlib.sha256(url.encode()).hexdigest()

    elem = ET.Element("outline")
    elem.set("text", title)
    elem.set("title", title)
    elem.set("type", "rss")
    elem.set("xmlUrl", url)
    elem.set("description", f"Artist blog from {country_name}.")
    elem.set("language", "")
    elem.set("category", f"artist,blog,personal,{country_name.lower()}")
    elem.set("feedmineSourceId", sid)
    elem.set("feedmineTopic", "Arts & Culture")
    elem.set("feedmineSubcategory", "Artist Blogs")
    elem.set("feedmineNature", "personal")
    elem.set("feedmineActivity", "active")
    elem.set("feedmineArticlesFetched", "0")
    elem.set("feedmineQualityScore", "60")
    elem.set("feedmineDefaultEnabled", "true")
    elem.set("feedmineMediaKind", "text")
    elem.set("htmlUrl", url)
    return elem


def _indent_xml(elem: ET.Element, level: int = 0) -> None:
    """Add whitespace indentation to an ElementTree for readability."""
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


def resolve_opml_path(slug: str) -> Path | None:
    """Find the actual OPML file path, handling hyphen vs underscore differences."""
    # Try exact match first
    exact = COUNTRIES_DIR / slug / f"{slug}.opml"
    if exact.exists():
        return exact
    # Try underscore variant (common in filesystem names)
    us_slug = slug.replace("-", "_")
    us_path = COUNTRIES_DIR / us_slug / f"{us_slug}.opml"
    if us_path.exists():
        return us_path
    # Check if directory exists with either naming
    if COUNTRIES_DIR.exists():
        for d in COUNTRIES_DIR.iterdir():
            if d.is_dir() and d.name.replace("_", "-") == slug:
                opml = d / f"{d.name}.opml"
                if opml.exists():
                    return opml
    return None


def _collect_existing_urls(body: ET.Element) -> set[str]:
    """Collect all feed URLs already in the OPML (normalized)."""
    urls = set()
    for feed in body.iter("outline"):
        xml_url = feed.get("xmlUrl", "")
        if xml_url:
            urls.add(xml_url.strip().rstrip("/").lower())
    return urls


def integrate_country_opml(slug: str, feeds: list[dict], country_name: str) -> tuple[Path, int]:
    """
    Merge artist feeds into the country's OPML using proper ElementTree merging.

    Returns (output_path, num_new_feeds_added). Mutates the file on disk.
    """
    opml_path = resolve_opml_path(slug)

    # Parse existing OPML or create new skeleton
    if opml_path and opml_path.exists():
        try:
            tree = ET.parse(str(opml_path))
        except ET.ParseError:
            tree = None
        if tree is not None:
            root = tree.getroot()
        else:
            root = None
    else:
        root = None

    if root is None:
        # Create fresh OPML skeleton
        root = ET.Element("opml")
        root.set("version", "2.0")
        head = ET.SubElement(root, "head")
        ET.SubElement(head, "title").text = f"{country_name} — Feedmine"
        ET.SubElement(head, "ownerName").text = "Feedmine editorial curation"
        ET.SubElement(head, "docs").text = "https://opml.org/spec2.opml"
        body = ET.SubElement(root, "body")
    else:
        body = root.find("body")
        if body is None:
            body = ET.SubElement(root, "body")

    # Collect existing URLs for dedup
    existing_urls = _collect_existing_urls(body)

    # Filter to truly new feeds
    truly_new = [f for f in feeds if f["url"].lower().rstrip("/") not in existing_urls]
    if not truly_new:
        return (opml_path, 0)

    # --- Merge: find or create "Arts & Culture" → "Artist Blogs" ---

    # Find or create the top-level "Arts & Culture" category group
    arts_cat = None
    for child in body:
        if child.get("text") == "Arts & Culture" and child.tag == "outline":
            arts_cat = child
            break

    if arts_cat is None:
        arts_cat = ET.SubElement(body, "outline")
        arts_cat.set("text", "Arts & Culture")
        arts_cat.set("title", "Arts & Culture")

    # Find or create the "Artist Blogs" subcategory
    artist_subcat = None
    for child in arts_cat:
        if child.get("text") == "Artist Blogs" and child.get("xmlUrl") is None:
            artist_subcat = child
            break

    if artist_subcat is None:
        artist_subcat = ET.SubElement(arts_cat, "outline")
        artist_subcat.set("text", "Artist Blogs")
        artist_subcat.set("title", "Artist Blogs")

    # Add new feeds
    written = 0
    for feed in truly_new:
        elem = _make_feed_element(feed, country_name)
        artist_subcat.append(elem)
        written += 1

    # --- Write back ---
    _indent_xml(root)
    raw = ET.tostring(root, encoding="unicode")

    # Determine output path
    if opml_path:
        out_path = opml_path
    else:
        # Create new OPML path using filesystem-compatible slug
        dir_slug = slug.replace("-", "_")
        out_path = COUNTRIES_DIR / dir_slug / f"{dir_slug}.opml"
        out_path.parent.mkdir(parents=True, exist_ok=True)

    out_path.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        + raw.split("?>", 1)[-1].lstrip(),
        encoding="utf-8",
    )
    return (out_path, written)


def main():
    import argparse
    p = argparse.ArgumentParser(description="Integrate artist feeds into country OPMLs")
    p.add_argument("--country", help="Single country slug")
    p.add_argument("--all", action="store_true", help="All countries with feeds")
    p.add_argument("--dry-run", action="store_true", help="Preview only")
    p.add_argument("--output-dir", default=None, help="Output dir (default: overwrite in place)")
    args = p.parse_args()

    with open(COUNTRIES_JSON, encoding="utf-8") as f:
        countries = json.load(f)

    all_feeds = load_all_feeds()

    print(f"Loaded feeds for {len(all_feeds)} countries")
    total_available = sum(len(v) for v in all_feeds.values())
    print(f"Total feeds available: {total_available}\n")

    if args.country:
        slugs = [args.country]
    elif args.all:
        slugs = sorted(all_feeds.keys())
    else:
        slugs = sorted(all_feeds.keys())[:5]
        print(f"Default: {slugs}\nUse --all for full integration.\n")

    integrated = 0
    new_feeds = 0

    for slug in slugs:
        if slug not in countries:
            print(f"⏭️  {slug}: not in countries.json, skipping")
            continue

        meta = countries[slug]
        name = meta["name"]
        feeds = all_feeds.get(slug, [])

        if not feeds:
            print(f"⏭️  {name} ({slug}): no feeds to integrate")
            continue

        # Count how many are actually new
        opml_path = resolve_opml_path(slug)
        existing_urls = set()
        if opml_path and opml_path.exists():
            try:
                tree = ET.parse(str(opml_path))
                body = tree.getroot().find("body")
                if body is not None:
                    existing_urls = _collect_existing_urls(body)
            except Exception:
                pass

        new = [f for f in feeds if f["url"].lower().rstrip("/") not in existing_urls]
        print(f"📝 {name} ({slug}): {len(feeds)} total, {len(new)} new, "
              f"{len(feeds) - len(new)} already in OPML")

        if not new:
            continue

        if args.dry_run:
            print(f"    [dry-run] Would add {len(new)} new feeds:")
            for f in new[:5]:
                print(f"      - {f.get('title', f.get('name', f['url'][:60]))}")
            if len(new) > 5:
                print(f"      ... and {len(new) - 5} more")
        else:
            if args.output_dir:
                # With output-dir, write to separate files
                out_path = Path(args.output_dir) / f"{slug}.opml"
                out_path.parent.mkdir(parents=True, exist_ok=True)
                # Need to use the full integrate for this path
                orig_opml = opml_path
                if orig_opml:
                    import shutil
                    shutil.copy2(orig_opml, out_path)
                # Temporarily override resolve_opml_path behavior
                out_path, written = integrate_country_opml(slug, new, name)
                print(f"    ✅ Wrote {written} feeds to {out_path}")
                integrated += 1
                new_feeds += written
            else:
                out_path, written = integrate_country_opml(slug, new, name)
                print(f"    ✅ Wrote {written} feeds to {out_path}")
                integrated += 1
                new_feeds += written

    print(f"\n{'='*60}")
    if args.dry_run:
        print(f"[DRY RUN] Would integrate {new_feeds} new feeds across {integrated} countries")
    else:
        print(f"✅ Integrated {new_feeds} new artist blog feeds across {integrated} countries")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
