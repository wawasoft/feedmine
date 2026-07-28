# Youtubers.me Scraper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single Python script that scrapes all channel data from youtubers.me (listings + profiles), resolves YouTube Channel IDs via web scraping, and outputs a merged JSON file compatible with the existing feed_discovery data pipeline.

**Architecture:** Single-file script (`scripts/youtubers_me_scraper.py`) following the exact patterns of existing scrapers (`socialblade_scraper.py`, `diamond_playbutton_scraper.py`). Uses `requests` + `BeautifulSoup`. Dry-run by default, `--write` to persist. Phase-based execution with checkpoint files for resumability. No new dependencies.

**Tech Stack:** Python 3, `requests`, `bs4` (BeautifulSoup), `json`, `re`, `time`, `pathlib`

## Global Constraints

- Follow existing scraper conventions: `--write` to save, dry-run otherwise; `--resume` for checkpoint recovery
- Output directory: `scripts/feed_discovery/data/`
- Output file: `youtube_channels_youtubersme.json`
- Schema matches existing channel JSON files (metadata wrapper + channels array)
- No YouTube Data API usage — all Channel ID resolution via web scraping
- Rate limiting: 0.5s between youtubers.me requests, 2s between YouTube requests
- Cross-reference existing `youtube_channels_*.json` files for channel ID cache

---

### Task 1: Script skeleton — constants, CLI, and helpers

**Files:**
- Create: `scripts/youtubers_me_scraper.py`

**Interfaces:**
- Produces: `PROJECT_ROOT`, `DATA_DIR`, `OUTPUT_PATH`, `CHECKPOINT_DIR`, `HEADERS`, `COUNTRIES`, `CATEGORIES`, `fetch_page(url, timeout)`, `parse_number(text)`, `save_checkpoint(name, data)`, `load_checkpoint(name)`, `main()`

- [ ] **Step 1: Write the skeleton**

```python
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
# slug on youtubers.me → our internal country slug
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
```

- [ ] **Step 2: Write helper functions**

```python
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
    """Parse '200,000,000' or '1.5M' or '2.3K' → int."""
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
    """Build {channel_name_normalized → {channel_id, ...}} from all existing JSON files."""
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
```

- [ ] **Step 3: Write main() outline with CLI parsing**

```python
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
```

- [ ] **Step 4: Verify skeleton runs**

Run: `python3 scripts/youtubers_me_scraper.py`
Expected: prints "DRY RUN" and "Skeleton ready.", exit 0

- [ ] **Step 5: Commit**

```bash
git add scripts/youtubers_me_scraper.py
git commit -m "feat: youtubers.me scraper skeleton — constants, CLI, helpers"
```

---

### Task 2: Phase 1 — Scrape country and category listing pages

**Files:**
- Modify: `scripts/youtubers_me_scraper.py`

**Interfaces:**
- Consumes: `fetch_page(url, timeout)`, `parse_number(text)`, `COUNTRIES`, `CATEGORIES`, `YT_BASE`, `save_checkpoint(name, data)`, `load_checkpoint(name)`
- Produces: `scrape_country_listing(slug, top_n) → list[dict]`, `scrape_category_listing(cat_slug, top_n) → list[dict]`, `scrape_all_listings(resume) → dict[slug, list[dict]]`

- [ ] **Step 1: Write the listing page parser**

```python
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

    # Build detail table index: rank → {subs_per_year, views_per_year, videos_per_year, thumbnail}
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
```

- [ ] **Step 2: Write the country scraper loop**

```python
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
```

- [ ] **Step 3: Write the category scraper loop**

```python
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
```

- [ ] **Step 4: Wire into main() for dry-run test**

```python
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
```

- [ ] **Step 5: Dry-run test against 1 country (quick sanity)**

Run: `python3 scripts/youtubers_me_scraper.py` — manually add `--phase 1` to main() call temporarily, or just test `scrape_listing_page` against a Top-15 URL to verify parsing.

