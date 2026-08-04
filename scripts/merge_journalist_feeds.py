#!/usr/bin/env python3
"""
Merge discovered journalist blog feeds into each country's main OPML file.

Inserts feeds under a new "Journalism & Media" subcategory within
"News & Current Affairs" (or creates the topic structure if needed).
Deduplicates against existing xmlUrl entries.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Optional

try:
    from scripts.catalog_identity import compute_source_id
except ModuleNotFoundError:
    from catalog_identity import compute_source_id


def find_insertion_point(lines: list[str]) -> Optional[int]:
    """Find where to insert new feeds within the OPML body.

    Looks for the 'News & Current Affairs' topic outline and inserts
    after the last subcategory or before the closing </outline>.
    If not found, looks for the first topic outline to insert after.
    """
    # Find "News & Current Affairs" topic
    news_topic_start = None
    news_topic_end = None
    depth = 0
    in_news = False

    for i, line in enumerate(lines):
        stripped = line.strip()

        if 'text="News &amp; Current Affairs"' in stripped or "text='News &amp; Current Affairs'" in stripped:
            if "<outline" in stripped:
                news_topic_start = i
                in_news = True
                depth = 1
                continue

        if in_news:
            # Count nested outlines
            opens = stripped.count("<outline")
            closes = stripped.count("</outline>")
            # Also count self-closing
            self_closing = len(re.findall(r'<outline[^>]*/>', stripped))
            opens -= self_closing

            depth += opens - closes
            if depth <= 0:
                news_topic_end = i
                break

    if news_topic_end is not None:
        # Insert before the closing </outline> of the News topic
        return news_topic_end

    return None


def merge_feeds_into_opml(
    opml_path: Path,
    feeds: list[dict],
    country_name: str,
    dry_run: bool = False,
) -> bool:
    """Merge journalist feeds into an OPML file. Returns True if changes made."""
    if not opml_path.exists():
        print(f"  [skip] {opml_path} not found")
        return False

    original = opml_path.read_text(encoding="utf-8")
    lines = original.splitlines(keepends=True)

    # Collect existing URLs
    existing_urls: set[str] = set()
    for line in lines:
        m = re.search(r'xmlUrl="([^"]+)"', line)
        if m:
            existing_urls.add(m.group(1).strip().rstrip("/").lower())

    # Filter out duplicates
    new_feeds = []
    for f in feeds:
        norm = f["url"].strip().rstrip("/").lower()
        if norm not in existing_urls:
            new_feeds.append(f)

    if not new_feeds:
        print(f"  [skip] all {len(feeds)} feeds already exist in OPML")
        return False

    print(f"  {len(new_feeds)} new feeds to add ({len(feeds) - len(new_feeds)} duplicates skipped)")

    # Build the new subcategory block
    indent = "                        "  # 24 spaces
    block_lines = []
    block_lines.append(f'{indent}<outline text="Journalism &amp; Media" title="Journalism &amp; Media">\n')

    for f in new_feeds:
        title = (f.get("title") or f["url"]).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        url_esc = f["url"].replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        cn = (country_name or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        import hashlib
        sid = compute_source_id(f["url"])

        desc = f"Journalist blog from {cn}."

        block_lines.append(
            f'{indent}    <outline text="{title}" title="{title}" '
            f'type="rss" xmlUrl="{url_esc}" '
            f'description="{desc}" '
            f'language="" '
            f'category="journalism,blog,personal,{country_name.lower()}" '
            f'feedmineSourceId="{sid}" '
            f'feedmineTopic="News &amp; Current Affairs" '
            f'feedmineSubcategory="Journalism &amp; Media" '
            f'feedmineNature="personal" '
            f'feedmineActivity="active" '
            f'feedmineArticlesFetched="0" '
            f'feedmineQualityScore="70" '
            f'feedmineDefaultEnabled="true" '
            f'feedmineMediaKind="text" '
            f'htmlUrl="{url_esc}" />\n'
        )

    block_lines.append(f'{indent}</outline>\n')

    # Find insertion point
    insert_at = find_insertion_point(lines)

    if insert_at is not None:
        # Insert before the closing </outline> of News & Current Affairs
        new_lines = lines[:insert_at] + block_lines + lines[insert_at:]
    else:
        # Append at end of body (before </body>)
        body_close = None
        for i, line in enumerate(lines):
            if "</body>" in line:
                body_close = i
                break
        if body_close is not None:
            # Create the full topic structure
            topic_block = [
                '            <outline text="News &amp; Current Affairs" title="News &amp; Current Affairs">\n',
            ] + block_lines + [
                '            </outline>\n',
            ]
            new_lines = lines[:body_close] + topic_block + lines[body_close:]
        else:
            print(f"  [error] could not find </body> in OPML")
            return False

    if dry_run:
        print(f"  [dry-run] would write {len(new_lines)} lines to {opml_path}")
        return True

    # Backup original
    backup_path = opml_path.with_suffix(opml_path.suffix + ".bak")
    if not backup_path.exists():
        backup_path.write_text(original, encoding="utf-8")

    # Write merged file
    opml_path.write_text("".join(new_lines), encoding="utf-8")
    print(f"  ✅ Merged {len(new_feeds)} feeds into {opml_path}")
    print(f"     Backup saved to {backup_path}")
    return True


def main():
    parser = argparse.ArgumentParser(description="Merge journalist feeds into OPML files")
    parser.add_argument("--country", help="Single country slug")
    parser.add_argument("--all", action="store_true", help="All countries with cached journalist feeds")
    parser.add_argument("--dry-run", action="store_true", help="Preview only, don't modify files")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    countries_dir = repo_root / "feedmine" / "Resources" / "Feeds" / "90_countries"
    cache_dir = repo_root / "scripts" / "feed_discovery" / "data" / "journalist_cache"

    import json as _json
    countries_json = repo_root / "scripts" / "feed_discovery" / "data" / "countries.json"
    with open(countries_json, encoding="utf-8") as f:
        countries = _json.load(f)

    if args.country:
        slugs = [args.country]
    elif args.all:
        # All countries that have validated caches
        slugs = []
        for cache_file in sorted(cache_dir.glob("*_validated.json")):
            slug = cache_file.stem.replace("_validated", "")
            if slug in countries:
                slugs.append(slug)
    else:
        # Default: first 3 cached countries
        slugs = []
        for cache_file in sorted(cache_dir.glob("*_validated.json"))[:3]:
            slug = cache_file.stem.replace("_validated", "")
            if slug in countries:
                slugs.append(slug)

    if not slugs:
        print("No countries to process. Run discovery first.")
        return

    print(f"Merging journalist feeds for {len(slugs)} countries...\n")

    total_added = 0
    for slug in slugs:
        cache_file = cache_dir / f"{slug}_validated.json"
        if not cache_file.exists():
            print(f"[{slug}] no cache file, skipping")
            continue

        feeds = _json.loads(cache_file.read_text(encoding="utf-8"))
        if not feeds:
            print(f"[{slug}] empty cache, skipping")
            continue

        name = countries[slug]["name"]
        opml_path = countries_dir / slug / f"{slug}.opml"

        print(f"[{slug}] {name}: {len(feeds)} feeds in cache")
        if merge_feeds_into_opml(opml_path, feeds, name, dry_run=args.dry_run):
            total_added += len(feeds)

    print(f"\n✅ Total feeds merged: {total_added}")


if __name__ == "__main__":
    main()
