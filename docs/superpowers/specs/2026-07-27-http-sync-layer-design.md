# HTTP Sync Layer — Design Spec

**Date:** 2026-07-27
**Status:** Ready for Review
**Scope:** Full rewrite of HTTP synchronization, scheduler intelligence, and feed metadata extraction

## Overview

FeedMine's media parsing is sophisticated, but the HTTP synchronization layer is primitive:
no conditional GET, no 304 handling, no cache directive respect, no adaptive scheduling,
and ~15 metadata fields are parsed by FeedKit but discarded before persistence.

This spec covers all improvements in a single iteration:
HTTP conditional requests, adaptive scheduling, and complete metadata extraction.

## Architecture

```
HTTP Sync Layer (NEW)              Parsing Layer (EXISTING, expanded)
┌─────────────────────┐            ┌──────────────────────────┐
│ FeedHTTPSync        │            │ RSSFetcher (refactored)   │
│ ─────────────────── │   Data     │ ──────────────────────── │
│ • conditional GET   │───────────→│ • extractItems (expanded)│
│ • ETag/If-None-Match│            │ • extractMetadata (new)   │
│ • Last-Modified     │            │ • validateAudio           │
│ • 304 Not Modified  │            │ • detectWebSub (new)      │
│ • Cache-Control     │            │ • detectCloud (new)       │
│ • Expires           │            │ • mergeUpdatedEntries     │
│ • Retry-After       │            └──────────┬───────────────┘
│ • Redirect tracking │                       │
│ • User-Agent        │                       ▼
└─────────┬───────────┘            ┌──────────────────────────┐
          │                        │ FeedItem (expanded)      │
          ▼                        │ ──────────────────────── │
┌─────────────────────┐            │ + updatedAt               │
│ SourceHealth v2     │            │ + authors                 │
│ ─────────────────── │            │ + itemCategories          │
│ + etag               │            │ + rights                  │
│ + lastModified       │            │ + attribution             │
│ + cacheControl       │            │ + enclosures[]            │
│ + expires            │            │ + languageFromFeed        │
│ + canonicalURL       │            │ + alternateLinks          │
│ + ttl                │            └──────────────────────────┘
│ + skipHours/Days     │
│ + capabilities (JSON)│            ┌──────────────────────────┐
│ + lastBuildDate      │            │ AdaptiveScheduler        │
│ + publicationInterval│            │ ──────────────────────── │
│ + pubIntervalConf    │            │ • cadence learning (EMA)  │
│ + retryAfter         │            │ • min interval gate       │
└──────────────────────┘            │ • skipHours/skipDays gate │
                                    │ • conditional vs full GET │
                                    │ • Retry-After throttling  │
                                    │ • diversity scoring (kept)│
                                    └──────────────────────────┘
```

### New Files
- `FeedHTTPSync.swift` — HTTP synchronization actor
- `AdaptiveScheduler.swift` — scheduler with cadence learning
- `HTTPValidators.swift` — HTTP validator models, capabilities, cadence estimator

### Modified Files
- `RSSFetcher.swift` — loses HTTP logic, gains metadata extraction
- `FeedItem.swift` — new fields (updatedAt, authors, categories, etc.)
- `FeedFetchResult.swift` — outcome enum replaces status, +validators +canonicalURL
- `FeedStore.swift` — new migration, validator persistence, item merging
- `SourceScheduler.swift` — replaced by AdaptiveScheduler

### Removed Files
None (SourceScheduler is replaced, not deleted until migration is complete).

---

## Section 1: FeedHTTPSync (HTTP Layer)

### Responsibility
All HTTP semantics. RSSFetcher receives only `Data` for parsing.

### Actor: FeedHTTPSync

```swift
actor FeedHTTPSync {
    private let session: URLSession

    func fetch(_ source: FeedSource, validators: HTTPValidators) async -> FetchHTTPResult
}
```

### Request Construction

1. Build URL from source URL.
2. Add conditional headers if available:
   - `If-None-Match: <etag>`
   - `If-Modified-Since: <lastModified>`
3. Set standard headers:
   - `User-Agent: FeedMine/1.0 (https://feedmine.app/bot)`
   - `Accept: application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml;q=0.9`
