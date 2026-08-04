#!/usr/bin/env python3
"""
Fast multi-source radio podcast discovery for all feedmine countries.

Sources (ordered by speed/reliability):
  1. iTunes podcast search (RSS feeds directly, very fast, cached)
  2. Radio Browser API (station metadata, cached)
  3. Wikipedia radio station lists (cached)
  4. Podcast Index API (if API keys configured)

The key insight: iTunes returns verified podcast RSS feeds directly.
No need to scrape station websites — iTunes already indexes radio podcasts.

Output: scripts/feed_discovery/data/radio_podcasts_by_country.json

Usage:
  python scripts/discover_radio_podcasts.py                    # dry-run
  python scripts/discover_radio_podcasts.py --write --fast     # iTunes only (fastest)
  python scripts/discover_radio_podcasts.py --write            # all sources
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path
from urllib.parse import urlencode, urljoin, urlparse

import aiohttp
import requests

try:
    from scripts.catalog_identity import compute_source_id
except ModuleNotFoundError:
    from catalog_identity import compute_source_id

# ── Paths ────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_ROOT / "scripts/feed_discovery/data"
COUNTRIES_PATH = DATA_DIR / "countries.json"
OUTPUT_PATH = DATA_DIR / "radio_podcasts_by_country.json"
CACHE_DIR = DATA_DIR / "cache/radio_discovery"

HEADERS = {
    "User-Agent": "Feedmine/1.0 (Radio Discovery; contact@feedmine.app)",
}

ITUNES_SEARCH = "https://itunes.apple.com/search"

# Radio keywords in 50+ languages — used for iTunes queries
RADIO_KEYWORDS: dict[str, str] = {
    "en": "radio", "es": "radio emisora", "pt": "rádio emissora",
    "fr": "radio", "de": "radio sender", "it": "radio",
    "nl": "radio", "ar": "إذاعة راديو", "ru": "радио",
    "zh": "电台广播", "ja": "ラジオ", "ko": "라디오 방송",
    "hi": "रेडियो", "tr": "radyo", "pl": "radio",
    "vi": "radio", "th": "วิทยุ", "id": "radio",
    "ro": "radio", "hu": "rádió", "cs": "rádio",
    "sv": "radio", "da": "radio", "fi": "radio",
    "no": "radio", "he": "רדיו", "fa": "رادیو",
    "uk": "радіо", "el": "ραδιόφωνο", "bg": "радио",
    "sr": "радио", "hr": "radio", "sl": "radio",
    "lt": "radijas", "lv": "radio", "et": "raadio",
    "sk": "rádio", "sw": "redio", "am": "ራዲዮ",
    "bn": "রেডিও", "ur": "ریڈیو", "my": "ရေဒီယို",
    "km": "វិទ្យុ", "ne": "रेडियो", "si": "රේඩියෝ",
    "ka": "რადიო", "hy": "ռադիո", "az": "radio",
    "kk": "радио", "ms": "radio", "fil": "radyo",
}


def sid(url: str) -> str:
    return compute_source_id(url)


# ── Source 1: iTunes (fastest, returns verified podcast RSS) ────────────────

def itunes_radio_podcasts(
    iso2: str, cities: list[str], country_name: str, lang: str,
    cache_path: Path,
) -> list[dict]:
    """Search iTunes for radio-related podcasts. Returns RSS feed URLs."""
    if cache_path.exists():
        try:
            return json.loads(cache_path.read_text(encoding="utf-8"))
        except Exception:
            pass

    base_lang = lang.split("-")[0]
    radio_kw = RADIO_KEYWORDS.get(lang, RADIO_KEYWORDS.get(base_lang, "radio"))

    all_results: list[dict] = []
    seen_urls: set[str] = set()

    # Query strategy:
    # 1. "{city} {radio_kw}" for top 3 cities
    # 2. "{country_name} {radio_kw}"
    # 3. Just "{country_name}" (catch-all)
    queries = []
    for city in cities[:3]:
        queries.append(f"{city} {radio_kw}")
    queries.append(f"{country_name} {radio_kw}")
    queries.append(country_name)  # Catch-all

    for query in queries[:6]:
        qs = urlencode({
            "term": query, "country": iso2,
            "entity": "podcast", "limit": 30,
        })
        url = f"{ITUNES_SEARCH}?{qs}"

        try:
            resp = requests.get(url, timeout=10, headers=HEADERS)
            if resp.status_code != 200:
                continue
            payload = resp.json()
        except Exception:
            continue

        for r in payload.get("results", []):
            feed_url = r.get("feedUrl")
            if not feed_url or feed_url in seen_urls:
                continue
            seen_urls.add(feed_url)

            title = r.get("collectionName", "")
            genre = r.get("primaryGenreName", "")
            artist = r.get("artistName", "")

            # Check if radio-related OR it's a country-level general search
            is_country_query = country_name.lower() in query.lower() and radio_kw not in query.lower()
            if not is_country_query:
                # City-level or radio-specific query: check for radio indicators
                combined = f"{title} {genre} {artist}".lower()
                indicators = [
                    "radio", "rádio", "fm ", " am ", "station", "emisora",
                    "emissora", "broadcast", "rundfunk", "radyo",
                    "noticias", "news", "jornal", "notícias", "journal",
                    "actualité", "nachrichten", "notizie",
                    "local", "ciudad", "cidade", "community",
                    "nacional", "municipal", "talk", "morning show",
                    "ラジオ", "放送", "电台", "广播", "방송", "라디오",
                    "радио", "радіо", "רדיו", "راديو", "रेडियो",
                    "programa", "programme", "emission", "transmission",
                    "boletim", "daily news", "matinal", "matutino",
                    "public radio", "independent radio", "community radio",
                ]
                if not any(kw in combined for kw in indicators):
                    continue

            all_results.append({
                "url": feed_url,
                "title": title,
                "city": "",
                "source": "itunes",
                "genre": genre,
                "artist": artist,
            })

        time.sleep(0.1)  # Polite rate limiting

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(
        json.dumps(all_results, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return all_results


# ── Source 2: Radio Browser API (station metadata) ──────────────────────────

def radio_browser_stations(iso2: str, cities: list[str], cache_path: Path) -> list[dict]:
    """Get radio stations from radio-browser.info."""
    if cache_path.exists():
        try:
            return json.loads(cache_path.read_text(encoding="utf-8"))
        except Exception:
            pass

    stations: list[dict] = []
    seen: set[str] = set()
    mirrors = [
        "https://de1.api.radio-browser.info",
        "https://at1.api.radio-browser.info",
    ]

    for mirror in mirrors:
        try:
            resp = requests.get(
                f"{mirror}/json/stations/bycountrycodeexact/{iso2.upper()}",
                timeout=12,
                headers={"User-Agent": HEADERS["User-Agent"]},
            )
            if resp.status_code == 200:
                data = resp.json()
                for st in data[:200]:
                    name = (st.get("name") or "").strip()
                    homepage = (st.get("homepage") or "").strip()
                    url = (st.get("url") or "").strip()
                    website = homepage if homepage.startswith("http") else url
                    if not website.startswith("http"):
                        continue
                    if website in seen:
                        continue
                    seen.add(website)
                    stations.append({
                        "name": name,
                        "website": website,
                        "city": st.get("state", ""),
                        "language": st.get("language", ""),
                    })
                break
        except Exception:
            continue

    # City-level search for top cities
    for city in cities[:3]:
        for mirror in mirrors:
            try:
                resp = requests.get(
                    f"{mirror}/json/stations/byname/{city}",
                    timeout=10,
                    headers={"User-Agent": HEADERS["User-Agent"]},
                )
                if resp.status_code == 200:
                    for st in resp.json()[:15]:
                        homepage = (st.get("homepage") or "").strip()
                        url = (st.get("url") or "").strip()
                        website = homepage if homepage.startswith("http") else url
                        if website.startswith("http") and website not in seen:
                            seen.add(website)
                            stations.append({
                                "name": st.get("name", ""),
                                "website": website,
                                "city": city,
                                "language": st.get("language", ""),
                            })
                break
            except Exception:
                continue
        time.sleep(0.2)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(
        json.dumps(stations, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return stations


# ── Source 3: Podcast Index (requires API keys) ─────────────────────────────

def podcast_index_search(
    country_name: str, lang: str, cache_path: Path,
) -> list[dict]:
    """Search Podcast Index for radio podcasts. Requires PODCAST_INDEX_KEY/SECRET."""
    if cache_path.exists():
        try:
            return json.loads(cache_path.read_text(encoding="utf-8"))
        except Exception:
            pass

    api_key = os.getenv("PODCAST_INDEX_KEY", "")
    api_secret = os.getenv("PODCAST_INDEX_SECRET", "")
    if not api_key or not api_secret:
        return []

    import hashlib as hl

    epoch_time = int(time.time())
    data_to_hash = f"{api_key}{api_secret}{epoch_time}"
    sha1_hash = hl.sha1(data_to_hash.encode()).hexdigest()
    auth_headers = {
        "User-Agent": "Feedmine/1.0",
        "X-Auth-Key": api_key,
        "X-Auth-Date": str(epoch_time),
        "Authorization": sha1_hash,
    }

    results: list[dict] = []
    seen: set[str] = set()
    base_lang = lang.split("-")[0]

    # Search for radio podcasts
    queries = [
        f"{country_name} radio",
        f"{country_name} news",
        f"{country_name} talk",
    ]

    for query in queries[:2]:
        params = {"q": query, "max": "20"}
        if base_lang:
            params["lang"] = base_lang
        url = f"https://api.podcastindex.org/api/1.0/search/byterm?{urlencode(params)}"
        try:
            resp = requests.get(url, timeout=12, headers=auth_headers)
            if resp.status_code == 200:
                data = resp.json()
                for feed in data.get("feeds", []):
                    feed_url = feed.get("url") or feed.get("originalUrl")
                    if not feed_url or feed_url in seen:
                        continue
                    seen.add(feed_url)
                    cats = feed.get("categories", {})
                    genre = next(iter(cats.values()), "") if cats else ""
                    results.append({
                        "url": feed_url,
                        "title": feed.get("title", ""),
                        "city": "",
                        "source": "podcast_index",
                        "genre": genre,
                    })
        except Exception:
            pass
        time.sleep(0.3)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(
        json.dumps(results, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return results


# ── Source 4: Wikipedia radio station lists (for station metadata) ───────────

def wikipedia_radio_sites(country_name: str, native_name: str = "", cache_path: Path = None) -> list[dict]:
    """Get radio station websites from Wikipedia lists."""
    if cache_path and cache_path.exists():
        try:
            return json.loads(cache_path.read_text(encoding="utf-8"))
        except Exception:
            pass

    import requests as req
    from bs4 import BeautifulSoup

    stations: list[dict] = []
    seen: set[str] = set()
    WIKI_BASE = "https://en.wikipedia.org/wiki/"
    PATTERNS = [
        "List_of_radio_stations_in_{}",
        "Radio_stations_in_{}",
        "List_of_radio_stations_{}",
    ]

    wiki_title = country_name.replace(" ", "_")
    resp = None

    for pat in PATTERNS:
        try:
            resp = req.get(WIKI_BASE + pat.format(wiki_title), timeout=10, headers=HEADERS)
            if resp.status_code == 200:
                break
        except Exception:
            continue

    if (resp is None or resp.status_code != 200) and native_name and native_name != country_name:
        nt = native_name.replace(" ", "_")
        for pat in PATTERNS:
            try:
                resp = req.get(WIKI_BASE + pat.format(nt), timeout=10, headers=HEADERS)
                if resp.status_code == 200:
                    break
            except Exception:
                continue

    if resp is None or resp.status_code != 200:
        return stations

    soup = BeautifulSoup(resp.text, "html.parser")
    content = soup.find("div", class_="mw-parser-output") or soup

    for a in content.find_all("a", href=True):
        href = a["href"].strip()
        if not href.startswith("http"):
            continue
        domain = urlparse(href).netloc.lower()
        skip = (
            "wikipedia.org", "wikimedia.org", "web.archive.org",
            "wikidata.org", "google.com", "facebook.com", "twitter.com",
            "youtube.com", "instagram.com", "linkedin.com",
        )
        if any(d in domain for d in skip) or domain.endswith(".gov"):
            continue
        if href not in seen:
            seen.add(href)
            stations.append({
                "name": a.get_text(strip=True)[:120],
                "website": href,
                "city": "",
            })

    if cache_path:
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache_path.write_text(
            json.dumps(stations, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    return stations[:150]


# ── Quick feed discovery (used only for supplement when needed) ──────────────

async def quick_feed_discovery(
    session: aiohttp.ClientSession,
    stations: list[dict],
    max_check: int = 15,
    sem: asyncio.Semaphore = None,
) -> list[dict]:
    """Quickly check top N station websites for podcast feed links."""
    if sem is None:
        sem = asyncio.Semaphore(8)

    results: list[dict] = []
    seen: set[str] = set()

    async def check_one(st: dict):
        website = st.get("website", "")
        if not website.startswith("http"):
            return None
        async with sem:
            try:
                async with session.get(
                    website.strip(),
                    timeout=aiohttp.ClientTimeout(total=5),
                    headers={"User-Agent": HEADERS["User-Agent"]},
                    ssl=False,
                ) as resp:
                    if resp.status != 200:
                        return None
                    try:
                        html = await resp.text()
                    except Exception:
                        return None
            except Exception:
                return None

        # Look for podcast RSS/feed links
        for pat in [
            r'<link[^>]*type\s*=\s*["\']application/(?:rss|atom)\+xml["\'][^>]*href\s*=\s*["\']([^"\']+)["\']',
            r'<link[^>]*href\s*=\s*["\']([^"\']+)["\'][^>]*type\s*=\s*["\']application/(?:rss|atom)\+xml["\']',
            r'https?://(?:www\.)?anchor\.fm/[^\s"\'<>]+',
            r'https?://(?:open\.)?spotify\.com/show/[^\s"\'<>]+',
            r'https?://(?:www\.)?spreaker\.com/show/[^\s"\'<>]+',
            r'https?://(?:www\.)?buzzsprout\.com/[^\s"\'<>]+',
            r'https?://(?:www\.)?ivoox\.com/[^\s"\'<>]+',
            r'https?://(?:www\.)?soundcloud\.com/[^\s"\'<>]+',
            r'https?://feeds\.(?:simplecast|transistor|captivate|megaphone|acast|libsyn|podbean)\.fm/[^\s"\'<>]+',
            r'https?://(?:www\.)?omnycontent\.com/d/[^\s"\'<>]+',
        ]:
            match = re.search(pat, html, re.IGNORECASE)
            if match:
                feed_url = match.group(1) if match.lastindex else match.group(0)
                feed_url = feed_url.rstrip('.,;:)}]"\'')
                if feed_url.startswith("/"):
                    feed_url = urljoin(website, feed_url)
                if feed_url not in seen:
                    seen.add(feed_url)
                    return {
                        "url": feed_url,
                        "title": st.get("name", ""),
                        "city": st.get("city", ""),
                        "source": "radio_site",
                        "station_website": website,
                        "feedmineSourceId": sid(feed_url),
                    }
                break
        return None

    tasks = [check_one(st) for st in stations[:max_check]]
    for coro in asyncio.as_completed(tasks):
        try:
            result = await coro
            if result:
                results.append(result)
        except Exception:
            pass

    return results


# ── Main Orchestration ──────────────────────────────────────────────────────

async def process_country(
    session: aiohttp.ClientSession,
    slug: str, info: dict,
    sem: asyncio.Semaphore,
    fast_mode: bool,
) -> dict:
    """Process one country through all available sources."""
    name = info["name"]
    native = info.get("native_name", "")
    cities = info.get("cities", [])
    iso2 = info.get("iso2", slug[:2])
    iso3 = info.get("iso3", iso2.upper())
    lang = info.get("lang", "en")

    all_feeds: dict[str, dict] = {}

    def add(feed: dict):
        if "feedmineSourceId" not in feed:
            feed["feedmineSourceId"] = sid(feed["url"])
        if feed["url"] not in all_feeds:
            all_feeds[feed["url"]] = feed

    # ── iTunes (always run — fastest, returns verified RSS) ──
    itunes_cache = CACHE_DIR / "itunes" / f"{slug}.json"
    itunes_feeds = itunes_radio_podcasts(iso2, cities, name, lang, itunes_cache)
    for f in itunes_feeds:
        add(f)
    print(f"  iTunes: {len(itunes_feeds)} podcasts")

    # ── Radio Browser stations ──
    rb_cache = CACHE_DIR / "radio_browser" / f"{slug}.json"
    rb_stations = radio_browser_stations(iso2, cities, rb_cache)
    print(f"  Radio Browser: {len(rb_stations)} stations")

    # ── Wikipedia stations ──
    wiki_cache = CACHE_DIR / "wikipedia" / f"{slug}.json"
    wiki_stations = wikipedia_radio_sites(name, native, wiki_cache)
    print(f"  Wikipedia: {len(wiki_stations)} sites")

    # ── Quick feed discovery from radio sites (only if under threshold) ──
    if len(all_feeds) < 5 and rb_stations and not fast_mode:
        print(f"  Feed discovery: checking top stations...")
        # Prioritize stations with city matches
        city_names = {c.lower() for c in cities}
        city_stations = [s for s in rb_stations if any(c in (s.get("city", "") or "").lower() for c in city_names)]
        other_stations = [s for s in rb_stations if s not in city_stations]
        prioritized = city_stations + other_stations

        site_feeds = await quick_feed_discovery(session, prioritized, max_check=20, sem=sem)
        for f in site_feeds:
            add(f)
        print(f"  Feed discovery: {len(site_feeds)} feeds found")

        # Also check Wikipedia sites if still under 5
        if len(all_feeds) < 5 and wiki_stations:
            wiki_feeds = await quick_feed_discovery(session, wiki_stations, max_check=10, sem=sem)
            for f in wiki_feeds:
                add(f)
            print(f"  Wikipedia feed discovery: {len(wiki_feeds)} feeds found")

    # ── Podcast Index (if configured) ──
    pi_cache = CACHE_DIR / "podcast_index" / f"{slug}.json"
    pi_feeds = podcast_index_search(name, lang, pi_cache)
    for f in pi_feeds:
        add(f)
    if pi_feeds:
        print(f"  Podcast Index: {len(pi_feeds)} podcasts")

    return {
        "country": slug,
        "country_name": name,
        "candidates": list(all_feeds.values()),
        "count": len(all_feeds),
        "stations_total": len(rb_stations) + len(wiki_stations),
    }


async def main_async():
    write_mode = "--write" in sys.argv
    fast_mode = "--fast" in sys.argv
    target_country = None
    start_from = None

    for i, arg in enumerate(sys.argv):
        if arg == "--country" and i + 1 < len(sys.argv):
            target_country = sys.argv[i + 1]
        if arg == "--start-from" and i + 1 < len(sys.argv):
            start_from = sys.argv[i + 1]

    countries = json.loads(COUNTRIES_PATH.read_text(encoding="utf-8"))

    if target_country:
        countries = {target_country: countries[target_country]}
    elif not write_mode:
        first = next(iter(countries.items()))
        countries = {first[0]: first[1]}
        print(f"DRY RUN — {first[1]['name']} only. Use --write for all.\n")
    elif fast_mode:
        print(f"FAST MODE — iTunes + Radio Browser only.\n")

    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    all_results: dict[str, dict] = {}
    grand_total = 0
    under_5: list[str] = []

    if start_from and OUTPUT_PATH.exists():
        try:
            existing = json.loads(OUTPUT_PATH.read_text(encoding="utf-8"))
            all_results = existing.get("countries", {})
            grand_total = sum(r.get("count", 0) for r in all_results.values())
            print(f"Resuming from {start_from}. {len(all_results)} countries already processed.\n")
        except Exception:
            pass

    started = start_from is None
    sem = asyncio.Semaphore(10)

    connector = aiohttp.TCPConnector(limit=15, ssl=False)
    async with aiohttp.ClientSession(connector=connector) as session:
        for slug, info in sorted(countries.items()):
            if not started:
                if slug == start_from:
                    started = True
                else:
                    continue

            name = info["name"]
            cities_str = ", ".join(info.get("cities", [])[:4])
            print(f"\n📻 {name} ({slug}) — {cities_str}")

            try:
                result = await process_country(session, slug, info, sem, fast_mode)
            except Exception as e:
                print(f"  ❌ Error: {e}")
                import traceback
                traceback.print_exc()
                result = {"country": slug, "country_name": name, "candidates": [], "count": 0}

            all_results[slug] = result
            grand_total = sum(r.get("count", 0) for r in all_results.values())

            if result["count"] < 5:
                under_5.append(slug)
                print(f"  ⚠️  {result['count']} feeds (under 5)")
            else:
                print(f"  ✅ {result['count']} feeds")

            # Save after each country
            if write_mode:
                output = {
                    "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                    "total_candidates": grand_total,
                    "countries_processed": len(all_results),
                    "countries_under_5": sorted(under_5),
                    "countries": all_results,
                }
                tmp = OUTPUT_PATH.with_suffix(".tmp")
                tmp.write_text(
                    json.dumps(output, ensure_ascii=False, indent=2),
                    encoding="utf-8",
                )
                tmp.replace(OUTPUT_PATH)

    # ── Final Summary ──
    print(f"\n{'='*60}")
    print(f"FINAL SUMMARY")
    print(f"{'='*60}")
    print(f"Countries processed: {len(all_results)}")
    print(f"Total radio podcast candidates: {grand_total}")
    print(f"Countries with <5: {len(under_5)}")
    if under_5:
        print(f"  ⚠️  {', '.join(sorted(under_5))}")
    else:
        print(f"  🎉 All countries have 5+ radio podcasts!")

    for slug, result in sorted(all_results.items()):
        n = result.get("count", 0)
        flag = "✅" if n >= 5 else "⚠️"
        bar = "█" * min(n, 40)
        print(f"  {flag} {result.get('country_name', slug):30s} {n:4d} {bar}")


def main():
    asyncio.run(main_async())


if __name__ == "__main__":
    main()
