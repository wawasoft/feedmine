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


def main():
    write_mode = "--write" in sys.argv
    resume_mode = "--resume" in sys.argv
    phase_filter = None

    for i, arg in enumerate(sys.argv):
        if arg == "--phase" and i + 1 < len(sys.argv):
            phase_filter = int(sys.argv[i + 1])

    if not write_mode:
        print("DRY RUN — use --write to save\n", file=sys.stderr)

    # ... phase logic will be filled in by subsequent tasks
    print("Skeleton ready.", file=sys.stderr)


if __name__ == "__main__":
    main()
