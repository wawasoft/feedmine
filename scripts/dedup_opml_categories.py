#!/usr/bin/env python3
"""
Deduplicate OPML category groups and feed URLs within each country OPML.

Problem: Multiple integration scripts (artist feeds, journalist feeds, writer feeds,
radio podcasts, etc.) append new category groups to country OPMLs without merging
into existing groups of the same name. This creates duplicate category groups like
"News & Current Affairs" (2x) and "Arts & Culture" (2-4x).

This script:
  1. Merges duplicate category groups (by text attribute) into a single group
  2. Removes duplicate feed URLs within each category (keeping the first occurrence)
  3. Preserves all feedmine* attributes and XML structure
  4. Backs up originals to .opml.pre_dedup if --write is used

Usage:
    python scripts/dedup_opml_categories.py                      # dry-run
    python scripts/dedup_opml_categories.py --write              # apply fixes
    python scripts/dedup_opml_categories.py --country brazil     # single country
"""

from __future__ import annotations

import sys
import shutil
from pathlib import Path
from collections import OrderedDict

import xml.etree.ElementTree as ET

REPO_ROOT = Path(__file__).resolve().parents[1]
OPML_BASE = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"


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


def read_opml(opml_path: Path) -> tuple[ET.Element, ET.Element, ET.Element]:
    """Parse OPML and return (root, head, body)."""
    tree = ET.parse(str(opml_path))
    root = tree.getroot()
    head = root.find("head")
    body = root.find("body")
    return root, head, body


def write_opml(opml_path: Path, root: ET.Element) -> None:
    """Write ElementTree back to OPML file with proper formatting."""
    _indent_xml(root)
    raw = ET.tostring(root, encoding="unicode")
    opml_path.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        + raw.split("?>", 1)[-1].lstrip(),
        encoding="utf-8",
    )


def dedup_country_opml(root: ET.Element, head: ET.Element, body: ET.Element) -> dict:
    """
    Deduplicate a single country OPML file (modifies tree in-place).

    Returns stats dict with counts of what was done.
    """

    stats = {
        "original_groups": 0,
        "merged_groups": 0,
        "removed_dup_urls": 0,
        "original_feeds": 0,
        "final_feeds": 0,
        "final_groups": 0,
    }

    # Collect all category groups
    groups: OrderedDict[str, list[ET.Element]] = OrderedDict()
    non_category_elements: list[ET.Element] = []  # elements without text (whitespace, comments)

    for child in list(body):
        # Strip tail text to avoid double whitespace
        text = child.get("text", "")
        if text:
            if text not in groups:
                groups[text] = []
            groups[text].append(child)
    # Remove the text to rebuilt
    stats["original_groups"] = sum(len(v) for v in groups.values())

    # Count original feeds
    stats["original_feeds"] = sum(
        1 for o in body.iter("outline") if o.get("xmlUrl")
    )

    # Rebuild body: one group per category, feeds merged and deduped
    body.clear()

    for cat_text, group_elements in groups.items():
        # Merge all feed elements from all groups of this category
        seen_urls: set[str] = set()
        merged_parent = ET.SubElement(body, "outline")
        merged_parent.set("text", cat_text)

        for old_group in group_elements:
            for child in list(old_group):
                child_text = child.get("text", "")
                # Copy subcategory outlines (they contain feeds)
                if child.tag == "outline" and child.get("xmlUrl") is None:
                    # This is a subcategory group (has text but no xmlUrl)
                    # Check if already exists in merged
                    sub_text = child.get("text", "")
                    existing_sub = None
                    for s in merged_parent:
                        if s.get("text") == sub_text and s.get("xmlUrl") is None:
                            existing_sub = s
                            break
                    if existing_sub is not None:
                        # Merge feeds into existing subcategory
                        for feed in child:
                            url = feed.get("xmlUrl", "")
                            if url and url not in seen_urls:
                                seen_urls.add(url)
                                existing_sub.append(feed)
                            elif url:
                                stats["removed_dup_urls"] += 1
                    else:
                        # Add new subcategory
                        merged_parent.append(child)
                        for feed in child.iter("outline"):
                            url = feed.get("xmlUrl", "")
                            if url:
                                if url in seen_urls:
                                    stats["removed_dup_urls"] += 1
                                    # Remove this duplicate feed from its parent
                                    feed_parent = None
                                    for p in child.iter("outline"):
                                        if p != feed and any(c is feed for c in p):
                                            feed_parent = p
                                            break
                                    if feed_parent is not None:
                                        feed_parent.remove(feed)
                                else:
                                    seen_urls.add(url)
                elif child.tag == "outline" and child.get("xmlUrl"):
                    # Direct feed (no subcategory wrapper)
                    url = child.get("xmlUrl", "")
                    if url and url not in seen_urls:
                        seen_urls.add(url)
                        merged_parent.append(child)
                    elif url:
                        stats["removed_dup_urls"] += 1

        if len(groups[cat_text]) > 1:
            stats["merged_groups"] += len(groups[cat_text]) - 1

        # Final pass: remove duplicate URLs within the merged category group.
        # Collect first so we don't mutate during iteration (ElementTree hazard).
        url_to_feeds: dict[str, list[ET.Element]] = {}
        for feed in merged_parent.iter("outline"):
            url = feed.get("xmlUrl", "")
            if not url:
                continue
            url_to_feeds.setdefault(url, []).append(feed)

        for url, feeds in url_to_feeds.items():
            # Keep the first occurrence, remove the rest
            for feed in feeds[1:]:
                # Find parent and remove
                parent = None
                for p in merged_parent.iter("outline"):
                    if any(c is feed for c in p):
                        parent = p
                        break
                if parent is not None:
                    parent.remove(feed)
                    stats["removed_dup_urls"] += 1

    stats["final_groups"] = len(groups)
    stats["final_feeds"] = sum(
        1 for o in body.iter("outline") if o.get("xmlUrl")
    )

    return stats


