# Prepared Feed Architecture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate Feedmine from reactive image loading (CachedAsyncImage in views) to a prepared-feed architecture where all media is resolved before cards enter the visible feed.

**Architecture:** Five-layer pipeline — Content Lake (SQLite) → Editorial Backlog (Reservoir interleave) → Resolved Runway (disk cache, no UIImage) → Render-Ready Runway (decoded images, bounded window) → Published Feed (SwiftUI renders terminal cards only). A `CardPreparationCoordinator` actor replaces `ReadyCardQueue`, a `FeedRunwayController` actor manages adaptive concurrency, and a `MediaAssetStore` actor provides single-flight deduplication.

**Tech Stack:** Swift 6, SwiftUI, GRDB, async/await actors, `@Observable` (MainActor), NSCache, SQLite `image_resolution` table, `URLProtocol` for testing

## Global Constraints

- Do NOT alter the interleave algorithm (weights, freshness, provider/country spreading, cooldown, stale tiers)
- Do NOT alter filter semantics, collection allowlists, Smart Feed rules, or bookmark retention
- Do NOT remove slow items or reorder by image completion time
- Do NOT publish intermediate states — cards must be terminal before entering `visibleCards`
- Do NOT use `CachedAsyncImage` as fallback in the main feed path
- Do NOT introduce synchronous disk reads on the main actor
- Do NOT place the coordinator on `@MainActor`
- Do NOT store hundreds of `UIImage` in the deep runway
- Do NOT use polling (replace with shared `Task`, continuations, actor state)
- Do NOT convert transient failures to permanent absence
- Do NOT substitute media after publication
- Build and run tests after every phase
- Compare editorial order with the legacy pipeline at each phase boundary

---

## File Structure

### New files to create

| File | Responsibility |
|---|---|
| `feedmine/Models/FeedPresentationContext.swift` | `FeedPresentationContext` struct — epoch, mode, generation tracking for context-aware preparation |
| `feedmine/Models/PreparedFeedCard.swift` | `PreparedFeedCard`, `RenderReadyMedia`, `ResolvedCardAsset`, `PlaceholderKind`, `PreparedCardLayout`, `CardPreparationState` — all new/refined models |
| `feedmine/Models/ImageResolutionRecord.swift` | GRDB `FetchableRecord` / `PersistableRecord` for the `image_resolution` table |
| `feedmine/Services/CardPreparationCoordinator.swift` | Actor replacing `ReadyCardQueue` — ordered sequence, contiguous prefix promotion, per-item deadlines, context validation |
| `feedmine/Services/FeedRunwayController.swift` | Actor managing adaptive concurrency — watermarks, pressure states, EMAs, hysteresis |
| `feedmine/Services/RunwayPolicy.swift` | `RunwayPolicy` struct — configurable buffer targets and deadlines |
| `feedmine/Services/MediaAssetStore.swift` | Actor with single-flight deduplication, download coordination, validation, downsample dispatch |
| `feedmine/Services/DiskImageCache.swift` | Actor wrapping disk I/O for cached images — non-MainActor |
| `feedmine/Services/MemoryImageCache.swift` | `final class` wrapping `NSCache<NSString, UIImage>` — `@unchecked Sendable` |
| `feedmine/Services/AsyncLimiter.swift` | Concurrency limiter with per-category slots (direct image, article HTML, disk decode, retry) |
| `feedmine/Services/RunwayMetrics.swift` | EMAs, counters, and histogram accumulators for runway health |
| `feedmineTests/CardPreparationCoordinatorTests.swift` | Tests for contiguous prefix, timeout terminalization, context invalidation |
| `feedmineTests/MediaAssetStoreTests.swift` | Tests for single-flight, failure classification, transient vs permanent |
| `feedmineTests/RunwayControllerTests.swift` | Tests for pressure state transitions, watermark hysteresis |

### Files to modify

| File | Changes |
|---|---|
| `feedmine/Models/FeedCardPresentation.swift` | Refactor: extract `ResolvedCardMedia` → `ResolvedCardAsset` + `PlaceholderKind`; remove `isRead`/`isBookmarked` from presentation; keep `FeedCardPresentation` as legacy alias during migration |
| `feedmine/Services/ReadyCardQueue.swift` | Phase 3: deprecated in favor of `CardPreparationCoordinator`; Phase 9: removed |
| `feedmine/Services/CardPreparationPipeline.swift` | Refactor: add `context`, `index`, `urgencyBand`, per-item deadline; return `ResolvedCardAsset` instead of `UIImage`; integrate `image_resolution` persistence |
| `feedmine/Services/ImageLoader.swift` | Absorb into `MediaAssetStore`; remove duplicate resolution logic |
| `feedmine/Services/ImageCache.swift` | Split: extract `DiskImageCache`, `MemoryImageCache`; remove `@MainActor`; keep `CachedAsyncImage` for non-feed paths |
| `feedmine/Services/ImagePrefetcher.swift` | Phase 9: absorb into `MediaAssetStore` or remove |
| `feedmine/Services/FeedStore.swift` | Add `preparationCoordinator`, `runwayController`; replace `visibleCards: [FeedCardPresentation]` with `visibleCards: [PreparedFeedCard]`; add `presentationEpoch`, `activePresentationContext`; modify all writers (startup, append, refresh, collections, Smart Feeds, bookmarks, etc.) |
| `feedmine/Services/FeedLoader.swift` | Expose `cards: [PreparedFeedCard]`; update `filteredCards`, `dateSections` |
| `feedmine/Views/FeedScreen.swift` | Render from `PreparedFeedCard`; `onAppear` reports position only |
| `feedmine/Views/FeedItemView.swift` | Accept `PreparedFeedCard`; pass prepared media to layouts |
| `feedmine/Views/FeedItemCardView.swift` | Remove `CachedAsyncImage` fallback; render exclusively from `card.media` switch; remove `imageLoadFailed`/`imageAppeared` state |
| `feedmine/Views/FeedItemRowView.swift` | Same as card view — remove `CachedAsyncImage` fallback |
| `feedmine/Services/WhatsNewManager.swift` | Work with candidate `FeedItem` → prepared carousel cards |
| `feedmine/Models/FeedItem.swift` | Add `imageResolutionState` relationship; deprecate `image_url = ''` sentinel |
| `feedmine/Services/AppSettings.swift` | Add `preparedFeedPipelineEnabled` feature flag key |
| `feedmine/Services/ImageResolutionQueue.swift` | Integrate with `image_resolution` table; update delegate protocol |
| Database migrations | Add `image_resolution` table + index; migration for `image_url = ''` → `NULL` |

---

### Task 1: Phase 0 — Baseline and Feature Flag

**Files:**
- Create: (none)
- Modify: `feedmine/Services/AppSettings.swift:1-56`
- Test: (none — build verification)

**Interfaces:**
- Consumes: (none — baseline)
- Produces: `Settings.preparedFeedPipelineEnabled: Bool` (default `false`), launch argument `-PreparedFeedPipeline`

- [ ] **Step 1: Add feature flag key to AppSettings**

```swift
// In enum Keys, add after line ~16:
static let preparedFeedPipelineEnabled = "preparedFeedPipelineEnabled"
```

- [ ] **Step 2: Add Settings accessor**

```swift
// In Settings extension (AppSettings.swift, after Keys enum):
static var preparedFeedPipelineEnabled: Bool {
    UserDefaults.standard.bool(forKey: Keys.preparedFeedPipelineEnabled)
}
```

- [ ] **Step 3: Add launch argument handling in feedmineApp.swift**

In `feedmineApp.swift`, in the `init()` or early setup, check `CommandLine.arguments.contains("-PreparedFeedPipeline")` and set `UserDefaults.standard.set(true, forKey: Keys.preparedFeedPipelineEnabled)`.

- [ ] **Step 4: Build and verify baseline compiles**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Run existing test suite to establish baseline**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Test.*passed|Test.*failed|Executed.*tests"`
Expected: All tests pass (or document pre-existing failures)

- [ ] **Step 6: Commit**

```bash
git add feedmine/Services/AppSettings.swift feedmine/feedmineApp.swift
git commit -m "feat: add prepared feed pipeline feature flag and launch argument

- Settings.preparedFeedPipelineEnabled (default false)
- Launch argument -PreparedFeedPipeline enables at runtime
- No behavior change in production

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Phase 1 — FeedPresentationContext Model

**Files:**
- Create: `feedmine/Models/FeedPresentationContext.swift`
- Modify: (none)
- Test: (none — model-only, tested via integration)

**Interfaces:**
- Consumes: (none)
- Produces: `FeedPresentationContext` (struct, Hashable, Sendable), `FeedPresentationMode` (enum, Hashable, Sendable)

- [ ] **Step 1: Write FeedPresentationContext.swift**

```swift
import Foundation

/// Identifies a specific feed composition session. Every async preparation
/// task captures this context; results are discarded if the context changes
/// before the task completes.
struct FeedPresentationContext: Hashable, Sendable {
    /// Monotonic counter incremented whenever the published sequence must
    /// be rebuilt (preset change, filter change, collection switch, etc.).
    let epoch: UInt64

    /// Which feed surface this context serves.
    let mode: FeedPresentationMode

    /// Snapshot of filterGeneration at context creation time.
    let filterGeneration: Int64

    /// Snapshot of presetGeneration at context creation time.
    let presetGeneration: Int64
}

