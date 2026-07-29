#!/usr/bin/env python3
"""Crawl museum websites for RSS/Atom feeds, YouTube channels, and podcasts.

Uses the seed list built by build_museum_list.py to crawl museum websites
for feed discovery. Supports per-country and all-country modes.

Usage:
    python3 scripts/crawl_museum_feeds.py                    # all countries
    python3 scripts/crawl_museum_feeds.py --country japan     # single country
    python3 scripts/crawl_museum_feeds.py --max 50            # limit per country
    python3 scripts/crawl_museum_feeds.py --fresh              # no cache
    python3 scripts/crawl_museum_feeds.py --parallel 8         # 8 countries at a time
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
from pathlib import Path

import aiohttp

# Add parent to path for imports
sys.path.insert(0, str(Path(__file__).resolve().parent))

from feed_discovery.models import Country
from feed_discovery.sources.museums import discover as discover_museums, USER_AGENT

DATA_DIR = Path(__file__).resolve().parent / "feed_discovery/data"
MUSEUMS_DIR = DATA_DIR / "museums" / "by_country"
OUTPUT_DIR = DATA_DIR / "museums" / "crawl_results"
CACHE_DIR = DATA_DIR / "museums" / "crawl_cache"


class Config:
    """Minimal config for the museum crawler."""
    def __init__(self, timeout: int = 15, fresh: bool = False, max_per_country: int = 0):
        self.timeout = timeout
        self.fresh = fresh
        self.max_per_country = max_per_country
        self.cache_dir = str(CACHE_DIR)


def _load_countries() -> dict:
    path = DATA_DIR / "countries.json"
    return json.loads(path.read_text(encoding="utf-8"))


async def crawl_country(
    slug: str,
    cdata: dict,
    cfg: Config,
    session: aiohttp.ClientSession,
) -> dict:
    """Crawl all museums for one country, return summary."""
    country = Country(
        slug=slug,
        name=cdata["name"],
        cctld=cdata.get("cctld", slug[:2]),
        use_cctld=cdata.get("use_cctld", False),
        lang=cdata.get("lang", "en"),
        ddg_region=cdata.get("ddg_region", f"{slug[:2]}-en"),
        cities=cdata.get("cities", []),
        iso2=cdata.get("iso2", slug[:2].upper()),
        iso3=cdata.get("iso3", slug[:3].upper()),
    )

    t0 = time.monotonic()
    candidates = await discover_museums(country, session, cfg)
    elapsed = time.monotonic() - t0

    # Separate by type
    rss = [c for c in candidates if c.category not in ("YouTube", "Podcasts")]
    yt = [c for c in candidates if c.category == "YouTube"]
    podcasts = [c for c in candidates if c.category == "Podcasts"]

    # Save results
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    out_file = OUTPUT_DIR / f"{slug}.json"
    out_data = {
        "country": slug,
        "country_name": cdata["name"],
        "crawled_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "rss_feeds": len(rss),
        "youtube_channels": len(yt),
        "podcasts": len(podcasts),
        "total": len(candidates),
        "elapsed_s": round(elapsed, 1),
        "candidates": [
            {
                "url": c.url,
                "category": c.category,
                "title": c.title,
                "genre": c.genre,
                "source_page": c.source_page,
                "national": c.national,
                "national_reason": c.national_reason,
            }
            for c in candidates
        ],
    }
    out_file.write_text(json.dumps(out_data, indent=2, ensure_ascii=False), encoding="utf-8")

    return {
        "country": slug,
        "name": cdata["name"],
        "rss": len(rss),
        "youtube": len(yt),
        "podcasts": len(podcasts),
        "total": len(candidates),
        "elapsed": round(elapsed, 1),
    }


async def crawl_all(
    countries: dict,
    cfg: Config,
    max_per_country: int = 0,
    parallel_countries: int = 6,
    skip_existing: bool = True,
):
    """Crawl all countries, with configurable parallelism."""
    sem = asyncio.Semaphore(parallel_countries)

    async def _crawl_one(slug: str, cdata: dict) -> dict:
        # Skip if already crawled and not fresh
        if skip_existing and not cfg.fresh:
            out_file = OUTPUT_DIR / f"{slug}.json"
            if out_file.exists():
                cached = json.loads(out_file.read_text(encoding="utf-8"))
                summary = {
                    "country": slug,
                    "name": cdata["name"],
                    "rss": cached.get("rss_feeds", 0),
                    "youtube": cached.get("youtube_channels", 0),
                    "podcasts": cached.get("podcasts", 0),
                    "total": cached.get("total", 0),
                    "elapsed": 0,
                }
                return summary

        async with sem:
            return await crawl_country(slug, cdata, cfg, session)

    async with aiohttp.ClientSession(
        headers={"User-Agent": USER_AGENT},
        timeout=aiohttp.ClientTimeout(total=30),
    ) as session:
        tasks = []
        for slug, cdata in countries.items():
            tasks.append(_crawl_one(slug, cdata))

        results = []
        for i, coro in enumerate(asyncio.as_completed(tasks)):
            r = await coro
            results.append(r)
            print(f"  [{i+1}/{len(tasks)}] {r['name']}: "
                  f"{r['rss']} RSS, {r['youtube']} YT, {r['podcasts']} podcasts "
                  f"({r['elapsed']}s)")

    return results


def main():
    parser = argparse.ArgumentParser(description="Crawl museum websites for feeds")
    parser.add_argument("--country", type=str, help="Crawl a single country (slug or name)")
    parser.add_argument("--max", type=int, default=0, help="Max museums per country (0=all)")
    parser.add_argument("--fresh", action="store_true", help="Ignore caches")
    parser.add_argument("--timeout", type=int, default=15, help="Per-request timeout in seconds")
    parser.add_argument("--parallel", type=int, default=6, help="Countries to crawl in parallel")
    parser.add_argument("--no-skip", action="store_true", help="Don't skip already-crawled countries")
    args = parser.parse_args()

    countries = _load_countries()

    # Filter to target country
    if args.country:
        target = args.country.lower().strip()
        if target not in countries:
            match = None
            for slug, cdata in countries.items():
                if cdata["name"].lower() == target or cdata.get("iso2", "").lower() == target:
                    match = slug
                    break
            if match:
                countries = {match: countries[match]}
            else:
                print(f"✗ Country '{args.country}' not found")
                sys.exit(1)
        else:
            countries = {target: countries[target]}

    cfg = Config(
        timeout=args.timeout,
        fresh=args.fresh,
        max_per_country=args.max,
    )

    print(f"Crawling {len(countries)} countries (parallel={args.parallel}, timeout={args.timeout}s)...")
    print(f"Output: {OUTPUT_DIR}/")
    print(f"Cache:  {CACHE_DIR}/")
    print()

    t0 = time.monotonic()
    results = asyncio.run(crawl_all(
        countries, cfg,
        max_per_country=args.max,
        parallel_countries=args.parallel,
        skip_existing=not args.no_skip,
    ))
    total_elapsed = time.monotonic() - t0

    # Summary
    total_rss = sum(r["rss"] for r in results)
    total_yt = sum(r["youtube"] for r in results)
    total_podcasts = sum(r["podcasts"] for r in results)
    total_all = sum(r["total"] for r in results)
    countries_with_results = sum(1 for r in results if r["total"] > 0)

    print(f"\n{'='*60}")
    print(f"Total: {total_all} candidates from {countries_with_results}/{len(results)} countries")
    print(f"  RSS feeds:     {total_rss}")
    print(f"  YouTube:       {total_yt}")
    print(f"  Podcasts:      {total_podcasts}")
    print(f"  Elapsed:       {total_elapsed:.0f}s")
    print(f"  Output:        {OUTPUT_DIR}/")

    # Write summary
    summary_path = OUTPUT_DIR / "crawl_summary.json"
    summary_path.write_text(json.dumps({
        "crawled_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "countries_crawled": len(results),
        "countries_with_results": countries_with_results,
        "total_rss": total_rss,
        "total_youtube": total_yt,
        "total_podcasts": total_podcasts,
        "total_candidates": total_all,
        "elapsed_s": round(total_elapsed, 1),
        "results": results,
    }, indent=2, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