- [ ] **Step 6: Commit**

```bash
git add scripts/youtubers_me_scraper.py
git commit -m "feat: Phase 1 — scrape country and category listing pages"
```

---

### Task 3: Phase 2 — Dedup & merge unique channels

**Files:**
- Modify: `scripts/youtubers_me_scraper.py`

**Interfaces:**
- Consumes: country/category scraped data dicts
- Produces: `merge_and_dedup(countries_data, categories_data) → dict[str, dict]` (keyed by slug)

- [ ] **Step 1: Write the merge function**

```python
def merge_and_dedup(
    countries_data: dict[str, list[dict]],
    categories_data: dict[str, list[dict]],
) -> dict[str, dict]:
    """Merge country + category listings into unique channels keyed by youtubersme_slug.

    For channels appearing in multiple countries/categories, accumulates arrays
    and keeps the highest-rank listing stats.
    """
    merged: dict[str, dict] = {}

    def ingest(listings: dict[str, list[dict]], source_type: str):
        for source_key, channels in listings.items():
            for ch in channels:
                slug = ch.get("youtubersme_slug", "")
                if not slug:
                    continue

                if slug not in merged:
                    merged[slug] = {
                        "channel_name": ch["channel_name"],
                        "youtubersme_slug": slug,
                        "subscribers_total": ch["subscribers_total"],
                        "video_views_total": ch["video_views_total"],
                        "video_count": ch["video_count"],
                        "started_year": ch.get("started_year", 0),
                        "subscribers_per_year": ch.get("subscribers_per_year", 0),
                        "views_per_year": ch.get("views_per_year", 0),
                        "videos_per_year": ch.get("videos_per_year", 0),
                        "thumbnail_url": ch.get("thumbnail_url", ""),
                        "categories": [],
                        "countries": [],
                    }

                entry = merged[slug]
                if source_type == "country" and source_key not in entry["countries"]:
                    entry["countries"].append(source_key)
                if source_type == "category" and source_key not in entry["categories"]:
                    entry["categories"].append(source_key)
                if ch.get("category") and ch["category"] not in entry["categories"]:
                    entry["categories"].append(ch["category"])

                # Keep the highest subscriber count version
                if ch["subscribers_total"] > entry["subscribers_total"]:
                    for field in ["subscribers_total", "video_views_total", "video_count",
                                  "subscribers_per_year", "views_per_year", "videos_per_year",
                                  "thumbnail_url", "started_year"]:
                        if ch.get(field):
                            entry[field] = ch[field]

    ingest(countries_data, "country")
    ingest(categories_data, "category")

    return merged
```

- [ ] **Step 2: Wire into main()**

```python
    # Phase 2: Dedup & merge
    if phase_filter in (None, 2):
        print(f"\n{'='*60}", file=sys.stderr)
        print("Phase 2: Dedup & merge", file=sys.stderr)

        merged = merge_and_dedup(countries_data, categories_data)

        # Dedup categories (normalize casing, remove duplicates)
        for slug, entry in merged.items():
            seen = set()
            unique_cats = []
            for cat in entry["categories"]:
                cat_lower = cat.lower().strip()
                if cat_lower and cat_lower not in seen:
                    seen.add(cat_lower)
                    unique_cats.append(cat)
            entry["categories"] = unique_cats

        unique_channels = list(merged.values())
        with_countries = sum(1 for c in unique_channels if c["countries"])
        with_categories = sum(1 for c in unique_channels if c["categories"])
        print(f"Unique channels: {len(unique_channels)}", file=sys.stderr)
        print(f"  With countries: {with_countries}", file=sys.stderr)
        print(f"  With categories: {with_categories}", file=sys.stderr)
        print(f"  Avg countries/channel: {sum(len(c['countries']) for c in unique_channels) / max(len(unique_channels), 1):.1f}", file=sys.stderr)
```

- [ ] **Step 3: Commit**