4. Execute `session.data(for: request)` with shared URLCache.

### Response Classification

| Status Code | Outcome | Action |
|-------------|---------|--------|
| 200 | `.success(Data)` | Extract new validators from response headers, return data for parsing |
| 304 | `.notModified` | No body — don't parse, return updated validators |
| 301/302/307/308 | Follow redirect | Store final URL as canonicalURL, re-request |
| 429 | `.throttled(retryAfter)` | Extract `Retry-After` header (seconds or HTTP-date) |
| 503 | `.throttled(retryAfter)` | Extract `Retry-After` header |
| Other 4xx/5xx | `.failed(error)` | Network error |
| Timeout/cancellation | `.failed(error)` | URLError |

### Validator Extraction from 200 Response

- `ETag` → response header → new etag (string, may be weak `W/"..."` — preserve as-is)
- `Last-Modified` → response header → new lastModified (HTTP-date string)
- `Cache-Control` → parse directives: max-age, no-cache, no-store, must-revalidate
- `Expires` → HTTP-date → Date

### FetchHTTPResult

```swift
struct FetchHTTPResult: Sendable {
    let data: Data?                    // nil on 304
    let outcome: HTTPOutcome
    let updatedValidators: HTTPValidators
    let canonicalURL: String?          // final URL after redirects
}

enum HTTPOutcome: Sendable {
    case notModified
    case success(Data)
    case throttled(until: Date)
    case failed(Error)
}
```

### URLSession Configuration (shared with RSSFetcher)

- `timeoutIntervalForRequest: 15`
- `timeoutIntervalForResource: 30`
- `waitsForConnectivity: true`
- `httpMaximumConnectionsPerHost: 2`
- `URLCache`: 4 MB memory, 20 MB disk

---

## Section 2: HTTP Validators and Persistence

### HTTPValidators Model

```swift
struct HTTPValidators: Codable, Sendable, Equatable {
    var etag: String?
    var lastModified: String?
    var cacheControl: ParsedCacheControl?
    var expires: Date?
    var canonicalURL: String?
    var lastFetchAt: Date?
    var lastOutcome: FetchOutcomeKind?
    var retryAfter: Date?
    var ttl: Int?                        // RSS <ttl> in minutes
    var skipHours: [Int]?               // hours of day (0-23)
    var skipDays: [String]?             // day names
    var lastBuildDate: Date?
    var capabilities: SourceCapabilities?
    var publicationInterval: TimeInterval?
    var publicationIntervalConfidence: Double?

    struct ParsedCacheControl: Codable, Sendable, Equatable {
        var maxAge: TimeInterval?
        var noCache: Bool
        var noStore: Bool
        var mustRevalidate: Bool
    }

    enum FetchOutcomeKind: String, Codable, Sendable {
        case notModified
        case modifiedWithNewItems
        case modifiedWithoutNewItems
        case failed
        case throttled
    }
}
```

### DB Migration: source_health v2

New columns added via ALTER TABLE:

| Column | Type | Default | Source |
|--------|------|---------|--------|
| `etag` | TEXT | NULL | Response header |
| `last_modified` | TEXT | NULL | Response header |
| `cache_control_max_age` | REAL | NULL | Response header |
| `cache_control_no_cache` | INTEGER | 0 | Response header |
| `cache_control_no_store` | INTEGER | 0 | Response header |
| `cache_control_must_revalidate` | INTEGER | 0 | Response header |
| `expires` | INTEGER | NULL | Response header |
| `canonical_url` | TEXT | NULL | Redirect chain |
| `last_outcome` | TEXT | NULL | RSSFetcher |
| `retry_after` | INTEGER | NULL | 429/503 header |
| `ttl` | INTEGER | NULL | RSS <ttl> element |
| `skip_hours` | TEXT | NULL | RSS element (JSON array) |
| `skip_days` | TEXT | NULL | RSS element (JSON array) |
| `capabilities` | TEXT | NULL | WebSub/cloud/pagination (JSON) |
| `last_build_date` | INTEGER | NULL | RSS element |
| `publication_interval` | REAL | 3600 | AdaptiveScheduler |
| `publication_interval_confidence` | REAL | 0.0 | AdaptiveScheduler |

