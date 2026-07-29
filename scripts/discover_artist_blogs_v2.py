#!/usr/bin/env python3
"""
Fast artist blog RSS discovery using famous_people.txt as seed data.

For each artist with "blog", "substack", "website", or "newsletter" listed:
  1. Substack: directly construct https://{name_slug}.substack.com/feed and validate
  2. Website: search DDG for "{name} official website", discover feed from result
  3. Blog: search DDG for "{name} blog RSS", discover feed
  4. Validate all discovered feeds

Much faster than broad category searches — targets specific people.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from typing import Optional
from urllib.parse import urljoin, urlparse


# ---------------------------------------------------------------------------
# Parse famous_people.txt
# ---------------------------------------------------------------------------

ARTIST_CATEGORIES = {
    "arts & culture", "music & audio", "entertainment",
    "music (extra)", "music", "arts", "culture",
    "sports", "tech & science", "business",
}

def parse_famous_people_all(famous_path: Path) -> list[dict]:
    """Parse ALL entries from famous_people.txt as candidates.

    Returns list of {name, known_for, platforms, country, category}.
    """
    entries: list[dict] = []
    current_country: str | None = None
    current_category: str | None = None

    if not famous_path.exists():
        return entries

    content = famous_path.read_text(encoding="utf-8")

    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("==="):
            continue

        # Country header: # --- BRAZIL (50+) ---
        country_match = re.match(r'^#\s*---\s*(.+?)\s*\(', line)
        if country_match:
            current_country = country_match.group(1).strip()
            continue

        # Category header: # Music & Audio
        if line.startswith("# ") and "|" not in line:
            current_category = line[2:].strip()
            continue

        # Data line: Name | known for | platform1, platform2
        if "|" in line and current_country and current_category:
            parts = [p.strip() for p in line.split("|")]
            if len(parts) >= 2:
                name = parts[0].strip()
                # Skip estate/legacy/fan club entries
                if "(estate)" in name.lower() or "(legacy)" in name.lower():
                    continue
                known_for = parts[1].strip()
                platforms = parts[2].strip() if len(parts) > 2 else ""
                entries.append({
                    "name": name,
                    "known_for": known_for,
                    "platforms": platforms,
                    "country": current_country,
                    "category": current_category,
                })

    return entries


# ---------------------------------------------------------------------------
# DDG search (minimal)
# ---------------------------------------------------------------------------

def _safe_import_ddgs():
    try:
        from ddgs import DDGS
        return DDGS
    except ImportError:
        return None


def search_ddg_fast(query: str, max_results: int = 5) -> list[str]:
    """Quick DDG search returning URLs only."""
    DDGS = _safe_import_ddgs()
    if DDGS is None:
        return []
    urls: list[str] = []
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, region="wt-wt", max_results=max_results))
        for row in results:
            u = (row.get("href") or row.get("url") or row.get("link") or "").strip()
            if u.startswith(("http://", "https://")):
                urls.append(u)
    except Exception:
        pass
    return urls


# ---------------------------------------------------------------------------
# Substack direct URL construction
# ---------------------------------------------------------------------------

def name_to_substack_slug(name: str) -> list[str]:
    """Generate likely Substack slugs from a person's name."""
    name = name.lower().strip()
    # Remove parentheticals
    name = re.sub(r'\(.*?\)', '', name).strip()
    # Replace spaces/special chars
    base = re.sub(r'[^a-z0-9]', '', name)
    dashed = re.sub(r'[^a-z0-9]', '-', name).strip('-')
    # Common patterns
    slugs = [dashed, base, dashed.replace('--', '-')]
    # First name only, last name only variants
    parts = name.split()
    if len(parts) >= 2:
        slugs.append(parts[-1])           # lastname
        slugs.append(parts[0])            # firstname
        slugs.append(f"{parts[0]}-{parts[-1]}")  # first-last
    return list(set(slugs))


# ---------------------------------------------------------------------------
# Feed discovery and validation
# ---------------------------------------------------------------------------

def is_likely_feed_url(url: str) -> bool:
    patterns = [
        r'/feed/?$', r'/rss/?$', r'/atom/?$', r'\.xml$',
        r'/feeds/', r'\.rss$', r'\.atom$', r'rss\.xml$', r'atom\.xml$',
        r'/index\.xml$',
    ]
    return any(re.search(p, url, re.I) for p in patterns)


