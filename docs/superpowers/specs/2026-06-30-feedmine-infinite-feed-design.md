# Feedmine — Infinite Feed Prototype: Design Spec

**Date:** 2026-06-30
**Platform:** iOS 18+ (iPhone only)
**Stack:** SwiftUI + `@Observable` + Actor + FeedKit
**Scope:** Single-screen infinite RSS feed with bounded memory buffer, OPML hot folder ingestion, and reservoir-based lazy loading

## Concept

Feedmine is an RSS reader that opens directly into a continuous vertical feed. Article cards scroll vertically with automatic content loading triggered by scroll position. A **reservoir** holds pre-fetched items and feeds them into the visible list as needed — new network fetches only happen when the reservoir runs low. Older items far from the user's current position are discarded to keep memory bounded. A debug status bar shows live counters for validation across the full pipeline.

This is a technical prototype — the goal is to prove the feed pipeline works before expanding the product.

## Architecture

Single-screen app. No tabs, no navigation. All state in memory.

```
FeedmineApp.swift          → entry point
ContentView.swift          → creates FeedLoader, injects via .environment
  └─ FeedScreen.swift      → ScrollView + LazyVStack + DebugStatusBar
       └─ FeedItemCardView → reusable card per item
```

### Data Flow Pipeline

```
OPML hot folder (Resources/Feeds/)
       ↓
OPMLParser          → OPMLParseResult (sources + statistics)
       ↓
FeedSource[]        → deduplicated by normalized URL
       ↓
RSSFetcher (actor)  → FeedFetchBatch (items + statistics), off main thread
       ↓
reservoir           → pre-fetched items, not yet visible
       ↓
visible items[]     → what the screen renders (window from reservoir)
       ↓
bounded buffer      → discard old items far from current position
```

The UI never sees OPML or fetching details. The UI only observes `loader.items`, loading state, and debug counters.

### Approach

`@Observable` + Actor. The `FeedLoader` manages the full pipeline: OPML ingestion → feed fetching → reservoir → visible window → buffer discard. The `RSSFetcher` actor handles concurrent network I/O. Views are passive observers.

## File Structure

```
feedmine/
├── feedmineApp.swift
├── ContentView.swift
├── Models/
│   ├── FeedSource.swift
│   ├── FeedItem.swift
│   ├── OPMLParseResult.swift
│   └── FeedFetchBatch.swift
├── Services/
│   ├── RSSFetcher.swift
│   ├── FeedLoader.swift
│   └── OPMLParser.swift
├── Resources/
│   └── Feeds/                  ← hot folder — all .opml files auto-loaded
│       ├── tech.opml
│       ├── news.opml
│       ├── science.opml
│       ├── design.opml
│       └── culture.opml
├── Views/
│   ├── FeedScreen.swift
│   ├── FeedItemCardView.swift
│   └── DebugStatusBar.swift
└── Assets.xcassets/
```

## Models

### FeedSource

Loaded from OPML. Read-only. Deduplication key is the normalized URL.

```swift
struct FeedSource: Codable, Identifiable, Sendable {
    var id: String { url }
    let title: String
    let url: String
    let category: String
}
```

### FeedItem

Created by `RSSFetcher` during parsing.

```swift
struct FeedItem: Identifiable, Sendable {
    let id: String           // SHA256("\(sourceURL)|\(guid ?? link)")
    let sourceTitle: String
    let sourceURL: String
    let category: String
    let title: String
    let excerpt: String      // HTML stripped, 200 chars max
    let url: String
    let imageURL: String?
    let publishedAt: Date
}
```

**ID generation:** `SHA256("\(sourceURL)|\(guid ?? link)")`. Guarantees uniqueness across different feeds that may share GUIDs. When both GUID and link are missing, fallback to `"\(sourceURL)|\(title)|\(publishedAt.timeIntervalSince1970)"` — imperfect but prevents data loss.

**URL requirement:** Items without a clickable URL (empty `link`) are discarded. A card with no destination breaks the test experience.

**Excerpt sources (tried in order):** `description` → `content:encoded` → `summary` → `content`. After extraction: strip HTML tags → trim whitespace → truncate to 200 chars → fallback to `"No description"`.

