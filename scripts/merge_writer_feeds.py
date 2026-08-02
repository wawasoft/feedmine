#!/usr/bin/env python3
"""
Merge discovered writer/author blog feeds into each country's main OPML file.

Inserts feeds under "Writing & Literature" subcategory within
"Arts & Culture" (or creates the topic structure if needed).
Deduplicates against existing xmlUrl entries.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Optional


def find_arts_insertion_point(lines: list[str]) -> Optional[int]:
    """Find where to insert new feeds within the Arts & Culture topic outline.

    Looks for the 'Arts & Culture' topic and returns the line index
    just before its closing </outline>, so new subcategories can be
    inserted there.
    """
    arts_topic_start = None
    depth = 0
    in_arts = False

    for i, line in enumerate(lines):
        stripped = line.strip()

        if 'text="Arts &amp; Culture"' in stripped or "text='Arts &amp; Culture'" in stripped:
            if "<outline" in stripped:
                arts_topic_start = i
                in_arts = True
                depth = 1
                continue

        if in_arts:
            opens = stripped.count("<outline")
            closes = stripped.count("</outline>")
            self_closing = len(re.findall(r'<outline[^>]*/>', stripped))
            opens -= self_closing
            depth += opens - closes
            if depth <= 0:
                # Return the line BEFORE the closing </outline>
                return i

    return None


def find_writing_lit_section(lines: list[str]) -> Optional[tuple[int, int]]:
    """Find existing 'Writing & Literature' subcategory within Arts & Culture.
    Returns (start_line, end_line) where end_line is the line with </outline>.
    """
    in_arts = False

    for i, line in enumerate(lines):
        stripped = line.strip()

        if 'text="Arts &amp; Culture"' in stripped or "text='Arts &amp; Culture'" in stripped:
            if "<outline" in stripped:
                in_arts = True
                continue

        if in_arts:
            if 'text="Writing &amp; Literature"' in stripped or "text='Writing &amp; Literature'" in stripped:
                # Found existing section — find its closing </outline>
                if "/>" in stripped:
                    return i, i  # self-closing, replace it
                depth = 0
                for j in range(i, len(lines)):
                    s = lines[j].strip()
                    opens = s.count("<outline")
                    closes = s.count("</outline>")
                    self_closing = len(re.findall(r'<outline[^>]*/>', s))
                    opens -= self_closing
                    if j == i:
                        depth = opens - closes
                    else:
                        depth += opens - closes
                    if depth <= 0:
                        return i, j
            # Stop if we exit Arts & Culture
            if "</outline>" in stripped and 'text="Arts' not in stripped:
                # Check if this closes Arts
                pass

    return None


def merge_feeds_into_opml(
    opml_path: Path,
    feeds: list[dict],
    country_name: str,
    dry_run: bool = False,
) -> bool:
    """Merge writer feeds into an OPML file. Returns True if changes made."""
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

    # Build feed entries
    indent = "                        "  # 24 spaces (inside subcategory)
    feed_lines = []
    for f in new_feeds:
        title = (f.get("title") or f["url"]).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        url_esc = f["url"].replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        cn = (country_name or "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
        sid = hashlib.sha256(f["url"].encode()).hexdigest()

        feed_lines.append(
            f'{indent}    <outline text="{title}" title="{title}" '
            f'type="rss" xmlUrl="{url_esc}" '
            f'description="Writer/author blog from {cn}." '
            f'language="" '
            f'category="writing,literature,books,blog,{country_name.lower()}" '
            f'feedmineSourceId="{sid}" '
            f'feedmineTopic="Arts &amp; Culture" '
            f'feedmineSubcategory="Writing &amp; Literature" '
            f'feedmineNature="personal" '
            f'feedmineActivity="active" '
            f'feedmineArticlesFetched="0" '
            f'feedmineQualityScore="70" '
            f'feedmineDefaultEnabled="true" '
            f'feedmineMediaKind="text" '
            f'htmlUrl="{url_esc}" />\n'
        )

    # Find insertion point — prefer existing Writing & Literature section
    existing_section = find_writing_lit_section(lines)

    if existing_section:
        section_start, section_end = existing_section
        if section_start == section_end:
            # Self-closing — replace with full block
            block = [f'{indent}<outline text="Writing &amp; Literature" title="Writing &amp; Literature">\n']
            block.extend(feed_lines)
            block.append(f'{indent}</outline>\n')
            new_lines = lines[:section_start] + block + lines[section_end + 1:]
        else:
            # Insert before closing </outline> of existing section
            new_lines = lines[:section_end] + feed_lines + lines[section_end:]
    else:
        # Insert new subcategory block within Arts & Culture
        arts_insert = find_arts_insertion_point(lines)

        if arts_insert is not None:
            block = [f'{indent}<outline text="Writing &amp; Literature" title="Writing &amp; Literature">\n']
            block.extend(feed_lines)
            block.append(f'{indent}</outline>\n')
            new_lines = lines[:arts_insert] + block + lines[arts_insert:]
        else:
            # Arts & Culture doesn't exist — append at end of body
            body_close = None
            for i, line in enumerate(lines):
                if "</body>" in line:
                    body_close = i
                    break
            if body_close is not None:
                topic_indent = "            "
                topic_block = [
                    f'{topic_indent}<outline text="Arts &amp; Culture" title="Arts &amp; Culture">\n',
                    f'{indent}<outline text="Writing &amp; Literature" title="Writing &amp; Literature">\n',
                ]
                topic_block.extend(feed_lines)
                topic_block.append(f'{indent}</outline>\n')
                topic_block.append(f'{topic_indent}</outline>\n')
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
    parser = argparse.ArgumentParser(description="Merge writer feeds into OPML files")
    parser.add_argument("--country", help="Single country slug")
    parser.add_argument("--all", action="store_true", help="All countries with cached writer feeds")
    parser.add_argument("--dry-run", action="store_true", help="Preview only, don't modify files")
    parser.add_argument("--limit", type=int, default=0, help="Limit to N countries")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    countries_dir = repo_root / "feedmine" / "Resources" / "Feeds" / "90_countries"
    cache_dir = repo_root / "scripts" / "feed_discovery" / "data" / "writer_cache"

    countries_json = repo_root / "scripts" / "feed_discovery" / "data" / "countries.json"
    with open(countries_json, encoding="utf-8") as f:
        countries = json.load(f)

    if args.country:
        slugs = [args.country]
    elif args.all:
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

    if args.limit:
        slugs = slugs[:args.limit]

    if not slugs:
        print("No countries to process. Run discovery first.")
        return

    print(f"Merging writer feeds for {len(slugs)} countries...\n")

    total_new = 0
    total_skipped = 0
    countries_modified = 0

    for slug in slugs:
        cache_file = cache_dir / f"{slug}_validated.json"
        if not cache_file.exists():
            print(f"[{slug}] no cache file, skipping")
            continue

        feeds = json.loads(cache_file.read_text(encoding="utf-8"))
        if not feeds:
            print(f"[{slug}] empty cache, skipping")
            continue

        name = countries[slug]["name"]
        # Convert hyphens to underscores for filesystem path
        dir_slug = slug.replace("-", "_")
        opml_path = countries_dir / dir_slug / f"{dir_slug}.opml"

        print(f"[{slug}] {name}: {len(feeds)} feeds in cache")
        if merge_feeds_into_opml(opml_path, feeds, name, dry_run=args.dry_run):
            total_new += len(feeds)
            countries_modified += 1

    print(f"\n{'='*60}")
    print(f"✅ Merged into {countries_modified} countries")
    print(f"   Total new feeds added: {total_new}")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
