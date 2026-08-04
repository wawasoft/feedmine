#!/usr/bin/env python3
"""
Fast artist blog RSS discovery — NO web search, direct URL construction + validation.

Strategies (all direct, no DDG):
  1. Substack:  https://{slug}.substack.com/feed  (instant construction)
  2. Blogspot:  https://{slug}.blogspot.com/feeds/posts/default
  3. WordPress: https://{slug}.com/feed  from known domains
  4. Ghost:     https://{slug}.ghost.io/rss/

Uses concurrent HTTP validation (8 threads) for speed.
Targets only famous_people.txt entries with blog/substack/website platforms.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import re
import sys
import time
import urllib.request
import urllib.error
from pathlib import Path
from urllib.parse import urljoin, urlparse

try:
    from scripts.catalog_identity import compute_source_id
except ModuleNotFoundError:
    from catalog_identity import compute_source_id


# ---------------------------------------------------------------------------
# Parse famous_people.txt
# ---------------------------------------------------------------------------

def parse_famous_people(famous_path: Path) -> list[dict]:
    """Parse ALL artist entries from famous_people.txt."""
    entries: list[dict] = []
    current_country: str | None = None

    if not famous_path.exists():
        return entries

    content = famous_path.read_text(encoding="utf-8")

    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("===") or line == "COUNTRIES":
            continue

        # Country header: # --- BRAZIL (50+) ---
        country_match = re.match(r'^#\s*---\s*(.+?)\s*\(\d+', line)
        if country_match:
            current_country = country_match.group(1).strip()
            continue

        # Skip category-only headers
        if line.startswith("# ") and "|" not in line:
            continue

        # Data line: Name | known for | platform1, platform2
        if "|" in line and current_country:
            parts = [p.strip() for p in line.split("|")]
            if len(parts) >= 2:
                name = parts[0].strip()
                if "(estate)" in name.lower() or "(legacy)" in name.lower():
                    continue
                known_for = parts[1].strip()
                platforms = parts[2].strip() if len(parts) > 2 else ""
                entries.append({
                    "name": name,
                    "known_for": known_for,
                    "platforms": platforms,
                    "country": current_country,
                })

    return entries


# ---------------------------------------------------------------------------
# Slug generation for name → URL construction
# ---------------------------------------------------------------------------

def name_to_slugs(name: str) -> list[str]:
    """Generate likely URL slugs from a name."""
    name = name.lower().strip()
    name = re.sub(r'\(.*?\)', '', name).strip()
    # Remove accents (simple version)
    name = name.replace('á', 'a').replace('ã', 'a').replace('â', 'a').replace('à', 'a')
    name = name.replace('é', 'e').replace('ê', 'e').replace('ë', 'e')
    name = name.replace('í', 'i').replace('î', 'i')
    name = name.replace('ó', 'o').replace('õ', 'o').replace('ô', 'o')
    name = name.replace('ú', 'u').replace('ü', 'u')
    name = name.replace('ç', 'c').replace('ñ', 'n')
    name = name.replace('ś', 's').replace('š', 's')
    name = name.replace('ł', 'l')
    name = name.replace('ž', 'z')

    dashed = re.sub(r'[^a-z0-9]+', '-', name).strip('-')
    flat = re.sub(r'[^a-z0-9]+', '', name)

    slugs = []
    if dashed:
        slugs.append(dashed)
    if flat and flat != dashed:
        slugs.append(flat)

    # Firstname-lastname variants
    parts = [p for p in name.split() if len(p) > 1]
    if len(parts) >= 2:
        fn_ln = f"{parts[0]}-{parts[-1]}"
        slugs.append(fn_ln)
        slugs.append(f"{parts[0]}{parts[-1]}")

    # Remove consecutive dashes
    return list(set(s.replace('--', '-') for s in slugs if s))


# ---------------------------------------------------------------------------
# URL construction patterns
# ---------------------------------------------------------------------------

def construct_feed_urls(name: str, platforms: set[str]) -> list[tuple[str, str]]:
    """Generate likely feed URLs for an artist. Returns [(url, source_label)]."""
    slugs = name_to_slugs(name)
    urls: list[tuple[str, str]] = []

    for slug in slugs:
        # Substack
        urls.append((f"https://{slug}.substack.com/feed", "substack"))

    # Blogspot
    for slug in slugs[:3]:
        urls.append((f"https://{slug}.blogspot.com/feeds/posts/default", "blogspot"))

    # Ghost
    for slug in slugs[:2]:
        urls.append((f"https://{slug}.ghost.io/rss/", "ghost"))

    # WordPress.com
    for slug in slugs[:2]:
        urls.append((f"https://{slug}.wordpress.com/feed/", "wordpress"))

    # Direct domain + /feed (for custom domains)
    for slug in slugs[:2]:
        urls.append((f"https://{slug}.com/feed", "custom-feed"))
        urls.append((f"https://{slug}.com/feed.xml", "custom-feed"))
        urls.append((f"https://www.{slug}.com/feed", "custom-feed"))
        urls.append((f"https://{slug}.com/rss", "custom-rss"))
        urls.append((f"https://www.{slug}.com/rss", "custom-rss"))
        urls.append((f"https://{slug}.com/blog/feed", "custom-blog"))
        urls.append((f"https://www.{slug}.com/blog/feed", "custom-blog"))

    return urls


# ---------------------------------------------------------------------------
# Feed validation
# ---------------------------------------------------------------------------

def validate_feed_url(url: str, timeout: int = 6) -> tuple[bool, str, str]:
    """Check if a URL returns valid RSS/Atom. Returns (is_valid, title, error)."""
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return False, "", f"HTTP {resp.status}"
            data = resp.read(100_000)
            text = data.decode("utf-8", errors="replace")[:3000].strip().lower()

            if "<rss" not in text and "<feed" not in text and "<rdf" not in text:
                return False, "", "no feed markers"

            # Extract title
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
                elif "feed" in root.tag:
                    for t in root:
                        if t.tag.endswith("title") or t.tag == "title":
                            title = (t.text or "").strip()
                            break
            except Exception:
                pass

            return True, title, "valid"

    except urllib.error.HTTPError as e:
        return False, "", f"HTTP {e.code}"
    except Exception as e:
        return False, "", str(e)[:80]


def check_one_url(url: str, source: str) -> dict | None:
    """Validate one URL. Returns feed dict or None."""
    is_valid, title, error = validate_feed_url(url)
    if is_valid:
        return {"url": url, "title": title, "source": f"{source}-direct", "error": error}
    return None


# ---------------------------------------------------------------------------
# Country name → slug mapping
# ---------------------------------------------------------------------------

COUNTRY_NAME_TO_SLUG: dict[str, str] = {
    "brazil": "brazil", "united states": "usa", "united kingdom": "united-kingdom",
    "france": "france", "germany": "germany", "japan": "japan",
    "india": "india", "canada": "canada", "mexico": "mexico",
    "nigeria": "nigeria", "south korea": "south_korea", "argentina": "argentina",
    "australia": "australia", "italy": "italy", "spain": "spain",
    "russia": "russia", "turkey": "turkey", "poland": "poland",
    "netherlands": "netherlands", "sweden": "sweden", "norway": "norway",
    "denmark": "denmark", "finland": "finland", "belgium": "belgium",
    "switzerland": "switzerland", "austria": "austria", "portugal": "portugal",
    "greece": "greece", "ireland": "ireland", "new zealand": "new_zealand",
    "south africa": "south_africa", "egypt": "egypt",
    "saudi arabia": "saudi_arabia", "uae": "uae", "israel": "israel",
    "pakistan": "pakistan", "bangladesh": "bangladesh", "indonesia": "indonesia",
    "malaysia": "malaysia", "philippines": "philippines", "vietnam": "vietnam",
    "thailand": "thailand", "colombia": "colombia", "chile": "chile",
    "peru": "peru", "venezuela": "venezuela", "ukraine": "ukraine",
    "romania": "romania", "hungary": "hungary", "serbia": "serbia",
    "croatia": "croatia", "bulgaria": "bulgaria", "slovakia": "slovakia",
    "slovenia": "slovenia", "lithuania": "lithuania", "latvia": "latvia",
    "estonia": "estonia", "cyprus": "cyprus", "luxembourg": "luxembourg",
    "malta": "malta", "iceland": "iceland", "kenya": "kenya",
    "ghana": "ghana", "ethiopia": "ethiopia", "morocco": "morocco",
    "tunisia": "tunisia", "algeria": "algeria", "ivory coast": "ivory_coast",
    "singapore": "singapore", "taiwan": "taiwan", "china": "china",
    "czech republic": "czech_republic", "sri lanka": "sri_lanka",
    "nepal": "nepal", "kazakhstan": "kazakhstan", "azerbaijan": "azerbaijan",
    "georgia": "georgia", "armenia": "armenia", "belarus": "belarus",
    "cuba": "cuba", "dominican republic": "dominican_republic",
    "puerto rico": "puerto_rico", "jamaica": "jamaica", "haiti": "haiti",
    "panama": "panama", "costa rica": "costa_rica",
    "el salvador": "el_salvador", "guatemala": "guatemala",
    "honduras": "honduras", "nicaragua": "nicaragua", "bolivia": "bolivia",
    "ecuador": "ecuador", "paraguay": "paraguay", "uruguay": "uruguay",
    "angola": "angola", "iraq": "iraq", "qatar": "qatar", "sudan": "sudan",
    "myanmar": "myanmar", "cambodia": "cambodia",
}


# ---------------------------------------------------------------------------
# OPML generation
# ---------------------------------------------------------------------------

def generate_opml(country_name: str, feeds: list[dict]) -> str:
    """Generate OPML snippet with artist blog feeds."""
    lines = []
    for f in feeds:
        url = f["url"]
        title = f.get("title", "") or f.get("name", "") or url
        title_esc = (title.replace("&", "&amp;").replace("<", "&lt;")
                     .replace(">", "&gt;").replace('"', "&quot;"))
        url_esc = (url.replace("&", "&amp;").replace("<", "&lt;")
                   .replace(">", "&gt;").replace('"', "&quot;"))
        source_id = compute_source_id(url)

        known = f.get("known_for", "").lower()
        if any(w in known for w in ["singer", "musician", "rapper", "band", "song", "composer", "music"]):
            topic = "Music &amp; Audio"
        elif any(w in known for w in ["actor", "actress", "film", "director", "filmmaker", "tv", "comedy"]):
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
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Fast artist blog discovery — direct URL construction, no web search"
    )
    parser.add_argument("--country", help="Feedmine country slug (e.g. brazil)")
    parser.add_argument("--all", action="store_true", help="Process all countries with seed data")
    parser.add_argument("--opml", action="store_true", help="Generate OPML output files")
    parser.add_argument("--output-dir", default=None)
    parser.add_argument("--workers", type=int, default=10, help="Concurrent HTTP workers")
    parser.add_argument("--timeout", type=int, default=6, help="HTTP timeout per URL")
    parser.add_argument("--max-per-artist", type=int, default=15, help="Max URLs to try per artist")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    famous_path = repo_root / "scripts" / "feed_discovery" / "data" / "famous_people.txt"
    countries_json = repo_root / "scripts" / "feed_discovery" / "data" / "countries.json"
    countries_dir = repo_root / "feedmine" / "Resources" / "Feeds" / "90_countries"
    cache_dir = repo_root / "scripts" / "feed_discovery" / "data" / "artist_cache_v3"

    # Parse all entries
    all_entries = parse_famous_people(famous_path)
    print(f"Parsed {len(all_entries)} entries from famous_people.txt")

    # Filter to entries with blog/substack/website
    blog_platforms = {"blog", "substack", "website", "newsletter", "gatesnotes", "tumblr"}
    candidates = [e for e in all_entries
                  if blog_platforms & {p.strip().lower() for p in e["platforms"].split(",")}]
    print(f"{len(candidates)} have blog/website/substack platforms")

    # Load valid slugs
    with open(countries_json, encoding="utf-8") as f:
        valid_slugs = set(json.load(f).keys())

    # Group by slug
    by_slug: dict[str, list[dict]] = {}
    for entry in candidates:
        cn = entry["country"].lower()
        slug = COUNTRY_NAME_TO_SLUG.get(cn, cn.replace(" ", "_"))
        if slug not in valid_slugs:
            continue
        by_slug.setdefault(slug, []).append(entry)

    print(f"Covered countries: {sorted(by_slug.keys())}")

    # Determine slugs to process
    if args.country:
        slugs = [args.country]
    elif args.all:
        slugs = sorted(by_slug.keys())
    else:
        slugs = sorted(by_slug.keys())[:3]
        print(f"\nTesting {slugs}. Use --all for full run.")

    if args.dry_run:
        for slug in slugs:
            entries = by_slug.get(slug, [])
            cname = json.loads(open(countries_json).read()).get(slug, {}).get("name", slug)
            print(f"  {cname} ({slug}): {len(entries)} candidates")
        return

    cache_dir.mkdir(parents=True, exist_ok=True)
    total_feeds = 0

    for slug in slugs:
        entries = by_slug.get(slug, [])
        if not entries:
            continue

        with open(countries_json, encoding="utf-8") as f:
            country_name = json.load(f).get(slug, {}).get("name", slug)

        # Load cache
        cache_file = cache_dir / f"{slug}_feeds.json"
        if cache_file.exists():
            try:
                cached = json.loads(cache_file.read_text(encoding="utf-8"))
                print(f"\n📦 {country_name} ({slug}): {len(cached)} cached feeds")
                total_feeds += len(cached)
                continue
            except Exception:
                pass

        # Load existing feed URLs
        existing_urls: set[str] = set()
        country_opml = countries_dir / slug / f"{slug}.opml"
        if country_opml.exists():
            try:
                for m in re.finditer(r'xmlUrl="([^"]+)"', country_opml.read_text(encoding="utf-8")):
                    existing_urls.add(m.group(1).strip().rstrip("/").lower())
            except Exception:
                pass

        print(f"\n🔍 {country_name} ({slug}): {len(entries)} artists, "
              f"{len(existing_urls)} existing feeds")

        # Build URL list for all artists
        url_tasks: list[tuple[str, dict]] = []  # (url, artist_entry)
        seen_candidate_urls: set[str] = set()

        for entry in entries:
            platforms = {p.strip().lower() for p in entry["platforms"].split(",")}
            feed_urls = construct_feed_urls(entry["name"], platforms)
            for url, source in feed_urls[:args.max_per_artist]:
                norm = url.lower().rstrip("/")
                if norm not in existing_urls and norm not in seen_candidate_urls:
                    seen_candidate_urls.add(norm)
                    url_tasks.append((url, {**entry, "source": source}))

        print(f"  → {len(url_tasks)} URLs to validate (from {len(entries)} artists)")

        # Validate concurrently
        feeds: list[dict] = []
        found_urls: set[str] = set()

        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
            future_to_url = {
                executor.submit(check_one_url, url, entry["source"]): (url, entry)
                for url, entry in url_tasks
            }

            done_count = 0
            for future in concurrent.futures.as_completed(future_to_url):
                done_count += 1
                result = future.result()
                if result:
                    url, entry = future_to_url[future]
                    if result["url"].lower().rstrip("/") not in found_urls:
                        found_urls.add(result["url"].lower().rstrip("/"))
                        feeds.append({
                            **entry,
                            "url": result["url"],
                            "feed_title": result["title"] or entry["name"],
                            "source": result["source"],
                        })
                        print(f"  ✅ {result['title'] or entry['name'][:50]} — {result['source']}")

                if done_count % 50 == 0:
                    print(f"  ... {done_count}/{len(url_tasks)} checked, {len(feeds)} found")

        print(f"  → {len(feeds)} valid feeds found for {country_name}")

        # Save cache
        cache_file.write_text(json.dumps(feeds, ensure_ascii=False, indent=2), encoding="utf-8")

        # OPML
        if args.opml and feeds:
            opml_snippet = generate_opml(country_name, feeds)
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
