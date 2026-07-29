# Museum Feed Discovery — Design

**Date:** 2026-07-29
**Status:** Implemented

## Overview

Discover RSS/Atom feeds, YouTube channels, and podcasts from museums worldwide, following the same 3-phase pattern used for universities: Wikidata seed list → web crawl → Candidate generation.

Museums are cultural institutions with active digital presences — exhibition announcements, event calendars, educational content, and increasingly podcasts and video channels. This makes them a natural fit for Feedmine's content catalog.

## Scope

**Museum types (Wikidata):** Art museums (`Q207694`), history museums (`Q188509`), science museums (`Q1747686`), natural history museums (`Q16735822`), generic museums (`Q33506`).

**Geography:** All 101 countries in the Feedmine country catalog.

## Architecture

### Phase 1 — Seed List (`build_museum_list.py`)

Wikidata SPARQL query per country:
- `P31` (instance of) ∈ {art, history, science, natural history, generic museum}
- `P17` (country) = target country
- Extracts: `P856` (website), `P2397` (YouTube channel), `P2003` (Instagram), `P2002` (Twitter), Wikipedia URL

Reuses the country Q-ID cache from `build_university_list.py`.

**Output:** `data/museums/by_country/{slug}.json` — 63,151 museums across 101 countries.

### Phase 2 — Web Crawl (`sources/museums.py`)

Per-museum crawl with 6 phases:

1. **Homepage + autodiscovery** — Fetch root URL, extract `<link alternate>` RSS/Atom tags and `<a href>` feed links
2. **Sub-page crawl** — Fetch `/news`, `/blog`, `/exhibitions`, `/events`, `/press`, `/podcast` (multilingual variants)
3. **YouTube extraction & verification** — Extract channel references from page HTML, then verify ownership:
   - Wikidata `P2397` = ground truth (official channel confirmed)
   - Name similarity: museum name vs channel handle (with stopword removal)
   - Only accept channels found on the museum's own domain
4. **Podcast discovery** — Apple Podcasts, Spotify, Anchor.fm links
5. **Feed probes** — Probe common paths (`/feed/`, `/rss.xml`, `/news/feed/`) if nothing found
6. **Validation** — Fetch + parse each candidate URL to confirm it's a live feed

### Phase 3 — Candidate Generation

All discoveries converted to `Candidate` dataclass:
- RSS feeds → `category="Education"`, `genre="Museum"`
- YouTube official → `category="YouTube"`, `genre="Museum"`
- Podcasts → `category="Podcasts"`, `genre="Museum"`

### CLI (`crawl_museum_feeds.py`)

Standalone async crawler with:
- Per-country or all-country mode
- Configurable parallelism (countries and per-country concurrency)
- Disk cache for both crawl results and per-museum HTML
- Resume support (skip already-crawled countries)

## Data Flow

```
Wikidata SPARQL
  ↓
data/museums/by_country/{slug}.json  (63,151 museums)
  ↓
sources/museums.py  (web crawl: 29,752 with websites)
  ↓
data/museums/crawl_results/{slug}.json  (RSS + YouTube + podcasts)
  ↓
Candidate format → curated/museums/ → curated/combined/
  ↓
Enrichment pipeline
```

## Key Decisions

1. **Reuse university infrastructure** — Same Q-ID resolution, same crawl patterns, same Candidate format. ~80% code overlap with `sources/universities.py`.

2. **Official YouTube detection** — Unlike universities (where any YouTube channel on the .edu domain is assumed official), museums require verification because they frequently embed third-party channels (artist talks, exhibition trailers). Wikidata `P2397` provides ground truth where available; name similarity is the fallback.

3. **Immediate YouTube feeds** — The 1,312 museums with Wikidata YouTube channels are converted to feeds immediately (no crawl needed). These were integrated into `curated/combined/` on 2026-07-29 (+1,303 after dedup).

4. **No social media crawling** — Instagram/Twitter are extracted as metadata only. They don't produce RSS feeds and would require separate API integration.

## Files

| File | Purpose |
|---|---|
| `scripts/build_museum_list.py` | Wikidata SPARQL seed list builder |
| `scripts/feed_discovery/sources/museums.py` | Museum web crawler (async, per-country) |
| `scripts/crawl_museum_feeds.py` | Standalone CLI for batch crawling |
| `scripts/feed_discovery/data/museums/by_country/{slug}.json` | Seed list output (101 files) |
| `scripts/feed_discovery/data/museums/crawl_results/{slug}.json` | Crawl results (101 files) |
| `scripts/feed_discovery/data/curated/museums/{slug}.json` | Candidate format, YouTube feeds (61 files) |

## Limitations & Future Work

- **Netherlands anomaly** — Only 6 museums returned by Wikidata query. Likely a language/label mismatch in SPARQL. Needs investigation.
- **Q-ID names** — Many museums (especially in Brazil, India) lack English labels on Wikidata and appear as `Q12345678`. These get placeholder names but lose discoverability.
- **29,752 websites crawled** — At 5-12s per site with 5 concurrent per country, full crawl takes 2-4 hours. Results cached for incremental updates.
- **No podcast RSS resolution** — Apple/Spotify links are stored as-is; they aren't feed URLs. A future step could resolve them to actual RSS feeds.
- **40 countries have zero museums with YouTube** — These will only get feeds if RSS is found via web crawl.
