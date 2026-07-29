#!/usr/bin/env python3
"""
Integrate YouTube channel RSS feeds from SocialBlade data as artist content.

SocialBlade data has 50 top YouTube channels per country (101 countries, 5,050 total).
Each channel already has a feed_url: youtube.com/feeds/videos.xml?channel_id=UC...

We filter for music/entertainment/arts channels using channel name heuristics,
then merge into country OPML files under "Artist Blogs" or "YouTube Artists" subcategory.
"""

import hashlib, json, re, sys
from pathlib import Path
from collections import defaultdict

REPO_ROOT = Path(__file__).resolve().parents[1]
COUNTRIES_JSON = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "countries.json"
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"
SOCIALBLADE = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "youtube_channels_socialblade.json"

# ISO2 → Feedmine slug mapping (from SocialBlade country codes)
ISO2_TO_SLUG: dict[str, str] = {}

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


def generate_outline(feed_url: str, channel_name: str, country_name: str) -> str:
    """Generate a single <outline> OPML entry."""
    te = channel_name.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
    ue = feed_url.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
    sid = hashlib.sha256(feed_url.encode()).hexdigest()
    return (
        f'      <outline text="{te}" title="{te}" '
        f'type="rss" xmlUrl="{ue}" '
        f'description="YouTube artist channel from {country_name}." '
        f'language="" '
        f'category="youtube,artist,video,{country_name.lower()}" '
        f'feedmineSourceId="{sid}" '
        f'feedmineTopic="Music &amp; Audio" '
        f'feedmineSubcategory="YouTube Artists" '
        f'feedmineNature="personal" '
        f'feedmineActivity="active" '
        f'feedmineArticlesFetched="0" '
        f'feedmineQualityScore="65" '
        f'feedmineDefaultEnabled="true" '
        f'feedmineMediaKind="video" '
        f'htmlUrl="{ue}" />'
    )


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
        # SocialBlade uses Feedmine-compatible slugs directly
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

        # Load existing URLs from OPML
        existing_urls = set()
        opml_path = resolve_opml_path(slug)
        if opml_path:
            try:
                for m in re.finditer(r'xmlUrl="([^"]+)"', opml_path.read_text(encoding="utf-8")):
                    existing_urls.add(m.group(1).strip().rstrip("/").lower())
            except Exception:
                pass

        # Filter new
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

        # Generate OPML entries and merge
        entries_xml = "\n".join(generate_outline(c["url"], c["title"], cname) for c in new)

        if opml_path and opml_path.exists():
            content = opml_path.read_text(encoding="utf-8")

            if 'feedmineSubcategory="YouTube Artists"' in content:
                print(f"    [skip] YouTube Artists already exists")
                continue

            # Insert before </body>
            new_section = f'    <outline text="YouTube Artists" title="YouTube Artists">\n{entries_xml}\n    </outline>\n  </body>'
            new_content = content.replace("  </body>", new_section)
        else:
            # Create new OPML
            new_content = f"""<?xml version="1.0" encoding="utf-8"?>
<opml version="2.0">
  <head>
    <title>{cname} — YouTube Artists</title>
    <ownerName>Feedmine editorial curation</ownerName>
    <docs>https://opml.org/spec2.opml</docs>
  </head>
  <body>
    <outline text="YouTube Artists" title="YouTube Artists">
{entries_xml}
    </outline>
  </body>
</opml>"""
            dir_slug = slug.replace("-", "_")
            opml_path = COUNTRIES_DIR / dir_slug / f"{dir_slug}.opml"
            opml_path.parent.mkdir(parents=True, exist_ok=True)

        opml_path.write_text(new_content, encoding="utf-8")
        integrated += 1
        total_new += len(new)
        print(f"    ✅ Added {len(new)} YouTube artist channels")

    print(f"\n{'='*60}")
    if args.dry_run:
        print(f"[DRY RUN] Would integrate {total_new} YouTube feeds across {integrated} countries")
    else:
        print(f"✅ Integrated {total_new} YouTube artist feeds across {integrated} countries")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
