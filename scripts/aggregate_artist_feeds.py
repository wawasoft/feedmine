#!/usr/bin/env python3
"""
Aggregate all artist blog feeds from all discovery cache directories,
deduplicate, and generate per-country OPML files ready for integration.

Also prints a per-country progress report showing feeds_found / 100 goal.
"""

import json
import os
import re
import sys
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
    """Load all feeds from all cache dirs, deduplicated by URL. Returns slug → [feeds]."""
    by_slug: dict[str, list[dict]] = defaultdict(list)
    seen_urls: set[str] = set()

    for cache_name in CACHE_DIRS:
        cache_path = DATA_DIR / cache_name
        if not cache_path.exists():
            continue
        for fname in cache_path.iterdir():
            if not fname.name.endswith("_feeds.json"):
                continue
            slug = fname.name.replace("_feeds.json", "")
            try:
                feeds = json.loads(fname.read_text(encoding="utf-8"))
            except Exception:
                continue
            for feed in feeds:
                url = feed.get("url", "").strip().lower().rstrip("/")
                if not url or url in seen_urls:
                    continue
                seen_urls.add(url)
                by_slug[slug].append(feed)

    return dict(by_slug)


def generate_opml(country_name: str, feeds: list[dict]) -> str:
    """Generate full OPML document with artist blog feeds."""
    import hashlib
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<opml version="2.0">',
        '  <head>',
        f'    <title>{country_name} — Artist Blogs</title>',
        '    <ownerName>Feedmine editorial curation</ownerName>',
        '    <docs>https://opml.org/spec2.opml</docs>',
        '  </head>',
        '  <body>',
        '    <outline text="Artist Blogs" title="Artist Blogs">',
    ]

    for f in feeds:
        u = f["url"]
        title = f.get("title") or f.get("feed_title") or f.get("name") or u
        te = title.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        ue = u.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        sid = hashlib.sha256(u.encode()).hexdigest()

        lines.append(
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

    lines.append('    </outline>')
    lines.append('  </body>')
    lines.append('</opml>')
    return "\n".join(lines)


def main():
    with open(COUNTRIES_JSON, encoding="utf-8") as f:
        countries = json.load(f)

    all_feeds = load_all_feeds()

    # Per-country stats
    print("=" * 75)
    print(f"{'Country':<25} {'Slug':<22} {'Feeds':>6} {'Goal':>6} {'%':>6}")
    print("-" * 75)

    total = 0
    at_goal = 0
    has_some = 0
    has_none = 0

    for slug in sorted(countries.keys()):
        meta = countries[slug]
        name = meta["name"]
        count = len(all_feeds.get(slug, []))
        pct = min(100, int(count / 100 * 100))
        bar = "█" * (pct // 5) + "░" * (20 - pct // 5)

        print(f"{name:<25} {slug:<22} {count:>6} {100:>6} {pct:>3}% {bar}")

        total += count
        if count >= 100:
            at_goal += 1
        if count > 0:
            has_some += 1
        else:
            has_none += 1

    print("-" * 75)
    print(f"{'TOTAL':<25} {'':<22} {total:>6}")
    print()
    print(f"Countries at 100+ feeds: {at_goal}/{len(countries)}")
    print(f"Countries with some feeds: {has_some}/{len(countries)}")
    print(f"Countries with zero feeds: {has_none}/{len(countries)}")
    print(f"Total feeds found: {total}")
    print(f"Goal: {len(countries) * 100} ({len(countries)} countries × 100)")
    print(f"Progress: {total / (len(countries) * 100) * 100:.1f}%")

    # Generate OPML for all countries that have feeds
    out_dir = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "artist_aggregated_opml"
    out_dir.mkdir(parents=True, exist_ok=True)

    for slug, feeds in all_feeds.items():
        if slug in countries:
            name = countries[slug]["name"]
            opml_text = generate_opml(name, feeds)
            (out_dir / f"{slug}_artist_blogs.opml").write_text(opml_text, encoding="utf-8")

    print(f"\nOPML files written to: {out_dir}")


if __name__ == "__main__":
    main()
