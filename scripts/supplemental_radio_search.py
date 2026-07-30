#!/usr/bin/env python3
"""
Supplemental radio podcast discovery for hard-to-cover countries.

Uses web search (DuckDuckGo/Bing), SoundCloud, and direct platform queries
to find radio podcasts for countries that the main crawler couldn't cover.

Usage:
  python scripts/supplemental_radio_search.py --country ethiopia
  python scripts/supplemental_radio_search.py --under-5  # reads main output, fixes gaps
  python scripts/supplemental_radio_search.py --write --under-5
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
from urllib.parse import quote_plus, urlencode, urljoin

import aiohttp
import requests

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_ROOT / "scripts/feed_discovery/data"
COUNTRIES_PATH = DATA_DIR / "countries.json"
MAIN_OUTPUT = DATA_DIR / "radio_podcasts_by_country.json"
CACHE_DIR = DATA_DIR / "cache/radio_supplemental"

HEADERS = {
    "User-Agent": "Feedmine/1.0 (Supplemental Radio; contact@feedmine.app)",
}


def sid(url: str) -> str:
    return hashlib.sha256(url.encode()).hexdigest()


# ── Strategy 1: DuckDuckGo Text Search ──────────────────────────────────────

def ddg_search_radio(
    slug: str, country_name: str, cities: list[str], lang: str, iso2: str,
    cache_path: Path,
) -> list[dict]:
    """Search DDG for radio podcasts in a country."""
    if cache_path.exists():
        try:
            return json.loads(cache_path.read_text(encoding="utf-8"))
        except Exception:
            pass

    results: list[dict] = []
    region = f"{iso2}-{lang.split('-')[0]}"

    # Radio search terms by language
    radio_terms = {
        "en": "radio station podcast rss",
        "es": "emisora radio podcast rss",
        "pt": "rádio emissora podcast rss",
        "fr": "station radio podcast rss",
        "de": "radiosender podcast rss",
        "ar": "إذاعة بودكاست راديو",
        "ru": "радиостанция подкаст rss",
        "zh": "广播电台 播客 rss",
        "ja": "ラジオ局 ポッドキャスト rss",
        "ko": "라디오 방송국 팟캐스트 rss",
    }
    base_lang = lang.split("-")[0]
    term_template = radio_terms.get(base_lang, radio_terms.get("en", "radio podcast rss"))

    queries = []
    for city in cities[:3]:
        queries.append(f"{city} {term_template}")
    queries.append(f"{country_name} {term_template}")

    for query in queries[:4]:
        try:
            from ddgs import DDGS
            with DDGS() as ddgs:
                rows = list(ddgs.text(query, region=region, max_results=10))
        except Exception:
            # Fallback: use requests to search
            try:
                from ddgs import DDGS
                with DDGS() as ddgs:
                    rows = list(ddgs.text(query, region="wt-wt", max_results=10))
            except Exception:
                continue

        for row in rows:
            url = row.get("href") or row.get("url") or ""
            if url.startswith(("http://", "https://")):
                results.append({
                    "url": url,
                    "title": row.get("title", ""),
                    "city": city if city in query else "",
                    "source": "ddg",
                    "query": query,
                })
        time.sleep(1.0)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(
        json.dumps(results, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return results


# ── Strategy 2: SoundCloud search ───────────────────────────────────────────

async def soundcloud_search(
    session: aiohttp.ClientSession,
    country_name: str, cities: list[str],
    cache_path: Path,
) -> list[dict]:
    """Search SoundCloud for radio station accounts with podcast-like content."""
    if cache_path.exists():
        try:
            return json.loads(cache_path.read_text(encoding="utf-8"))
        except Exception:
            pass

    results: list[dict] = []
    seen: set[str] = set()
    SC_API = "https://api-v2.soundcloud.com/search"

    for city in cities[:3]:
        query = f"{city} radio"
        params = {"q": query, "limit": "15", "offset": "0"}
        url = f"{SC_API}?{urlencode(params)}"
        try:
            async with session.get(
                url,
                timeout=aiohttp.ClientTimeout(total=10),
                headers={
                    **HEADERS,
                    "Accept": "application/json",
                },
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    for user in data.get("collection", []):
                        username = user.get("permalink", "")
                        if username and f"https://soundcloud.com/{username}" not in seen:
                            seen.add(f"https://soundcloud.com/{username}")
                            # SoundCloud RSS: https://feeds.soundcloud.com/users/soundcloud:users:ID/sounds.rss
                            user_id = user.get("id", "")
                            if user_id:
                                rss = f"https://feeds.soundcloud.com/users/soundcloud:users:{user_id}/sounds.rss"
                                results.append({
                                    "url": rss,
                                    "title": user.get("username", username),
                                    "city": city,
                                    "source": "soundcloud",
                                })
        except Exception:
            pass
        await asyncio.sleep(0.5)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(
        json.dumps(results, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return results


# ── Strategy 3: Google search via programmatic (using requests to search.bing.com) ──

def bing_search_radio(
    country_name: str, cities: list[str], lang: str,
    cache_path: Path,
) -> list[dict]:
    """Search Bing for radio podcasts."""
    if cache_path.exists():
        try:
            return json.loads(cache_path.read_text(encoding="utf-8"))
        except Exception:
            pass

    results: list[dict] = []

    for city in cities[:3]:
        query = f"{city} radio station podcast feed"
        url = f"https://www.bing.com/search?q={quote_plus(query)}&count=10"
        try:
            resp = requests.get(
                url, timeout=10,
                headers={**HEADERS, "Accept-Language": lang},
            )
            if resp.status_code == 200:
                # Extract result URLs
                for match in re.finditer(
                    r'<a[^>]*href="(https?://[^"]+)"[^>]*>',
                    resp.text,
                ):
                    href = match.group(1)
                    if not any(d in href for d in ("bing.com", "microsoft.com", "live.com")):
                        results.append({
                            "url": href,
                            "title": "",
                            "city": city,
                            "source": "bing",
                        })
        except Exception:
            pass
        time.sleep(0.5)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(
        json.dumps(results, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return results


# ── Strategy 4: YouTube search for radio stations ───────────────────────────

async def youtube_radio_search(
    session: aiohttp.ClientSession,
    country_name: str, cities: list[str], lang: str,
    cache_path: Path,
) -> list[dict]:
    """Find YouTube channels of radio stations (they often have RSS)."""
    if cache_path.exists():
        try:
            return json.loads(cache_path.read_text(encoding="utf-8"))
        except Exception:
            pass

    # YouTube channel RSS: https://www.youtube.com/feeds/videos.xml?channel_id=CHANNEL_ID
    results: list[dict] = []
    YT_API_KEY = os.getenv("YOUTUBE_API_KEY", "")

    if not YT_API_KEY:
        return results

    YT_SEARCH = "https://www.googleapis.com/youtube/v3/search"

    for city in cities[:2]:
        params = {
            "part": "snippet",
            "q": f"{city} radio station",
            "type": "channel",
            "maxResults": "10",
            "key": YT_API_KEY,
            "relevanceLanguage": lang.split("-")[0],
        }
        try:
            async with session.get(
                f"{YT_SEARCH}?{urlencode(params)}",
                timeout=aiohttp.ClientTimeout(total=10),
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    for item in data.get("items", []):
                        channel_id = item.get("id", {}).get("channelId", "")
                        if channel_id:
                            results.append({
                                "url": f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}",
                                "title": item.get("snippet", {}).get("title", ""),
                                "city": city,
                                "source": "youtube",
                            })
        except Exception:
            pass
        await asyncio.sleep(0.3)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(
        json.dumps(results, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return results


# ── Strategy 5: Known radio podcast hosting platforms ────────────────────────

RADIO_HOSTING_PLATFORMS = [
    # These are radio-specific hosting platforms that provide RSS
    "https://www.radioking.com/",
    "https://www.radio.co/",
    "https://www.radioking.com/",
    "https://www.airtime.pro/",
    "https://www.radiojar.com/",
    "https://www.spreaker.com/",  # Very popular for radio
    "https://www.ivoox.com/",    # Popular in LatAm/Spain
    "https://www.podcastics.com/",
    "https://www.ausha.co/",     # Popular in France/Africa
    "https://www.acast.com/",    # Popular in Europe
]


async def search_radio_platforms(
    session: aiohttp.ClientSession,
    country_name: str, cities: list[str],
    cache_path: Path,
) -> list[dict]:
    """Search dedicated radio podcast platforms for stations by country/city."""
    if cache_path.exists():
        try:
            return json.loads(cache_path.read_text(encoding="utf-8"))
        except Exception:
            pass

    results: list[dict] = []

    for city in cities[:3]:
        # Search Spreaker (popular globally for radio)
        try:
            async with session.get(
                f"https://www.spreaker.com/search?q={quote_plus(city + ' radio')}",
                timeout=aiohttp.ClientTimeout(total=10),
                headers=HEADERS,
            ) as resp:
                if resp.status == 200:
                    html = await resp.text()
                    # Extract show links
                    for match in re.finditer(r'https?://www\.spreaker\.com/show/[^"\'\s]+', html):
                        show_url = match.group(0).rstrip('"\'')
                        results.append({
                            "url": show_url,
                            "title": "",
                            "city": city,
                            "source": "spreaker_search",
                        })
        except Exception:
            pass
        await asyncio.sleep(0.3)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(
        json.dumps(results, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return results


# ── Main Processing ─────────────────────────────────────────────────────────

async def supplement_country(
    session: aiohttp.ClientSession,
    slug: str, info: dict,
    strategies: list[str],
    write_mode: bool,
) -> list[dict]:
    """Run all supplemental strategies for one country."""
    name = info["name"]
    cities = info.get("cities", [])
    iso2 = info.get("iso2", slug[:2])
    lang = info.get("lang", "en")

    all_feeds: dict[str, dict] = {}

    def add(f: dict):
        f["feedmineSourceId"] = sid(f["url"])
        if f["url"] not in all_feeds:
            all_feeds[f["url"]] = f

    if "ddg" in strategies and write_mode:
        cached = ddg_search_radio(
            slug, name, cities, lang, iso2,
            CACHE_DIR / "ddg" / f"{slug}.json",
        )
        for r in cached:
            add(r)
        print(f"  DDG: {len(cached)} results")

    if "soundcloud" in strategies and write_mode:
        sc = await soundcloud_search(
            session, name, cities,
            CACHE_DIR / "soundcloud" / f"{slug}.json",
        )
        for r in sc:
            add(r)
        print(f"  SoundCloud: {len(sc)} feeds")

    if "bing" in strategies and write_mode:
        bing = bing_search_radio(
            name, cities, lang,
            CACHE_DIR / "bing" / f"{slug}.json",
        )
        for r in bing:
            add(r)
        print(f"  Bing: {len(bing)} results")

    if "youtube" in strategies and write_mode:
        yt = await youtube_radio_search(
            session, name, cities, lang,
            CACHE_DIR / "youtube" / f"{slug}.json",
        )
        for r in yt:
            add(r)
        print(f"  YouTube: {len(yt)} channels")

    if "platforms" in strategies and write_mode:
        plat = await search_radio_platforms(
            session, name, cities,
            CACHE_DIR / "platforms" / f"{slug}.json",
        )
        for r in plat:
            add(r)
        print(f"  Platforms: {len(plat)} shows")

    return list(all_feeds.values())


async def main_async():
    write_mode = "--write" in sys.argv
    target_country = None
    fix_under_5 = "--under-5" in sys.argv

    for i, arg in enumerate(sys.argv):
        if arg == "--country" and i + 1 < len(sys.argv):
            target_country = sys.argv[i + 1]

    countries = json.loads(COUNTRIES_PATH.read_text(encoding="utf-8"))

    # Determine which countries to process
    to_process: dict[str, dict] = {}
    if target_country:
        to_process = {target_country: countries[target_country]}
    elif fix_under_5 and MAIN_OUTPUT.exists():
        main_data = json.loads(MAIN_OUTPUT.read_text(encoding="utf-8"))
        under_5 = set(main_data.get("countries_under_5", []))
        for slug in under_5:
            if slug in countries:
                to_process[slug] = countries[slug]
        print(f"Fixing {len(to_process)} countries with <5 results\n")
    else:
        to_process = dict(sorted(countries.items()))

    if not write_mode:
        first = next(iter(to_process.items()))
        to_process = {first[0]: first[1]}
        print(f"DRY RUN — {first[1]['name']} only. Use --write for all.\n")

    strategies = ["ddg", "soundcloud", "bing", "platforms"]
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    all_new: dict[str, list[dict]] = {}

    connector = aiohttp.TCPConnector(limit=8, ssl=False)
    async with aiohttp.ClientSession(connector=connector) as session:
        for slug, info in sorted(to_process.items()):
            name = info["name"]
            print(f"🔍 {name} ({slug}) — supplemental search...")

            try:
                feeds = await supplement_country(
                    session, slug, info, strategies, write_mode,
                )
            except Exception as e:
                print(f"  ❌ Error: {e}")
                feeds = []

            all_new[slug] = feeds
            print(f"  📊 {len(feeds)} new candidates found")

    # ── Merge with main output if fixing ──
    if fix_under_5 and write_mode and MAIN_OUTPUT.exists():
        main_data = json.loads(MAIN_OUTPUT.read_text(encoding="utf-8"))
        for slug, feeds in all_new.items():
            if slug in main_data["countries"]:
                existing_urls = {
                    c["url"] for c in main_data["countries"][slug].get("candidates", [])
                }
                for f in feeds:
                    f["feedmineSourceId"] = sid(f["url"])
                    if f["url"] not in existing_urls:
                        main_data["countries"][slug]["candidates"].append(f)
                        existing_urls.add(f["url"])
                main_data["countries"][slug]["count"] = len(
                    main_data["countries"][slug]["candidates"]
                )

        # Recalculate summary
        main_data["total_candidates"] = sum(
            c["count"] for c in main_data["countries"].values()
        )
        main_data["countries_under_5"] = sorted([
            s for s, c in main_data["countries"].items() if c["count"] < 5
        ])
        main_data["generated_at"] = time.strftime("%Y-%m-%dT%H:%M:%S")

        MAIN_OUTPUT.write_text(
            json.dumps(main_data, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        print(f"\n✅ Merged results. Updated: {MAIN_OUTPUT}")

    # Summary
    total_new = sum(len(f) for f in all_new.values())
    print(f"\nSupplemental search complete: {total_new} new candidates across {len(all_new)} countries")


def main():
    asyncio.run(main_async())


if __name__ == "__main__":
    main()
