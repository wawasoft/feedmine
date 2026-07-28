# Design: Youtubers.me Scraper

**Date:** 2026-07-28
**Branch:** fix/onboarding-image-pipeline
**Goal:** Scrape ALL channel data from youtubers.me — listings, profiles, resolve YouTube Channel IDs.

## Source Scope

- **30 countries** × Top 1000 each (URL: `/{slug}/all/top-1000-youtube-channels-in-{slug}`)
- **16 global categories** × Top 1000 each (URL: `/global/{cat}/top-{cat}-youtube-channels`)
- **Individual channel profiles** for every unique channel discovered (URL: `/{handle}/youtuber-stats`)
- Total: ~46 listing pages → ~10-15K unique channels

## Data Extracted

### From listing pages (2 tables per page)

| Table 1 (main) | Table 2 (detail) |
|---|---|
| rank, channel_name, youtubersme_slug | rank, channel_name |
| subscribers_total, video_views_total | subscribers_per_year, views_per_year |
| video_count, category, started_year | videos_per_year |
| — | thumbnail_url (real, from yt3.ggpht.com) |

### From individual `/youtuber-stats` pages

| Section | Fields |
|---|---|
| Identity | real_name, age, birthday, zodiac, country, category, biography |
| Growth | subs_7d, subs_30d, subs_90d, views_7d, views_30d, views_90d |
| Earnings | earnings_30d_low, earnings_30d_high |
| Daily stats | daily_stats[]: {date, video_views, earnings_low, earnings_high} |
| Social | twitter_url (and any other social links found) |
| Similar | similar_channels[]: {channel_name, subscribers, youtubersme_slug} |
| Trending | trending_videos[]: {title, views} |

## Architecture

### Phase 1 — Scrape Listings (46 requests)

- For each of 30 countries + 16 categories, fetch Top 1000 page
- Parse with BeautifulSoup (2nd table for thumbnails, 1st table for everything else)
- Extract: rank, name, slug, subs, views, videos, category, started_year, thumbnail
- Collect into raw index keyed by slug
- Rate limit: 0.5s between requests (polite, ~25s total)

### Phase 2 — Dedup & Merge

- Deduplicate by youtubersme_slug (unique per channel)
- Merge: if same channel appears in US and BR, accumulate `countries: ["us", "br"]`
- Same for categories: accumulate `categories: ["entertainment", "music"]` for category listings
- Produce flat list of unique channel slugs + merged metadata from listings

### Phase 3 — Resolve YouTube Channel IDs (no API, web scrape)

For each unique channel:
1. **Attempt 1:** `youtube.com/@<slug>` — extract `UC...` from page HTML (regex: `"externalId":"UC[\w-]{22}"`)
2. **Attempt 2 (fallback):** `youtube.com/results?search_query=<channel_name>` — parse first channel result, extract UC ID
3. **Cache hit:** Check existing data files first (`youtube_channels_wikipedia.json`, `socialblade.json`, `diamond.json`, `awards.json`) for known channel names/IDs

Rate limit: 1-2s between requests (YouTube scraping, ~3-8 hours for 10K channels). Saves progress incrementally.

### Phase 4 — Scrape Individual Profiles (10-15K requests)

For each unique channel with a resolved channel_id:
- Fetch `/{slug}/youtuber-stats`
- Parse identity, growth, earnings, daily stats, bio, social, similar, trending
- Rate limit: 0.5s between requests (~2 hours for 10K)
- Saves progress incrementally to survive interruptions

### Phase 5 — Cross-Reference & Enrich

- Match against existing channel data by channel_id
- Fill in missing fields from wikipedia, socialblade, diamond, awards datasets
- Mark source provenance per channel

## Channel ID Resolution Strategy (Phase 3 detail)

```
Input: {channel_name: "MrBeast", slug: "mrbeast"}

1. Check local cache (all existing JSON files) → if found, use cached channel_id
2. GET youtube.com/@mrbeast → extract UC ID from meta/script tags
3. If #2 fails (404/redirect/no ID → not a valid handle):
   GET youtube.com/results?search_query=MrBeast → parse first channel card
4. If still fails: mark as unresolved, log for manual review
```

Expected resolution rate: 85-95% (most youtubers.me slugs match YouTube handles; search fallback for the rest).

## Output Schema

```json
{
  "metadata": {
    "source": "youtubers.me — 30 countries + 16 categories, Top 1000 each",
    "scraped_at": "2026-07-28T00:00:00Z",
    "total_unique_channels": 12345,
    "resolved_channel_ids": 11000,
    "unresolved": 1345,
    "countries_scraped": 30,
    "categories_scraped": 16
  },
  "channels": [
    {
      "channel_id": "UCX6OQ3DkcsbYNE6H8uQQuVA",
      "channel_name": "MrBeast",
      "feed_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCX6OQ3DkcsbYNE6H8uQQuVA",
      "youtubersme_slug": "mrbeast",
      "countries": ["united-states", "brazil", "india"],
      "categories": ["entertainment"],
      "listing_stats": {
        "subscribers_total": 477000000,
        "video_views_total": 117617897625,
        "video_count": 963,
        "started_year": 2012,
        "thumbnail_url": "https://yt3.ggpht.com/...=s88-c-k-c0x00ffffff-no-rj",
        "subscribers_per_year": 34071428,
        "views_per_year": 8401278401,
        "videos_per_year": 68
      },
      "profile": {
        "real_name": "Jimmy Donaldson",
        "age": 28,
        "birthday": "1998-05-07",
        "country": "United States",
        "biography": "...",
        "growth": {
          "subs_7d": 2333334,
          "subs_30d": 10000000,
          "subs_90d": 30000000,
          "views_7d": 713765756,
          "views_30d": 3058996095,
          "views_90d": 9176988285
        },
        "earnings_30d": {"low": 1150000, "high": 6880000},
        "daily_stats": [{"date": "2026-04-13", "views": 611799219, "earnings_low": 229000, "earnings_high": 1380000}],
        "twitter_url": "https://twitter.com/MrBeast",
        "similar_channels": [{"name": "...", "subscribers": 22000000, "slug": "..."}],
        "trending_videos": [{"title": "...", "views": 6405555}]
      },
      "source": "youtubers.me"
    }
  ]
}
```

## Dependencies

- `requests` + `BeautifulSoup` (matches existing scraper stack)
- No new dependencies
- YouTube Data API: NOT used (pure web scraping for Channel ID resolution)

## Existing Patterns Followed

- Same CLI convention: dry-run default, `--write` to save
- Same output directory: `scripts/feed_discovery/data/`
- Same JSON schema conventions (metadata wrapper, channels array)
- Incremental save with `--resume` support (pick up where left off)
- Cross-reference with existing `youtube_channels_*.json` files

## Edge Cases & Error Handling

- **Channel not found on YouTube:** Mark as unresolved, continue
- **Rate limited by YouTube:** Exponential backoff, longer delays after 429/block
- **Missing data:** All fields optional/nullable, don't break on missing elements
- **Encoding issues:** Channel names may have emoji (✿ Kids Diana Show), use UTF-8
- **Interrupted runs:** Phase-level checkpoint files, `--resume` flag
- **Duplicate slugs:** Different countries may use different slugs for same channel — match by channel_id after resolution, re-merge