### Field Ownership

| Field | Filled By |
|-------|-----------|
| `etag`, `lastModified`, `cacheControl`, `expires`, `canonicalURL`, `retryAfter` | FeedHTTPSync |
| `ttl`, `skipHours`, `skipDays`, `lastBuildDate`, `capabilities` | RSSFetcher (via FeedKit) |
| `lastOutcome`, `lastFetchAt` | RSSFetcher |
| `publicationInterval`, `publicationIntervalConfidence` | AdaptiveScheduler |

---

## Section 3: AdaptiveScheduler

### Two-Phase Decision Per Source

```
Phase 1 — GATE (may I fetch now?)
├─ Retry-After still active?                 → SKIP
├─ Current hour in skipHours?                → SKIP
├─ Current day in skipDays?                  → SKIP
├─ Time since last fetch < minimumInterval?  → SKIP
│   (minimumInterval = max(TTL×60, Cache-Control max-age, Expires delta, learned cadence×0.8))
│   (default: 300s when no signals)
└─ Passed all gates                          → PROCEED

Phase 2 — STRATEGY (how to fetch?)
├─ Has ETag or Last-Modified? → conditional GET (cheap)
└─ No validators              → full GET
```

### CadenceEstimator

```swift
struct CadenceEstimator: Codable, Sendable {
    var publicationInterval: TimeInterval = 3600  // default 1h
    var confidence: Double = 0.0                   // 0 = no data, 1 = predictable
    var lastPublication: Date = .distantPast

    /// Weighted moving average (EMA), 0.7 old + 0.3 new
    mutating func recordPublication(_ date: Date) {
        let interval = date.timeIntervalSince(lastPublication)
        if lastPublication > .distantPast {
            publicationInterval = publicationInterval * 0.7 + interval * 0.3
        }
        lastPublication = date
        confidence = min(1.0, confidence + 0.1)
    }

    mutating func recordNoChange() {
        confidence = max(0.1, confidence - 0.02)
    }

    var minInterval: TimeInterval {
        max(300, min(publicationInterval * 0.8, 2_592_000))  // 5 min → 30 days
    }
}
```

### Minimum Interval Calculation

```swift
func minimumInterval(validators: HTTPValidators, estimator: CadenceEstimator) -> TimeInterval {
    if let retryAfter = validators.retryAfter, retryAfter > Date() {
        return retryAfter.timeIntervalSinceNow  // hard block
    }
    var candidates: [TimeInterval] = []
    if let maxAge = validators.cacheControl?.maxAge { candidates.append(maxAge) }
    if let ttl = validators.ttl { candidates.append(TimeInterval(ttl * 60)) }
    if let expires = validators.expires { candidates.append(expires.timeIntervalSinceNow) }
    if estimator.confidence > 0.3 { candidates.append(estimator.minInterval) }
    return candidates.max() ?? 300  // default 5 min
}
```

### Urgency Function

```swift
func urgency(validators: HTTPValidators, estimator: CadenceEstimator, now: Date) -> Double {
    let minInterval = minimumInterval(validators: validators, estimator: estimator)
    let elapsed = now.timeIntervalSince(validators.lastFetchAt ?? .distantPast)

    // If confidence is high and we're past expected publication, urgency spikes
    if estimator.confidence > 0.5 {
        let expectedNext = estimator.lastPublication.addingTimeInterval(estimator.publicationInterval)
        if now > expectedNext {
            return min(1.0, 0.5 + now.timeIntervalSince(expectedNext) / estimator.publicationInterval)
        }
    }

    // Otherwise smooth ramp from 0 at minInterval to 1.0 at 2× minInterval
    let excess = elapsed - minInterval
    return min(1.0, max(0, excess / max(minInterval, 1)))
}
```

### skipHours/skipDays Gate

```swift
func isSkipped(validators: HTTPValidators, now: Date) -> Bool {
    if let skipHours = validators.skipHours {
        let hour = Calendar.current.component(.hour, from: now)
        if skipHours.contains(hour) { return true }
    }
    if let skipDays = validators.skipDays {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"  // "Monday", "Tuesday", etc.
        let dayName = formatter.string(from: now)
        if skipDays.contains(dayName) { return true }
    }
    return false
}
```

