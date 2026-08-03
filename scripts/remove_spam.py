#!/usr/bin/env python3
"""
Remove known spam feeds from all country OPMLs.
Targeted, conservative — only removes confirmed junk.

Spam confirmed:
  - "FREE UK STBEMU CODES" — pirate IPTV codes (12 countries)
  - "Mastering Poker Chip Stacking" — SEO spam blog (29 countries)
  - "Emerging AI Technologies for Hyper-Predictive SEO" — SEO spam blog (20 countries)
"""

import xml.etree.ElementTree as ET
from pathlib import Path
import sys

SPAM_SOURCE_IDS = {
    "41b6a490c523fd8bb2d19a1a9000fd508c9ba25aa4a6290585c81fa96a82dc9e",  # STBEMU
    "a84f21f8b3a57ba16261e82950ff8bc35ab70e86ecb2591c389f02deaf046fec",  # Poker SEO
    "95e0af222428fa7396adb3fd07bed0eddd5c3e8189f59758c842a729fa2d357c",  # AI SEO
}

FEEDS_DIR = Path(__file__).resolve().parent.parent / "feedmine" / "Resources" / "Feeds" / "90_countries"


def remove_spam(opml_path):
    tree = ET.parse(opml_path)
    root = tree.getroot()
    body = root.find("body")
    if body is None:
        return 0

    removed = 0
    # Collect feeds to remove
    def walk(parent):
        nonlocal removed
        for child in list(parent):
            if child.tag == "outline" and child.get("type") == "rss":
                sid = child.get("feedmineSourceId", "")
                if sid in SPAM_SOURCE_IDS:
                    parent.remove(child)
                    removed += 1
            else:
                walk(child)
    walk(body)

    if removed > 0:
        ET.indent(root, space="  ")
        tree.write(opml_path, encoding="utf-8", xml_declaration=True)
    return removed


def main():
    total_removed = 0
    for country_dir in sorted(FEEDS_DIR.iterdir()):
        if not country_dir.is_dir() or country_dir.name.startswith("."):
            continue
        opml = country_dir / f"{country_dir.name}.opml"
        if not opml.exists():
            continue
        n = remove_spam(opml)
        if n > 0:
            total_removed += n
            print(f"  {country_dir.name}: {n} spam feed(s) removed")

    print(f"\nTotal spam removed: {total_removed} from {total_removed} placements")


if __name__ == "__main__":
    main()
