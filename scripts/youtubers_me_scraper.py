#!/usr/bin/env python3
"""
Scrape youtubers.me for all YouTube channel data across 30 countries and 16 categories.

Resolves YouTube Channel IDs by scraping youtube.com directly (no API key needed).
Produces a comprehensive JSON file for the Feedmine discovery pipeline.

Usage:
    python scripts/youtubers_me_scraper.py              # dry-run
    python scripts/youtubers_me_scraper.py --write      # full scrape & save
    python scripts/youtubers_me_scraper.py --resume     # resume from last checkpoint
    python scripts/youtubers_me_scraper.py --phase 1    # run specific phase only
"""

from __future__ import annotations

import json
import re
import sys
import time
from collections import defaultdict
from pathlib import Path

import requests
from bs4 import BeautifulSoup

# ── Paths ────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = PROJECT_ROOT / "scripts/feed_discovery/data"
OUTPUT_PATH = DATA_DIR / "youtube_channels_youtubersme.json"
CHECKPOINT_DIR = DATA_DIR / ".checkpoints_youtubersme"

# ── HTTP ─────────────────────────────────────────────────────────────────────
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                  "AppleWebKit/537.36 (KHTML, like Gecko) "
                  "Chrome/120.0.0.0 Safari/537.36",
}

# ── Countries (30 total) ─────────────────────────────────────────────────────
# slug on youtubers.me -> our internal country slug
COUNTRIES: dict[str, str] = {
    "united-states": "united-states",
    "germany": "germany",
    "united-kingdom": "united-kingdom",
    "brazil": "brazil",
    "mexico": "mexico",
    "spain": "spain",
    "italy": "italy",
    "czech-republic": "czech-republic",
    "russian-federation": "russian-federation",
    "india": "india",
    "france": "france",
    "japan": "japan",
    "turkey": "turkey",
    "korea-republic-of": "korea-republic-of",
    "poland": "poland",
    "canada": "canada",
    "viet-nam": "viet-nam",
    "thailand": "thailand",
    "indonesia": "indonesia",
    "ukraine": "ukraine",
    "morocco": "morocco",
    "argentina": "argentina",
    "saudi-arabia": "saudi-arabia",
    "netherlands": "netherlands",
    "egypt": "egypt",
    "taiwan": "taiwan",
    "australia": "australia",
    "greece": "greece",
    "colombia": "colombia",
    "romania": "romania",
}

# ── Categories (16 global) ───────────────────────────────────────────────────
CATEGORIES: dict[str, str] = {
    "film-animation": "Film & Animation",
    "autos-vehicles": "Autos & Vehicles",
    "music": "Music",
    "pets-animals": "Pets & Animals",
    "sports": "Sports",
    "travel-events": "Travel & Events",
    "gaming": "Gaming",
    "people-blogs": "People & Blogs",
    "comedy": "Comedy",
    "entertainment": "Entertainment",
    "news-politics": "News & Politics",
    "howto-style": "Howto & Style",
    "education": "Education",
    "science-technology": "Science & Technology",
    "shows": "Shows",
    "nonprofits-activism": "Nonprofits & Activism",
}

YT_BASE = "https://us.youtubers.me"


def fetch_page(url: str, timeout: int = 30) -> BeautifulSoup | None:
    """Fetch a URL and return parsed HTML, or None on failure."""
    try:
        resp = requests.get(url, timeout=timeout, headers=HEADERS)
        resp.raise_for_status()
        return BeautifulSoup(resp.text, "html.parser")
    except Exception as e:
        print(f"  ⚠ {url}: {e}", file=sys.stderr)
        return None


def parse_number(text: str) -> int:
    """Parse '200,000,000' or '1.5M' or '2.3K' -> int."""
    text = text.strip().replace(",", "").replace("~", "")
    multiplier = 1
    if text.upper().endswith("B"):
        multiplier = 1_000_000_000
        text = text[:-1]
    elif text.upper().endswith("M"):
        multiplier = 1_000_000
        text = text[:-1]
    elif text.upper().endswith("K"):
        multiplier = 1_000
        text = text[:-1]
    try:
        return int(float(text) * multiplier)
    except (ValueError, TypeError):
        return 0