def main():
    write_mode = "--write" in sys.argv
    country_filter = None

    for i, arg in enumerate(sys.argv):
        if arg == "--country" and i + 1 < len(sys.argv):
            country_filter = sys.argv[i + 1]

    if not write_mode:
        print("🔍 DRY RUN — use --write to apply fixes\n")

    # Collect OPMLs to process
    opmls: list[Path] = []
    if country_filter:
        candidate = OPML_BASE / country_filter / f"{country_filter}.opml"
        if candidate.exists():
            opmls.append(candidate)
        else:
            # Try with underscore
            for d in OPML_BASE.iterdir():
                if d.is_dir() and d.name.replace("_", "-") == country_filter.replace("_", "-"):
                    candidate = d / f"{d.name}.opml"
                    if candidate.exists():
                        opmls.append(candidate)
                    break
            if not opmls:
                print(f"Country '{country_filter}' not found")
                sys.exit(1)
    else:
        for country_dir in sorted(OPML_BASE.iterdir()):
            if not country_dir.is_dir():
                continue
            opml = country_dir / f"{country_dir.name}.opml"
            if opml.exists():
                opmls.append(opml)

    # Process
    total = {"original_groups": 0, "merged_groups": 0, "removed_dup_urls": 0,
             "original_feeds": 0, "final_feeds": 0, "fixed": 0, "countries": 0}

    for opml_path in opmls:
        country = opml_path.parent.name

        if write_mode:
            # Backup
            backup = opml_path.with_suffix(".opml.pre_dedup")
            shutil.copy2(opml_path, backup)

        root, head, body = read_opml(opml_path)
        stats = dedup_country_opml(root, head, body)

        if "error" in stats:
            print(f"  ❌ {country}: {stats['error']}")
            continue

        needs_fix = stats["merged_groups"] > 0 or stats["removed_dup_urls"] > 0

        if write_mode and needs_fix:
            write_opml(opml_path, root)
            status = "✅"
            total["fixed"] += 1
        elif needs_fix:
            status = "🔧"
            total["fixed"] += 1
        else:
            status = "✅"

        for key in total:
            if key in stats:
                total[key] += stats[key]
        total["countries"] += 1

        detail = ""
        if stats["merged_groups"] > 0:
            detail += f"merged={stats['merged_groups']} "
        if stats["removed_dup_urls"] > 0:
            detail += f"urls_removed={stats['removed_dup_urls']} "
        if not detail:
            detail = "clean"

        print(f"  {status} {country}: {stats['original_groups']}→{stats['final_groups']} groups, "
              f"{stats['original_feeds']}→{stats['final_feeds']} feeds [{detail}]")

    print(f"\n📊 Total: {total['countries']} countries | "
          f"{total['merged_groups']} groups merged | "
          f"{total['removed_dup_urls']} duplicate URLs removed | "
          f"{total['original_feeds']}→{total['final_feeds']} feeds")

    if not write_mode:
        print("\n🔍 DRY RUN complete. Use --write to apply fixes.")
    else:
        print(f"\n✅ {total['fixed']} countries fixed. Backups saved as .opml.pre_dedup")


if __name__ == "__main__":
    main()