```bash
git add scripts/youtubers_me_scraper.py
git commit -m "feat: Phase 2 — dedup & merge unique channels"
```

---

### Task 4: Phase 3 — Resolve YouTube Channel IDs via web scraping

**Files:**
- Modify: `scripts/youtubers_me_scraper.py`

**Interfaces:**
- Consumes: merged channel dict (keyed by slug), `load_existing_channel_cache()`, `fetch_page(url, timeout)`
- Produces: `resolve_channel_id(slug, channel_name, cache) → str | None`, `resolve_all_channel_ids(merged, cache, resume) → dict[str, str]`

- [ ] **Step 1: Write the YouTube scraper for Channel ID extraction**

```python
def resolve_channel_id(slug: str, channel_name: str, cache: dict[str, dict]) -> str | None:
    """Resolve a YouTube Channel ID for a youtubers.me channel.

    Strategy:
      1. Check cache (existing JSON files) by normalized name
      2. Scrape youtube.com/@<slug> → extract UC ID from meta/script tags
      3. Fallback: scrape youtube.com/results?search_query=<name> → first channel result
    """
    # Strategy 1: local cache by name
    name_key = channel_name.lower().strip()
    if name_key in cache and cache[name_key].get("channel_id"):
        return cache[name_key]["channel_id"]

    # Strategy 2: try youtube.com/@<slug>
    handle_url = f"https://www.youtube.com/@{slug}"
    soup = fetch_page(handle_url, timeout=15)
    if soup:
        html = str(soup)
        # Patterns YouTube uses in page source
        for pattern in [
            r'"externalId"\s*:\s*"(UC[\w-]{22})"',
            r'"channelId"\s*:\s*"(UC[\w-]{22})"',
            r'browse_id\s*=\s*(UC[\w-]{22})',
            r'canonicalBaseUrl"\s*:\s*"/channel/(UC[\w-]{22})"',
        ]:
            match = re.search(pattern, html)
            if match:
                return match.group(1)

    # Strategy 3: search fallback
    search_url = f"https://www.youtube.com/results?search_query={requests.utils.quote(channel_name)}"
    soup = fetch_page(search_url, timeout=15)
    if soup:
        html = str(soup)
        # First channel result
        match = re.search(r'UC[\w-]{22}', html)
        if match:
            return match.group(0)

    return None


def resolve_all_channel_ids(
    merged: dict[str, dict],
    cache: dict[str, dict],
    resume: bool = False,
) -> dict[str, str]:
    """Resolve channel IDs for all unique channels. Returns {slug: channel_id}."""
    resolved: dict[str, str] = {}
    if resume:
        cp = load_checkpoint("phase3_resolved")
        if cp:
            resolved = cp

    slugs = sorted(merged.keys())
    # Already-resolved from cache can be loaded immediately
    for slug in slugs:
        if slug in resolved:
            continue
        name = merged[slug]["channel_name"]
        name_key = name.lower().strip()
        if name_key in cache and cache[name_key].get("channel_id"):
            resolved[slug] = cache[name_key]["channel_id"]

    pending = [s for s in slugs if s not in resolved]

    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Phase 3: Resolving {len(pending)} Channel IDs (via youtube.com scraping)", file=sys.stderr)
    print(f"  Pre-resolved from cache: {len(resolved)}/{len(slugs)}", file=sys.stderr)

    consecutive_failures = 0
    for i, slug in enumerate(pending):
        if consecutive_failures >= 5:
            time.sleep(5)  # Longer pause if we hit a block
            consecutive_failures = 0

        name = merged[slug]["channel_name"]
        if i > 0:
            time.sleep(2)  # Rate limit: be polite to YouTube

        cid = resolve_channel_id(slug, name, cache)
        if cid:
            resolved[slug] = cid
            consecutive_failures = 0
        else:
            consecutive_failures += 1

        if (i + 1) % 50 == 0 or i == len(pending) - 1:
            pct = (i + 1) / max(len(pending), 1) * 100
            resolved_count = sum(1 for s in pending[:i+1] if s in resolved)
            print(f"  [{i+1}/{len(pending)}] {pct:.0f}% — {resolved_count} resolved, "
                  f"cache total: {len(resolved)}", file=sys.stderr)
            save_checkpoint("phase3_resolved", resolved)
            time.sleep(1)  # Extra pause every 50

    unresolved = [s for s in slugs if s not in resolved]
    print(f"Resolved: {len(resolved)}/{len(slugs)} ({len(unresolved)} unresolved)", file=sys.stderr)
    if unresolved:
        print(f"Sample unresolved: {unresolved[:10]}", file=sys.stderr)

    return resolved
```