def extract_feeds_from_page(url: str, timeout: int = 8) -> list[str]:
    """Fetch an HTML page and extract RSS/Atom <link> tags."""
    feeds: list[str] = []
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0 (RSS discovery)"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return feeds
            html_text = resp.read().decode("utf-8", errors="replace")[:500_000]
    except Exception:
        return feeds

    # <link> tags
    link_pattern = re.compile(
        r'<link[^>]*\b(?:rel|type)=["\'][^"\']*(?:alternate|feed|rss|atom)[^"\']*["\'][^>]*\bhref=["\']([^"\']+)["\']',
        re.I,
    )
    for m in link_pattern.finditer(html_text):
        feed_url = urljoin(url, m.group(1))
        if "/comments/" not in feed_url and "/comment/" not in feed_url:
            feeds.append(feed_url)

    # Also check common feed paths
    parsed = urlparse(url)
    base = f"{parsed.scheme}://{parsed.netloc}"
    for path in ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml"]:
        feeds.append(f"{base}{path}")

    return list(dict.fromkeys(feeds))


def validate_feed_url(url: str, timeout: int = 8) -> tuple[bool, str]:
    """Check if URL returns valid RSS/Atom XML. Returns (is_valid, title_or_reason)."""
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return False, f"HTTP {resp.status}"
            data = resp.read(100_000)
            text = data.decode("utf-8", errors="replace")[:3000].strip()

            # Check for RSS/Atom markers
            if "<rss" in text.lower() or "<feed" in text.lower() or "<rdf" in text.lower():
                # Try to extract a title
                title = ""
                try:
                    import xml.etree.ElementTree as ET
                    root = ET.fromstring(data)
                    if root.tag == "rss":
                        channel = root.find("channel")
                        if channel is not None:
                            t = channel.find("title")
                            if t is not None and t.text:
                                title = t.text.strip()
                    elif root.tag.endswith("feed"):
                        t = root.find("{http://www.w3.org/2005/Atom}title")
                        if t is None:
                            t = root.find("title")
                        if t is not None and t.text:
                            title = t.text.strip()
                except Exception:
                    pass
                return True, title or "valid"
            return False, "no RSS/Atom markers"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}"
    except Exception as e:
        return False, str(e)[:100]


# ---------------------------------------------------------------------------
# Main discovery — fast path per artist
# ---------------------------------------------------------------------------

def discover_artist_feed(entry: dict, existing_urls: set[str]) -> dict | None:
    """Try to find a valid RSS feed for one artist. Returns feed dict or None."""
    name = entry["name"]
    platforms_str = entry["platforms"].lower()
    platforms = {p.strip() for p in platforms_str.split(",")}

    # Skip if no blog-capable platform
    blog_platforms = {"blog", "substack", "website", "newsletter", "gatesnotes", "tumblr"}
    if not (platforms & blog_platforms):
        return None

    # ── Path 1: Substack ──
    if "substack" in platforms:
        slugs = name_to_substack_slug(name)
        for slug in slugs[:5]:
            feed_url = f"https://{slug}.substack.com/feed"
            norm = feed_url.lower()
            if norm in existing_urls:
                continue
            is_valid, title = validate_feed_url(feed_url, timeout=6)
            if is_valid:
                existing_urls.add(norm)
                return {
                    "url": feed_url,
                    "title": title or f"{name} (Substack)",
                    "name": name,
                    "source": "substack-direct",
                }
            time.sleep(0.3)

    # ── Path 2: Blog/website — search DDG for "{name} blog/official site" ──
    if "blog" in platforms or "website" in platforms or "newsletter" in platforms:
        # Try "{name} blog RSS"
        for query in [f'"{name}" blog', f'"{name}" official website', f'"{name}" RSS']:
            urls = search_ddg_fast(query, max_results=5)
            for url in urls:
                if url.lower() in existing_urls:
                    continue

                # If URL is a feed, validate directly
                if is_likely_feed_url(url):
                    is_valid, title = validate_feed_url(url, timeout=6)
                    if is_valid:
                        existing_urls.add(url.lower())
                        return {
                            "url": url,
                            "title": title or name,
                            "name": name,
                            "source": f"ddg:{query}",
                        }
                else:
                    # Try to discover feeds from the page
                    feeds = extract_feeds_from_page(url, timeout=8)
                    for feed_url in feeds:
                        if feed_url.lower() in existing_urls:
                            continue
                        is_valid, title = validate_feed_url(feed_url, timeout=6)
                        if is_valid:
                            existing_urls.add(feed_url.lower())
                            return {
                                "url": feed_url,
                                "title": title or name,
                                "page_url": url,
                                "name": name,
                                "source": f"ddg-discovered:{query}",
                            }
            time.sleep(1.0)  # rate limit DDG

        # ── Path 3: Known blog platforms — try Substack even if not explicitly listed ──
        # Many artists have Substacks that aren't in our data
        if "blog" in platforms or "newsletter" in platforms:
            slugs = name_to_substack_slug(name)
            for slug in slugs[:3]:
                feed_url = f"https://{slug}.substack.com/feed"
                if feed_url.lower() in existing_urls:
                    continue
                is_valid, title = validate_feed_url(feed_url, timeout=6)
                if is_valid:
                    existing_urls.add(feed_url.lower())
                    return {
                        "url": feed_url,
                        "title": title or f"{name} (Substack)",
                        "name": name,
                        "source": "substack-guess",
                    }
                time.sleep(0.2)

    return None