def save_checkpoint(name: str, data: dict) -> None:
    """Save a phase checkpoint for resumability."""
    CHECKPOINT_DIR.mkdir(parents=True, exist_ok=True)
    path = CHECKPOINT_DIR / f"{name}.json"
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


def load_checkpoint(name: str) -> dict | None:
    """Load a phase checkpoint if it exists."""
    path = CHECKPOINT_DIR / f"{name}.json"
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return None


def load_existing_channel_cache() -> dict[str, dict]:
    """Build {channel_name_normalized -> {channel_id, ...}} from all existing JSON files."""
    cache: dict[str, dict] = {}
    for fname in ["youtube_channels_wikipedia.json", "youtube_channels_socialblade.json",
                  "youtube_channels_diamond.json", "youtube_channels_awards.json"]:
        path = DATA_DIR / fname
        if not path.exists():
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        for ch in data.get("channels", []):
            cid = ch.get("channel_id", "")
            name = ch.get("channel_name", "").lower().strip()
            if cid and name:
                cache[name] = {"channel_id": cid, "channel_name": ch.get("channel_name", ""),
                               "feed_url": ch.get("feed_url", "")}
            if cid:
                cache[cid] = {"channel_id": cid, "channel_name": ch.get("channel_name", ""),
                              "feed_url": ch.get("feed_url", "")}
    return cache


def scrape_listing_page(url: str, source_type: str, source_value: str) -> list[dict]:
    """Scrape a single Top-N listing page (country or category).

    Returns list of channel entries with data from both tables.
    """
    soup = fetch_page(url)
    if not soup:
        return []

    # Find the two tables: main stats + detail stats
    tables = soup.find_all("table")
    if len(tables) < 2:
        print(f"  ⚠ {url}: expected 2 tables, found {len(tables)}", file=sys.stderr)
        return []

    main_table = tables[0]
    detail_table = tables[1]

    # Build detail table index: rank -> {subs_per_year, views_per_year, videos_per_year, thumbnail}
    detail_by_rank: dict[int, dict] = {}
    for row in detail_table.find_all("tr")[1:]:
        cells = row.find_all("td")
        if len(cells) < 5:
            continue
        try:
            rank = int(cells[0].get_text(strip=True))
        except ValueError:
            continue
        img = cells[1].find("img")
        thumbnail = img.get("data-src", img.get("src", "")) if img else ""
        detail_by_rank[rank] = {
            "subscribers_per_year": parse_number(cells[2].get_text(strip=True)),
            "views_per_year": parse_number(cells[3].get_text(strip=True)),
            "videos_per_year": parse_number(cells[4].get_text(strip=True)),
            "thumbnail_url": thumbnail,
        }

    # Parse main table
    channels = []
    for row in main_table.find_all("tr")[1:]:
        cells = row.find_all("td")
        if len(cells) < 1:
            continue

        # Rank (col 0) may be in a th or td
        rank_text = cells[0].get_text(strip=True)
        try:
            rank = int(rank_text)
        except ValueError:
            continue

        name_cell = cells[1] if len(cells) > 1 else None
        name = name_cell.get_text(strip=True) if name_cell else ""
        slug = ""
        if name_cell:
            link = name_cell.find("a", href=True)
            if link:
                href = link["href"]
                # Extract slug from /{slug}/youtuber-stats
                slug_match = re.match(r'/([^/]+)/youtuber-stats', href)
                if slug_match:
                    slug = slug_match.group(1)

        subscribers = parse_number(cells[2].get_text(strip=True)) if len(cells) > 2 else 0
        video_views = parse_number(cells[3].get_text(strip=True)) if len(cells) > 3 else 0
        video_count = parse_number(cells[4].get_text(strip=True)) if len(cells) > 4 else 0

        category = ""
        if len(cells) > 5:
            cat_link = cells[5].find("a", href=True)
            if cat_link:
                category = cat_link.get_text(strip=True)

        started_year = 0
        if len(cells) > 6:
            try:
                started_year = int(cells[6].get_text(strip=True))
            except ValueError:
                pass

        detail = detail_by_rank.get(rank, {})
        channels.append({
            "rank": rank,
            "channel_name": name,
            "youtubersme_slug": slug,
            "subscribers_total": subscribers,
            "video_views_total": video_views,
            "video_count": video_count,
            "category": category,
            "started_year": started_year,
            "subscribers_per_year": detail.get("subscribers_per_year", 0),
            "views_per_year": detail.get("views_per_year", 0),
            "videos_per_year": detail.get("videos_per_year", 0),
            "thumbnail_url": detail.get("thumbnail_url", ""),
            "source_type": source_type,  # "country" or "category"
            "source_value": source_value,  # e.g. "brazil" or "gaming"
        })

    return channels