- [ ] **Step 2: Wire into main()**

```python
    # Phase 3: Resolve Channel IDs
    if phase_filter in (None, 3):
        cache = load_existing_channel_cache()
        print(f"Channel cache loaded: {len(cache)} entries", file=sys.stderr)
        resolved_ids = resolve_all_channel_ids(merged, cache, resume=resume_mode)
```

- [ ] **Step 3: Commit**

```bash
git add scripts/youtubers_me_scraper.py
git commit -m "feat: Phase 3 — resolve YouTube Channel IDs via web scraping"
```

---

### Task 5: Phase 4 — Scrape individual channel profiles

**Files:**
- Modify: `scripts/youtubers_me_scraper.py`

**Interfaces:**
- Consumes: merged channel dict, resolved_ids dict, `fetch_page(url, timeout)`, `parse_number(text)`
- Produces: `scrape_channel_profile(slug) → dict | None`, `scrape_all_profiles(merged, resolved_ids, resume) → dict[str, dict]`

- [ ] **Step 1: Write the profile page parser**

```python
def scrape_channel_profile(slug: str) -> dict | None:
    """Scrape a single /{slug}/youtuber-stats page for detailed profile data."""
    url = f"{YT_BASE}/{slug}/youtuber-stats"
    soup = fetch_page(url)
    if not soup:
        return None

    profile: dict = {}

    # ── Identity section ──
    # Real name (often in a definition list or labeled section)
    for label in soup.find_all(["dt", "th", "strong", "b"]):
        text = label.get_text(strip=True).lower()
        next_el = label.find_next(["dd", "td", "span", "p"])
        if not next_el:
            continue
        value = next_el.get_text(strip=True)
        if not value:
            continue
        if "real name" in text or "full name" in text:
            profile["real_name"] = value
        elif "age" in text and ":" not in text:
            try:
                profile["age"] = int(value)
            except ValueError:
                pass
        elif "birthday" in text or "born" in text:
            profile["birthday"] = value
        elif "zodiac" in text:
            profile["zodiac"] = value

    # ── Biography (first substantial paragraph) ──
    for p in soup.find_all("p"):
        text = p.get_text(strip=True)
        if len(text) > 80 and not text.startswith("<") and "cookie" not in text.lower():
            profile["biography"] = text
            break

    # ── Growth stats (7d, 30d, 90d) ──
    # These are typically in labeled divs/spans near the main stats
    page_text = soup.get_text()

    growth_fields = {
        "subs_7d": r"last\s*7\s*days?\s*[:\-]?\s*([\d,]+)",
        "subs_30d": r"last\s*30\s*days?\s*[:\-]?\s*([\d,]+)",
        "subs_90d": r"last\s*90\s*days?\s*[:\-]?\s*([\d,]+)",
    }
    growth: dict[str, int] = {}
    for field, pattern in growth_fields.items():
        match = re.search(pattern, page_text, re.IGNORECASE)
        if match:
            growth[field] = parse_number(match.group(1))

    # View growth (similar patterns but for views)
    view_growth_fields = {
        "views_7d": r"(?:video\s*)?views?\s*(?:last\s*)?7\s*days?\s*[:\-]?\s*([\d,]+)",
        "views_30d": r"(?:video\s*)?views?\s*(?:last\s*)?30\s*days?\s*[:\-]?\s*([\d,]+)",
        "views_90d": r"(?:video\s*)?views?\s*(?:last\s*)?90\s*days?\s*[:\-]?\s*([\d,]+)",
    }
    for field, pattern in view_growth_fields.items():
        match = re.search(pattern, page_text, re.IGNORECASE)
        if match:
            growth[field] = parse_number(match.group(1))

    if growth:
        profile["growth"] = growth

    # ── Earnings (30-day) ──
    earnings_match = re.search(
        r'\$[\s]*([\d,.]+[KMB]?)\s*[-–—]\s*\$[\s]*([\d,.]+[KMB]?)',
        page_text, re.IGNORECASE,
    )
    if earnings_match:
        profile["earnings_30d"] = {
            "low": parse_number(earnings_match.group(1)),
            "high": parse_number(earnings_match.group(2)),
        }

    # ── Daily stats table ──
    daily_stats = []
    for table in soup.find_all("table"):
        # Look for table with date + views + earnings columns
        rows = table.find_all("tr")
        if len(rows) < 2:
            continue
        header_text = " ".join(cell.get_text(strip=True).lower() for cell in rows[0].find_all(["td", "th"]))
        if "date" in header_text and ("views" in header_text or "earnings" in header_text):
            for row in rows[1:]:
                cells = row.find_all("td")
                if len(cells) < 3:
                    continue
                date_text = cells[0].get_text(strip=True)
                views = parse_number(cells[1].get_text(strip=True))
                earnings_text = cells[-1].get_text(strip=True)
                earnings_match = re.search(
                    r'\$[\s]*([\d,.]+[KMB]?)\s*[-–—]\s*\$[\s]*([\d,.]+[KMB]?)',
                    earnings_text, re.IGNORECASE,
                )
                daily_stats.append({
                    "date": date_text,
                    "views": views,
                    "earnings_low": parse_number(earnings_match.group(1)) if earnings_match else 0,
                    "earnings_high": parse_number(earnings_match.group(2)) if earnings_match else 0,
                })
            if daily_stats:
                profile["daily_stats"] = daily_stats
            break

    # ── Social links ──
    for a in soup.find_all("a", href=True):
        href = a["href"]
        if "twitter.com" in href and "share" not in href:
            profile["twitter_url"] = href
            break

    # ── Similar channels ──
    similar = []
    for section in soup.find_all(["div", "section"]):
        section_text = section.get_text().lower()
        if "similar" in section_text and "youtuber" in section_text:
            for card in section.find_all(["div", "li"], class_=True):
                link = card.find("a", href=True)
                if link and "/youtuber-stats" in link["href"]:
                    name_el = card.find(["span", "strong", "h3", "h4", "p"])
                    subs_el = card.find(text=re.compile(r'subscriber', re.I))
                    s_slug = link["href"].split("/")[1] if link["href"].startswith("/") else ""
                    similar.append({
                        "channel_name": name_el.get_text(strip=True) if name_el else "",
                        "subscribers_text": subs_el.parent.get_text(strip=True) if subs_el and subs_el.parent else "",
                        "youtubersme_slug": s_slug,
                    })
            break
    if similar:
        profile["similar_channels"] = similar

    # ── Trending videos ──
    trending = []
    for section in soup.find_all(["div", "section"]):
        section_text = section.get_text().lower()
        if "trending" in section_text and "video" in section_text:
            for card in section.find_all(["div", "li"], class_=True):
                link = card.find("a", href=True)
                title_el = link or card.find(["span", "p", "h4"])
                views_el = card.find(text=re.compile(r'(view|watch)', re.I))
                if title_el:
                    trending.append({
                        "title": title_el.get_text(strip=True) if hasattr(title_el, 'get_text') else str(title_el),
                        "views_text": views_el.parent.get_text(strip=True) if views_el and hasattr(views_el, 'parent') and views_el.parent else "",
                    })
            break
    if trending:
        profile["trending_videos"] = trending

    return profile
```