# ---------------------------------------------------------------------------
# OPML generation
# ---------------------------------------------------------------------------

def generate_opml(
    country_name: str,
    feeds: list[dict],
    existing_urls: set[str],
) -> str:
    """Generate OPML snippet with artist blog feeds."""
    lines = []
    for f in feeds:
        url = f["url"]
        norm = url.lower().split("#")[0].rstrip("/")
        if norm in existing_urls:
            continue

        title = f.get("title", "") or f.get("name", "") or url
        title_esc = (title.replace("&", "&amp;").replace("<", "&lt;")
                     .replace(">", "&gt;").replace('"', "&quot;"))
        url_esc = (url.replace("&", "&amp;").replace("<", "&lt;")
                   .replace(">", "&gt;").replace('"', "&quot;"))
        source_id = hashlib.sha256(url.encode()).hexdigest()

        # Determine topic
        name_lower = f.get("name", "").lower()
        known = entry = f.get("known_for", "").lower()
        if any(w in known or w in name_lower for w in ["singer", "musician", "rapper", "band", "song", "composer"]):
            topic = "Music &amp; Audio"
        elif any(w in known or w in name_lower for w in ["actor", "actress", "film", "director", "filmmaker"]):
            topic = "Entertainment"
        else:
            topic = "Arts &amp; Culture"

        lines.append(
            f'                        <outline text="{title_esc}" title="{title_esc}" '
            f'type="rss" xmlUrl="{url_esc}" '
            f'description="Artist blog from {country_name}." '
            f'language="" '
            f'category="artist,blog,personal,{country_name.lower()}" '
            f'feedmineSourceId="{source_id}" '
            f'feedmineTopic="{topic}" '
            f'feedmineSubcategory="Artist Blogs" '
            f'feedmineNature="personal" '
            f'feedmineActivity="active" '
            f'feedmineArticlesFetched="0" '
            f'feedmineQualityScore="70" '
            f'feedmineDefaultEnabled="true" '
            f'feedmineMediaKind="text" '
            f'htmlUrl="{url_esc}" />'
        )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Country slug mapping
# ---------------------------------------------------------------------------