def scrape_all_countries(resume: bool = False) -> dict[str, list[dict]]:
    """Scrape top-1000 for all 30 countries. Returns {slug: [channels]}."""
    result: dict[str, list[dict]] = {}
    if resume:
        cp = load_checkpoint("phase1_countries")
        if cp:
            result = cp

    country_slugs = sorted(COUNTRIES.keys())
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Phase 1a: Scraping {len(country_slugs)} countries (Top 1000 each)", file=sys.stderr)

    for i, slug in enumerate(country_slugs):
        if slug in result:
            print(f"  [{i+1}/{len(country_slugs)}] {slug}: SKIP (already scraped)", file=sys.stderr)
            continue
        if i > 0:
            time.sleep(0.5)  # Rate limit
        url = f"{YT_BASE}/{slug}/all/top-1000-youtube-channels-in-{slug}"
        channels = scrape_listing_page(url, "country", slug)
        result[slug] = channels
        print(f"  [{i+1}/{len(country_slugs)}] {slug}: {len(channels)} channels", file=sys.stderr)
        save_checkpoint("phase1_countries", result)

    print(f"Countries scraped: {len(result)}, total entries: {sum(len(v) for v in result.values())}", file=sys.stderr)
    return result


def scrape_all_categories(resume: bool = False) -> dict[str, list[dict]]:
    """Scrape top-1000 for all 16 categories. Returns {cat_slug: [channels]}."""
    result: dict[str, list[dict]] = {}
    if resume:
        cp = load_checkpoint("phase1_categories")
        if cp:
            result = cp

    cat_slugs = sorted(CATEGORIES.keys())
    print(f"\nPhase 1b: Scraping {len(cat_slugs)} categories (Top 1000 each)", file=sys.stderr)

    for i, cat_slug in enumerate(cat_slugs):
        if cat_slug in result:
            print(f"  [{i+1}/{len(cat_slugs)}] {cat_slug}: SKIP (already scraped)", file=sys.stderr)
            continue
        if i > 0:
            time.sleep(0.5)
        url = f"{YT_BASE}/global/{cat_slug}/top-{cat_slug}-youtube-channels"
        channels = scrape_listing_page(url, "category", cat_slug)
        result[cat_slug] = channels
        print(f"  [{i+1}/{len(cat_slugs)}] {cat_slug}: {len(channels)} channels", file=sys.stderr)
        save_checkpoint("phase1_categories", result)

    print(f"Categories scraped: {len(result)}, total entries: {sum(len(v) for v in result.values())}", file=sys.stderr)
    return result


def main():
    write_mode = "--write" in sys.argv
    resume_mode = "--resume" in sys.argv
    phase_filter = None

    for i, arg in enumerate(sys.argv):
        if arg == "--phase" and i + 1 < len(sys.argv):
            phase_filter = int(sys.argv[i + 1])

    if not write_mode:
        print("DRY RUN — use --write to save\n", file=sys.stderr)

    # Phase 1: Listings
    if phase_filter in (None, 1):
        countries_data = scrape_all_countries(resume=resume_mode)
        categories_data = scrape_all_categories(resume=resume_mode)

        if not write_mode:
            total = sum(len(v) for v in countries_data.values()) + \
                    sum(len(v) for v in categories_data.values())
            print(f"\nPhase 1 dry-run complete. {total} total entries across "
                  f"{len(countries_data)} countries + {len(categories_data)} categories.", file=sys.stderr)


if __name__ == "__main__":
    main()
