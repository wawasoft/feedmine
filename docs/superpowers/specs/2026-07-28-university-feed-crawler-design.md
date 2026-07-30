# University RSS/Atom Feed Crawler

**Date:** 2026-07-28
**Status:** Implemented

## Overview

Crawls all university websites globally to discover RSS/Atom feeds, YouTube channels,
and podcast links. Integrates with the existing feedmine feed discovery pipeline.

## Architecture

### 1. Data Source: Wikidata SPARQL

**Script:** `scripts/build_university_list.py`

Queries Wikidata for all higher education institutions (Q3918, Q189004, Q11427974)
per country. Extracts: name, official website, YouTube channel, Instagram, Twitter.

**Results:** 38,757 universities across 101 countries, 25,798 with official websites.

**Output:** `scripts/feed_discovery/data/universities/by_country/{slug}.json`

### 2. University Crawler

**Module:** `scripts/feed_discovery/sources/universities.py`

For each university website, performs phased discovery:

- **Phase 1:** Homepage crawl — `<link alternate>` autodiscovery + `<a href>` feed links + feed hub detection
- **Phase 2:** Sub-page crawl — `/news`, `/blog`, `/podcast`, `/noticias`, etc.
- **Phase 2b:** Feed hub crawl — pages like `/rss`, `/feeds` that aggregate multiple feeds
- **Phase 2c:** Direct hub probing — `/rss`, `/feeds`, `/podcasts` (bypasses homepage CDN variability)
- **Phase 3:** YouTube channel extraction — Wikidata + `<a href>` scraping
- **Phase 4:** Podcast link extraction — Apple Podcasts, Spotify, Anchor.fm
- **Phase 5:** Common path probing — `/feed/`, `/rss.xml`, `/atom.xml`, `/feed.xml`, etc.
- **Phase 6:** Feed validation — HTTP GET + RSS/Atom parse verification

**Key design decisions:**
- Browser-like headers (`Accept: text/html`) to avoid JS-only CDN stubs
- `TCPConnector(force_close=True)` to prevent CDN connection-pool corruption
- Retry logic for truncated responses (< 2000 bytes)
- Direct hub probing as fallback when homepage CDN omits footer content
- Caching per-university to avoid re-crawling

### 3. Standalone Runner

**Script:** `scripts/crawl_university_feeds.py`

Processes one or all countries, aggregating results.

**Usage:**
```bash
# Build university list first
python3 scripts/build_university_list.py           # all countries
python3 scripts/build_university_list.py --country brazil

# Crawl feeds
python3 scripts/crawl_university_feeds.py --country brazil
python3 scripts/crawl_university_feeds.py --country brazil --max 10 --fresh
python3 scripts/crawl_university_feeds.py --all    # all countries
```

**Output:** `scripts/feed_discovery/data/universities/output/{slug}_feeds.json`

## Verified Results

| Country | Universities | With Feeds | Feeds Total |
|---------|-------------|------------|-------------|
| Brazil | 310 | — | — |
| Uruguay | 5 | 2 | 2 |
| Portugal | 12 | 5 | 12 |
| MIT (US) | 1 | 1 | 64 |

## Limitations

- **JavaScript-rendered sites:** Cannot crawl SPAs or sites requiring JS execution. Some major universities (Harvard, Stanford — Cloudflare-protected) return no content.
- **CDN variability:** Some CDNs (MIT Pantheon/Varnish) serve different page versions per backend pod. Mitigated with retry + direct hub probing.
- **Rate limiting:** Wikipedia/Wikidata requires 0.3-0.5s delays between requests.

## Data Flow

```
Wikidata SPARQL
  → universities/by_country/{slug}.json
    → universities.py (_crawl_one_university)
      → Candidate objects (feeds, YouTube, podcasts)
        → crawl_university_feeds.py
          → universities/output/{slug}_feeds.json
            → OPML export / feedmine pipeline
```