### Backoff (preserved from SourceScheduler)

```swift
if failures >= 3 {
    let backoff = pow(2.0, Double(failures - 2)) * 60  // 60s → 120s → 240s...
    if now.timeIntervalSince(last) < backoff { continue }
}
```

### Diversity Scoring (preserved from SourceScheduler)

The existing region/category/content-type/language deficit scoring, diverseSources
selection, and Priority Source fast-pass are all preserved. AdaptiveScheduler adds
the Gate and Strategy layers *before* scoring.

---

## Section 4: FeedFetchOutcome

### New Outcome Model

```swift
enum FeedFetchOutcome: Sendable, Equatable {
    case notModified                                                  // 304
    case modifiedWithNewItems([FeedItem], validators: HTTPValidators) // 200 + new items
    case modifiedWithoutNewItems(validators: HTTPValidators)          // 200 + zero items
    case failed(Error)                                                // network/parse
    case throttled(until: Date)                                       // 429/503
}
```

### Updated FeedFetchResult

```swift
struct FeedFetchResult: Sendable {
    let source: FeedSource
    let items: [FeedItem]
    let outcome: FeedFetchOutcome
    let validators: HTTPValidators
    let canonicalURL: String?
}
```

### Updated FeedFetchBatch

```swift
struct FeedFetchBatch: Sendable {
    let items: [FeedItem]
    let fetchedSourceCount: Int
    let failedSourceCount: Int
    let emptySourceCount: Int
    let notModifiedCount: Int          // NEW
    let throttledCount: Int            // NEW
    let sourceOutcomes: [String: FeedFetchOutcome]  // URL → outcome (was sourceStatuses)
}
```

---

## Section 5: Metadata Extraction (RSSFetcher)

### FeedItem — New Fields

```swift
struct FeedItem: Identifiable, Sendable, Codable, Equatable {
    // --- existing fields (unchanged) ---
    let id: String
    let sourceTitle: String
    let sourceURL: String
    let category: String               // OPML taxonomy category
    let title: String
    let excerpt: String
    let url: String
    var imageURL: String?
    let publishedAt: Date
    let audioURL: String?
    let duration: TimeInterval?
    let region: String
    let language: String?              // from catalog + content detection

    // --- NEW fields (all optional, NULL-able in DB) ---
    let updatedAt: Date?
    let authors: [FeedItemAuthor]?
    let itemCategories: [FeedItemCategory]?   // publisher-declared tags
    let rights: String?
    let attribution: FeedItemAttribution?
    let enclosures: [FeedEnclosure]?
    let languageFromFeed: String?
    let alternateLinks: [FeedAlternateLink]?
}

struct FeedItemAuthor: Codable, Sendable, Equatable {
    let name: String?
    let email: String?
    let uri: String?
}

struct FeedItemCategory: Codable, Sendable, Equatable {
    let term: String
    let scheme: String?
    let label: String?
}

struct FeedItemAttribution: Codable, Sendable, Equatable {
    let title: String?
    let url: String?
    let feedURL: String?
}

struct FeedEnclosure: Codable, Sendable, Equatable {
    let url: String
    let mimeType: String?
    let length: Int64?
    let duration: TimeInterval?
    let medium: String?
}

struct FeedAlternateLink: Codable, Sendable, Equatable {
    let url: String
    let mimeType: String?
    let language: String?
    let rel: String?
}
```

### ParsedItemMetadata (intermediate struct)

To keep `makeItem` manageable, metadata is collected into an intermediate struct:

```swift
struct ParsedItemMetadata {
    let authors: [FeedItemAuthor]?
    let categories: [FeedItemCategory]?
    let rights: String?
    let attribution: FeedItemAttribution?
    let enclosures: [FeedEnclosure]?
    let language: String?
    let alternateLinks: [FeedAlternateLink]?
    let publishedAt: Date?
    let updatedAt: Date?
}
```

### RSS Extraction (FeedKit → FeedItem)

