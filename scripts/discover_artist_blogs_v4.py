#!/usr/bin/env python3
"""
Hybrid artist blog discovery: Wikidata names → URL construction → concurrent validation.

For each country:
  1. Wikidata SPARQL: get musician/actor/artist names (no website required — broader)
  2. For each name, construct likely feed URLs (Substack, Blogspot, WordPress, Ghost, etc.)
  3. Validate all URLs concurrently (12 workers)
  4. Also try DDG search for countries where Wikidata returns few results
  5. Generate per-country OPML

Covers all 101 Feedmine countries. Fast because URL validation is the only I/O bottleneck.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
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

REPO_ROOT = Path(__file__).resolve().parents[1]
CACHE_DIR = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "artist_v4"
COUNTRIES_JSON = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "countries.json"
COUNTRIES_DIR = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "90_countries"


# ===========================================================================
# Wikidata — get artist NAMES by country (no website required)
# ===========================================================================

WIKIDATA_SPARQL = "https://query.wikidata.org/sparql"
ISO2_TO_QID: dict[str, str] = {}
REVERSE_QID_MAP: dict[str, str] = {}  # Q-ID → ISO2

# Occupations we care about
OCCUPATION_QIDS = {
    "Q639669": "musician",   # musician
    "Q177220": "singer",      # singer
    "Q33999": "actor",        # actor
    "Q1028181": "painter",    # painter
    "Q483501": "artist",      # visual artist
    "Q36834": "composer",     # composer
    "Q488205": "singer-songwriter",
    "Q753110": "songwriter",
    "Q1281618": "sculptor",
    "Q33231": "photographer",
    "Q2526255": "film director",
    "Q2252262": "rapper",
    "Q10800557": "film actor",
    "Q1075651": "stage actor",
}


def resolve_country_qid(iso2: str) -> str | None:
    if iso2 in ISO2_TO_QID:
        return ISO2_TO_QID[iso2]
    query = f'SELECT ?country WHERE {{ ?country wdt:P297 "{iso2.upper()}". }} LIMIT 1'
    try:
        url = WIKIDATA_SPARQL + "?format=json&query=" + urllib.parse.quote(query)
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0", "Accept": "application/json"
        })
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
        bindings = data.get("results", {}).get("bindings", [])
        if bindings:
            qid = bindings[0]["country"]["value"].split("/")[-1]
            ISO2_TO_QID[iso2] = qid
            REVERSE_QID_MAP[qid] = iso2
            return qid
    except Exception:
        pass
    return None


def wikidata_artist_names(iso2: str, lang: str, max_per_profession: int = 80) -> list[str]:
    """Get artist names from Wikidata for a country. Only names, no websites."""
    country_qid = resolve_country_qid(iso2)
    if not country_qid:
        return []

    all_names: set[str] = set()

    for qid, category in list(OCCUPATION_QIDS.items())[:8]:  # first 8 professions = faster
        query = f"""
            SELECT DISTINCT ?itemLabel WHERE {{
              ?item wdt:P106 wd:{qid}.
              ?item wdt:P17 wd:{country_qid}.
              SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{lang},en". }}
            }}
            LIMIT {max_per_profession}
        """
        try:
            url = WIKIDATA_SPARQL + "?format=json&query=" + urllib.parse.quote(query)
            req = urllib.request.Request(url, headers={
                "User-Agent": "Feedmine/1.0", "Accept": "application/json"
            })
            with urllib.request.urlopen(req, timeout=25) as resp:
                data = json.loads(resp.read())
        except Exception:
            continue

        for binding in data.get("results", {}).get("bindings", []):
            name = binding.get("itemLabel", {}).get("value", "").strip()
            if name and len(name) > 1:
                all_names.add(name)

        time.sleep(0.4)

    return sorted(all_names)


# ===========================================================================
# URL construction from name
# ===========================================================================

def name_to_slugs(name: str) -> list[str]:
    """Generate likely URL slugs from a name."""
    name = name.lower().strip()
    name = re.sub(r'\(.*?\)', '', name).strip()
    name = re.sub(r'\b(film|painting|music|band|group|actor|actress|singer|rapper|dj)\b', '', name).strip()
    name = re.sub(r'\s+', ' ', name)

    # Remove accents
    accents = str.maketrans(
        'áãâàäéêèëíîìïóõôòöúûùüçñśšłžćč',
        'aaaaaeeeeiiiiooooouuuucnsslscc'
    )
    name = name.translate(accents)

    dashed = re.sub(r'[^a-z0-9]+', '-', name).strip('-')
    flat = re.sub(r'[^a-z0-9]+', '', name)

    slugs = []
    if dashed:
        slugs.append(dashed)
    if flat and flat != dashed:
        slugs.append(flat)

    parts = [p for p in name.split() if len(p) > 1]
    if len(parts) >= 2:
        slugs.append(f"{parts[0]}-{parts[-1]}")
        slugs.append(f"{parts[0]}{parts[-1]}")

    return list(dict.fromkeys(s.replace('--', '-') for s in slugs if s and len(s) > 2))


def construct_urls(name: str) -> list[tuple[str, str]]:
    """Build potential feed URLs for an artist name. Returns [(url, source)]."""
    slugs = name_to_slugs(name)
    urls: list[tuple[str, str]] = []

    for slug in slugs[:6]:
        # Substack
        urls.append((f"https://{slug}.substack.com/feed", "substack"))

    for slug in slugs[:4]:
        # Blogspot
        urls.append((f"https://{slug}.blogspot.com/feeds/posts/default", "blogspot"))
        # WordPress.com
        urls.append((f"https://{slug}.wordpress.com/feed/", "wordpress-com"))
        # Ghost
        urls.append((f"https://{slug}.ghost.io/rss/", "ghost"))

    for slug in slugs[:3]:
        # Custom domains
        urls.append((f"https://{slug}.com/feed", "custom"))
        urls.append((f"https://www.{slug}.com/feed", "custom"))
        urls.append((f"https://{slug}.com/feed.xml", "custom"))
        urls.append((f"https://{slug}.com/rss.xml", "custom"))
        urls.append((f"https://www.{slug}.com/rss.xml", "custom"))
        urls.append((f"https://{slug}.com/blog/feed", "custom"))

    # Deduplicate URLs
    seen = set()
    result = []
    for url, source in urls:
        if url not in seen:
            seen.add(url)
            result.append((url, source))
    return result


# ===========================================================================
# Feed validation
# ===========================================================================

def is_feed_url(url: str) -> bool:
    patterns = [r'/feed/?$', r'/rss/?$', r'/atom/?$', r'\.xml$',
                r'/feeds/', r'\.rss$', r'\.atom$', r'/rss\.xml$', r'/feed\.xml$']
    return any(re.search(p, url, re.I) for p in patterns)


def validate_feed(url: str, timeout: int = 6) -> tuple[bool, str]:
    """Returns (is_valid, title_or_error)."""
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return False, f"HTTP {resp.status}"
            data = resp.read(100_000)
            text = data.decode("utf-8", errors="replace")[:3000].strip().lower()
            if "<rss" in text or "<feed" in text or "<rdf" in text:
                title = ""
                try:
                    import xml.etree.ElementTree as ET
                    root = ET.fromstring(data)
                    if root.tag == "rss":
                        ch = root.find("channel")
                        if ch is not None:
                            t = ch.find("title")
                            if t is not None and t.text:
                                title = t.text.strip()
                    elif "feed" in root.tag:
                        for el in root:
                            if el.tag.endswith("title") or el.tag == "title":
                                title = (el.text or "").strip()
                                break
                except Exception:
                    pass
                return True, title or "valid"
            return False, "no markers"
    except urllib.error.HTTPError as e:
        return False, f"HTTP {e.code}"
    except Exception as e:
        return False, str(e)[:80]


# ===========================================================================
# DDG search for countries with few Wikidata results
# ===========================================================================

def _safe_ddgs():
    try:
        from ddgs import DDGS
        return DDGS
    except ImportError:
        return None


def ddg_search_urls(query: str, region: str, n: int = 8) -> list[str]:
    DDGS = _safe_ddgs()
    if DDGS is None:
        return []
    try:
        with DDGS() as ddgs:
            results = list(ddgs.text(query, region=region, max_results=n))
        return [r.get("href") or r.get("url") or "" for r in results
                if (r.get("href") or r.get("url") or "").startswith("http")]
    except Exception:
        return []


# ===========================================================================
# Country discovery
# ===========================================================================

def discover_country(slug: str, meta: dict, existing_feeds: set[str],
                     wd_names: list[str] | None = None,
                     use_ddg: bool = True) -> tuple[list[dict], list[str]]:
    """Returns (feeds, wikidata_names_used)."""
    name = meta["name"]
    cctld = meta.get("cctld", "")
    iso2 = meta.get("iso2", "")
    region = meta.get("ddg_region", f"{cctld}-{meta['lang']}")

    # 1. Get artist names from Wikidata (or use provided)
    if wd_names is None:
        lang = meta.get("lang", "en")
        print(f"  [wikidata] Fetching artist names...")
        wd_names = wikidata_artist_names(iso2, lang, max_per_profession=60)
    print(f"  → {len(wd_names)} Wikidata artist names")

    # 2. Build URLs to validate
    url_tasks: list[tuple[str, dict]] = []
    seen_urls: set[str] = set()
    per_artist = 18 if len(wd_names) < 30 else 12 if len(wd_names) < 80 else 8

    for artist_name in wd_names:
        for url, source in construct_urls(artist_name)[:per_artist]:
            norm = url.lower().rstrip("/")
            if norm not in existing_feeds and norm not in seen_urls:
                seen_urls.add(norm)
                url_tasks.append((url, {"name": artist_name, "source": source}))

    # 3. DDG enrichment for small countries
    ddg_urls: set[str] = set()
    if use_ddg and len(wd_names) < 50:
        print(f"  [ddg] Enriching with web search...")
        for term in ["musician blog", "singer blog", "actor blog", "artist blog"]:
            query = f'{term} {name}'
            for u in ddg_search_urls(query, region, n=8):
                norm = u.rstrip("/")
                if norm not in existing_feeds and norm not in seen_urls and norm not in ddg_urls:
                    ddg_urls.add(norm)
                    url_tasks.append((u, {"name": "", "source": f"ddg:{term}"}))
            time.sleep(0.8)

        # Platform search
        for platform in ["substack.com", "blogspot.com"]:
            query = f'site:{platform} blog {name}'
            for u in ddg_search_urls(query, region, n=5):
                norm = u.rstrip("/")
                if norm not in existing_feeds and norm not in seen_urls and norm not in ddg_urls:
                    ddg_urls.add(norm)
                    url_tasks.append((u, {"name": "", "source": f"ddg:platform:{platform}"}))
            time.sleep(0.8)

    # Deduplicate
    unique = []
    seen2 = set()
    for url, entry in url_tasks:
        n = url.lower().rstrip("/")
        if n not in seen2:
            seen2.add(n)
            unique.append((url, entry))
    url_tasks = unique

    print(f"  → {len(url_tasks)} URLs to validate (from {len(wd_names)} artists + DDG)")

    # 4. Concurrent validation
    feeds: list[dict] = []
    found_set: set[str] = set()

    def check(url_entry):
        url, entry = url_entry
        if is_feed_url(url):
            ok, title = validate_feed(url)
            if ok:
                return {"url": url, "title": title, "name": entry["name"], "source": entry["source"]}
        else:
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "Feedmine/1.0"})
                with urllib.request.urlopen(req, timeout=6) as resp:
                    if resp.status == 200:
                        html = resp.read().decode("utf-8", errors="replace")[:200_000]
                link_re = re.compile(
                    r'<link[^>]*(?:rel|type)=["\'][^"\']*(?:alternate|feed|rss|atom)[^"\']*["\'][^>]*href=["\']([^"\']+)["\']',
                    re.I,
                )
                for m in link_re.finditer(html):
                    f_url = urljoin(url, m.group(1))
                    if "/comments/" not in f_url:
                        ok, title = validate_feed(f_url)
                        if ok:
                            return {"url": f_url, "title": title, "name": entry["name"],
                                    "source": f"discovered:{entry['source']}"}
                # Also probe common paths
                parsed = urlparse(url)
                base = f"{parsed.scheme}://{parsed.netloc}"
                for p in ["/feed", "/rss", "/feed.xml", "/rss.xml"]:
                    f_url = base + p
                    ok, title = validate_feed(f_url)
                    if ok:
                        return {"url": f_url, "title": title, "name": entry["name"],
                                "source": f"probe:{entry['source']}"}
            except Exception:
                pass
        return None

    with concurrent.futures.ThreadPoolExecutor(max_workers=15) as executor:
        futures = {executor.submit(check, t): t for t in url_tasks}
        done = 0
        for future in concurrent.futures.as_completed(futures):
            done += 1
            result = future.result()
            if result:
                norm = result["url"].lower().rstrip("/")
                if norm not in found_set:
                    found_set.add(norm)
                    feeds.append(result)
                    if len(feeds) <= 20 or len(feeds) % 10 == 0:
                        print(f"  ✅ [{len(feeds)}] {result['title'] or result['name'][:50]} — {result['source']}")
            if done % 100 == 0:
                print(f"  ... {done}/{len(url_tasks)} checked, {len(feeds)} found")

    # Deduplicate by URL
    final = []
    seen_f = set()
    for f in feeds:
        n = f["url"].lower().rstrip("/")
        if n not in seen_f:
            seen_f.add(n)
            final.append(f)

    return final, wd_names


# ===========================================================================
# OPML
# ===========================================================================

def generate_opml(country_name: str, feeds: list[dict]) -> str:
    lines = []
    for f in feeds:
        url = f["url"]
        title = f.get("title") or f.get("name") or url
        title_esc = (title.replace("&", "&amp;").replace("<", "&lt;")
                     .replace(">", "&gt;").replace('"', "&quot;"))
        url_esc = (url.replace("&", "&amp;").replace("<", "&lt;")
                   .replace(">", "&gt;").replace('"', "&quot;"))
        source_id = compute_source_id(url)

        nm = f.get("name", "").lower()
        if any(w in nm for w in ["music", "singer", "song", "band", "rapper", "composer"]):
            topic = "Music &amp; Audio"
        elif any(w in nm for w in ["actor", "actress", "film", "director", "cinema"]):
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
            f'feedmineQualityScore="60" '
            f'feedmineDefaultEnabled="true" '
            f'feedmineMediaKind="text" '
            f'htmlUrl="{url_esc}" />'
        )
    return "\n".join(lines)


# ===========================================================================
# Merger — combine v3 + v4 feeds
# ===========================================================================

def load_existing_feeds(slug: str) -> set[str]:
    """Load all existing feed URLs for a country to avoid dupes."""
    urls: set[str] = set()

    # Country OPML
    opml = COUNTRIES_DIR / slug / f"{slug}.opml"
    if opml.exists():
        try:
            for m in re.finditer(r'xmlUrl="([^"]+)"', opml.read_text(encoding="utf-8")):
                urls.add(m.group(1).strip().rstrip("/").lower())
        except Exception:
            pass

    # v3 cache
    v3 = REPO_ROOT / "scripts" / "feed_discovery" / "data" / "artist_cache_v3" / f"{slug}_feeds.json"
    if v3.exists():
        try:
            for f in json.loads(v3.read_text(encoding="utf-8")):
                urls.add(f["url"].lower().rstrip("/"))
        except Exception:
            pass

    # v4 cache
    v4 = CACHE_DIR / f"{slug}_feeds.json"
    if v4.exists():
        try:
            for f in json.loads(v4.read_text(encoding="utf-8")):
                urls.add(f["url"].lower().rstrip("/"))
        except Exception:
            pass

    return urls


# ===========================================================================
# CLI
# ===========================================================================

def main():
    parser = argparse.ArgumentParser(description="Hybrid artist blog discovery v4")
    parser.add_argument("--country", help="Single country")
    parser.add_argument("--all", action="store_true", help="All 101 countries")
    parser.add_argument("--opml", action="store_true", help="Write OPML files")
    parser.add_argument("--output-dir", default=None)
    parser.add_argument("--batch-size", type=int, default=20, help="Countries per batch")
    parser.add_argument("--start-from", default=None, help="Country slug to start from")
    parser.add_argument("--max-countries", type=int, default=None)
    parser.add_argument("--no-ddg", action="store_true", help="Skip DDG enrichment")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    with open(COUNTRIES_JSON, encoding="utf-8") as f:
        countries = json.load(f)

    if args.country:
        slugs = [args.country]
    elif args.all:
        slugs = sorted(countries.keys())
        if args.start_from and args.start_from in slugs:
            idx = slugs.index(args.start_from)
            slugs = slugs[idx:]
        if args.max_countries:
            slugs = slugs[:args.max_countries]
    else:
        slugs = sorted(countries.keys())[:3]
        print(f"Testing with {slugs}. Use --all for full run.\n")

    if args.dry_run:
        for slug in slugs:
            meta = countries[slug]
            print(f"  {meta['name']} ({slug}): cctld={meta.get('cctld','')}, iso2={meta.get('iso2','')}")
        return

    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    # Pre-compute Wikidata names for all countries (batch)
    all_wd_names: dict[str, list[str]] = {}
    wd_cache = CACHE_DIR / "_wikidata_names.json"
    if wd_cache.exists():
        try:
            all_wd_names = json.loads(wd_cache.read_text(encoding="utf-8"))
            print(f"Loaded Wikidata names for {len(all_wd_names)} countries from cache")
        except Exception:
            pass

    total = 0

    for slug in slugs:
        meta = countries[slug]
        cname = meta["name"]

        # Skip if already cached
        cache_file = CACHE_DIR / f"{slug}_feeds.json"
        if cache_file.exists():
            try:
                feeds = json.loads(cache_file.read_text(encoding="utf-8"))
                print(f"\n📦 {cname} ({slug}): {len(feeds)} cached feeds")
                total += len(feeds)
                continue
            except Exception:
                pass

        print(f"\n{'='*60}")
        print(f"🔍 {cname} ({slug}) — {meta.get('iso2', meta.get('cctld','')).upper()}")
        print(f"{'='*60}")

        existing = load_existing_feeds(slug)
        print(f"  Existing feeds (to avoid): {len(existing)}")

        # Get Wikidata names (from cache or fetch)
        wd_names = all_wd_names.get(slug)
        if wd_names is None and meta.get("iso2"):
            print(f"  [wikidata] Fetching names...")
            wd_names = wikidata_artist_names(meta["iso2"], meta.get("lang", "en"), max_per_profession=50)
            all_wd_names[slug] = wd_names
            # Save cache periodically
            wd_cache.write_text(json.dumps(all_wd_names, ensure_ascii=False, indent=2), encoding="utf-8")
            print(f"  → {len(wd_names)} names")
        elif wd_names is None:
            wd_names = []
            print(f"  [warn] No ISO2 code, skipping Wikidata")

        feeds, _ = discover_country(slug, meta, existing, wd_names, use_ddg=not args.no_ddg)

        # Save
        cache_file.write_text(json.dumps(feeds, ensure_ascii=False, indent=2), encoding="utf-8")

        if args.opml and feeds:
            out_dir = Path(args.output_dir) if args.output_dir else CACHE_DIR / "opml"
            out_dir.mkdir(parents=True, exist_ok=True)
            opml_text = generate_opml(cname, feeds)
            (out_dir / f"{slug}_artist_blogs.opml").write_text(opml_text, encoding="utf-8")

        total += len(feeds)
        print(f"  ✅ {cname}: {len(feeds)} new feeds (running total: {total})")

    # Save Wikidata cache
    wd_cache.write_text(json.dumps(all_wd_names, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\n{'='*60}")
    print(f"✅ Total: {total} feeds across {len(slugs)} countries")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