- [ ] **Step 2: Write the profile scraping loop**

```python
def scrape_all_profiles(
    merged: dict[str, dict],
    resolved_ids: dict[str, str],
    resume: bool = False,
) -> dict[str, dict]:
    """Scrape profile pages for all channels with resolved IDs. Returns {slug: profile_dict}."""
    profiles: dict[str, dict] = {}
    if resume:
        cp = load_checkpoint("phase4_profiles")
        if cp:
            profiles = cp

    # Only scrape profiles for channels we have IDs for
    to_scrape = [s for s in resolved_ids if s not in profiles and s in merged]

    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Phase 4: Scraping {len(to_scrape)} individual channel profiles", file=sys.stderr)

    for i, slug in enumerate(to_scrape):
        if i > 0:
            time.sleep(0.5)  # Rate limit

        profile = scrape_channel_profile(slug)
        if profile:
            profiles[slug] = profile

        if (i + 1) % 100 == 0 or i == len(to_scrape) - 1:
            print(f"  [{i+1}/{len(to_scrape)}] {len(profiles)} profiles scraped", file=sys.stderr)
            save_checkpoint("phase4_profiles", profiles)

    print(f"Profiles scraped: {len(profiles)}", file=sys.stderr)
    return profiles
```

- [ ] **Step 3: Wire into main()**