| FeedItem Field | FeedKit Source | Notes |
|----------------|---------------|-------|
| `authors` | `item.author` + `item.iTunes?.iTunesAuthor` | RSS author is a string; parse name/email if format allows |
| `itemCategories` | `item.categories?` | FeedKit parses `<category>` elements |
| `rights` | — | Not native to RSS; check Dublin Core namespace if available |
| `attribution` | `item.source?.value` + `item.source?.attributes?.url` | Already partially used for Google News; expand to all sources |
| `enclosures` | `item.enclosure?` + `item.media?.mediaContents` | ALL enclosures, not just audio. Include length, duration, medium |
| `languageFromFeed` | `rssFeed.language` | Channel-level xml:lang |
| `publishedAt` | `item.pubDate` | |
| `updatedAt` | — | RSS has no update date; nil |

### Atom Extraction (FeedKit → FeedItem)

| FeedItem Field | FeedKit Source | Notes |
|----------------|---------------|-------|
| `authors` | `entry.authors?` → `[AtomFeedEntryAuthor]` | name, email, uri |
| `itemCategories` | `entry.categories?` → `[AtomFeedEntryCategory]` | term, scheme, label |
| `rights` | `entry.rights` | |
| `attribution` | `entry.source?.attributes` | atom:source element |
| `enclosures` | `entry.links?` filtered by `rel="enclosure"` | All enclosure links |
| `languageFromFeed` | `entry.xmlLang` ?? `atomFeed.xmlLang` | Entry-level first, fallback to feed |
| `alternateLinks` | `entry.links?` | href, type, hreflang, rel |
| `publishedAt` | `entry.published` | |
| `updatedAt` | `entry.updated` | |

### JSON Feed Extraction (FeedKit → FeedItem)

| FeedItem Field | FeedKit Source | Notes |
|----------------|---------------|-------|
| `authors` | `jsonItem.author?.name` + `jsonItem.authors?` | Single author or array |
| `itemCategories` | `jsonItem.tags?` | Array of strings |
| `rights` | — | JSON Feed has no rights field |
| `enclosures` | `jsonItem.attachments?` | url, mime_type, size_in_bytes, duration_in_seconds |
| `languageFromFeed` | `jsonFeed.language` | |
| `publishedAt` | `jsonItem.datePublished` | |
| `updatedAt` | `jsonItem.dateModified` | |

### makeItem Refactored

The current 12-parameter `makeItem` method is refactored to use `ParsedItemMetadata`:

```swift
func makeItem(
    guid: String?,
    link: String?,
    title: String?,
    source: FeedSource,
    rawDescription: String?,
    rawContent: String?,
    imageURL: String?,
    audioURL: String?,
    duration: TimeInterval?,
    metadata: ParsedItemMetadata
) -> FeedItem?
```

### Atom Entry Update-by-ID

When an entry has the same `id` as an already-persisted item but a newer `updated`:

```swift
func mergeItems(_ incoming: [FeedItem], into existing: [FeedItem]) -> [FeedItem] {
    var merged = Dictionary(grouping: existing + incoming, by: \.id)
        .compactMapValues { items in
            items.max { a, b in
                let dateA = a.updatedAt ?? a.publishedAt
                let dateB = b.updatedAt ?? b.publishedAt
                return (dateA ?? .distantPast) < (dateB ?? .distantPast)
            }
        }
    return Array(merged.values)
}
```

This is applied in FeedStore during `persistFetchedItems`.

---

## Section 6: Feed Discovery (WebSub / RSS Cloud / Pagination)

### SourceCapabilities Model

```swift
struct SourceCapabilities: Codable, Sendable, Equatable {
    var websub: WebSubEndpoints?
    var cloud: RSSCloudEndpoints?
    var hasPagination: Bool

    struct WebSubEndpoints: Codable, Sendable, Equatable {
        let hub: String
        let selfURL: String?
    }

    struct RSSCloudEndpoints: Codable, Sendable, Equatable {
        let domain: String
        let port: Int
        let path: String
        let registerProcedure: String
        let protocolVersion: String
    }

    var canPush: Bool { websub != nil || cloud != nil }
}
```

### Detection

