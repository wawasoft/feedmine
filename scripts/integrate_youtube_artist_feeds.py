#!/usr/bin/env python3
"""
Integrate YouTube channel RSS feeds from SocialBlade data as artist content.

SocialBlade data has 50 top YouTube channels per country (101 countries, 5,050 total).
Each channel already has a feed_url: youtube.com/feeds/videos.xml?channel_id=UC...

We filter for music/entertainment/arts channels using channel name heuristics,
then merge into country OPML files under Music & Audio → YouTube Artists subcategory.

Uses proper XML merging (ElementTree) — does NOT use fragile string manipulation.
"""

import hashlib, json, re, sys
from pathlib import Path
from collections import defaultdict
import xml.etree.ElementTree as ET

try:
    from scripts.catalog_identity import compute_source_id
except ModuleNotFoundError:
    from catalog_identity import compute_source_id

REPO_ROOT = Path(__file__).resolve().parents[1]
COUNTRIES_JSON = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "countries.json"
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"
SOCIALBLADE = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "youtube_channels_socialblade.json"

# Music/entertainment/arts keywords in channel names
ARTIST_KEYWORDS = [
    "music", "musica", "musique", "musik", "song", "singer", "cantor",
    "cantora", "chanteur", "rapper", "rap", "hip hop", "hiphop", "beat",
    "guitar", "piano", "violin", "drum", "bass", "vocal", "voice",
    "band", "banda", "benda", "orchestra", "ensemble", "group", "duo",
    "actor", "actress", "film", "cinema", "movie", "director",
    "artist", "artista", "artiste", "kunstler", "painter", "draw",
    "dance", "dancer", "danza", "ballet", "choreo",
    "comedy", "comedian", "humor", "funny", "stand up", "standup",
    "entertainment", "show", "performance", "performer",
    "tv", "television", "series", "drama", "theatre", "theater",
    "pop", "rock", "jazz", "blues", "folk", "soul", "funk", "reggae",
    "samba", "bossa", "mpb", "sertanejo", "forro", "kpop", "jpop",
    "edm", "techno", "house", "dj", "producer", "remix",
    "cover", "acoustic", "live", "session", "concert",
    "studio", "recording", "label", "records",
    "talent", "idol", "star", "celebrity",
    "photography", "photo", "design", "creative",
]


def _make_feed_element(feed_url: str, channel_name: str, country_name: str) -> ET.Element:
    """Create an <outline> element for a YouTube channel feed."""
    sid = compute_source_id(feed_url)
    elem = ET.Element("outline")
    elem.set("text", channel_name)
    elem.set("title", channel_name)
    elem.set("type", "rss")
    elem.set("xmlUrl", feed_url)
    elem.set("description", f"YouTube artist channel from {country_name}.")
    elem.set("language", "")
    elem.set("category", f"youtube,artist,video,{country_name.lower()}")
    elem.set("feedmineSourceId", sid)
    elem.set("feedmineTopic", "Music & Audio")
    elem.set("feedmineSubcategory", "YouTube Artists")
    elem.set("feedmineNature", "personal")
    elem.set("feedmineActivity", "active")
    elem.set("feedmineArticlesFetched", "0")
    elem.set("feedmineQualityScore", "65")
    elem.set("feedmineDefaultEnabled", "true")
    elem.set("feedmineMediaKind", "video")
    elem.set("htmlUrl", feed_url)
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


def build_slug_set():
    """Build set of valid Feedmine country slugs from countries.json."""
    with open(COUNTRIES_JSON, encoding="utf-8") as f:
        countries = json.load(f)
    return set(countries.keys())


def is_artist_channel(name: str) -> bool:
    """Heuristic: does this channel name suggest music/arts/entertainment content?"""
    name_lower = name.lower()
    for kw in ARTIST_KEYWORDS:
        if kw in name_lower:
            return True
    return False


def resolve_opml_path(slug: str) -> Path | None:
    """Find the actual OPML file path, handling hyphen vs underscore differences."""
    exact = COUNTRIES_DIR / slug / f"{slug}.opml"
    if exact.exists():
        return exact
    us_slug = slug.replace("-", "_")
    us_path = COUNTRIES_DIR / us_slug / f"{us_slug}.opml"
    if us_path.exists():
        return us_path
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