```python
    # Phase 4: Individual profiles
    if phase_filter in (None, 4):
        profiles = scrape_all_profiles(merged, resolved_ids, resume=resume_mode)
```

- [ ] **Step 4: Commit**

```bash
git add scripts/youtubers_me_scraper.py
git commit -m "feat: Phase 4 — scrape individual channel profiles"
```

---

### Task 6: Phase 5 — Cross-reference, final output, dry-run test

**Files:**
- Modify: `scripts/youtubers_me_scraper.py`

**Interfaces:**
- Consumes: all previous phase outputs
- Produces: final `OUTPUT_PATH` JSON file

- [ ] **Step 1: Write the output assembler**

```python
def assemble_output(
    merged: dict[str, dict],
    resolved_ids: dict[str, str],
    profiles: dict[str, dict],
) -> dict:
    """Assemble final JSON output matching existing schema conventions."""
    channels = []
    with_cid = 0
    with_feed = 0
    with_profile = 0

    for slug, data in merged.items():
        cid = resolved_ids.get(slug, "")
        profile = profiles.get(slug, {})

        channel = {
            "channel_id": cid,
            "channel_name": data["channel_name"],
            "feed_url": f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}" if cid else "",
            "youtubersme_slug": slug,
            "youtubersme_url": f"https://us.youtubers.me/{slug}/youtuber-stats",
            "countries": data.get("countries", []),
            "categories": data.get("categories", []),
            "listing_stats": {
                "subscribers_total": data.get("subscribers_total", 0),
                "video_views_total": data.get("video_views_total", 0),
                "video_count": data.get("video_count", 0),
                "started_year": data.get("started_year", 0),
                "thumbnail_url": data.get("thumbnail_url", ""),
                "subscribers_per_year": data.get("subscribers_per_year", 0),
                "views_per_year": data.get("views_per_year", 0),
                "videos_per_year": data.get("videos_per_year", 0),
            },
            "profile": profile if profile else None,
            "source": "youtubers.me",
        }

        if cid:
            with_cid += 1
            if channel["feed_url"]:
                with_feed += 1
        if profile:
            with_profile += 1

        channels.append(channel)

    # Sort by subscribers descending
    channels.sort(key=lambda c: c["listing_stats"]["subscribers_total"], reverse=True)

    return {
        "metadata": {
            "source": "youtubers.me — 30 countries + 16 categories, Top 1000 each",
            "total_unique_channels": len(channels),
            "with_channel_id": with_cid,
            "with_feed_url": with_feed,
            "with_profile": with_profile,
            "countries_scraped": len(COUNTRIES),
            "categories_scraped": len(CATEGORIES),
        },
        "channels": channels,
    }
```

