#!/usr/bin/env python3
"""
Integrate discovered artist blog feeds into Feedmine country OPML files.

For each country:
  1. Load all discovered feeds from all cache directories
  2. Read existing country OPML
  3. Merge: add new Artist Blogs subcategory with unique feeds
  4. Write updated OPML file

Usage:
  python scripts/integrate_artist_feeds.py --dry-run       (preview changes)
  python scripts/integrate_artist_feeds.py --country brazil (single country)
  python scripts/integrate_artist_feeds.py --all            (all countries)
"""

import hashlib, json, os, re, sys
from pathlib import Path
from collections import defaultdict

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


def generate_outline_entry(feed: dict, country_name: str) -> str:
    """Generate a single <outline> element for a feed."""
    url = feed["url"]
    title = feed.get("title") or feed.get("feed_title") or feed.get("name") or url
    te = title.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
    ue = url.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
    sid = hashlib.sha256(url.encode()).hexdigest()

    return (
        f'      <outline text="{te}" title="{te}" '
        f'type="rss" xmlUrl="{ue}" '
        f'description="Artist blog from {country_name}." '
        f'language="" '
        f'category="artist,blog,personal,{country_name.lower()}" '
        f'feedmineSourceId="{sid}" '
        f'feedmineTopic="Arts &amp; Culture" '
        f'feedmineSubcategory="Artist Blogs" '
        f'feedmineNature="personal" '
        f'feedmineActivity="active" '
        f'feedmineArticlesFetched="0" '
        f'feedmineQualityScore="60" '
        f'feedmineDefaultEnabled="true" '
        f'feedmineMediaKind="text" '
        f'htmlUrl="{ue}" />'
    )


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


def integrate_country_opml(slug: str, feeds: list[dict], country_name: str) -> str | None:
    """Merge artist feeds into the country's existing OPML. Returns new OPML text or None."""
    opml_path = resolve_opml_path(slug)
    if opml_path is None:
        # Create new OPML for this country
        return create_new_opml(country_name, feeds)

    content = opml_path.read_text(encoding="utf-8")

    # Check if "Artist Blogs" subcategory already exists
    if 'feedmineSubcategory="Artist Blogs"' in content:
        print(f"    [skip] Artist Blogs subcategory already exists in {slug}.opml")
        return None  # Already integrated — just update

    # Find the </body> tag to insert before it
    entries_xml = "\n".join(generate_outline_entry(f, country_name) for f in feeds)

    new_subcategory = f"""    <outline text="Artist Blogs" title="Artist Blogs">
{entries_xml}
    </outline>
  </body>"""

    # Insert before </body>
    new_content = content.replace("  </body>", new_subcategory)

    return new_content


def create_new_opml(country_name: str, feeds: list[dict]) -> str:
    """Create a brand new OPML file for a country."""
    entries_xml = "\n".join(generate_outline_entry(f, country_name) for f in feeds)

    return f"""<?xml version="1.0" encoding="utf-8"?>
<opml version="2.0">
  <head>
    <title>{country_name} — Artist Blogs</title>
    <ownerName>Feedmine editorial curation</ownerName>
    <docs>https://opml.org/spec2.opml</docs>
  </head>
  <body>
    <outline text="Artist Blogs" title="Artist Blogs">
{entries_xml}
    </outline>
  </body>
</opml>"""


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

        # Count how many are actually new (not already in existing OPML)
        existing_urls = set()
        opml_path = resolve_opml_path(slug)
        if opml_path and opml_path.exists():
            try:
                for m in re.finditer(r'xmlUrl="([^"]+)"', opml_path.read_text(encoding="utf-8")):
                    existing_urls.add(m.group(1).strip().rstrip("/").lower())
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
            new_opml = integrate_country_opml(slug, new, name)
            if new_opml:
                if args.output_dir:
                    out_path = Path(args.output_dir) / f"{slug}.opml"
                    out_path.parent.mkdir(parents=True, exist_ok=True)
                elif opml_path:
                    out_path = opml_path
                else:
                    # Create new OPML path using filesystem-compatible slug
                    dir_slug = slug.replace("-", "_")
                    out_path = COUNTRIES_DIR / dir_slug / f"{dir_slug}.opml"
                    out_path.parent.mkdir(parents=True, exist_ok=True)
                out_path.write_text(new_opml, encoding="utf-8")
                print(f"    ✅ Wrote {len(new)} feeds to {out_path}")
                integrated += 1
                new_feeds += len(new)

    print(f"\n{'='*60}")
    if args.dry_run:
        print(f"[DRY RUN] Would integrate {new_feeds} new feeds across {integrated} countries")
    else:
        print(f"✅ Integrated {new_feeds} new artist blog feeds across {integrated} countries")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