- **WebSub (Atom)**: `atomFeed.links?` → find `rel="hub"` and `rel="self"`
- **WebSub (RSS)**: Parse `atom:link` elements from raw XML for `rel="hub"` and `rel="self"`
- **WebSub (JSON Feed)**: `jsonFeed.hubs?` → array of hub URLs
- **RSS Cloud**: `rssFeed.cloud?` → FeedKit exposes domain, port, path, registerProcedure, protocol
- **Atom Pagination**: `atomFeed.links?` → find `rel="next"`, `rel="previous"`, `rel="first"`, `rel="last"`

### Canonical URL Resolution

```swift
func resolveCanonicalURL(
    fetchedURL: String,
    finalURL: String?,       // after redirect chain
    selfLink: String?        // from Atom rel="self" or RSS atom:link rel="self"
) -> String {
    selfLink ?? finalURL ?? fetchedURL
}
```

### What We Do Now vs Later

| Capability | Now | Later |
|-----------|-----|-------|
| WebSub endpoints | Detect, store, count (% of feeds) | Build push server, subscribe |
| RSS Cloud | Detect, store | Subscribe (if WebSub isn't available) |
| Atom pagination | Detect, store | Fetch historical pages |
| Canonical URL | Resolve, store, deduplicate | Auto-fix catalog URLs |

---

## Section 7: Network Hygiene

### Headers

```swift
"User-Agent": "FeedMine/1.0 (https://feedmine.app/bot)"
"Accept": "application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml;q=0.9"
```

`https://feedmine.app/bot` must be a real page with:
- Explanation that FeedMine is a news aggregator
- Contact information for server administrators
- Rate limiting policy and how to request exclusion

### application/feed+json

The official MIME type for JSON Feed is `application/feed+json`. Added to Accept header
to signal JSON Feed support to servers that may serve different formats.

---

## Section 8: DB Migration for feed_item

New columns in `feed_item`:

| Column | Type | Default |
|--------|------|---------|
| `updated_at` | INTEGER | NULL |
| `authors` | TEXT | NULL (JSON array) |
| `item_categories` | TEXT | NULL (JSON array) |
| `rights` | TEXT | NULL |
| `attribution_title` | TEXT | NULL |
| `attribution_url` | TEXT | NULL |
| `attribution_feed_url` | TEXT | NULL |
| `enclosures` | TEXT | NULL (JSON array) |
| `language_from_feed` | TEXT | NULL |
| `alternate_links` | TEXT | NULL (JSON array) |

FTS5 virtual table `feed_item_fts` is rebuilt to include `authors`, `item_categories`, and `rights`
for full-text search.

Note: `source_title` already exists in feed_item (the display name of the feed).
The new `attribution_*` fields are for *attribution* — the original source when an item
comes through an aggregator (e.g., Google News items have source="Reuters").
This maps to `FeedItem.attribution` of type `FeedItemAttribution?`.

To avoid confusion with the existing `source_title`, the new attribution fields are
named `attribution_title`, `attribution_url`, `attribution_feed_url`.

---

## Section 9: Data Flow (End to End)

```
User scrolls → consumption recorded
                    │
                    ▼
AdaptiveScheduler.nextBatch()
  ├─ Gate check per source (Retry-After, skipHours, minInterval)
  ├─ Strategy selection (conditional vs full GET)
  ├─ Diversity scoring (region, category, content type, language)
  └─ Returns [FeedSource] to fetch
                    │
                    ▼
RSSFetcher.fetch(source, validators)
  ├─ FeedHTTPSync.fetch(source, validators)
  │   ├─ Conditional headers (If-None-Match, If-Modified-Since)
  │   ├─ Execute request
  │   ├─ 304 → .notModified
  │   ├─ 200 → extract validators, return data
  │   ├─ 429/503 → .throttled(retryAfter)
  │   └─ Error → .failed
  ├─ Parse data via FeedKit (if 200)
  ├─ extractItems → [FeedItem] with metadata
  ├─ detectWebSub, detectCloud, extractTTL, extractSkipHours/Days
  ├─ validateAudio (for items with enclosures)
  └─ Return FeedFetchResult(outcome, items, validators, canonicalURL)
                    │
                    ▼
FeedStore.processFetchResults()
  ├─ For .modifiedWithNewItems:
  │   ├─ mergeItems() — update existing entries by ID
  │   ├─ detect language (skip if languageFromFeed exists)
  │   ├─ persist to feed_item table
  │   └─ update FTS index
  ├─ For .notModified:
  │   └─ Update validators only (no item changes)
  ├─ For .modifiedWithoutNewItems:
  │   └─ Update validators, record no-change
  ├─ For .throttled:
  │   └─ Record retryAfter in validators
  ├─ Save validators to source_health
  ├─ AdaptiveScheduler.recordFetch(...) → update CadenceEstimator
  └─ Submit items to Reservoir
```

---

## Section 10: Testing Strategy

### Unit Tests

| Component | What to Test |
|-----------|-------------|
| `FeedHTTPSync` | ETag/If-None-Match round-trip, 304 handling, Cache-Control parsing, Retry-After parsing, redirect canonical URL |
| `HTTPValidators` | Codable round-trip, JSON serialization of capabilities |
| `AdaptiveScheduler` | Gate rejection (Retry-After, skipHours, minInterval), strategy selection, CadenceEstimator EMA convergence, urgency function |
| `RSSFetcher` | Metadata extraction for RSS/Atom/JSON Feed, WebSub/cloud detection, enclosure extraction, author parsing |
| `FeedItem` | mergeItems (same ID, newer updated wins), new fields encoding |
| `FeedStore` | Migration up/down, validator persistence, canonical URL dedup |

### Integration Tests

- Full pipeline: mock HTTP → parse → persist → schedule next
- AdaptiveScheduler learns cadence over multiple fetch cycles
- 304 → notModified → doesn't re-parse or add items
- 429 → throttled → blocked until Retry-After
- Atom entry updated → old item replaced in DB

---

## Section 11: Rollout Plan

### Phase 1: Models + Migration
1. Add `HTTPValidators`, `ParsedCacheControl`, `CadenceEstimator`, `SourceCapabilities` models
2. Add `FeedFetchOutcome` enum
3. Update `FeedItem` with new fields
4. Write DB migration (source_health v2, feed_item new columns, FTS rebuild)
5. Update `FeedFetchResult` and `FeedFetchBatch`

### Phase 2: HTTP Layer
1. Create `FeedHTTPSync` actor
2. Refactor `RSSFetcher.fetch()` to use FeedHTTPSync
3. Wire up validator persistence in FeedStore
4. Update User-Agent and Accept headers

### Phase 3: Scheduler
1. Create `AdaptiveScheduler` with Gate + Strategy
2. Implement `CadenceEstimator` EMA
3. Wire scheduler into FeedStore fetching pipeline
4. Remove SourceScheduler dependency

### Phase 4: Metadata
1. Expand `extractItems` for RSS/Atom/JSON to harvest all metadata
2. Implement `makeItem` with `ParsedItemMetadata`
3. Add WebSub/cloud detection
4. Implement `mergeItems` for Atom update-by-ID
5. Wire all metadata into FeedItem persistence

### Phase 5: Testing + Polish
1. Unit tests for each component
2. Integration tests for end-to-end pipeline
3. Performance validation (no regression on fetch latency)
4. Metrics: % of 304 responses, % of feeds with WebSub, scheduler accuracy

---

## Appendix: Design Decisions

1. **Keep FeedKit** — it already exposes most metadata fields. Replacing it would add weeks of work with minimal benefit. Complement with inline XML parsing only where FeedKit doesn't cover (RSS atom:link discovery).

2. **Separate HTTP from parsing** — FeedHTTPSync knows HTTP semantics; RSSFetcher knows feed formats. Clean boundary: `Data` crosses between them.

3. **Adaptive scheduler is additive** — the existing diversity scoring (√n regions, category deficits, content type boosts) is preserved. The new Gate and Strategy layers are added *before* scoring.

4. **NULL-able new fields** — all new FeedItem and source_health fields are optional. Old items remain valid. New metadata populates gradually as feeds are re-fetched.

5. **WebSub detection now, push server later** — detecting and storing capabilities is cheap and builds the foundation. The push notification server is a separate project.

6. **Canonical URL resolves duplicates** — two catalog entries pointing to the same `rel="self"` URL are detected as duplicates, preventing double-fetching.