def integrate_channels(slug: str, channels: list[dict], country_name: str) -> tuple[Path, int]:
    """
    Merge YouTube channels into the country's OPML under Music & Audio → YouTube Artists.

    Returns (output_path, num_added).
    """
    opml_path = resolve_opml_path(slug)

    # Parse or create OPML
    if opml_path and opml_path.exists():
        try:
            tree = ET.parse(str(opml_path))
        except ET.ParseError:
            tree = None
        root = tree.getroot() if tree else None
    else:
        root = None

    if root is None:
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

    # Dedup
    existing_urls = _collect_existing_urls(body)
    truly_new = [c for c in channels if c["url"].lower().rstrip("/") not in existing_urls]
    if not truly_new:
        return (opml_path, 0)

    # Find or create "Music & Audio" → "YouTube Artists"
    music_cat = None
    for child in body:
        if child.get("text") == "Music & Audio" and child.tag == "outline":
            music_cat = child
            break
    if music_cat is None:
        music_cat = ET.SubElement(body, "outline")
        music_cat.set("text", "Music & Audio")
        music_cat.set("title", "Music & Audio")

    yt_subcat = None
    for child in music_cat:
        if child.get("text") == "YouTube Artists" and child.get("xmlUrl") is None:
            yt_subcat = child
            break
    if yt_subcat is None:
        yt_subcat = ET.SubElement(music_cat, "outline")
        yt_subcat.set("text", "YouTube Artists")
        yt_subcat.set("title", "YouTube Artists")

    # Add feeds
    written = 0
    for c in truly_new:
        elem = _make_feed_element(c["url"], c["title"], country_name)
        yt_subcat.append(elem)
        written += 1

    # Write back
    _indent_xml(root)
    raw = ET.tostring(root, encoding="unicode")

    if opml_path:
        out_path = opml_path
    else:
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
    p = argparse.ArgumentParser(description="Integrate YouTube artist feeds into OPMLs")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--all", action="store_true")
    p.add_argument("--country")
    args = p.parse_args()

    valid_slugs = build_slug_set()

    with open(SOCIALBLADE, encoding="utf-8") as f:
        sb = json.load(f)

    by_country_sb = sb.get("by_country", {})
    print(f"Loaded SocialBlade data: {len(by_country_sb)} countries, "
          f"{sum(len(v) for v in by_country_sb.values())} total channels")

    # Load countries for name lookup
    with open(COUNTRIES_JSON, encoding="utf-8") as f:
        countries = json.load(f)

    # Group artist channels by Feedmine slug
    by_slug: dict[str, list[dict]] = defaultdict(list)
    total_artist = 0

    for sb_slug, channels in by_country_sb.items():
        if sb_slug not in valid_slugs:
            continue
        for ch in channels:
            name = ch.get("channel_name", "")
            feed_url = ch.get("feed_url", "")
            if not feed_url or not name:
                continue
            entry = {"url": feed_url, "title": name, "name": name, "source": "socialblade"}
            if is_artist_channel(name):
                by_slug[sb_slug].append(entry)
                total_artist += 1

    print(f"Artist channels (filtered): {total_artist} across {len(by_slug)} countries\n")

    # Determine slugs to process
    if args.country:
        slugs = [args.country]
    elif args.all:
        slugs = sorted(by_slug.keys())
    else:
        slugs = sorted(by_slug.keys())[:5]
        print(f"Default: {slugs}\nUse --all for full integration.\n")

    integrated = 0
    total_new = 0

    for slug in slugs:
        if slug not in countries:
            continue
        cname = countries[slug]["name"]
        channels = by_slug.get(slug, [])
        if not channels:
            continue

        # Count how many are new
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

        new = [c for c in channels if c["url"].lower().rstrip("/") not in existing_urls]
        print(f"📺 {cname} ({slug}): {len(channels)} artist channels, "
              f"{len(new)} new, {len(channels) - len(new)} already in OPML")

        if not new:
            continue

        if args.dry_run:
            for c in new[:3]:
                print(f"    - {c['title'][:50]}")
            if len(new) > 3:
                print(f"    ... and {len(new) - 3} more")
            integrated += 1
            total_new += len(new)
            continue

        out_path, written = integrate_channels(slug, new, cname)
        if written > 0:
            print(f"    ✅ Added {written} YouTube artist channels")
        integrated += 1
        total_new += written

    print(f"\n{'='*60}")
    if args.dry_run:
        print(f"[DRY RUN] Would integrate {total_new} YouTube feeds across {integrated} countries")
    else:
        print(f"✅ Integrated {total_new} YouTube artist feeds across {integrated} countries")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