enum FeedPresentationMode: Hashable, Sendable {
    case main
    case collection(Int64)
    case smartFeed(Int64)
    case bookmarks(Int64?)
    case lastClicked
    case whatsNew
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add feedmine/Models/FeedPresentationContext.swift
git commit -m "feat: add FeedPresentationContext model for context-aware preparation

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Phase 1 — Refined Presentation Models

**Files:**
- Create: `feedmine/Models/PreparedFeedCard.swift`
- Modify: `feedmine/Models/FeedCardPresentation.swift:1-91`
- Test: `feedmineTests/CardPresentationTests.swift:1-183`

**Interfaces:**
- Consumes: `FeedItem` (existing), `FeedPresentationContext` (from Task 2)
- Produces: `PlaceholderKind`, `ResolvedCardAsset`, `RenderReadyMedia`, `RenderImage`, `PreparedCardLayout`, `PreparedFeedCard`, `CardPreparationState`, `ResolvedImageAsset`

- [ ] **Step 1: Add new types to PreparedFeedCard.swift**

```swift
import Foundation
import UIKit

// MARK: - Placeholder Kind

enum PlaceholderKind: String, Codable, Sendable {
    case article
    case video
    case podcast
    case forum
}

// MARK: - Resolved Asset (disk-level, no UIImage)

struct ResolvedImageAsset: Sendable, Equatable {
    let cacheKey: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let source: ImageResolutionSource
}

enum ImageResolutionSource: String, Sendable, Equatable {
    case directImageURL
    case articleOpenGraph
    case youTubeThumbnail
    case unknown
}

enum ResolvedCardAsset: Sendable, Equatable {
    case image(ResolvedImageAsset)
    case placeholder(PlaceholderKind)
    case none
}

// MARK: - Render-Ready Media (decoded, bounded window)

enum RenderReadyMedia: @unchecked Sendable {
    case image(RenderImage)
    case placeholder(PlaceholderKind)
    case none
}

struct RenderImage: @unchecked Sendable {
    let cacheKey: String
    let image: UIImage
}

// MARK: - Layout

enum PreparedCardLayout: Sendable, Equatable {
    case hero
    case thumbnail
    case textOnly
}

// MARK: - Preparation State (internal, never observed by UI)

enum CardPreparationState: Sendable {
    case queued
    case resolvingDirectImage
    case resolvingArticle
    case writingCache
    case resolved(ResolvedCardAsset)
    case decoding
    case renderReady(PreparedFeedCard)
}

// MARK: - Prepared Feed Card (published to UI)

struct PreparedFeedCard: Identifiable, @unchecked Sendable {
    var id: String { item.id }

    /// The original feed content. `isRead` and `isBookmarked` are mutable
    /// independently of `media` — no presentation rebuild on bookmark toggle.
    var item: FeedItem

    /// Terminal media — `.image`, `.placeholder(kind)`, or `.none`.
    let media: RenderReadyMedia

    /// Deterministic layout for this card.
    let layout: PreparedCardLayout

    /// The epoch of the context that produced this card. Used to discard
    /// stale promotions.
    let presentationEpoch: UInt64
}
```

- [ ] **Step 2: Update FeedCardPresentation.swift — keep as compatibility alias, deprecate isRead/isBookmarked**

Keep `FeedCardPresentation`, `ResolvedCardMedia`, `FeedCardLayout` as-is for now (they're used by existing code). Add a comment at the top:

```swift
// MARK: - Deprecation Notice
// FeedCardPresentation, ResolvedCardMedia, and FeedCardLayout are being
// replaced by PreparedFeedCard, RenderReadyMedia, and PreparedCardLayout
// respectively. During migration, both coexist. After Phase 9, this file
// will be removed.
```

Also add a convenience initializer on `FeedCardPresentation` that accepts `PreparedFeedCard`:

```swift
extension FeedCardPresentation {
    init(from prepared: PreparedFeedCard, isRead: Bool, isBookmarked: Bool) {
        let legacyMedia: ResolvedCardMedia
        switch prepared.media {
        case .image(let ri):
            legacyMedia = .image(ri.image)
        case .placeholder:
            legacyMedia = .placeholder
        case .none:
            legacyMedia = .none
        }
        self.init(
            item: prepared.item,
            media: legacyMedia,
            layout: FeedCardLayout(from: prepared.layout),
            isRead: isRead,
            isBookmarked: isBookmarked
        )
    }
}

extension FeedCardLayout {
    init(from layout: PreparedCardLayout) {
        switch layout {
        case .hero: self = .hero
        case .thumbnail: self = .thumbnail
        case .textOnly: self = .textOnly
        }
    }
}
```

- [ ] **Step 3: Update CardPresentationTests — add tests for new types**

Add tests to `CardPresentationTests.swift`:

```swift
// MARK: - PlaceholderKind

func test_placeholderKind_hasFourCases() {
    let cases: [PlaceholderKind] = [.article, .video, .podcast, .forum]
    XCTAssertEqual(cases.count, 4)
}

// MARK: - ResolvedCardAsset (no UIImage in deep runway)

func test_resolvedCardAsset_image_usesResolvedImageAsset_notUIImage() {
    let asset = ResolvedImageAsset(
        cacheKey: "abc", pixelWidth: 800, pixelHeight: 600,
        byteCount: 50000, source: .directImageURL
    )
    let resolved = ResolvedCardAsset.image(asset)
    if case .image(let a) = resolved {
        XCTAssertEqual(a.cacheKey, "abc")
        XCTAssertEqual(a.pixelWidth, 800)
    } else {
        XCTFail("Expected .image")
    }
}

// MARK: - PreparedFeedCard does not duplicate read/bookmark

func test_preparedFeedCard_noIsReadProperty() {
    // PreparedFeedCard must NOT have isRead or isBookmarked — those are
    // mutated directly on card.item without rebuilding the presentation.
    let item = makeItem(id: "x")
    let card = PreparedFeedCard(
        item: item,
        media: .none,
        layout: .textOnly,
        presentationEpoch: 1
    )
    // Verify we can mutate item state without touching card:
    card.item.isRead = true
    XCTAssertTrue(card.item.isRead)
    // card.media is a let — unchanged
}
```

- [ ] **Step 4: Build and run tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Test.*passed|Test.*failed|Executed"`

Expected: All existing + new tests pass.

- [ ] **Step 5: Commit**

```bash
git add feedmine/Models/PreparedFeedCard.swift feedmine/Models/FeedCardPresentation.swift feedmineTests/CardPresentationTests.swift
git commit -m "feat: add PreparedFeedCard and refined presentation models

- PreparedFeedCard with separated media (RenderReadyMedia) from interactive state
- PlaceholderKind with explicit article/video/podcast/forum cases
- ResolvedCardAsset for disk-level representation (no UIImage in deep runway)
- CardPreparationState for internal preparation tracking
- Backward-compatible FeedCardPresentation.init(from: PreparedFeedCard)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Phase 1 — RunwayPolicy Model

**Files:**
- Create: `feedmine/Services/RunwayPolicy.swift`
- Modify: (none)
- Test: (none — config value object)

**Interfaces:**
- Consumes: (none)
- Produces: `RunwayPolicy` (struct, Sendable)

- [ ] **Step 1: Write RunwayPolicy.swift**

```swift
import Foundation

/// Configurable buffer targets and deadlines for the feed preparation pipeline.
/// All values are initial proposals; adjust based on metrics.
struct RunwayPolicy: Sendable {
    // MARK: - Published feed
    var initialPublishedCount = 20
    var publishedAheadLow = 30
    var publishedAheadTarget = 50

    // MARK: - Render-ready runway (decoded images)
    var renderReadyLow = 60
    var renderReadyTarget = 120
    var renderReadyHigh = 180

    // MARK: - Resolved runway (disk-level, no UIImage)
    var resolvedLow = 200
    var resolvedTarget = 400
    var resolvedHigh = 600

    // MARK: - Editorial backlog
    var editorialLow = 500
    var editorialTarget = 1_000
    var editorialHigh = 1_500

    // MARK: - Per-item deadlines
    /// Total budget for items in the initial viewport (positions 0..<20).
    var initialViewportDeadline: Duration = .seconds(6)

    /// Total budget for items near the runway edge.
    var nearRunwayDeadline: Duration = .seconds(15)

    /// Total budget for items deep in the runway.
    var deepRunwayDeadline: Duration = .seconds(30)

    // MARK: - Adaptive targets for constrained devices

    func constrained() -> RunwayPolicy {
        var p = self
        p.renderReadyLow = 40
        p.renderReadyTarget = 70
        p.resolvedLow = 150
        p.resolvedTarget = 250
        p.editorialLow = 400
        p.editorialTarget = 700
        return p
    }

    func comfortable() -> RunwayPolicy {
        var p = self
        p.renderReadyLow = 120
        p.renderReadyTarget = 180
        p.resolvedLow = 500
        p.resolvedTarget = 700
        p.editorialLow = 1_200
        p.editorialTarget = 1_800
        return p
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform:iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/RunwayPolicy.swift
git commit -m "feat: add RunwayPolicy with configurable buffer targets and deadlines

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Phase 2 — ImageResolutionRecord and Database Migration

**Files:**
- Create: `feedmine/Models/ImageResolutionRecord.swift`
- Modify: Database migration file (find existing migrations pattern)
- Test: `feedmineTests/MediaAssetStoreTests.swift` (create file with initial migration test)

**Interfaces:**
- Consumes: GRDB `DatabaseQueue` (existing), `FeedItem.id` (existing)
- Produces: `ImageResolutionRecord` (GRDB FetchableRecord & PersistableRecord), `image_resolution` table, `image_resolution_state_retry` index

- [ ] **Step 1: Find existing migrations pattern**

Read the file where GRDB migrations are registered (likely `FeedStore.swift` or a dedicated migrations file). Note the pattern for `registerMigration` calls.

- [ ] **Step 2: Write ImageResolutionRecord.swift**

```swift
import Foundation
import GRDB

/// Persisted image resolution state for a feed item. Separates transient
/// failures (retry-able) from confirmed absence (no image exists).
struct ImageResolutionRecord: Codable, FetchableRecord, PersistableRecord {
    var itemID: String
    var candidateFingerprint: String
    var state: String  // "unknown", "resolved", "no_image_confirmed", "transient_failure", "permanent_failure"
    var cacheKey: String?
    var resolvedURL: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteCount: Int?
    var attemptCount: Int
    var lastAttemptAt: Int64?
    var nextRetryAt: Int64?
    var failureClass: String?
    var failureCode: Int?
    var updatedAt: Int64

    enum Columns {
        static let itemID = Column("item_id")
        static let candidateFingerprint = Column("candidate_fingerprint")
        static let state = Column("state")
        static let cacheKey = Column("cache_key")
        static let resolvedURL = Column("resolved_url")
        static let pixelWidth = Column("pixel_width")
        static let pixelHeight = Column("pixel_height")
        static let byteCount = Column("byte_count")
        static let attemptCount = Column("attempt_count")
        static let lastAttemptAt = Column("last_attempt_at")
        static let nextRetryAt = Column("next_retry_at")
        static let failureClass = Column("failure_class")
        static let failureCode = Column("failure_code")
        static let updatedAt = Column("updated_at")
    }
}

// MARK: - Resolution State

enum ImageResolutionState: String, Sendable {
    case unknown
    case resolved
    case noImageConfirmed = "no_image_confirmed"
    case transientFailure = "transient_failure"
    case permanentFailure = "permanent_failure"
}

// MARK: - Candidate Fingerprint

enum ImageCandidateFingerprint {
    static func compute(
        feedImageURL: String?,
        articleURL: String?,
        youTubeThumbnailURL: String?,
        policyVersion: Int = 1
    ) -> String {
        let components = [
            feedImageURL ?? "",
            articleURL ?? "",
            youTubeThumbnailURL ?? "",
            String(policyVersion)
        ]
        return components.joined(separator: "|")
    }
}
```

- [ ] **Step 3: Add GRDB migration**

In the migration registration block (typically in `FeedStore`'s initializer), add after the last existing migration:

```swift
// Migration N+1: image_resolution table
try db.create(table: "image_resolution") { t in
    t.column("item_id", .text)
        .primaryKey()
        .references("feed_item", column: "id", onDelete: .cascade)
    t.column("candidate_fingerprint", .text).notNull()
    t.column("state", .text).notNull().defaults(to: "unknown")
    t.column("cache_key", .text)
    t.column("resolved_url", .text)
    t.column("pixel_width", .integer)
    t.column("pixel_height", .integer)
    t.column("byte_count", .integer)
    t.column("attempt_count", .integer).notNull().defaults(to: 0)
    t.column("last_attempt_at", .integer)
    t.column("next_retry_at", .integer)
    t.column("failure_class", .text)
    t.column("failure_code", .integer)
    t.column("updated_at", .integer).notNull()
}
try db.create(index: "image_resolution_state_retry",
              on: "image_resolution", columns: ["state", "next_retry_at"])

// Migration N+2: Clean up empty image_url sentinels
try db.execute(sql: """
    UPDATE feed_item SET image_url = NULL WHERE image_url = ''
    """)
```

- [ ] **Step 4: Write initial MediaAssetStoreTests.swift**

```swift
import XCTest
import GRDB
@testable import feedmine

final class MediaAssetStoreTests: XCTestCase {

    var db: DatabaseQueue!

    override func setUp() async throws {
        db = try DatabaseQueue()
        // Run migrations up to and including image_resolution
        // (This will need to match the actual migration setup)
    }

    override func tearDown() async throws {
        db = nil
    }

    // MARK: - image_resolution table exists

    func test_imageResolutionTable_exists() async throws {
        let count = try await db.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM image_resolution") ?? 0
        }
        XCTAssertEqual(count, 0, "Table should exist and be empty")
    }

    // MARK: - Empty image_url sentinel cleanup

    func test_emptyImageURL_migratedToNull() async throws {
        // Insert a feed_item with image_url = '' (requires feed_item table to exist)
        // Then verify it became NULL after migration
        // This is an integration test — skip if feed_item table migration isn't available
        // in the test's migration set
    }
}
```

- [ ] **Step 5: Build and run tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform:iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Test.*passed|Test.*failed|Executed"`

Expected: DB migration tests pass, existing tests unaffected.

- [ ] **Step 6: Commit**

```bash
git add feedmine/Models/ImageResolutionRecord.swift feedmine/Services/FeedStore.swift feedmineTests/MediaAssetStoreTests.swift
git commit -m "feat: add image_resolution table with persistence for resolution state

- ImageResolutionRecord GRDB model
- ImageResolutionState: unknown/resolved/no_image_confirmed/transient_failure/permanent_failure
- Candidate fingerprint invalidation support
- Cleanup migration for empty image_url sentinels ('' -> NULL)
- Index on (state, next_retry_at) for efficient retry queries

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Phase 2 — DiskImageCache Actor

**Files:**
- Create: `feedmine/Services/DiskImageCache.swift`
- Modify: (none)
- Test: `feedmineTests/MediaAssetStoreTests.swift` (add disk cache tests)

**Interfaces:**
- Consumes: FileManager (Foundation)
- Produces: `DiskImageCache` actor — `data(for:)`, `store(_:key:)`, `evictIfNeeded()`, `removeAll()`

- [ ] **Step 1: Write DiskImageCache.swift**

```swift
import Foundation
import UIKit

/// Disk-level image cache. Runs off the MainActor — all I/O is async.
/// Uses the same FNV-1a cache key scheme as the existing ImageCache.
actor DiskImageCache {
    private let cacheDir: URL
    private let maxBytes: Int = 100 * 1024 * 1024  // 100 MB

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("FeedmineImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func data(for key: String) async -> Data? {
        let url = cacheDir.appendingPathComponent(key)
        return try? Data(contentsOf: url)
    }

    func store(_ data: Data, key: String) async throws {
        let url = cacheDir.appendingPathComponent(key)
        try data.write(to: url, options: .atomic)
    }

    func remove(key: String) async {
        let url = cacheDir.appendingPathComponent(key)
        try? FileManager.default.removeItem(at: url)
    }

    func evictIfNeeded() async {
        // Simple oldest-first eviction — same strategy as existing ImageCache
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return }

        var total: Int = 0
        var entries: [(url: URL, date: Date, size: Int)] = []
        for url in contents {
            guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = attrs.contentModificationDate,
                  let size = attrs.fileSize else { continue }
            total += size
            entries.append((url, date, size))
        }

        guard total > maxBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > maxBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    func removeAll() async {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
}
```

- [ ] **Step 2: Add disk cache tests to MediaAssetStoreTests**

```swift
func test_diskCache_storeAndRetrieve() async throws {
    let cache = DiskImageCache()
    let key = "test-key-123"
    let data = Data("hello".utf8)

    try await cache.store(data, key: key)
    let retrieved = await cache.data(for: key)

    XCTAssertEqual(retrieved, data)
}

func test_diskCache_nonexistentKey_returnsNil() async throws {
    let cache = DiskImageCache()
    let data = await cache.data(for: "nonexistent")
    XCTAssertNil(data)
}

func test_diskCache_remove() async throws {
    let cache = DiskImageCache()
    let key = "to-remove"
    try await cache.store(Data("bye".utf8), key: key)
    await cache.remove(key: key)
    let retrieved = await cache.data(for: key)
    XCTAssertNil(retrieved)
}
```

- [ ] **Step 3: Build and run tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform:iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Test.*passed|Test.*failed|Executed"`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/DiskImageCache.swift feedmineTests/MediaAssetStoreTests.swift
git commit -m "feat: extract DiskImageCache actor from ImageCache

- Non-MainActor disk I/O for cached images
- Same FNV-1a key scheme and 100 MB cap as existing ImageCache
- Oldest-first eviction on overflow

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Phase 2 — MemoryImageCache and MediaAssetStore

**Files:**
- Create: `feedmine/Services/MemoryImageCache.swift`, `feedmine/Services/MediaAssetStore.swift`
- Modify: (none)
- Test: `feedmineTests/MediaAssetStoreTests.swift` (add single-flight and cache tests)

**Interfaces:**
- Consumes: `DiskImageCache` (Task 6), `ImageCache.downsample(data:to:)` (existing static)
- Produces: `MemoryImageCache` class (`@unchecked Sendable`), `MediaAssetStore` actor with single-flight `resolve(request:)`

- [ ] **Step 1: Write MemoryImageCache.swift**

```swift
import UIKit

/// In-memory image cache using NSCache. Thread-safe via @unchecked Sendable
/// (NSCache is internally thread-safe). Used by MediaAssetStore — never
/// consulted directly by views to decide whether to show an image.
final class MemoryImageCache: @unchecked Sendable {
    private let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 200
        c.totalCostLimit = 200 * 1024 * 1024  // 200 MB
        return c
    }()

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, for key: String, cost: Int? = nil) {
        if let cost {
            cache.setObject(image, forKey: key as NSString, cost: cost)
        } else {
            cache.setObject(image, forKey: key as NSString)
        }
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
```

- [ ] **Step 2: Write MediaAssetStore.swift**

```swift
import Foundation
import UIKit

/// Central actor for image asset resolution. Coordinates:
/// - Memory cache lookup (MemoryImageCache)
/// - Disk cache lookup (DiskImageCache)
/// - Single-flight deduplication (shared Tasks)
/// - Network download + validation
/// - Downsample + disk write
/// - image_resolution persistence
actor MediaAssetStore {
    private let memoryCache = MemoryImageCache()
    private let diskCache = DiskImageCache()
    private let db: DatabaseQueue

    /// In-flight resolution tasks keyed by `ImageAssetKey`.
    /// All consumers of the same key await the same Task — no polling.
    private var inFlight: [ImageAssetKey: Task<ResolvedImageAsset?, Never>] = [:]

    /// Session for image downloads.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config)
    }()

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Public API

    /// Resolve an image asset with single-flight deduplication.
    /// Returns nil if the image cannot be resolved (transient or permanent).
    func resolve(request: ImageResolutionRequest) async -> ResolvedImageAsset? {
        let key = request.key

        // 1. Memory cache hit
        if let memKey = request.cacheKey,
           memoryCache.image(for: memKey) != nil {
            // Already in memory — build asset metadata from disk record
            return await loadAssetMetadata(cacheKey: memKey)
        }

        // 2. Single-flight dedup
        if let task = inFlight[key] {
            return await task.value
        }

        // 3. Create shared task
        let task = Task<ResolvedImageAsset?, Never> { [weak self] in
            await self?.performResolution(request)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    /// Cancel all in-flight work (context change).
    func cancelAll() {
        inFlight.removeAll()
    }

    /// Read raw image data from disk cache (exposed for coordinator decode step).
    func diskData(for key: String) async -> Data? {
        await diskCache.data(for: key)
    }

    /// Clear memory cache (memory warning).
    func clearMemoryCache() {
        memoryCache.removeAll()
    }

    // MARK: - Private

    private func performResolution(_ request: ImageResolutionRequest) async -> ResolvedImageAsset? {
        // 1. Check disk cache
        if let cacheKey = request.cacheKey,
           let data = await diskCache.data(for: cacheKey),
           let image = ImageCache.downsample(data: data, to: ImageCache.downsampleMaxDimension) {
            memoryCache.setImage(image, for: cacheKey)
            return assetMetadata(from: image, cacheKey: cacheKey, data: data, source: request.source)
        }

        // 2. Download (handles URL candidates internally)
        guard let url = request.url else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            guard isValidImageData(data) else { return nil }

            let cacheKey = request.cacheKey ?? ImageCacheKey.forURL(url)
            let image = ImageCache.downsample(data: data, to: ImageCache.downsampleMaxDimension)

            // Store to disk
            try? await diskCache.store(data, key: cacheKey)
            await diskCache.evictIfNeeded()

            // Cache in memory
            if let image {
                let cost = Int(image.size.width * image.size.height * 4)
                memoryCache.setImage(image, for: cacheKey, cost: cost)
            }

            // Persist resolution state
            await persistResolution(itemID: request.itemID, cacheKey: cacheKey,
                                    data: data, url: url, source: request.source)

            if let image {
                return assetMetadata(from: image, cacheKey: cacheKey, data: data, source: request.source)
            }
            return nil
        } catch {
            await persistFailure(itemID: request.itemID, error: error, url: url)
            return nil
        }
    }

    private func assetMetadata(from image: UIImage, cacheKey: String, data: Data, source: ImageResolutionSource) -> ResolvedImageAsset {
        ResolvedImageAsset(
            cacheKey: cacheKey,
            pixelWidth: Int(image.size.width * image.scale),
            pixelHeight: Int(image.size.height * image.scale),
            byteCount: data.count,
            source: source
        )
    }

    private func loadAssetMetadata(cacheKey: String) async -> ResolvedImageAsset? {
        // Query image_resolution table for metadata
        do {
            return try await db.read { db in
                try ImageResolutionRecord
                    .filter(ImageResolutionRecord.Columns.cacheKey == cacheKey)
                    .filter(ImageResolutionRecord.Columns.state == ImageResolutionState.resolved.rawValue)
                    .fetchOne(db)
                    .map { record in
                        ResolvedImageAsset(
                            cacheKey: record.cacheKey ?? cacheKey,
                            pixelWidth: record.pixelWidth ?? 0,
                            pixelHeight: record.pixelHeight ?? 0,
                            byteCount: record.byteCount ?? 0,
                            source: ImageResolutionSource(rawValue: record.failureClass ?? "") ?? .unknown
                        )
                    }
            }
        } catch {
            return nil
        }
    }

    private func persistResolution(itemID: String, cacheKey: String, data: Data, url: URL, source: ImageResolutionSource) async {
        let fingerprint = ImageCandidateFingerprint.compute(
            feedImageURL: url.absoluteString,
            articleURL: nil,
            youTubeThumbnailURL: nil
        )
        let now = Int64(Date().timeIntervalSince1970)
        let record = ImageResolutionRecord(
            itemID: itemID, candidateFingerprint: fingerprint,
            state: ImageResolutionState.resolved.rawValue,
            cacheKey: cacheKey, resolvedURL: url.absoluteString,
            pixelWidth: 0, pixelHeight: 0, byteCount: data.count,
            attemptCount: 1, lastAttemptAt: now, nextRetryAt: nil,
            failureClass: source.rawValue, failureCode: nil,
            updatedAt: now
        )
        do {
            try await db.write { db in
                try record.save(db)
            }
        } catch {
            // Upsert on conflict
        }
    }

    private func persistFailure(itemID: String, error: Error, url: URL) async {
        let nsError = error as NSError
        let isTransient = nsError.domain == NSURLErrorDomain && [
            NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
            NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost
        ].contains(nsError.code)

        let now = Int64(Date().timeIntervalSince1970)
        let fingerprint = ImageCandidateFingerprint.compute(
            feedImageURL: url.absoluteString,
            articleURL: nil, youTubeThumbnailURL: nil
        )
        let state = isTransient
            ? ImageResolutionState.transientFailure.rawValue
            : ImageResolutionState.permanentFailure.rawValue

        let record = ImageResolutionRecord(
            itemID: itemID, candidateFingerprint: fingerprint,
            state: state, cacheKey: nil, resolvedURL: nil,
            pixelWidth: nil, pixelHeight: nil, byteCount: nil,
            attemptCount: 1, lastAttemptAt: now,
            nextRetryAt: isTransient ? now + 30 : nil,
            failureClass: nsError.domain, failureCode: nsError.code,
            updatedAt: now
        )
        do {
            try await db.write { db in
                try record.save(db)
            }
        } catch {
            // Upsert on conflict
        }
    }

    private nonisolated func isValidImageData(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        // JPEG: FF D8 FF
        if data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF { return true }
        // PNG: 89 50 4E 47
        if data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 { return true }
        // GIF: 47 49 46 38
        if data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x38 { return true }
        // WebP/RIFF: 52 49 46 46
        if data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 { return true }
        return false
    }
}

// MARK: - Supporting Types

struct ImageResolutionRequest: Sendable {
    let itemID: String
    let url: URL?
    let cacheKey: String?
    let source: ImageResolutionSource
    var key: ImageAssetKey { ImageAssetKey(url: url, cacheKey: cacheKey) }
}

struct ImageAssetKey: Hashable, Sendable {
    let url: URL?
    let cacheKey: String?
}

enum ImageCacheKey {
    // Reuse existing FNV-1a logic or a simpler stable hash
    static func forURL(_ url: URL) -> String {
        var hasher = Hasher()
        url.absoluteString.hash(into: &hasher)
        return String(hasher.finalize(), radix: 36)
    }
}
```

- [ ] **Step 3: Add single-flight test to MediaAssetStoreTests**

```swift
func test_singleFlight_sameURL_oneDownload() async throws {
    let store = MediaAssetStore(db: db)
    // This test requires URLProtocol stubbing to count requests.
    // Create a mock URLProtocol that tracks request count.
    // For now, verify that two concurrent resolve() calls for the
    // same key return the same result without crashing.
    let req = ImageResolutionRequest(
        itemID: "test-1",
        url: URL(string: "https://example.com/img.jpg"),
        cacheKey: "test-key",
        source: .directImageURL
    )
    async let r1 = store.resolve(request: req)
    async let r2 = store.resolve(request: req)
    let (a, b) = await (r1, r2)
    // Both nil (no real network), but no crash = single-flight working
    XCTAssertEqual(a, b)
}
```

- [ ] **Step 4: Build and run tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform:iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Test.*passed|Test.*failed|Executed"`

- [ ] **Step 5: Commit**

```bash
git add feedmine/Services/MemoryImageCache.swift feedmine/Services/MediaAssetStore.swift feedmineTests/MediaAssetStoreTests.swift
git commit -m "feat: add MemoryImageCache and MediaAssetStore with single-flight dedup

- MemoryImageCache: NSCache wrapper, @unchecked Sendable
- MediaAssetStore: actor coordinating memory/disk/network with shared Tasks
- Single-flight: concurrent requests for same key await one shared download
- Failure classification: transient vs permanent persisted to image_resolution
- No polling — uses Task reuse instead

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Phase 2 — AsyncLimiter

**Files:**
- Create: `feedmine/Services/AsyncLimiter.swift`
- Modify: (none)
- Test: (tests in next phase with coordinator)

**Interfaces:**
- Consumes: (none — standalone)
- Produces: `AsyncLimiter` actor — per-category concurrency slots

- [ ] **Step 1: Write AsyncLimiter.swift**

```swift
import Foundation

/// Bounded concurrency limiter with per-category slot allocation.
/// Categories (direct image, article HTML, disk decode, retry) get
/// independent limits so one slow category doesn't starve others.
actor AsyncLimiter {
    private var slots: [String: AsyncSemaphore]

    init(categories: [(String, Int)]) {
        self.slots = Dictionary(uniqueKeysWithValues: categories.map {
            ($0.0, AsyncSemaphore(limit: $0.1))
        })
    }

    func withSlot<T: Sendable>(
        category: String,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        let semaphore = slots[category] ?? AsyncSemaphore(limit: 1)
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }
        return try await operation()
    }

    func updateLimit(category: String, limit: Int) {
        slots[category] = AsyncSemaphore(limit: limit)
    }
}

private actor AsyncSemaphore {
    private let limit: Int
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func wait() async {
        if count < limit { count += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count -= 1
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform:iOS Simulator,name=iPhone 16 Pro' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/AsyncLimiter.swift
git commit -m "feat: add AsyncLimiter with per-category concurrency slots

- Separate limits for direct images, article HTML, disk decode, retries
- Prevents one slow category from starving others

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Phase 3 — CardPreparationCoordinator (Core)

**Files:**
- Create: `feedmine/Services/CardPreparationCoordinator.swift`
- Modify: (none yet — ReadyCardQueue stays active)
- Test: `feedmineTests/CardPreparationCoordinatorTests.swift`

**Interfaces:**
- Consumes: `MediaAssetStore` (Task 7), `RunwayPolicy` (Task 4), `AsyncLimiter` (Task 8), `FeedPresentationContext` (Task 2)
- Produces: `CardPreparationCoordinator` actor — `replaceEditorialSequence`, `appendEditorialSequence`, `takeRenderReadyPrefix`, `invalidate`

- [ ] **Step 1: Write CardPreparationCoordinator.swift**

```swift
import Foundation
import UIKit

/// Actor that manages the editorial sequence, concurrent preparation,
/// and contiguous-prefix promotion. Replaces ReadyCardQueue.
///
/// Key invariant: cards finish preparation out of order, but are only
/// promoted in contiguous editorial order. A slow item at position 3
/// blocks promotion of items 4..N until it reaches a terminal state.
actor CardPreparationCoordinator {

    // MARK: - Internal state

    private var orderedItems: [FeedItem] = []
    private var stateByID: [String: CardPreparationState] = [:]
    private var resolvedByID: [String: ResolvedCardAsset] = [:]
    private var renderReadyByID: [String: PreparedFeedCard] = [:]

    /// Index of the next item that hasn't started preparation.
    private var nextPrepareIndex: Int = 0

    /// Index of the first item whose render-ready card hasn't been taken.
    private var nextPublishIndex: Int = 0

    /// The context this coordinator is currently serving.
    private var activeContext: FeedPresentationContext?

    // MARK: - Dependencies

    private let mediaStore: MediaAssetStore
    private let policy: RunwayPolicy
    private let limiter: AsyncLimiter
    private let db: DatabaseQueue

    // MARK: - Initialization

    init(mediaStore: MediaAssetStore, policy: RunwayPolicy, db: DatabaseQueue) {
        self.mediaStore = mediaStore
        self.policy = policy
        self.db = db
        self.limiter = AsyncLimiter(categories: [
            ("direct_image", 8),
            ("article_html", 3),
            ("disk_decode", 4),
            ("background_retry", 2),
        ])
    }

    // MARK: - Public API

    /// Replace the entire editorial sequence. Cancels all in-flight work
    /// for any previous context.
    func replaceEditorialSequence(
        _ items: [FeedItem],
        context: FeedPresentationContext
    ) async {
        await mediaStore.cancelAll()
        orderedItems = items
        stateByID.removeAll()
        resolvedByID.removeAll()
        renderReadyByID.removeAll()
        nextPrepareIndex = 0
        nextPublishIndex = 0
        activeContext = context
    }

    /// Append items to the end of the editorial sequence.
    func appendEditorialSequence(
        _ items: [FeedItem],
        context: FeedPresentationContext
    ) async {
        guard context == activeContext else { return }
        orderedItems.append(contentsOf: items)
    }

    /// Fill the runway up to the specified target count.
    func fillRunway(targetRenderReady: Int, context: FeedPresentationContext) async {
        guard context == activeContext else { return }
        let currentReady = renderReadyByID.count
        guard currentReady < targetRenderReady else { return }

        // Start preparation for items up to targetRenderReady * 2 (buffer)
        let prepareUpTo = min(orderedItems.count, nextPublishIndex + targetRenderReady * 2)
        while nextPrepareIndex < prepareUpTo {
            let idx = nextPrepareIndex
            let item = orderedItems[idx]
            nextPrepareIndex += 1
            prepareItem(at: idx, item: item, context: context)
        }
    }

    /// Take the longest contiguous prefix of render-ready cards starting
    /// from `nextPublishIndex`. Returns cards in editorial order.
    func takeRenderReadyPrefix(
        maximumCount: Int,
        context: FeedPresentationContext
    ) -> [PreparedFeedCard] {
        guard context == activeContext else { return [] }
        var ready: [PreparedFeedCard] = []
        var idx = nextPublishIndex

        while ready.count < maximumCount, idx < orderedItems.count {
            let item = orderedItems[idx]
            if let card = renderReadyByID[item.id] {
                ready.append(card)
                idx += 1
            } else {
                break  // Not contiguous — stop here
            }
        }

        nextPublishIndex = idx
        return ready
    }

    /// Discard all state for a context that's no longer active.
    func invalidate(context: FeedPresentationContext) {
        guard context != activeContext else { return }
        // State from old contexts is discarded; cache stays shared
        stateByID.removeAll()
        resolvedByID.removeAll()
        renderReadyByID.removeAll()
    }

    func handleMemoryPressure() {
        // Discard render-ready cards beyond the publish window
        let keepUpTo = nextPublishIndex + policy.publishedAheadTarget
        let keysToRemove = renderReadyByID.keys.filter { id in
            guard let idx = orderedItems.firstIndex(where: { $0.id == id }) else { return true }
            return idx >= keepUpTo
        }
        for key in keysToRemove {
            renderReadyByID.removeValue(forKey: key)
        }
        Task { await mediaStore.clearMemoryCache() }
    }

    // MARK: - Private

    private func prepareItem(at index: Int, item: FeedItem, context: FeedPresentationContext) {
        stateByID[item.id] = .queued

        let deadline = deadlineForIndex(index)
        let urgencyBand = urgencyBandForIndex(index)

        Task { [weak self] in
            guard let self else { return }

            // 1. Resolve to disk-level asset
            stateByID[item.id] = .resolvingDirectImage
            let asset = await self.resolveImageAsset(for: item, context: context, deadline: deadline)

            guard context == self.activeContext else { return }

            let resolved: ResolvedCardAsset
            if let asset {
                resolved = .image(asset)
                self.resolvedByID[item.id] = resolved
                stateByID[item.id] = .resolved(resolved)
            } else if item.hasPotentialImage {
                // Has candidates but failed — placeholder with kind
                let kind = self.placeholderKind(for: item)
                resolved = .placeholder(kind)
                self.resolvedByID[item.id] = resolved
                stateByID[item.id] = .resolved(resolved)
            } else {
                resolved = .none
                self.resolvedByID[item.id] = resolved
                stateByID[item.id] = .resolved(resolved)
            }

            // 2. Decode to render-ready
            stateByID[item.id] = .decoding
            let renderReady = await self.decodeToRenderReady(
                item: item, asset: resolved, context: context
            )

            guard context == self.activeContext else { return }
            self.renderReadyByID[item.id] = renderReady
            stateByID[item.id] = .renderReady(renderReady)
        }
    }

    private func resolveImageAsset(
        for item: FeedItem,
        context: FeedPresentationContext,
        deadline: Date
    ) async -> ResolvedImageAsset? {
        guard let imageURL = item.bestImageURL.flatMap(URL.init(string:)) else {
            return nil
        }

        let request = ImageResolutionRequest(
            itemID: item.id,
            url: imageURL,
            cacheKey: nil,  // Will be computed by MediaAssetStore
            source: .directImageURL
        )

        // Race: resolution vs deadline
        return await withTaskCancellation(deadline: deadline) {
            await self.limiter.withSlot(category: "direct_image") {
                await self.mediaStore.resolve(request: request)
            }
        }
    }

    private func decodeToRenderReady(
        item: FeedItem,
        asset: ResolvedCardAsset,
        context: FeedPresentationContext
    ) async -> PreparedFeedCard {
        let media: RenderReadyMedia
        let layout: PreparedCardLayout

        switch asset {
        case .image(let resolvedAsset):
            // Decode from disk via MediaAssetStore (which wraps DiskImageCache)
            if let data = await mediaStore.diskData(for: resolvedAsset.cacheKey),
               let image = UIImage(data: data) {
                let renderImage = RenderImage(cacheKey: resolvedAsset.cacheKey, image: image)
                media = .image(renderImage)
                layout = .hero  // Default; view adapts by size class
            } else {
                media = .placeholder(placeholderKind(for: item))
                layout = .textOnly
            }

        case .placeholder(let kind):
            media = .placeholder(kind)
            layout = item.hasPotentialImage ? .hero : .textOnly

        case .none:
            media = .none
            layout = .textOnly
        }

        return PreparedFeedCard(
            item: item,
            media: media,
            layout: layout,
            presentationEpoch: context.epoch
        )
    }

    private func deadlineForIndex(_ index: Int) -> Date {
        let duration: Duration
        if index < policy.initialPublishedCount {
            duration = policy.initialViewportDeadline
        } else if index < policy.renderReadyTarget {
            duration = policy.nearRunwayDeadline
        } else {
            duration = policy.deepRunwayDeadline
        }
        return Date().addingTimeInterval(TimeInterval(duration.components.seconds))
    }

    private func urgencyBandForIndex(_ index: Int) -> TaskPriority {
        if index < policy.initialPublishedCount { return .userInitiated }
        if index < policy.renderReadyTarget { return .utility }
        if index < policy.resolvedTarget { return .utility }
        return .background
    }

    private func placeholderKind(for item: FeedItem) -> PlaceholderKind {
        if item.isYouTube { return .video }
        if item.isPodcast { return .podcast }
        if item.isForum { return .forum }
        return .article
    }
}

// MARK: - Deadline Helper

private func withTaskCancellation<T>(
    deadline: Date,
    operation: @escaping () async -> T?
) async -> T? {
    await withCheckedContinuation { continuation in
        Task {
            let result = await operation()
            continuation.resume(returning: result)
        }
        Task {
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            continuation.resume(returning: nil)
        }
    }
}
```

- [ ] **Step 2: Write CardPreparationCoordinatorTests.swift**

```swift
import XCTest
import GRDB
@testable import feedmine

final class CardPreparationCoordinatorTests: XCTestCase {

    var db: DatabaseQueue!
    var coordinator: CardPreparationCoordinator!
    var context: FeedPresentationContext!

    override func setUp() async throws {
        db = try DatabaseQueue()
        let mediaStore = MediaAssetStore(db: db)
        let policy = RunwayPolicy()
        coordinator = CardPreparationCoordinator(mediaStore: mediaStore, policy: policy, db: db)
        context = FeedPresentationContext(
            epoch: 1, mode: .main, filterGeneration: 0, presetGeneration: 0
        )
    }

    // MARK: - Contiguous prefix: out-of-order completion

    func test_outOfOrderCompletion_contiguousPrefix() async throws {
        let items = makeItems(5)
        await coordinator.replaceEditorialSequence(items, context: context)
        await coordinator.fillRunway(targetRenderReady: 5, context: context)

        // Allow time for async preparation
        try? await Task.sleep(for: .seconds(2))

        let prefix = await coordinator.takeRenderReadyPrefix(
            maximumCount: 5, context: context
        )
        // Items must appear in editorial order (0, 1, 2, ...)
        for (i, card) in prefix.enumerated() {
            if i > 0 {
                let prevIdx = items.firstIndex(where: { $0.id == prefix[i-1].id })!
                let currIdx = items.firstIndex(where: { $0.id == card.id })!
                XCTAssertLessThan(prevIdx, currIdx, "Items must maintain editorial order")
            }
        }
    }

    // MARK: - Context invalidation

    func test_contextChange_preventsPublication() async throws {
        let items = makeItems(5)
        await coordinator.replaceEditorialSequence(items, context: context)

        // Change context before preparation completes
        let newContext = FeedPresentationContext(
            epoch: 2, mode: .main, filterGeneration: 1, presetGeneration: 0
        )
        await coordinator.replaceEditorialSequence([], context: newContext)

        let prefix = await coordinator.takeRenderReadyPrefix(
            maximumCount: 5, context: context
        )
        XCTAssertTrue(prefix.isEmpty, "Old context must not produce cards")
    }

    // MARK: - Slow item doesn't block infinite wait

    func test_missingItem_doesNotBlockSubsequent() async throws {
        // Create items where item[1] has no image URL (will resolve to .none quickly)
        var items = makeItems(3)
        items[1] = FeedItem(
            id: "slow-1", sourceTitle: "S", sourceURL: "https://x.com",
            category: "News", title: "Slow", excerpt: "",
            url: "https://x.com/art", imageURL: nil,
            publishedAt: Date(), audioURL: nil, duration: nil,
            region: "imported", language: "en", updatedAt: nil,
            authors: nil, itemCategories: nil, rights: nil,
            attribution: nil, enclosures: nil, languageFromFeed: nil,
            alternateLinks: nil
        )
        await coordinator.replaceEditorialSequence(items, context: context)
        await coordinator.fillRunway(targetRenderReady: 3, context: context)

        try? await Task.sleep(for: .seconds(2))

        let cards = await coordinator.takeRenderReadyPrefix(
            maximumCount: 3, context: context
        )
        // All 3 should be ready (item 1 resolves to .none immediately)
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[0].item.id, items[0].id)
        XCTAssertEqual(cards[1].item.id, items[1].id)
        XCTAssertEqual(cards[2].item.id, items[2].id)
    }

    // MARK: - Helpers

    private func makeItems(_ count: Int) -> [FeedItem] {
        (0..<count).map { i in
            FeedItem(
                id: "item-\(i)",
                sourceTitle: "Source \(i)",
                sourceURL: "https://example.com/feed\(i)",
                category: "News",
                title: "Title \(i)",
                excerpt: "Excerpt \(i)",
                url: "https://example.com/article\(i)",
                imageURL: "https://example.com/img\(i).jpg",
                publishedAt: Date(),
                audioURL: nil, duration: nil,
                region: "imported", language: "en", updatedAt: nil,
                authors: nil, itemCategories: nil, rights: nil,
                attribution: nil, enclosures: nil, languageFromFeed: nil,
                alternateLinks: nil
            )
        }
    }
}
```

- [ ] **Step 3: Build and run tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform:iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Test.*passed|Test.*failed|Executed"`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/CardPreparationCoordinator.swift feedmineTests/CardPreparationCoordinatorTests.swift
git commit -m "feat: add CardPreparationCoordinator actor with contiguous prefix promotion

- Replaces ReadyCardQueue with ordered editorial sequence
- Concurrent preparation, contiguous-prefix-only promotion
- Per-item deadlines by distance (initial/near/deep runway)
- Context validation before publishing any result
- PlaceholderKind selection by content type (video/podcast/forum/article)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: Phase 3 — FeedStore Integration (Shadow Mode)

**Files:**
- Modify: `feedmine/Services/FeedStore.swift`
- Test: `feedmineTests/FeedStoreTests.swift` (add shadow mode test)

**Interfaces:**
- Consumes: `CardPreparationCoordinator` (Task 9), `FeedPresentationContext` (Task 2), `RunwayPolicy` (Task 4), `MediaAssetStore` (Task 7)
- Produces: Shadow mode — new pipeline runs in parallel, legacy pipeline still publishes

- [ ] **Step 1: Add coordinator properties to FeedStore**

In `FeedStore.swift`, after the existing `cardQueue` and `imageResolutionQueue` declarations, add:

```swift
// MARK: - Prepared feed pipeline (shadow mode)

/// Feature flag controlling which pipeline publishes.
private let usePreparedPipeline = Settings.preparedFeedPipelineEnabled

/// Presentation epoch — increments on filter/preset/collection changes.
private var presentationEpoch: UInt64 = 0

/// Active presentation context for the current feed composition.
private var activePresentationContext: FeedPresentationContext = .init(
    epoch: 0, mode: .main, filterGeneration: 0, presetGeneration: 0
)

/// New pipeline components (initialized lazily).
private lazy var mediaAssetStore = MediaAssetStore(db: db)
private lazy var runwayPolicy = RunwayPolicy()
private lazy var preparationCoordinator = CardPreparationCoordinator(
    mediaStore: mediaAssetStore, policy: runwayPolicy, db: db
)
```

- [ ] **Step 2: Add shadow preparation call after existing `setVisibleItems`**

Find the method that publishes items (search for `setVisibleItems` or the append logic). After the existing `visibleItems = ...` and `visibleCards = ...` assignments, add a shadow-mode block:

```swift
// Shadow mode: run new pipeline in parallel for metrics comparison
if !usePreparedPipeline {
    Task { [weak self] in
        guard let self else { return }
        let items = self.visibleItems.prefix(40)
        let ctx = self.activePresentationContext
        await self.preparationCoordinator.replaceEditorialSequence(
            Array(items), context: ctx
        )
        await self.preparationCoordinator.fillRunway(
            targetRenderReady: 20, context: ctx
        )
        // Metrics: compare IDs/order with visibleItems
    }
}
```

- [ ] **Step 3: Add epoch increment on filter/preset change**

In every method that changes filters, presets, or feed mode, add:

```swift
presentationEpoch &+= 1
activePresentationContext = FeedPresentationContext(
    epoch: presentationEpoch,
    mode: currentMode,  // .main, .collection(id), etc.
    filterGeneration: filterGeneration,
    presetGeneration: presetGeneration
)
```

- [ ] **Step 4: Build and run tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform:iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Test.*passed|Test.*failed|Executed"`

Expected: All existing tests pass. New pipeline runs in shadow without affecting UI.

- [ ] **Step 5: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "feat: integrate CardPreparationCoordinator into FeedStore in shadow mode

- New pipeline runs in parallel when feature flag is OFF
- presentationEpoch increments on filter/preset/mode changes
- Legacy pipeline still publishes; new pipeline only collects metrics

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 11: Phase 4 — Warm Start with Prepared Cards

**Files:**
- Modify: `feedmine/Services/FeedStore.swift` (startup path)
- Test: `feedmineTests/FeedStoreTests.swift` (warm start test)

**Interfaces:**
- Consumes: `CardPreparationCoordinator.takeRenderReadyPrefix` (Task 9)
- Produces: Warm start publishes only `PreparedFeedCard` when feature flag is ON

- [ ] **Step 1: Gate the startup publishing on feature flag**

In the `reloadFromSQLite` or equivalent startup method, after the reservoir interleave produces items, add a branch:

```swift
if usePreparedPipeline {
    let ctx = FeedPresentationContext(
        epoch: presentationEpoch,
        mode: currentMode,
        filterGeneration: filterGeneration,
        presetGeneration: presetGeneration
    )
    await preparationCoordinator.replaceEditorialSequence(
        interleavedItems, context: ctx
    )
    await preparationCoordinator.fillRunway(
        targetRenderReady: policy.initialPublishedCount, context: ctx
    )
    let readyCards = await preparationCoordinator.takeRenderReadyPrefix(
        maximumCount: policy.initialPublishedCount, context: ctx
    )
    setVisibleCards(readyCards, context: ctx)

    // Continue filling deeper runways
    Task {
        await preparationCoordinator.fillRunway(
            targetRenderReady: policy.renderReadyTarget, context: ctx
        )
    }
} else {
    // Legacy path — unchanged
    setVisibleItems(interleavedItems)
}
```

- [ ] **Step 2: Implement `setVisibleCards`**

```swift
private func setVisibleCards(
    _ cards: [PreparedFeedCard],
    context: FeedPresentationContext
) {
    guard context.epoch == presentationEpoch else { return }

    // Validate all cards are terminal
    assert(cards.allSatisfy { card in
        if case .image = card.media { return true }
        if case .placeholder = card.media { return true }
        if case .none = card.media { return true }
        return false
    }, "All published cards must be terminal")

    // Convert to legacy FeedCardPresentation for existing views
    let legacyPresentations = cards.map { card in
        FeedCardPresentation(from: card, isRead: card.item.isRead, isBookmarked: card.item.isBookmarked)
    }

    visibleItems = cards.map(\.item)
    visibleCards = legacyPresentations
    visibleItemsGeneration &+= 1
    activePresentationContext = context

    // Update loading state if this is the initial page
    if cards.count >= RunwayPolicy().initialPublishedCount || !hasPreviouslyLoadedContent {
        loadingState = .ready
        hasPreviouslyLoadedContent = true
    }
}
```

- [ ] **Step 3: Add warm start test**

In `FeedStoreTests.swift`, add:

```swift
func test_warmStart_withPreparedPipeline_publishesTerminalCards() async throws {
    // Pre-populate DB with items that have images already in cache
    // Enable feature flag
    // Call reloadFromSQLite
    // Assert: visibleCards.count >= 20
    // Assert: all cards have terminal media (no loading states)
    // Assert: editorial order matches expected
}
```

- [ ] **Step 4: Build and run all tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform:iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Test.*passed|Test.*failed|Executed"`

- [ ] **Step 5: Commit**

```bash
git add feedmine/Services/FeedStore.swift feedmineTests/FeedStoreTests.swift
git commit -m "feat: warm start publishes only terminal prepared cards when flag is ON

- Startup gates on render-ready first page before clearing loading state
- Legacy path preserved when feature flag is OFF
- setVisibleCards validates terminality before publishing

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 12: Phase 5 — Remove CachedAsyncImage from Feed Views

**Files:**
- Modify: `feedmine/Views/FeedItemCardView.swift`, `feedmine/Views/FeedItemRowView.swift`, `feedmine/Views/FeedItemView.swift`
- Test: `feedmineTests/CardPresentationTests.swift` (existing tests already pass with presentation param)

**Interfaces:**
- Consumes: `PreparedFeedCard`, `RenderReadyMedia` (Task 3)
- Produces: Views render exclusively from prepared media — zero `CachedAsyncImage` usage in feed path

- [ ] **Step 1: Refactor FeedItemCardView — remove CachedAsyncImage fallback**

In `FeedItemCardView.swift`, replace the `hasImage` computed property and the image-rendering branches:

```swift
// Replace hasImage:
private var hasImage: Bool {
    guard let pres = presentation else { return false }
    if case .image = pres.media { return true }
    return false
}

// In portraitCard, replace the CachedAsyncImage else-branch (lines ~124-136):
if hasImage, !imageLoadFailed {
    if let pres = presentation, case .image = pres.media {
        PreparedCardImage(media: pres.media)
            .scaledToFill()
            .frame(width: geometry.size.width, height: geometry.size.height)
            .opacity(imageAppeared ? 1 : 0)
            .overlay(isRead ? Color.black.opacity(0.15) : nil)
            .onAppear {
                withAnimation(.easeIn(duration: 0.25)) { imageAppeared = true }
            }
    }
    // REMOVED: CachedAsyncImage else-branch
}

// In landscapeCard, same treatment — remove the CachedAsyncImage else-branch
```

- [ ] **Step 2: Add placeholder-kind rendering to FeedItemCardView**

Add a new view builder for placeholder media:

```swift
@ViewBuilder
private var placeholderSlot: some View {
    if let pres = presentation, case .placeholder(let kind) = pres.media {
        switch kind {
        case .podcast:
            podcastPlaceholder
        case .video:
            contentTypePlaceholderImage
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(0.5)
        case .forum, .article:
            contentTypePlaceholderImage
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(0.5)
        }
    }
}
```

Use this when `hasImage` is false but presentation has `.placeholder` media.

- [ ] **Step 3: Refactor FeedItemRowView — remove CachedAsyncImage fallback**

In `FeedItemRowView.swift`, remove the `CachedAsyncImage` else-branch (lines ~29-35). When `presentation` is nil or media isn't `.image`, render nothing in the thumbnail slot (or a placeholder).

- [ ] **Step 4: Update FeedItemView to pass PreparedFeedCard**

Currently `FeedItemView` gets presentation from `loader.cards`. This path stays the same — `loader.cards` already provides `[FeedCardPresentation]`. No change needed here until Phase 9 when we switch to `PreparedFeedCard`.

- [ ] **Step 5: Remove @State imageLoadFailed and imageAppeared**

In `FeedItemCardView`, remove:
```swift
@State private var imageLoadFailed = false
@State private var imageAppeared = false
```
These are no longer needed — media is always terminal on arrival.

- [ ] **Step 6: Build and run tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform:iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Test.*passed|Test.*failed|Executed"`

- [ ] **Step 7: Commit**

```bash
git add feedmine/Views/FeedItemCardView.swift feedmine/Views/FeedItemRowView.swift feedmine/Views/FeedItemView.swift
git commit -m "feat: remove CachedAsyncImage fallback from main feed views

- FeedItemCardView: render exclusively from presentation media
- FeedItemRowView: remove CachedAsyncImage, use PreparedCardImage only
- Remove @State imageLoadFailed/imageAppeared — media is always terminal
- CachedAsyncImage remains in non-feed paths (onboarding, detail, etc.)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 13: Phase 5 — Pagination via Render-Ready Prefix

**Files:**
- Modify: `feedmine/Services/FeedStore.swift` (loadMoreIfNeeded replacement)
- Test: `feedmineTests/CardPreparationCoordinatorTests.swift` (add scroll promotion test)

**Interfaces:**
- Consumes: `CardPreparationCoordinator.takeRenderReadyPrefix` (Task 9)
- Produces: Scroll consumes prepared stock; `loadMoreIfNeeded` only promotes, never fetches

- [ ] **Step 1: Add reportViewportPosition to FeedStore**

```swift
func reportViewportPosition(currentCardID: String) {
    // Inform the runway controller of scroll progress
    Task {
        await runwayController.reportViewport(
            currentIndex: visibleItems.firstIndex(where: { $0.id == currentCardID }) ?? 0,
            publishedCount: visibleItems.count,
            timestamp: .now
        )
    }
}
```

- [ ] **Step 2: Gate loadMoreIfNeeded on feature flag**

```swift
func loadMoreIfNeeded(currentCardID: String) async {
    reportViewportPosition(currentCardID: currentCardID)

    if usePreparedPipeline {
        let ctx = activePresentationContext
        let cards = await preparationCoordinator.takeRenderReadyPrefix(
            maximumCount: Reservoir.pageSize,
            context: ctx
        )
        guard !cards.isEmpty else { return }
        appendVisibleCards(cards, context: ctx)
        await runwayController.evaluate()
    } else {
        // Legacy path — existing fetch-based logic
        await legacyLoadMoreIfNeeded(currentCardID: currentCardID)
    }
}
```

- [ ] **Step 3: Implement `appendVisibleCards`**

```swift
private func appendVisibleCards(
    _ cards: [PreparedFeedCard],
    context: FeedPresentationContext
) {
    guard context.epoch == presentationEpoch else { return }
    guard !cards.isEmpty else { return }

    // No duplicate IDs
    let existingIDs = Set(visibleCards.map(\.id))
    let newCards = cards.filter { !existingIDs.contains($0.id) }
    guard !newCards.isEmpty else { return }

    let legacyPresentations = newCards.map { card in
        FeedCardPresentation(from: card, isRead: card.item.isRead, isBookmarked: card.item.isBookmarked)
    }

    visibleItems.append(contentsOf: newCards.map(\.item))
    visibleCards.append(contentsOf: legacyPresentations)
    visibleItemsGeneration &+= 1
}
```

- [ ] **Step 4: Build and run tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform:iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Test.*passed|Test.*failed|Executed"`

- [ ] **Step 5: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "feat: pagination consumes render-ready prefix, never triggers fetch

- loadMoreIfNeeded promotes already-prepared cards
- appendVisibleCards validates context epoch, no dups
- Legacy path unchanged when feature flag is OFF

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 14: Phase 6 — Special Flow: Collections

**Files:**
- Modify: `feedmine/Services/FeedStore.swift` (collection loading path)
- Test: `feedmineTests/FeedStoreTests.swift` (collection test)

**Interfaces:**
- Consumes: `CardPreparationCoordinator.replaceEditorialSequence` (Task 9)
- Produces: Collections publish `PreparedFeedCard` when flag is ON

- [ ] **Step 1: Gate collection publishing on feature flag**

In the collection loading method (search for `loadCollection` or `.collection` context creation), add:

```swift
if usePreparedPipeline {
    let ctx = FeedPresentationContext(
        epoch: presentationEpoch,
        mode: .collection(collectionID),
        filterGeneration: filterGeneration,
        presetGeneration: presetGeneration
    )
    await preparationCoordinator.replaceEditorialSequence(members, context: ctx)
    await preparationCoordinator.fillRunway(
        targetRenderReady: max(members.count, 20), context: ctx
    )
    let ready = await preparationCoordinator.takeRenderReadyPrefix(
        maximumCount: members.count, context: ctx
    )
    setVisibleCards(ready, context: ctx)
} else {
    // Legacy path
    // ... existing collection loading ...
}
```

- [ ] **Step 2: Build and run tests**

- [ ] **Step 3: Commit**

---

### Task 15: Phase 6 — Special Flows: Smart Feeds, Bookmarks, Last Clicked, What's New

**Files:**
- Modify: `feedmine/Services/FeedStore.swift` (all remaining feed mode paths)
- Test: `feedmineTests/FeedStoreTests.swift`

**Interfaces:**
- Consumes: Same coordinator APIs as Task 14
- Produces: All feed modes publish `PreparedFeedCard` when flag is ON

- [ ] **Step 1: Gate Smart Feed on feature flag**

Use context `.smartFeed(id)`.

- [ ] **Step 2: Gate Bookmarks on feature flag**

Use context `.bookmarks(listID)`.

- [ ] **Step 3: Gate Last Clicked on feature flag**

Use context `.lastClicked`.

- [ ] **Step 4: Gate What's New on feature flag**

Use context `.whatsNew`.

- [ ] **Step 5: Gate source/region/category toggles**

On toggle, rebuild with same context mode but incremented epoch.

- [ ] **Step 6: Gate shake refresh**

On refresh, increment epoch, rebuild from SQLite.

- [ ] **Step 7: Build and run all tests**

- [ ] **Step 8: Commit**

---

### Task 16: Phase 7 — FeedRunwayController

**Files:**
- Create: `feedmine/Services/FeedRunwayController.swift`, `feedmine/Services/RunwayMetrics.swift`
- Modify: `feedmine/Services/FeedStore.swift` (integrate controller)
- Test: `feedmineTests/RunwayControllerTests.swift`

**Interfaces:**
- Consumes: `RunwayPolicy` (Task 4), `RunwayMetrics` (new), `NetworkMonitor` (existing)
- Produces: `FeedRunwayController` actor — `start`, `stop`, `reportViewport`, `evaluate`, pressure-driven adaptive concurrency

- [ ] **Step 1: Write RunwayMetrics.swift**

```swift
import Foundation

/// Exponential moving averages and counters for runway health monitoring.
struct RunwayMetrics: Sendable {
    var scrollCardsPerSecondEMA: Double = 1.0
    var prepareCardsPerSecondEMA: Double = 0.5
    var resolveImagesPerSecondEMA: Double = 0.3
    var failureRateEMA: Double = 0.0
    var prepareLatencyP50: Double = 0.0
    var prepareLatencyP95: Double = 0.0

    let smoothingFactor: Double = 0.2

    mutating func recordScroll(cardsPerSecond: Double) {
        scrollCardsPerSecondEMA = scrollCardsPerSecondEMA * (1 - smoothingFactor) + cardsPerSecond * smoothingFactor
    }

    mutating func recordPrepare(cardsPerSecond: Double) {
        prepareCardsPerSecondEMA = prepareCardsPerSecondEMA * (1 - smoothingFactor) + cardsPerSecond * smoothingFactor
    }
}
```

- [ ] **Step 2: Write FeedRunwayController.swift**

```swift
import Foundation

actor FeedRunwayController {
    private let policy: RunwayPolicy
    private let coordinator: CardPreparationCoordinator
    private var metrics = RunwayMetrics()
    private var pressureState: RunwayPressure = .bootstrap
    private var activeContext: FeedPresentationContext?

    private var publishedAhead: Int = 0
    private var renderReadyCount: Int = 0
    private var resolvedCount: Int = 0
    private var editorialCount: Int = 0

    private var lastViewportUpdate: ContinuousClock.Instant = .now
    private var lastViewportIndex: Int = 0

    private var isEvaluating = false

    init(policy: RunwayPolicy, coordinator: CardPreparationCoordinator) {
        self.policy = policy
        self.coordinator = coordinator
    }

    func start(context: FeedPresentationContext) {
        activeContext = context
        pressureState = .bootstrap
    }

    func stop(context: FeedPresentationContext) {
        guard context == activeContext else { return }
        activeContext = nil
    }

    func reportViewport(currentIndex: Int, publishedCount: Int, timestamp: ContinuousClock.Instant) {
        let elapsed = lastViewportUpdate.duration(to: timestamp)
        let indexDelta = Double(max(0, currentIndex - lastViewportIndex))
        if elapsed > .zero {
            let rate = indexDelta / elapsed.timeInterval
            metrics.recordScroll(cardsPerSecond: rate)
        }
        lastViewportUpdate = timestamp
        lastViewportIndex = currentIndex
        publishedAhead = max(0, publishedCount - currentIndex)
    }

    func evaluate() async {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        guard let ctx = activeContext else { return }

        let estimatedSeconds = Double(publishedAhead + renderReadyCount) / max(metrics.scrollCardsPerSecondEMA, 0.1)

        let newPressure = computePressure(estimatedSeconds: estimatedSeconds)

        guard newPressure != pressureState else { return }
        pressureState = newPressure

        switch newPressure {
        case .critical, .bootstrap:
            // Max priority — fill initial page immediately
            await coordinator.fillRunway(
                targetRenderReady: policy.initialPublishedCount + policy.publishedAheadLow,
                context: ctx
            )

        case .filling:
            await coordinator.fillRunway(
                targetRenderReady: policy.renderReadyTarget,
                context: ctx
            )

        case .cruising:
            // Light refresh only
            await coordinator.fillRunway(
                targetRenderReady: policy.renderReadyTarget,
                context: ctx
            )

        case .maintenance:
            // Pause new preparation; only maintain existing
            break

        case .constrained:
            await coordinator.handleMemoryPressure()
        }
    }

    private func computePressure(estimatedSeconds: Double) -> RunwayPressure {
        if renderReadyCount < 20 || estimatedSeconds < 30 {
            return .critical
        }
        if renderReadyCount < policy.renderReadyLow {
            return .filling
        }
        if renderReadyCount >= policy.renderReadyHigh {
            return .maintenance
        }
        return .cruising
    }
}

enum RunwayPressure: Sendable {
    case critical
    case bootstrap
    case filling
    case cruising
    case maintenance
    case constrained
}
```

- [ ] **Step 3: Integrate controller into FeedStore**

```swift
private lazy var runwayController = FeedRunwayController(
    policy: runwayPolicy, coordinator: preparationCoordinator
)
```

- [ ] **Step 4: Write RunwayControllerTests.swift**

```swift
final class RunwayControllerTests: XCTestCase {
    func test_pressureTransitions_bootstrapToFilling() async { /* ... */ }
    func test_pressureTransitions_cruisingToMaintenance() async { /* ... */ }
    func test_pressureHysteresis_noFlickering() async { /* ... */ }
}
```

- [ ] **Step 5: Build and run tests**

- [ ] **Step 6: Commit**

---

### Task 17: Phase 8 — Memory and Performance Tuning

**Files:**
- Modify: `feedmine/Services/CardPreparationCoordinator.swift` (decode window), `feedmine/Services/FeedStore.swift` (memory warning handler)
- Test: `feedmineTests/CardPreparationCoordinatorTests.swift` (memory warning test)

**Interfaces:**
- Consumes: `RunwayPolicy` (adaptive targets), `PreparedFeedCard` (UIImage reference counting)
- Produces: Decoded image window bounded to published + render-ready only; memory warning releases deep cards

- [ ] **Step 1: Add memory budget tracking to CardPreparationCoordinator**

```swift
private var decodedImageByteCost: Int = 0
private let maxDecodedBytes: Int = 80 * 1024 * 1024  // 80 MB

private func trackDecodeCost(_ image: UIImage) {
    let cost = Int(image.size.width * image.size.height * 4 * image.scale * image.scale)
    decodedImageByteCost += cost
}

private func releaseDecodeCost(_ image: UIImage) {
    let cost = Int(image.size.width * image.size.height * 4 * image.scale * image.scale)
    decodedImageByteCost = max(0, decodedImageByteCost - cost)
}
```

- [ ] **Step 2: Implement memory warning handler in FeedStore**

Already partially done in `CardPreparationCoordinator.handleMemoryPressure()`. Wire to `UIApplication.didReceiveMemoryWarningNotification`.

- [ ] **Step 3: Add adaptive targets based on device memory**

In `RunwayPolicy`, add:

```swift
static func forDevice() -> RunwayPolicy {
    let physicalMemory = ProcessInfo.processInfo.physicalMemory
    if physicalMemory < 2_000_000_000 {  // < 2 GB
        return RunwayPolicy().constrained()
    } else if physicalMemory > 6_000_000_000 {  // > 6 GB
        return RunwayPolicy().comfortable()
    }
    return RunwayPolicy()  // default
}
```

- [ ] **Step 4: Build and run tests**

- [ ] **Step 5: Commit**

---

### Task 18: Phase 9 — Legacy Removal

**Files:**
- Remove: `feedmine/Services/ReadyCardQueue.swift`
- Modify: `feedmine/Services/FeedStore.swift` (remove legacy paths), `feedmine/Services/ImageCache.swift` (remove `diskImageSync`), `feedmine/Services/ImagePrefetcher.swift` (remove or absorb), `feedmine/Services/AppSettings.swift` (enable flag by default)

**Interfaces:**
- Consumes: (none — final cleanup)
- Produces: `visibleCards` is the sole source of truth; all legacy feed-image paths removed

- [ ] **Step 1: Remove ReadyCardQueue.swift**

Delete the file.

- [ ] **Step 2: Remove legacy publishing paths from FeedStore**

Delete `prefetchUpcoming()`, `resolveArticleImagesInBackground()`, and the legacy `loadMoreIfNeeded` path. Remove the feature flag gate — prepared pipeline is always ON.

- [ ] **Step 3: Remove `visibleItems` compatibility property**

```swift
// Remove:
var visibleItems: [FeedItem] { visibleCards.map(\.item) }
```

Replace all external references with `visibleCards.map(\.item)` or update consumers to use `PreparedFeedCard` directly.

- [ ] **Step 4: Remove `diskImageSync` from ImageCache**

Delete the synchronous disk read method (or mark unavailable).

- [ ] **Step 5: Remove `CachedAsyncImage` from ImageCache.swift feed-path usage**

`CachedAsyncImage` stays for onboarding, detail views, source views, but any remaining feed-path references are deleted.

- [ ] **Step 6: Enable feature flag by default**

```swift
static var preparedFeedPipelineEnabled: Bool {
    // Default ON after Phase 9 stabilization
    if UserDefaults.standard.object(forKey: Keys.preparedFeedPipelineEnabled) == nil {
        return true
    }
    return UserDefaults.standard.bool(forKey: Keys.preparedFeedPipelineEnabled)
}
```

- [ ] **Step 7: Run full test suite**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform:iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Test.*passed|Test.*failed|Executed.*tests"`

- [ ] **Step 8: Run UI tests**

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:feedmineUITests 2>&1 | tail -20
```

- [ ] **Step 9: Commit**

```bash
git rm feedmine/Services/ReadyCardQueue.swift
git add feedmine/Services/FeedStore.swift feedmine/Services/ImageCache.swift feedmine/Services/ImagePrefetcher.swift feedmine/Services/AppSettings.swift
git commit -m "chore: remove legacy feed image path

- Delete ReadyCardQueue (replaced by CardPreparationCoordinator)
- Remove prefetchUpcoming, resolveArticleImagesInBackground
- Remove visibleItems compatibility — visibleCards is sole source
- Remove diskImageSync from ImageCache
- Enable prepared feed pipeline by default
- CachedAsyncImage retained for non-feed paths only

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 19: Final Verification

**Files:**
- Test: Run all tests
- Build: Verify clean build

**Interfaces:**
- Consumes: All
- Produces: Verified migration complete

- [ ] **Step 1: Full test suite**

```bash
xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform:iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Executed.*tests"
```

Expected: All tests pass.

- [ ] **Step 2: Verify invariants with grep**

```bash
# No CachedAsyncImage in feed views
! grep -r "CachedAsyncImage" feedmine/Views/FeedItemCardView.swift feedmine/Views/FeedItemRowView.swift

# No .task for image loading in feed views
! grep -r "\.task\s*{" feedmine/Views/FeedItemCardView.swift feedmine/Views/FeedItemRowView.swift

# No URLSession in feed views
! grep -r "URLSession" feedmine/Views/FeedItemCardView.swift feedmine/Views/FeedItemRowView.swift

# No diskImageSync in views
! grep -r "diskImageSync" feedmine/Views/

# No @MainActor on coordinator
! grep "@MainActor" feedmine/Services/CardPreparationCoordinator.swift
```

- [ ] **Step 3: Verify editorial order preservation**

Run the comparison test added in Phase 1 to confirm IDs and order match legacy.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "test: final verification of prepared feed migration

- All tests pass
- Zero CachedAsyncImage in feed views
- Zero URLSession/.task in feed views
- Coordinator not on MainActor
- Editorial order preserved

Co-Authored-By: Claude <noreply@anthropic.com>"
```