**Image extraction order:** `media:content` / `media:thumbnail` → `enclosure` with `type="image/*"` → first `<img>` tag in content HTML → `nil`.

### OPMLParseResult

```swift
struct OPMLParseResult: Sendable {
    let sources: [FeedSource]
    let fileCount: Int
    let failedFileCount: Int
    let invalidSourceCount: Int
}
```

### FeedFetchBatch

```swift
struct FeedFetchBatch: Sendable {
    let items: [FeedItem]
    let fetchedSourceCount: Int
    let failedSourceCount: Int
    let emptySourceCount: Int
}
```

## OPML Parsing

### Hot Folder

`OPMLParser` scans `Bundle.main` for all `.opml` files under `Resources/Feeds/`. Every `.opml` in that directory is loaded automatically — drop a new file in, it's included on next build.

### Tolerant Parser

Accepts both naming conventions for the title attribute:

```xml
<outline title="Ars Technica" xmlUrl="https://..." type="rss"/>
<outline text="Ars Technica" xmlUrl="https://..." type="rss"/>
```

Extracts these fields from each `<outline>`: `title` (or `text`), `xmlUrl`, `htmlUrl` (if present), `type` (if present).

### Category Inheritance

1. If the parent `<outline>` has a `text` attribute → use it as category.
2. If no parent category → use the filename without extension, capitalized (e.g., `tech.opml` → `"Tech"`, `science.opml` → `"Science"`).

### Isolation

Each `.opml` file is processed independently. A malformed `culture.opml` does not prevent `tech.opml` and `news.opml` from working. Failed files increment `failedFileCount` in `OPMLParseResult`.

### Source Deduplication

Sources are deduplicated by normalized URL before being returned. Normalization: trim whitespace, remove trailing slash, lowercase scheme and host. If the same `xmlUrl` appears in multiple OPML files, keep only one `FeedSource`.

## Services

### RSSFetcher

Actor. Off main thread. Fetches and parses RSS/Atom via FeedKit.

```swift
actor RSSFetcher {
    init(timeout: TimeInterval = 15)

    /// Fetch a single feed. Never throws — returns empty on error.
    func fetch(_ source: FeedSource) async -> [FeedItem]

    /// Fetch multiple feeds concurrently with a real concurrency cap.
    func fetchAll(_ sources: [FeedSource], maxConcurrent: Int = 5) async -> FeedFetchBatch
}
```

**Behavior:**
- **Real timeout:** 15 seconds per feed via `URLSessionConfiguration.timeoutIntervalForResource`. Not just documented — enforced.
- **Real concurrency cap:** `TaskGroup` limited to `maxConcurrent` simultaneous requests. If the hot folder grows to 100 feeds, the cap prevents flooding.
- **Network error:** returns `[]`, logs to console — never throws.
- **Malformed feed (FeedKit parse failure):** returns `[]`, increments `failedSourceCount`.
- **Empty feed (valid, no items):** returns `[]`, increments `emptySourceCount`.
- **Success:** items included, increments `fetchedSourceCount`.

**Return type:**
```swift
FeedFetchBatch(
    items: [...],
    fetchedSourceCount: 12,
    failedSourceCount: 1,
    emptySourceCount: 2
)
```

### FeedLoader

`@Observable`, `@MainActor`. Manages the full pipeline from OPML to visible items.

```swift
@MainActor
@Observable
final class FeedLoader {
    // MARK: - Public state (observed by views)
    private(set) var items: [FeedItem] = []         // visible items rendered by UI
    private(set) var loadingState: FeedLoadingState = .idle

    // Debug counters
    private(set) var opmlFileCount = 0
    private(set) var sourceCount = 0
    private(set) var invalidSourceCount = 0
    private(set) var opmlErrorCount = 0
    private(set) var reservoirCount = 0
    private(set) var totalFetched = 0
    private(set) var totalDiscarded = 0
    private(set) var fetchErrorCount = 0
    private(set) var emptyFeedCount = 0

    // MARK: - Internal state
    private var reservoir: [FeedItem] = []
    private var loadedIDs: Set<String> = []
    private var currentVisibleItemID: String?
    private var currentVisibleIndex: Int = 0
    private var hasStarted = false

    // MARK: - Constants
    static let maxBuffer = 300
    static let loadMoreThreshold = 15
    static let discardBatchSize = 50
    static let initialWindowSize = 50
    static let reservoirLowWatermark = 20
    static let safetyZoneRadius = 50
}
```