- [ ] **Step 2: Wire final output into main()**

```python
    # Phase 5: Assemble & save
    if phase_filter in (None, 5):
        print(f"\n{'='*60}", file=sys.stderr)
        print("Phase 5: Assembling final output", file=sys.stderr)

        output = assemble_output(merged, resolved_ids, profiles)
        meta = output["metadata"]
        print(f"Total unique channels: {meta['total_unique_channels']}", file=sys.stderr)
        print(f"With channel ID: {meta['with_channel_id']}", file=sys.stderr)
        print(f"With feed URL: {meta['with_feed_url']}", file=sys.stderr)
        print(f"With profile data: {meta['with_profile']}", file=sys.stderr)

        if write_mode:
            OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
            OUTPUT_PATH.write_text(
                json.dumps(output, indent=2, ensure_ascii=False),
                encoding="utf-8",
            )
            print(f"\n✓ Written {meta['total_unique_channels']} channels to {OUTPUT_PATH}", file=sys.stderr)
        else:
            # Dry-run: show sample
            print(f"\nDRY RUN — top 5 channels:", file=sys.stderr)
            for ch in output["channels"][:5]:
                print(f"  {ch['channel_name'][:40]:40s} "
                      f"{ch['listing_stats']['subscribers_total']:>15,} subs  "
                      f"cid={ch['channel_id'] or 'UNRESOLVED'}", file=sys.stderr)
            print(f"\nDRY RUN complete. Use --write to save.", file=sys.stderr)
```

- [ ] **Step 3: Full dry-run test with limited scope**

Add a quick test mode for verification:

```python
# Add near top of main(), before phase execution:
    quick_test = "--quick" in sys.argv
    if quick_test:
        # Override: only scrape 1 country (top 15) + 1 category (top 15), skip profiles
        test_country = {"united-states": "united-states"}
        test_category = {"gaming": "Gaming"}
        # ... override globals or pass through
```

Run: `python3 scripts/youtubers_me_scraper.py`
Expected: Parses listing pages, deduplicates, attempts channel ID resolution, assembles output, prints top 5 channels.

- [ ] **Step 4: Commit**

```bash
git add scripts/youtubers_me_scraper.py
git commit -m "feat: Phase 5 — cross-reference, final output assembly, dry-run"
```

---

### Task 7: Integration test — end-to-end with Top 15 US

**Files:**
- Modify: `scripts/youtubers_me_scraper.py` (add `--quick` flag)

- [ ] **Step 1: Add `--quick` test mode**

Add after CLI parsing in `main()`:

```python
    quick_test = "--quick" in sys.argv

    # Limit scope for quick testing
    top_n = 15 if quick_test else 1000

    if quick_test:
        print("QUICK TEST MODE — Top 15 only\n", file=sys.stderr)
```

Pass `top_n` through to `scrape_country_listing` and `scrape_category_listing` (the functions already accept URLs; modify `scrape_all_countries` to accept an optional `top_n` parameter).

- [ ] **Step 2: Run quick test**

Run: `python3 scripts/youtubers_me_scraper.py --quick`
Expected: 
- Scrapes US Top 15 + Gaming Top 15
- Deduplicates
- Resolves some channel IDs (via cache + scraping)
- Prints top 5 channels with data
- No errors

- [ ] **Step 3: Fix any parsing issues found in quick test**

Inspect output, adjust selectors if the HTML structure differs from expectations.

- [ ] **Step 4: Final commit**

```bash
git add scripts/youtubers_me_scraper.py
git commit -m "feat: add --quick test mode for integration testing"
```