# Map country names from famous_people.txt to Feedmine slugs
COUNTRY_NAME_TO_SLUG: dict[str, str] = {
    "brazil": "brazil",
    "united states": "usa",
    "united kingdom": "united_kingdom",
    "france": "france",
    "germany": "germany",
    "japan": "japan",
    "india": "india",
    "canada": "canada",
    "mexico": "mexico",
    "nigeria": "nigeria",
    "south korea": "south_korea",
    "argentina": "argentina",
    "australia": "australia",
    "italy": "italy",
    "spain": "spain",
    "russia": "russia",
    "china": "china",
    "turkey": "turkey",
    "iran": "iran",
    "poland": "poland",
    "netherlands": "netherlands",
    "sweden": "sweden",
    "norway": "norway",
    "denmark": "denmark",
    "finland": "finland",
    "belgium": "belgium",
    "switzerland": "switzerland",
    "austria": "austria",
    "portugal": "portugal",
    "greece": "greece",
    "ireland": "ireland",
    "new zealand": "new_zealand",
    "south africa": "south_africa",
    "egypt": "egypt",
    "saudi arabia": "saudi_arabia",
    "uae": "uae",
    "israel": "israel",
    "pakistan": "pakistan",
    "bangladesh": "bangladesh",
    "indonesia": "indonesia",
    "malaysia": "malaysia",
    "philippines": "philippines",
    "vietnam": "vietnam",
    "thailand": "thailand",
    "colombia": "colombia",
    "chile": "chile",
    "peru": "peru",
    "venezuela": "venezuela",
    "ukraine": "ukraine",
    "romania": "romania",
    "czech_republic": "czech republic",
    "hungary": "hungary",
    "serbia": "serbia",
    "croatia": "croatia",
    "bulgaria": "bulgaria",
    "slovakia": "slovakia",
    "slovenia": "slovenia",
    "lithuania": "lithuania",
    "latvia": "latvia",
    "estonia": "estonia",
    "cyprus": "cyprus",
    "luxembourg": "luxembourg",
    "malta": "malta",
    "iceland": "iceland",
    "kenya": "kenya",
    "ghana": "ghana",
    "ethiopia": "ethiopia",
    "morocco": "morocco",
    "tunisia": "tunisia",
    "algeria": "algeria",
    "ivory coast": "ivory_coast",
    "singapore": "singapore",
    "taiwan": "taiwan",
    "myanmar": "myanmar",
    "cambodia": "cambodia",
    "sri lanka": "sri_lanka",
    "nepal": "nepal",
    "kazakhstan": "kazakhstan",
    "azerbaijan": "azerbaijan",
    "georgia": "georgia",
    "armenia": "armenia",
    "belarus": "belarus",
    "cuba": "cuba",
    "dominican republic": "dominican_republic",
    "puerto rico": "puerto_rico",
    "jamaica": "jamaica",
    "haiti": "haiti",
    "panama": "panama",
    "costa rica": "costa_rica",
    "el salvador": "el_salvador",
    "guatemala": "guatemala",
    "honduras": "honduras",
    "nicaragua": "nicaragua",
    "bolivia": "bolivia",
    "ecuador": "ecuador",
    "paraguay": "paraguay",
    "uruguay": "uruguay",
    "angola": "angola",
    "iraq": "iraq",
    "qatar": "qatar",
    "sudan": "sudan",
    "finland": "finland",
}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Fast artist blog discovery from famous_people.txt seed data"
    )
    parser.add_argument("--country", help="Feedmine country slug (e.g. brazil)")
    parser.add_argument("--all", action="store_true", help="Process all countries")
    parser.add_argument("--opml", action="store_true", help="Generate OPML output files")
    parser.add_argument("--output-dir", default=None, help="Output directory for OPML")
    parser.add_argument("--limit", type=int, default=0, help="Max feeds per country (0=unlimited)")
    parser.add_argument("--max-countries", type=int, default=None)
    parser.add_argument("--dry-run", action="store_true", help="Just count, don't discover")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    famous_path = repo_root / "scripts" / "feed_discovery" / "data" / "famous_people.txt"
    countries_json = repo_root / "scripts" / "feed_discovery" / "data" / "countries.json"
    countries_dir = repo_root / "feedmine" / "Resources" / "Feeds" / "90_countries"
    cache_dir = repo_root / "scripts" / "feed_discovery" / "data" / "artist_cache_v2"

    # Parse all entries
    all_entries = parse_famous_people_all(famous_path)
    print(f"Loaded {len(all_entries)} total entries from famous_people.txt")

    # Filter to entries with blog-capable platforms
    blog_platforms = {"blog", "substack", "website", "newsletter", "gatesnotes", "tumblr"}
    artist_entries = [e for e in all_entries
                      if blog_platforms & {p.strip() for p in e["platforms"].lower().split(",")}]
    print(f"{len(artist_entries)} entries have blog/website/substack platforms\n")

    # Load valid country slugs
    with open(countries_json, encoding="utf-8") as f:
        valid_slugs = set(json.load(f).keys())

    # Group by Feedmine country slug
    by_slug: dict[str, list[dict]] = {}
    for entry in artist_entries:
        country_name = entry["country"].lower()
        slug = COUNTRY_NAME_TO_SLUG.get(country_name, country_name.replace(" ", "_"))
        # Only include valid Feedmine countries
        if slug not in valid_slugs:
            continue
        by_slug.setdefault(slug, []).append(entry)

    print(f"Entries grouped into {len(by_slug)} countries: {sorted(by_slug.keys())}\n")

    # Load countries.json
    with open(countries_json, encoding="utf-8") as f:
        countries = json.load(f)

    # Determine which slugs to process
    if args.country:
        slugs = [args.country]
    elif args.all:
        slugs = sorted(set(list(by_slug.keys()) + list(countries.keys())))
        if args.max_countries:
            slugs = slugs[:args.max_countries]
    else:
        # Default: countries with seed data, first 5
        slugs_with_data = [s for s in by_slug if s in countries][:5]
        slugs = slugs_with_data
        print(f"Testing with {len(slugs)} countries that have seed data: {slugs}")
        print("Use --all for full run.\n")

    if args.dry_run:
        for slug in slugs:
            entries = by_slug.get(slug, [])
            country_name = countries.get(slug, {}).get("name", slug)
            print(f"  {country_name} ({slug}): {len(entries)} seed entries")
        return

    total_feeds = 0
    cache_dir.mkdir(parents=True, exist_ok=True)

    for slug in slugs:
        entries = by_slug.get(slug, [])
        country_name = countries.get(slug, {}).get("name", slug)

        # Load cache
        cache_file = cache_dir / f"{slug}_feeds.json"
        if cache_file.exists():
            try:
                cached = json.loads(cache_file.read_text(encoding="utf-8"))
                print(f"📦 {country_name} ({slug}): {len(cached)} cached feeds")
                total_feeds += len(cached)
                continue
            except Exception:
                pass

        # Existing feed URLs
        existing_urls: set[str] = set()
        country_opml = countries_dir / slug / f"{slug}.opml"
        if country_opml.exists():
            try:
                content = country_opml.read_text(encoding="utf-8")
                for m in re.finditer(r'xmlUrl="([^"]+)"', content):
                    existing_urls.add(m.group(1).strip().rstrip("/").lower())
            except Exception:
                pass

        if not entries:
            print(f"⏭️  {country_name} ({slug}): no seed data, skipping")
            continue

        print(f"🔍 {country_name} ({slug}): {len(entries)} candidates, "
              f"{len(existing_urls)} existing feeds")

        # Discover feeds
        feeds: list[dict] = []
        seen_names: set[str] = set()

        for i, entry in enumerate(entries):
            if entry["name"] in seen_names:
                continue
            seen_names.add(entry["name"])

            result = discover_artist_feed(entry, existing_urls)
            if result:
                result["country_slug"] = slug
                result["country_name"] = country_name
                feeds.append(result)
                print(f"  ✅ {result['title'][:60]} — {result['source']}")

            if args.limit and len(feeds) >= args.limit:
                break

            if (i + 1) % 10 == 0:
                print(f"  ... {i+1}/{len(entries)} checked, {len(feeds)} found")

        print(f"  → {len(feeds)} valid feeds found for {country_name}")

        # Save cache
        cache_file.write_text(json.dumps(feeds, ensure_ascii=False, indent=2), encoding="utf-8")

        # OPML output
        if args.opml and feeds:
            opml_snippet = generate_opml(country_name, feeds, set())
            output_dir = Path(args.output_dir) if args.output_dir else cache_dir / "opml"
            output_dir.mkdir(parents=True, exist_ok=True)
            opml_file = output_dir / f"{slug}_artist_blogs.opml"
            opml_file.write_text(opml_snippet, encoding="utf-8")
            print(f"  📄 OPML → {opml_file}")

        total_feeds += len(feeds)

    print(f"\n{'='*60}")
    print(f"✅ Total: {total_feeds} artist blog feeds across {len(slugs)} countries")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