**Loading states:**
```swift
enum FeedLoadingState {
    case idle
    case initial          // first load on app open
    case refreshing       // pull-to-refresh
    case loadingMore      // scrolling near bottom
}
```

### Pipeline Methods

**`start() async` — initial load:**
1. Guard `!hasStarted` → prevents multiple starts from `.task` re-execution
2. `hasStarted = true`
3. `loadingState = .initial`
4. Parse OPML: `OPMLParser.parseAll()` → `OPMLParseResult`
5. Populate `opmlFileCount`, `sourceCount`, `invalidSourceCount`, `opmlErrorCount`
6. Deduplicate sources by normalized URL
7. `let batch = await fetcher.fetchAll(sources)`
8. Update `totalFetched`, `fetchErrorCount`, `emptyFeedCount`
9. Deduplicate batch items against `loadedIDs`
10. Sort by `publishedAt` descending (newest first)
11. `reservoir = batch.items`
12. Move first `initialWindowSize` items from reservoir to `items`
13. Register moved items in `loadedIDs`
14. `reservoirCount = reservoir.count`
15. `loadingState = .idle`

**`refresh() async` — pull-to-refresh:**
1. `loadingState = .refreshing`
2. Clear `loadedIDs`, `reservoir`, `items`
3. Same fetch flow as start
4. `loadingState = .idle`

**`loadMoreIfNeeded(currentItem: FeedItem) async` — triggered on card appear:**
1. Track visible position: `currentVisibleItemID = currentItem.id`, store `currentVisibleIndex`
2. If `loadingState != .idle`, return immediately (prevents overlapping loads)
3. If `currentItem` is not within the last `loadMoreThreshold` items of `items`, return
4. If `reservoir.count >= loadMoreThreshold`:
   - Move `loadMoreThreshold` items from reservoir to `items` (no network fetch)
   - `reservoirCount = reservoir.count`
5. If `reservoir.count < reservoirLowWatermark`:
   - `loadingState = .loadingMore`
   - Fetch new batch → deduplicate → sort → append to `reservoir`
   - Move `loadMoreThreshold` items from reservoir to `items`
   - `trimBufferIfNeeded()`
   - `loadingState = .idle`

**`trimBufferIfNeeded()` — buffer management:**
1. If `items.count <= maxBuffer`, return
2. Identify items outside the safety zone: more than `safetyZoneRadius` positions away from `currentVisibleIndex`
3. Remove candidates in batches of `discardBatchSize`, starting with the furthest from current position
4. Do NOT remove items within ±`safetyZoneRadius` of `currentVisibleIndex`
5. Increment `totalDiscarded`

## Lazy Loading Strategy

RSS feeds have no pagination — refetching the same feeds returns mostly the same items, which deduplication would filter out. Instead:

1. **Initial fetch** collects a large batch into the `reservoir`
2. Only `initialWindowSize` (50) items are moved to the visible `items` array
3. **Scrolling near the bottom** moves more items from reservoir to visible list — no network call
4. **Network fetch** only triggers when `reservoir` drops below `reservoirLowWatermark` (20 items)
5. Newly fetched items are appended to `reservoir`, then a batch moves to `items`

This keeps the feed responsive, avoids wasteful refetches, and correctly models the "infinite" feel despite finite RSS data.

## Views

### ContentView

```swift
struct ContentView: View {
    @State private var loader = FeedLoader()

    var body: some View {
        FeedScreen()
            .environment(loader)
    }
}
```

### FeedScreen

```swift
struct FeedScreen: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        VStack(spacing: 0) {
            DebugStatusBar()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(loader.items) { item in
                        FeedItemCardView(item: item)
                            .onAppear {
                                Task {
                                    await loader.loadMoreIfNeeded(currentItem: item)
                                }
                            }
                    }
                }
            }
        }
        .task {
            await loader.start()
        }
        .refreshable {
            await loader.refresh()
        }
    }
}
```

### FeedItemCardView

Lightweight, no buttons, no swipe. Read-only display.

```
┌──────────────────────────────────┐
│ ┌──────────────────────────────┐ │
│ │   AsyncImage (imageURL?)     │ │  ← .frame(height: 180), .clipped()
│ │   placeholder: gray.opacity  │ │
│ └──────────────────────────────┘ │
│  🔬 Science · Ars Technica       │  ← category chip + source, .caption
│  Black holes may have a          │  ← title, 2 lines, .headline
│  temperature after all           │
│  Scientists at CERN have...      │  ← excerpt, 3 lines, .subheadline
│  2 hours ago                     │  ← relative date, .caption
└──────────────────────────────────┘
```

- **No image:** image area collapses, card starts at title
- **Placeholder:** `Color.gray.opacity(0.2)` while loading
- **Image load failure:** placeholder remains, no broken image UI
- **Tap:** opens article URL in `SFSafariViewController` (single approach — not browser fallback)

UI knows nothing about OPML or fetching. It observes `FeedLoader` properties exclusively.

### DebugStatusBar

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 120 visible · 480 reservoir · 15 sources · 5 files · 900 fetched
 300 discarded · 2 fetch errors · 1 OPML error · ⏳ loading
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Two-line compact strip, fixed above the feed. Monospaced digits.

- **Background:** `Color(.systemGray6)`
- **Font:** `.caption.monospacedDigit()`
- **Loading state indicator:** `⏳ initial` / `⟳ refreshing` / `⏳ loading more` / `✓ idle`
- **Always visible** during prototyping

## Buffer Management

- **Max visible buffer:** 300 items
- **Discard batch size:** 50 items at a time
- **Safety zone:** ±50 positions from the currently visible item — never discard inside this zone
- **Discard candidates:** items furthest from `currentVisibleIndex`, starting with the most distant
- **Scroll stability:** removal happens outside the user's visible area; no visual jumps
- **Tracking:** `totalDiscarded` counter reflects all removals

## Error Handling

Two distinct error categories:

| Error Type | Counter | Source |
|-----------|---------|--------|
| OPML ingestion | `opmlErrorCount` | Malformed `.opml` file, unparseable XML |
| RSS fetch/parse | `fetchErrorCount` | Network timeout, FeedKit parse failure |
| Empty feeds | `emptyFeedCount` | Valid feed, zero items (not an error) |

- Broken OPML → skip that file, increment `opmlErrorCount`, continue with remaining files
- Failed feed → skip that source, increment `fetchErrorCount`, other sources continue
- All sources fail → feed is empty, counters reflect reality, UI stays usable
- Feed screen remains responsive regardless of failure count

## Empty States

- **OPML directory empty or missing:** debug bar shows `0 sources · 0 files · ✓ idle`
- **All feeds failed:** empty feed, debug bar shows `fetchErrorCount`
- **Reservoir and items both empty after fetch:** feed is empty, user can pull-to-refresh

## Dependencies

- **FeedKit** (MIT, via SPM) — RSS 2.0, Atom, JSON Feed parsing. Handles encoding, dates, malformed feeds.
- **AsyncImage** (native, iOS 15+) — async image loading with built-in placeholder support.

## Testing Strategy

Manual validation only for this prototype.

### Acceptance Criteria

**Feed pipeline:**
- App opens directly into feed screen with real RSS content
- Smooth scrolling using `LazyVStack`
- No duplicate posts (validated via `loadedIDs` and source deduplication)

**Reservoir behavior:**
- Items move from reservoir to visible list without refetching when reservoir has enough items
- Network fetch only triggers when reservoir drops below low watermark (20 items)

**OPML hot folder:**
- All `.opml` files in `Resources/Feeds/` are loaded automatically
- Adding a new `.opml` file includes its sources on next build
- Same feed URL in multiple OPMLs is loaded only once (source deduplication)

**Buffer management:**
- Visible items stay bounded near 300
- Discard never removes items within ±50 positions of the current visible item
- Scroll remains stable during discard

**Error resilience:**
- Malformed OPML file does not break other OPML files
- Failed feed fetch does not break the feed
- UI remains responsive during all background operations

**Debug visibility:**
- Debug bar distinguishes OPML errors from fetch errors
- Counters reflect: visible items, reservoir size, source count, file count, fetched, discarded, fetch errors, OPML errors, loading state
