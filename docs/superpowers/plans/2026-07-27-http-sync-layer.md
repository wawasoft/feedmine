# HTTP Sync Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite the HTTP synchronization layer with conditional GET (ETag/Last-Modified/304), adaptive scheduling with cadence learning, and complete feed metadata extraction — all fields FeedKit already parses but the code currently discards.

**Architecture:** Extract a dedicated `FeedHTTPSync` actor for all HTTP semantics. Expand `FeedItem` with 8 new metadata fields. Replace `SourceScheduler` with `AdaptiveScheduler` that learns publication cadence via EMA and respects TTL/Cache-Control/Retry-After. Persist HTTP validators per-source in `source_health` v2. Keep FeedKit as the parser — harvest fields it already exposes.

**Tech Stack:** Swift 6, Swift Concurrency (async/await, actors), FeedKit 9.1.2, GRDB 7.4.0, URLSession with URLCache

## Global Constraints

- Keep FeedKit as dependency — do not replace the parser
- All new FeedItem fields are optional (NULL-able) — existing items remain valid
- SourceScheduler diversity scoring (√n regions, category deficits, diverseSources) must be preserved in AdaptiveScheduler
- Existing tests must continue to pass (updated for new types)
- User-Agent: `FeedMine/1.0 (https://feedmine.app/bot)`
- Accept: `application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml;q=0.9`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `feedmine/Models/HTTPValidators.swift` | **Create** | HTTPValidators, ParsedCacheControl, CadenceEstimator, SourceCapabilities, WebSubEndpoints, RSSCloudEndpoints |
| `feedmine/Models/FetchOutcome.swift` | **Create** | FeedFetchOutcome enum, FetchHTTPResult struct |
| `feedmine/Services/FeedHTTPSync.swift` | **Create** | HTTP actor: conditional GET, 304, redirect, Retry-After |
| `feedmine/Services/AdaptiveScheduler.swift` | **Create** | Gate + Strategy + CadenceEstimator + diversity scoring |
| `feedmine/Models/FeedItem.swift` | **Modify** | +8 new fields, +ParsedItemMetadata, updated copying methods |
| `feedmine/Models/FeedFetchResult.swift` | **Modify** | status → outcome, +validators, +canonicalURL |
| `feedmine/Models/FeedFetchBatch.swift` | **Modify** | sourceStatuses → sourceOutcomes, +notModifiedCount, +throttledCount |
| `feedmine/Services/RSSFetcher.swift` | **Modify** | Remove HTTP logic, add metadata extraction, WebSub/cloud detection |
| `feedmine/Services/FeedStore.swift` | **Modify** | source_health v2 migration, validator persistence, mergeItems, AdaptiveScheduler wiring |
| `feedmine/Services/SourceScheduler.swift` | **Modify** | Mark deprecated (kept for reference, replaced by AdaptiveScheduler) |
| `feedmineTests/HTTPValidatorsTests.swift` | **Create** | Unit tests for validators, capabilities, cadence estimator |
| `feedmineTests/FeedHTTPSyncTests.swift` | **Create** | Unit tests for HTTP actor (mock URLSession) |
| `feedmineTests/AdaptiveSchedulerTests.swift` | **Create** | Unit tests for gate, strategy, urgency, cadence learning |
| `feedmineTests/SourceSchedulerTests.swift` | **Modify** | Update for new types, keep diversity tests |

---

### Task 1: Create HTTPValidators, capabilities, and CadenceEstimator models

**Files:**
- Create: `feedmine/Models/HTTPValidators.swift`

**Interfaces:**
- Produces: `HTTPValidators` (Codable, Sendable, Equatable), `HTTPValidators.ParsedCacheControl`, `HTTPValidators.FetchOutcomeKind`, `CadenceEstimator` (Codable, Sendable), `SourceCapabilities` (Codable, Sendable, Equatable), `SourceCapabilities.WebSubEndpoints`, `SourceCapabilities.RSSCloudEndpoints`

- [ ] **Step 1: Create the file with all models**

```swift
import Foundation

// MARK: - HTTP Validators

/// Per-source HTTP validators persisted in source_health.
/// Populated by FeedHTTPSync (headers) and RSSFetcher (feed-level elements).
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
    var skipHours: [Int]?               // hours of day (0-23) when fetching should be avoided
    var skipDays: [String]?             // day names when fetching should be avoided
    var lastBuildDate: Date?
    var capabilities: SourceCapabilities?
    var publicationInterval: TimeInterval?
    var publicationIntervalConfidence: Double?

    init(
        etag: String? = nil,
        lastModified: String? = nil,
        cacheControl: ParsedCacheControl? = nil,
        expires: Date? = nil,
        canonicalURL: String? = nil,
        lastFetchAt: Date? = nil,
        lastOutcome: FetchOutcomeKind? = nil,
        retryAfter: Date? = nil,
        ttl: Int? = nil,
        skipHours: [Int]? = nil,
        skipDays: [String]? = nil,
        lastBuildDate: Date? = nil,
        capabilities: SourceCapabilities? = nil,
        publicationInterval: TimeInterval? = nil,
        publicationIntervalConfidence: Double? = nil
    ) {
        self.etag = etag
        self.lastModified = lastModified
        self.cacheControl = cacheControl
        self.expires = expires
        self.canonicalURL = canonicalURL
        self.lastFetchAt = lastFetchAt
        self.lastOutcome = lastOutcome
        self.retryAfter = retryAfter
        self.ttl = ttl
        self.skipHours = skipHours
        self.skipDays = skipDays
        self.lastBuildDate = lastBuildDate
        self.capabilities = capabilities
        self.publicationInterval = publicationInterval
        self.publicationIntervalConfidence = publicationIntervalConfidence
    }

    struct ParsedCacheControl: Codable, Sendable, Equatable {
        var maxAge: TimeInterval?
        var noCache: Bool
        var noStore: Bool
        var mustRevalidate: Bool

        init(maxAge: TimeInterval? = nil, noCache: Bool = false,
             noStore: Bool = false, mustRevalidate: Bool = false) {
            self.maxAge = maxAge
            self.noCache = noCache
            self.noStore = noStore
            self.mustRevalidate = mustRevalidate
        }

        /// Parse a Cache-Control header value into its directives.
        static func parse(_ header: String) -> ParsedCacheControl {
            var result = ParsedCacheControl()
            let directives = header.lowercased().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for directive in directives {
                if directive == "no-cache" { result.noCache = true }
                else if directive == "no-store" { result.noStore = true }
                else if directive == "must-revalidate" { result.mustRevalidate = true }
                else if directive.hasPrefix("max-age=") {
                    result.maxAge = TimeInterval(directive.dropFirst(8))
                }
            }
            return result
        }
    }

    enum FetchOutcomeKind: String, Codable, Sendable {
        case notModified
        case modifiedWithNewItems
        case modifiedWithoutNewItems
        case failed
        case throttled
    }
}

// MARK: - Cadence Estimator

/// Learns publication frequency per source using exponential moving average.
struct CadenceEstimator: Codable, Sendable {
    var publicationInterval: TimeInterval = 3600  // default 1 hour
    var confidence: Double = 0.0                   // 0 = no data, 1 = highly predictable
    var lastPublication: Date = .distantPast

    /// Record that the feed produced new items — update EMA.
    mutating func recordPublication(_ date: Date) {
        let interval = date.timeIntervalSince(lastPublication)
        if lastPublication > .distantPast, interval > 0 {
            publicationInterval = publicationInterval * 0.7 + interval * 0.3
        }
        lastPublication = date
        confidence = min(1.0, confidence + 0.1)
    }

    /// Record that we checked and found nothing new — slight confidence decay.
    mutating func recordNoChange() {
        confidence = max(0.1, confidence - 0.02)
    }

    /// Recommended minimum interval before next fetch (80% of learned interval).
    var minInterval: TimeInterval {
        max(300, min(publicationInterval * 0.8, 2_592_000))  // 5 min → 30 days
    }
}

// MARK: - Source Capabilities

/// Feed-level features discovered during parsing.
/// Serialized as JSON in source_health.capabilities.
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

    init(websub: WebSubEndpoints? = nil, cloud: RSSCloudEndpoints? = nil, hasPagination: Bool = false) {
        self.websub = websub
        self.cloud = cloud
        self.hasPagination = hasPagination
    }
}
```

- [ ] **Step 2: Write unit tests for ParsedCacheControl.parse and CadenceEstimator**

Create `feedmineTests/HTTPValidatorsTests.swift`:

```swift
import XCTest
@testable import feedmine

final class HTTPValidatorsTests: XCTestCase {

    // MARK: - Cache-Control parsing

    func testParseMaxAge() {
        let cc = HTTPValidators.ParsedCacheControl.parse("max-age=3600")
        XCTAssertEqual(cc.maxAge, 3600)
        XCTAssertFalse(cc.noCache)
    }

    func testParseNoCache() {
        let cc = HTTPValidators.ParsedCacheControl.parse("no-cache, max-age=0")
        XCTAssertTrue(cc.noCache)
        XCTAssertEqual(cc.maxAge, 0)
    }

    func testParseNoStore() {
        let cc = HTTPValidators.ParsedCacheControl.parse("no-store")
        XCTAssertTrue(cc.noStore)
    }

    func testParseMustRevalidate() {
        let cc = HTTPValidators.ParsedCacheControl.parse("must-revalidate, max-age=86400")
        XCTAssertTrue(cc.mustRevalidate)
        XCTAssertEqual(cc.maxAge, 86400)
    }

    func testParseEmpty() {
        let cc = HTTPValidators.ParsedCacheControl.parse("")
        XCTAssertNil(cc.maxAge)
        XCTAssertFalse(cc.noCache)
    }

    // MARK: - CadenceEstimator

    func testDefaultValues() {
        let e = CadenceEstimator()
        XCTAssertEqual(e.publicationInterval, 3600)
        XCTAssertEqual(e.confidence, 0)
        XCTAssertTrue(e.lastPublication == .distantPast)
    }

    func testFirstPublicationDoesNotChangeInterval() {
        var e = CadenceEstimator()
        let now = Date()
        e.recordPublication(now)
        XCTAssertEqual(e.publicationInterval, 3600) // unchanged on first record
        XCTAssertEqual(e.confidence, 0.1)
    }

    func testEMAConverges() {
        var e = CadenceEstimator()
        let t0 = Date()
        e.recordPublication(t0)                              // first — no interval yet
        let t1 = t0.addingTimeInterval(7200)                 // 2h later
        e.recordPublication(t1)
        // EMA: 3600*0.7 + 7200*0.3 = 2520 + 2160 = 4680
        XCTAssertEqual(e.publicationInterval, 4680, accuracy: 0.01)
        XCTAssertEqual(e.confidence, 0.2)
        let t2 = t1.addingTimeInterval(7200)                 // consistent 2h
        e.recordPublication(t2)
        // EMA: 4680*0.7 + 7200*0.3 = 3276 + 2160 = 5436
        XCTAssertEqual(e.publicationInterval, 5436, accuracy: 0.01)
        XCTAssertEqual(e.confidence, 0.3)
    }

    func testMinIntervalClamped() {
        var e = CadenceEstimator(publicationInterval: 60, confidence: 1.0, lastPublication: Date())
        XCTAssertEqual(e.minInterval, 300) // clamped to 5 min minimum

        e = CadenceEstimator(publicationInterval: 100_000_000, confidence: 1.0, lastPublication: Date())
        XCTAssertEqual(e.minInterval, 2_592_000) // clamped to 30 day maximum
    }

    func testRecordNoChangeDecreasesConfidence() {
        var e = CadenceEstimator(publicationInterval: 3600, confidence: 0.5, lastPublication: Date())
        e.recordNoChange()
        XCTAssertEqual(e.confidence, 0.48)
        // Can't drop below 0.1
        for _ in 0..<30 { e.recordNoChange() }
        XCTAssertEqual(e.confidence, 0.1)
    }

    // MARK: - Codable round-trip

    func testRoundTripValidators() throws {
        var v = HTTPValidators()
        v.etag = "\"abc123\""
        v.cacheControl = HTTPValidators.ParsedCacheControl(maxAge: 3600)
        v.capabilities = SourceCapabilities(
            websub: SourceCapabilities.WebSubEndpoints(hub: "https://hub.example.com", selfURL: nil)
        )

        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(HTTPValidators.self, from: data)
        XCTAssertEqual(decoded.etag, "\"abc123\"")
        XCTAssertEqual(decoded.cacheControl?.maxAge, 3600)
        XCTAssertEqual(decoded.capabilities?.websub?.hub, "https://hub.example.com")
    }
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests/HTTPValidatorsTests 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 4: Add test file to Xcode project**

Add `feedmineTests/HTTPValidatorsTests.swift` to the `feedmineTests` target in Xcode.
Verify via: `ls -la feedmineTests/HTTPValidatorsTests.swift`

- [ ] **Step 5: Commit**

```bash
git add feedmine/Models/HTTPValidators.swift feedmineTests/HTTPValidatorsTests.swift
git commit -m "feat: add HTTPValidators, CadenceEstimator, and SourceCapabilities models

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Create FetchOutcome, FetchHTTPResult, and HTTPOutcome models

**Files:**
- Create: `feedmine/Models/FetchOutcome.swift`

**Interfaces:**
- Consumes: `HTTPValidators` (from Task 1), `FeedItem` (existing)
- Produces: `HTTPOutcome` (enum, Sendable), `FetchHTTPResult` (struct, Sendable), `FeedFetchOutcome` (enum, Sendable, Equatable) — used by Tasks 4, 5, 6

- [ ] **Step 1: Create the outcome models**

```swift
import Foundation

// MARK: - HTTP-level outcome (from FeedHTTPSync)

enum HTTPOutcome: Sendable {
    case notModified
    case success(Data)
    case throttled(until: Date)
    case failed(Error)
}

/// Returned by FeedHTTPSync.fetch() — raw HTTP result before parsing.
struct FetchHTTPResult: Sendable {
    let data: Data?
    let outcome: HTTPOutcome
    let updatedValidators: HTTPValidators
    let canonicalURL: String?
}

// MARK: - Feed-level outcome (from RSSFetcher)

enum FeedFetchOutcome: Sendable, Equatable {
    case notModified
    case modifiedWithNewItems([FeedItem], validators: HTTPValidators)
    case modifiedWithoutNewItems(validators: HTTPValidators)
    case failed(Error)
    case throttled(until: Date)

    // Equatable conformance for .failed (Error is not Equatable)
    static func == (lhs: FeedFetchOutcome, rhs: FeedFetchOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.notModified, .notModified): return true
        case (.modifiedWithNewItems(let lItems, _), .modifiedWithNewItems(let rItems, _)):
            return lItems == rItems
        case (.modifiedWithoutNewItems, .modifiedWithoutNewItems): return true
        case (.failed, .failed): return true  // approximate — errors aren't Equatable
        case (.throttled(let lDate), .throttled(let rDate)): return lDate == rDate
        default: return false
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add feedmine/Models/FetchOutcome.swift
git commit -m "feat: add FetchOutcome and FetchHTTPResult models

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Expand FeedItem with metadata fields and ParsedItemMetadata

**Files:**
- Modify: `feedmine/Models/FeedItem.swift`

**Interfaces:**
- Consumes: (none new)
- Produces: `FeedItem` +8 new optional fields, `FeedItemAuthor`, `FeedItemCategory`, `FeedItemAttribution`, `FeedEnclosure`, `FeedAlternateLink`, `ParsedItemMetadata`

- [ ] **Step 1: Add new sub-types at the bottom of FeedItem.swift (before closing brace of file)**

Insert after the existing `FeedItem` struct closing brace and before the end of file:

```swift
// MARK: - New metadata types

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

    init(
        authors: [FeedItemAuthor]? = nil,
        categories: [FeedItemCategory]? = nil,
        rights: String? = nil,
        attribution: FeedItemAttribution? = nil,
        enclosures: [FeedEnclosure]? = nil,
        language: String? = nil,
        alternateLinks: [FeedAlternateLink]? = nil,
        publishedAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.authors = authors
        self.categories = categories
        self.rights = rights
        self.attribution = attribution
        self.enclosures = enclosures
        self.language = language
        self.alternateLinks = alternateLinks
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
    }
}
```

- [ ] **Step 2: Add new fields to FeedItem struct**

After line 17 (`let language: String?`), add:

```swift
    // --- NEW metadata fields (all optional, NULL-able in DB) ---
    let updatedAt: Date?
    let authors: [FeedItemAuthor]?
    let itemCategories: [FeedItemCategory]?
    let rights: String?
    let attribution: FeedItemAttribution?
    let enclosures: [FeedEnclosure]?
    let languageFromFeed: String?
    let alternateLinks: [FeedAlternateLink]?
```

- [ ] **Step 3: Update the init to include new fields**

Replace the existing `init` (lines 30-52) with an updated version that adds the new parameters with defaults:

```swift
    init(id: String, sourceTitle: String, sourceURL: String, category: String,
         title: String, excerpt: String, url: String, imageURL: String?,
         publishedAt: Date, audioURL: String? = nil, duration: TimeInterval? = nil,
         region: String = "global", language: String? = nil,
         updatedAt: Date? = nil,
         authors: [FeedItemAuthor]? = nil,
         itemCategories: [FeedItemCategory]? = nil,
         rights: String? = nil,
         attribution: FeedItemAttribution? = nil,
         enclosures: [FeedEnclosure]? = nil,
         languageFromFeed: String? = nil,
         alternateLinks: [FeedAlternateLink]? = nil,
         isRead: Bool = false, isBookmarked: Bool = false,
         sectionDayOffset: Int = 0) {
        self.id = id
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.category = category
        self.title = title
        self.excerpt = excerpt
        self.url = url
        self.imageURL = imageURL
        self.publishedAt = publishedAt
        self.audioURL = audioURL
        self.duration = duration
        self.region = region
        self.language = language
        self.updatedAt = updatedAt
        self.authors = authors
        self.itemCategories = itemCategories
        self.rights = rights
        self.attribution = attribution
        self.enclosures = enclosures
        self.languageFromFeed = languageFromFeed
        self.alternateLinks = alternateLinks
        self.isRead = isRead
        self.isBookmarked = isBookmarked
        self.sectionDayOffset = sectionDayOffset
    }
```

- [ ] **Step 4: Update all copying methods to preserve new fields**

Update `withoutAudio()` (line 176):

```swift
    func withoutAudio() -> FeedItem {
        FeedItem(
            id: id, sourceTitle: sourceTitle, sourceURL: sourceURL, category: category,
            title: title, excerpt: excerpt, url: url, imageURL: imageURL,
            publishedAt: publishedAt, audioURL: nil, duration: nil, region: region,
            language: language,
            updatedAt: updatedAt,
            authors: authors,
            itemCategories: itemCategories,
            rights: rights,
            attribution: attribution,
            enclosures: enclosures,
            languageFromFeed: languageFromFeed,
            alternateLinks: alternateLinks
        )
    }
```

Update `replacingMetadata` (line 189):

```swift
    func replacingMetadata(region: String, language: String?) -> FeedItem {
        FeedItem(
            id: id, sourceTitle: sourceTitle, sourceURL: sourceURL, category: category,
            title: title, excerpt: excerpt, url: url, imageURL: imageURL,
            publishedAt: publishedAt, audioURL: audioURL, duration: duration,
            region: region,
            language: language,
            updatedAt: updatedAt,
            authors: authors,
            itemCategories: itemCategories,
            rights: rights,
            attribution: attribution,
            enclosures: enclosures,
            languageFromFeed: languageFromFeed,
            alternateLinks: alternateLinks,
            isRead: isRead,
            isBookmarked: isBookmarked,
            sectionDayOffset: sectionDayOffset
        )
    }
```

Update `withNormalizedSourceURL` (line 205):

```swift
    var withNormalizedSourceURL: FeedItem {
        let normalized = OPMLParser.normalizeURL(sourceURL)
        guard normalized != sourceURL else { return self }
        return FeedItem(
            id: id, sourceTitle: sourceTitle, sourceURL: normalized, category: category,
            title: title, excerpt: excerpt, url: url, imageURL: imageURL,
            publishedAt: publishedAt, audioURL: audioURL, duration: duration,
            region: region,
            language: language,
            updatedAt: updatedAt,
            authors: authors,
            itemCategories: itemCategories,
            rights: rights,
            attribution: attribution,
            enclosures: enclosures,
            languageFromFeed: languageFromFeed,
            alternateLinks: alternateLinks,
            isRead: isRead,
            isBookmarked: isBookmarked,
            sectionDayOffset: sectionDayOffset
        )
    }
```

Update `withSectionDayOffset` (line 222):

```swift
    func withSectionDayOffset(_ offset: Int) -> FeedItem {
        FeedItem(
            id: id, sourceTitle: sourceTitle, sourceURL: sourceURL, category: category,
            title: title, excerpt: excerpt, url: url, imageURL: imageURL,
            publishedAt: publishedAt, audioURL: audioURL, duration: duration,
            region: region, language: language,
            updatedAt: updatedAt,
            authors: authors,
            itemCategories: itemCategories,
            rights: rights,
            attribution: attribution,
            enclosures: enclosures,
            languageFromFeed: languageFromFeed,
            alternateLinks: alternateLinks,
            isRead: isRead, isBookmarked: isBookmarked,
            sectionDayOffset: offset
        )
    }
```

Update `stamped` (line 234):

```swift
    func stamped(readItemIDs: Set<String>, bookmarkItemIDs: Set<String>) -> FeedItem {
        FeedItem(
            id: id, sourceTitle: sourceTitle, sourceURL: sourceURL, category: category,
            title: title, excerpt: excerpt, url: url, imageURL: imageURL,
            publishedAt: publishedAt, audioURL: audioURL, duration: duration,
            region: region,
            language: language,
            updatedAt: updatedAt,
            authors: authors,
            itemCategories: itemCategories,
            rights: rights,
            attribution: attribution,
            enclosures: enclosures,
            languageFromFeed: languageFromFeed,
            alternateLinks: alternateLinks,
            isRead: readItemIDs.contains(id),
            isBookmarked: bookmarkItemIDs.contains(id),
            sectionDayOffset: sectionDayOffset
        )
    }
```

- [ ] **Step 5: Verify project compiles**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add feedmine/Models/FeedItem.swift
git commit -m "feat: expand FeedItem with metadata fields and ParsedItemMetadata

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Update FeedFetchResult and FeedFetchBatch for new outcome model

**Files:**
- Modify: `feedmine/Models/FeedFetchResult.swift`
- Modify: `feedmine/Models/FeedFetchBatch.swift`

**Interfaces:**
- Consumes: `FeedFetchOutcome`, `FetchHTTPResult` (from Task 2), `HTTPValidators` (from Task 1)
- Produces: Updated `FeedFetchResult` with outcome-based API, updated `FeedFetchBatch` with new counters

- [ ] **Step 1: Update FeedFetchResult.swift**

Replace the entire file with a version that uses the types from Task 2:

```swift
import Foundation

/// Backward-compatible status for code that only needs a simple pass/fail signal.
enum FeedFetchStatus: Sendable, Equatable, CaseIterable {
    case success
    case empty
    case failed
}

struct FeedFetchResult: Sendable {
    let source: FeedSource
    let items: [FeedItem]
    let outcome: FeedFetchOutcome

    /// Convenience status for backward compatibility during migration.
    var status: FeedFetchStatus {
        switch outcome {
        case .modifiedWithNewItems: return .success
        case .modifiedWithoutNewItems: return .empty
        case .notModified: return .success  // not a failure
        case .failed: return .failed
        case .throttled: return .failed     // temporary block → treat as failed
        }
    }
}
```

- [ ] **Step 2: Update FeedFetchBatch.swift**

Replace `sourceStatuses` with `sourceOutcomes` and add new counters:

```swift
import Foundation

struct FeedFetchBatch: Sendable {
    let items: [FeedItem]
    let fetchedSourceCount: Int      // sources that produced new items
    let failedSourceCount: Int       // sources that failed (network/parse)
    let emptySourceCount: Int        // sources with zero items but 200 OK
    let notModifiedCount: Int        // sources that returned 304
    let throttledCount: Int          // sources that returned 429/503
    /// Per-source outcome, keyed by source URL.
    let sourceOutcomes: [String: FeedFetchOutcome]
}
```

- [ ] **Step 3: Fix all callers of FeedFetchBatch that reference sourceStatuses**

Search for `sourceStatuses` across the project and update to `sourceOutcomes`:

```bash
grep -rn "sourceStatuses" feedmine/ --include="*.swift"
```

Each occurrence needs updating. In `RSSFetcher.swift` `fetchAll()` and `fetchStarter()`, update the property name. In `FeedStore.swift`, update all references.

For now, verify the count:
Run: `grep -rn "sourceStatuses" feedmine/ --include="*.swift" | wc -l`

Expected: non-zero (we'll fix these in Task 5 when refactoring RSSFetcher)

- [ ] **Step 4: Verify project compiles**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Note: May have errors from sourceStatuses references — that's expected, will be resolved in Task 5.

- [ ] **Step 5: Commit**

```bash
git add feedmine/Models/FeedFetchResult.swift feedmine/Models/FeedFetchBatch.swift
git commit -m "feat: update FeedFetchResult and FeedFetchBatch for new outcome model

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Create FeedHTTPSync actor

**Files:**
- Create: `feedmine/Services/FeedHTTPSync.swift`

**Interfaces:**
- Consumes: `FeedSource` (existing), `HTTPValidators` (from Task 1), `FetchHTTPResult`, `HTTPOutcome` (from Task 2)
- Produces: `FeedHTTPSync` actor with `fetch(_:validators:) -> FetchHTTPResult`

- [ ] **Step 1: Create FeedHTTPSync.swift**

```swift
import Foundation

/// Actor responsible for all HTTP-level feed fetching semantics:
/// conditional GET (ETag/If-None-Match, Last-Modified/If-Modified-Since),
/// 304 Not Modified handling, Cache-Control/Expires extraction,
/// Retry-After parsing, and redirect canonical URL resolution.
actor FeedHTTPSync {
    private let session: URLSession

    /// Shared headers for all feed requests.
    private static let requestHeaders: [String: String] = [
        "User-Agent": "FeedMine/1.0 (https://feedmine.app/bot)",
        "Accept": "application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml;q=0.9"
    ]

    init() {
        let cache = URLCache(memoryCapacity: 4_194_304, diskCapacity: 20_971_520)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = cache
        config.httpAdditionalHeaders = Self.requestHeaders
        self.session = URLSession(configuration: config)
    }

    /// Fetch a feed with conditional GET semantics.
    /// - Parameters:
    ///   - source: The feed source to fetch.
    ///   - validators: Previously-stored HTTP validators for this source.
    /// - Returns: The HTTP result with (possibly empty) data, outcome, and updated validators.
    func fetch(_ source: FeedSource, validators: HTTPValidators) async -> FetchHTTPResult {
        guard !Task.isCancelled else {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(CancellationError()),
                updatedValidators: validators,
                canonicalURL: nil
            )
        }

        guard let url = URL(string: source.url) else {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(URLError(.badURL)),
                updatedValidators: validators,
                canonicalURL: nil
            )
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        // Conditional GET headers
        if let etag = validators.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return FetchHTTPResult(
                    data: nil,
                    outcome: .failed(URLError(.badServerResponse)),
                    updatedValidators: validators,
                    canonicalURL: nil
                )
            }

            var updated = validators
            updated.lastFetchAt = Date()

            switch httpResponse.statusCode {
            case 200:
                updated = extractValidators(from: httpResponse, into: updated)
                let canonicalURL = httpResponse.url?.absoluteString
                return FetchHTTPResult(
                    data: data,
                    outcome: .success(data),
                    updatedValidators: updated,
                    canonicalURL: canonicalURL
                )

            case 304:
                updated = extractValidators(from: httpResponse, into: updated)
                updated.lastOutcome = .notModified
                return FetchHTTPResult(
                    data: nil,
                    outcome: .notModified,
                    updatedValidators: updated,
                    canonicalURL: nil
                )

            case 429, 503:
                let retryAfter = parseRetryAfter(from: httpResponse)
                updated.retryAfter = retryAfter
                updated.lastOutcome = .throttled
                return FetchHTTPResult(
                    data: nil,
                    outcome: .throttled(until: retryAfter),
                    updatedValidators: updated,
                    canonicalURL: nil
                )

            case 301, 302, 307, 308:
                // Followed automatically by URLSession. Record canonical URL.
                let canonicalURL = httpResponse.url?.absoluteString
                // Re-fetch is handled by URLSession's redirect — data is the final response.
                // If we got here, the final response was 200 and data is available.
                updated = extractValidators(from: httpResponse, into: updated)
                updated.canonicalURL = canonicalURL
                return FetchHTTPResult(
                    data: data,
                    outcome: .success(data),
                    updatedValidators: updated,
                    canonicalURL: canonicalURL
                )

            default:
                updated.lastOutcome = .failed
                return FetchHTTPResult(
                    data: nil,
                    outcome: .failed(URLError(.badServerResponse)),
                    updatedValidators: updated,
                    canonicalURL: nil
                )
            }

        } catch is CancellationError {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(CancellationError()),
                updatedValidators: validators,
                canonicalURL: nil
            )
        } catch let error as URLError where error.code == .cancelled {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(error),
                updatedValidators: validators,
                canonicalURL: nil
            )
        } catch {
            var updated = validators
            updated.lastFetchAt = Date()
            updated.lastOutcome = .failed
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(error),
                updatedValidators: updated,
                canonicalURL: nil
            )
        }
    }

    // MARK: - Private

    /// Extract HTTP validators from a 200/304 response into the mutable validators struct.
    private func extractValidators(from response: HTTPURLResponse, into validators: HTTPValidators) -> HTTPValidators {
        var v = validators

        if let etag = response.value(forHTTPHeaderField: "ETag") {
            v.etag = etag
        }
        if let lastMod = response.value(forHTTPHeaderField: "Last-Modified") {
            v.lastModified = lastMod
        }
        if let cacheControl = response.value(forHTTPHeaderField: "Cache-Control") {
            v.cacheControl = HTTPValidators.ParsedCacheControl.parse(cacheControl)
        }
        if let expiresStr = response.value(forHTTPHeaderField: "Expires") {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            v.expires = formatter.date(from: expiresStr)
        }

        return v
    }

    /// Parse Retry-After header: either seconds or HTTP-date.
    private func parseRetryAfter(from response: HTTPURLResponse) -> Date {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else {
            return Date().addingTimeInterval(60) // default 60s
        }

        // Try seconds first
        if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) {
            return Date().addingTimeInterval(seconds)
        }

        // Try HTTP-date
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let date = formatter.date(from: header) {
            return date
        }

        return Date().addingTimeInterval(60) // unparseable → default 60s
    }
}
```

- [ ] **Step 2: Verify project compiles**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (may have warnings about unused FetchOutcome.swift since it's duplicated in FeedFetchResult.swift — remove FetchOutcome.swift in next step)

- [ ] **Step 3: Verify project compiles**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/FeedHTTPSync.swift
git rm feedmine/Models/FetchOutcome.swift 2>/dev/null
git commit -m "feat: create FeedHTTPSync actor with conditional GET support

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Refactor RSSFetcher to use FeedHTTPSync

**Files:**
- Modify: `feedmine/Services/RSSFetcher.swift`

**Interfaces:**
- Consumes: `FeedHTTPSync` (from Task 5), `HTTPValidators` (from Task 1), `FeedFetchOutcome` (from Task 4)
- Produces: `FeedFetchResult` with new outcome model, metadata extraction, WebSub/cloud detection

- [ ] **Step 1: Add FeedHTTPSync dependency and new method signatures**

At the top of RSSFetcher, after `private let starterSession`, add:

```swift
    private let httpSync: FeedHTTPSync
```

In `init()`, after `self.starterSession = ...`, add:

```swift
        self.httpSync = FeedHTTPSync()
```

Replace the existing `fetch(_:)` and `fetch(_:using:)` methods with:

```swift
    /// Fetch and parse a single feed with conditional GET support.
    func fetch(_ source: FeedSource, validators: HTTPValidators = HTTPValidators()) async -> FeedFetchResult {
        guard !Task.isCancelled else {
            return FeedFetchResult(source: source, items: [], outcome: .failed(CancellationError()))
        }

        let httpResult = await httpSync.fetch(source, validators: validators)

        switch httpResult.outcome {
        case .notModified:
            return FeedFetchResult(
                source: source, items: [],
                outcome: .notModified
            )

        case .throttled(let until):
            return FeedFetchResult(
                source: source, items: [],
                outcome: .throttled(until: until)
            )

        case .failed(let error):
            return FeedFetchResult(
                source: source, items: [],
                outcome: .failed(error)
            )

        case .success(let data):
            let parser = FeedParser(data: data)
            let result = parser.parse()

            switch result {
            case .success(let feed):
                let feedLevelMeta = extractFeedLevelMetadata(from: feed, source: source)
                var updatedValidators = httpResult.updatedValidators
                updatedValidators.ttl = feedLevelMeta.ttl
                updatedValidators.skipHours = feedLevelMeta.skipHours
                updatedValidators.skipDays = feedLevelMeta.skipDays
                updatedValidators.lastBuildDate = feedLevelMeta.lastBuildDate
                updatedValidators.capabilities = feedLevelMeta.capabilities
                if let canonicalURL = httpResult.canonicalURL {
                    updatedValidators.canonicalURL = canonicalURL
                }

                let items = extractItems(from: feed, source: source)
                if items.isEmpty {
                    updatedValidators.lastOutcome = .modifiedWithoutNewItems
                    Log.network.info("Empty feed: \(source.title)")
                    return FeedFetchResult(
                        source: source, items: [],
                        outcome: .modifiedWithoutNewItems(validators: updatedValidators)
                    )
                }
                let validated = await validateAudio(in: items)
                updatedValidators.lastOutcome = .modifiedWithNewItems
                return FeedFetchResult(
                    source: source, items: validated,
                    outcome: .modifiedWithNewItems(validated, validators: updatedValidators)
                )

            case .failure(let error):
                var failedValidators = httpResult.updatedValidators
                failedValidators.lastOutcome = .failed
                Log.network.error("Parse failure for \(source.title): \(error)")
                return FeedFetchResult(
                    source: source, items: [],
                    outcome: .failed(error)
                )
            }
        }
    }
```

Remove the old `private func fetch(_:using:)` method entirely.

- [ ] **Step 2: Update fetchAll() to use new outcome model**

In `fetchAll()`, replace the switch on `result.status` with `result.outcome`:

```swift
                sourceOutcomes[result.source.url] = result.outcome
                switch result.outcome {
                case .modifiedWithNewItems(let items, _):
                    fetchedSourceCount += 1
                    allItems.append(contentsOf: items)
                case .modifiedWithoutNewItems:
                    emptySourceCount += 1
                case .notModified:
                    notModifiedCount += 1
                case .failed:
                    failedSourceCount += 1
                case .throttled:
                    throttledCount += 1
                }
```

Update the `FeedFetchBatch` construction at the end of `fetchAll()`:

```swift
        return FeedFetchBatch(
            items: allItems,
            fetchedSourceCount: fetchedSourceCount,
            failedSourceCount: failedSourceCount,
            emptySourceCount: emptySourceCount,
            notModifiedCount: notModifiedCount,
            throttledCount: throttledCount,
            sourceOutcomes: sourceOutcomes
        )
```

Add local counters at the top of `fetchAll()`:

```swift
        var notModifiedCount = 0
        var throttledCount = 0
```

- [ ] **Step 3: Update fetchStarter() similarly**

Apply the same outcome switch changes to `fetchStarter()`. Add the two new counters. Update the `FeedFetchBatch` construction.

- [ ] **Step 4: Add the fetchStarterSource method that uses starter timeouts**

Replace `fetchStarterSource` with a version that still uses the starter session for faster timeouts but the same HTTP sync logic. Since `FeedHTTPSync` only uses the standard session, we need a second `FeedHTTPSync` instance with starter config, OR we can parameterize the timeout. For simplicity, add a `starterHTTPSync` instance:

In `init()`:
```swift
        // ... existing starter config ...
        self.starterHTTPSync = FeedHTTPSync()  // We'll make this configurable in a follow-up
```

And add property:
```swift
    private let starterHTTPSync: FeedHTTPSync
```

For now, both instances use the same config. The starter deadline in `fetchStarter` provides the fast-lane behavior.

- [ ] **Step 5: Verify project compiles**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add feedmine/Services/RSSFetcher.swift
git commit -m "feat: refactor RSSFetcher to use FeedHTTPSync with conditional GET

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Add feed-level metadata extraction (TTL, skipHours/Days, WebSub, Cloud)

**Files:**
- Modify: `feedmine/Services/RSSFetcher.swift`

**Interfaces:**
- Consumes: `FeedKit` types (RSSFeed, AtomFeed, JSONFeed), `SourceCapabilities` (from Task 1)
- Produces: `FeedLevelMetadata` struct, methods for extracting TTL/skipHours/skipDays/WebSub/Cloud

- [ ] **Step 1: Add FeedLevelMetadata struct to RSSFetcher.swift**

Below the existing imports, add a private struct:

```swift
/// Feed-level metadata extracted during parsing.
/// These are per-feed (not per-item) and go into source_health.
private struct FeedLevelMetadata {
    var ttl: Int?
    var skipHours: [Int]?
    var skipDays: [String]?
    var lastBuildDate: Date?
    var capabilities: SourceCapabilities?
}
```

- [ ] **Step 2: Add extractFeedLevelMetadata method**

```swift
    private func extractFeedLevelMetadata(from feed: Feed, source: FeedSource) -> FeedLevelMetadata {
        var meta = FeedLevelMetadata()

        switch feed {
        case .rss(let rssFeed):
            // TTL
            if let ttl = rssFeed.ttl, ttl > 0 {
                meta.ttl = ttl
            }

            // skipHours
            if let hours = rssFeed.skipHours?.hours, !hours.isEmpty {
                meta.skipHours = hours.compactMap { Int($0) }
            }

            // skipDays
            if let days = rssFeed.skipDays?.days, !days.isEmpty {
                meta.skipDays = days
            }

            // lastBuildDate
            meta.lastBuildDate = rssFeed.lastBuildDate

            // RSS Cloud
            var cloud: SourceCapabilities.RSSCloudEndpoints? = nil
            if let c = rssFeed.cloud {
                cloud = SourceCapabilities.RSSCloudEndpoints(
                    domain: c.attributes?.domain ?? "",
                    port: c.attributes?.port ?? 0,
                    path: c.attributes?.path ?? "",
                    registerProcedure: c.attributes?.registerProcedure ?? "",
                    protocolVersion: c.attributes?.protocol ?? ""
                )
            }

            // WebSub discovery for RSS (atom:link elements)
            let websub = discoverWebSubFromRSS(source: source)

            meta.capabilities = SourceCapabilities(
                websub: websub,
                cloud: cloud,
                hasPagination: false
            )

        case .atom(let atomFeed):
            // TTL: Atom uses Cache-Control headers (handled by FeedHTTPSync), but
            // some feeds put update frequency in generator or extension elements.
            // Not extracted from Atom feed body.

            // lastBuildDate / updated
            meta.lastBuildDate = atomFeed.updated

            // WebSub (rel="hub" and rel="self" in feed-level links)
            let hubLink = atomFeed.links?.first(where: {
                $0.attributes?.rel?.lowercased() == "hub"
            })
            let selfLink = atomFeed.links?.first(where: {
                $0.attributes?.rel?.lowercased() == "self"
            })
            let websub: SourceCapabilities.WebSubEndpoints? = if let hub = hubLink?.attributes?.href {
                SourceCapabilities.WebSubEndpoints(hub: hub, selfURL: selfLink?.attributes?.href)
            } else { nil }

            // Pagination (rel="next", "previous", "first", "last")
            let hasPagination = atomFeed.links?.contains(where: {
                let rel = $0.attributes?.rel?.lowercased() ?? ""
                return rel == "next" || rel == "previous" || rel == "first" || rel == "last"
            }) ?? false

            meta.capabilities = SourceCapabilities(
                websub: websub,
                cloud: nil,
                hasPagination: hasPagination
            )

        case .json(let jsonFeed):
            // WebSub (JSON Feed hubs)
            let firstHub = jsonFeed.hubs?.first
            let websub: SourceCapabilities.WebSubEndpoints? = if let hub = firstHub?.url {
                SourceCapabilities.WebSubEndpoints(hub: hub, selfURL: source.url)
            } else { nil }

            meta.capabilities = SourceCapabilities(
                websub: websub,
                cloud: nil,
                hasPagination: false
            )
        }

        return meta
    }

    /// Discover WebSub endpoints from RSS feed's atom:link elements.
    /// FeedKit doesn't expose these natively, so we parse the raw XML.
    private func discoverWebSubFromRSS(source: FeedSource) -> SourceCapabilities.WebSubEndpoints? {
        // WebSub in RSS is declared via atom:link elements.
        // FeedKit 9.x may expose these via rssFeed.namespaces or similar.
        // For now, return nil — a follow-up can add regex-based extraction
        // from raw XML if FeedKit doesn't expose these links.
        // The Atom and JSON Feed paths are already covered.
        return nil
    }
```

- [ ] **Step 3: Verify project compiles**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/RSSFetcher.swift
git commit -m "feat: add feed-level metadata extraction (TTL, skipHours, WebSub, Cloud)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Add item-level metadata extraction for all three feed formats

**Files:**
- Modify: `feedmine/Services/RSSFetcher.swift`

**Interfaces:**
- Consumes: `FeedKit` item types, `ParsedItemMetadata` (from Task 3)
- Produces: Extended `extractItems` that populates authors, categories, rights, attribution, enclosures, language, alternateLinks, publishedAt, updatedAt

- [ ] **Step 1: Add helper methods for metadata extraction**

Add these private methods to RSSFetcher:

```swift
    // MARK: - Metadata helpers

    private func extractRSSAuthors(from item: RSSFeedItem) -> [FeedItemAuthor]? {
        var authors: [FeedItemAuthor] = []
        if let author = item.author, !author.isEmpty {
            // RSS author is often just a string — parse name if it looks like "Name <email>"
            if let emailStart = author.firstIndex(of: "<"),
               let emailEnd = author.firstIndex(of: ">"),
               emailStart < emailEnd {
                let name = String(author[..<emailStart]).trimmingCharacters(in: .whitespaces)
                let email = String(author[author.index(after: emailStart)..<emailEnd])
                authors.append(FeedItemAuthor(name: name.isEmpty ? nil : name, email: email, uri: nil))
            } else {
                authors.append(FeedItemAuthor(name: author, email: nil, uri: nil))
            }
        }
        if let itunesAuthor = item.iTunes?.iTunesAuthor, !itunesAuthor.isEmpty {
            // Avoid duplicates
            if !authors.contains(where: { $0.name == itunesAuthor }) {
                authors.append(FeedItemAuthor(name: itunesAuthor, email: nil, uri: nil))
            }
        }
        return authors.isEmpty ? nil : authors
    }

    private func extractRSSCategories(from item: RSSFeedItem) -> [FeedItemCategory]? {
        guard let cats = item.categories, !cats.isEmpty else { return nil }
        return cats.compactMap { cat in
            guard let term = cat.attributes?.term ?? cat.value, !term.isEmpty else { return nil }
            return FeedItemCategory(term: term, scheme: cat.attributes?.domain, label: nil)
        }
    }

    private func extractRSSAttribution(from item: RSSFeedItem) -> FeedItemAttribution? {
        guard let src = item.source?.value, !src.isEmpty else { return nil }
        return FeedItemAttribution(
            title: src,
            url: item.source?.attributes?.url,
            feedURL: nil
        )
    }

    private func extractRSSEnclosures(from item: RSSFeedItem, source: FeedSource) -> [FeedEnclosure]? {
        var enclosures: [FeedEnclosure] = []

        // Standard enclosure
        if let enc = item.enclosure?.attributes, let url = enc.url, !url.isEmpty {
            enclosures.append(FeedEnclosure(
                url: FeedItem.resolvedMediaURL(from: url, baseURL: source.url)?.absoluteString ?? url,
                mimeType: enc.type,
                length: enc.length.flatMap(Int64.init),
                duration: nil,
                medium: classifyMedium(mimeType: enc.type, url: url)
            ))
        }

        // Media RSS contents
        for media in (item.media?.mediaContents ?? []) {
            guard let attr = media.attributes, let url = attr.url, !url.isEmpty else { continue }
            enclosures.append(FeedEnclosure(
                url: FeedItem.resolvedMediaURL(from: url, baseURL: source.url)?.absoluteString ?? url,
                mimeType: attr.type,
                length: attr.fileSize.flatMap(Int64.init),
                duration: attr.duration.map(TimeInterval.init),
                medium: attr.medium ?? classifyMedium(mimeType: attr.type, url: url)
            ))
        }

        return enclosures.isEmpty ? nil : enclosures
    }

    private func extractAtomAuthors(from entry: AtomFeedEntry) -> [FeedItemAuthor]? {
        guard let authors = entry.authors, !authors.isEmpty else { return nil }
        return authors.map { author in
            FeedItemAuthor(name: author.name, email: author.email, uri: author.uri)
        }
    }

    private func extractAtomCategories(from entry: AtomFeedEntry) -> [FeedItemCategory]? {
        guard let cats = entry.categories, !cats.isEmpty else { return nil }
        return cats.compactMap { cat in
            guard let term = cat.attributes?.term, !term.isEmpty else { return nil }
            return FeedItemCategory(term: term, scheme: cat.attributes?.scheme, label: cat.attributes?.label)
        }
    }

    private func extractAtomAttribution(from entry: AtomFeedEntry) -> FeedItemAttribution? {
        guard let attrs = entry.source?.attributes else { return nil }
        let title = attrs.title
        let url = attrs.links?.first(where: {
            ($0.attributes?.rel?.lowercased() ?? "") == "self" || ($0.attributes?.rel?.lowercased() ?? "") == "alternate"
        })?.attributes?.href
        return FeedItemAttribution(title: title, url: url, feedURL: attrs.links?.first(where: {
            ($0.attributes?.rel?.lowercased() ?? "") == "self"
        })?.attributes?.href)
    }

    private func extractAtomEnclosures(from entry: AtomFeedEntry, source: FeedSource) -> [FeedEnclosure]? {
        guard let links = entry.links, !links.isEmpty else { return nil }
        let enclosures = links.compactMap { link -> FeedEnclosure? in
            guard let href = link.attributes?.href, !href.isEmpty else { return nil }
            return FeedEnclosure(
                url: FeedItem.resolvedMediaURL(from: href, baseURL: source.url)?.absoluteString ?? href,
                mimeType: link.attributes?.type,
                length: link.attributes?.length.flatMap(Int64.init),
                duration: nil,
                medium: classifyMedium(mimeType: link.attributes?.type, url: href)
            )
        }
        return enclosures.isEmpty ? nil : enclosures
    }

    private func extractAtomAlternateLinks(from entry: AtomFeedEntry, source: FeedSource) -> [FeedAlternateLink]? {
        guard let links = entry.links, !links.isEmpty else { return nil }
        let alternates = links.compactMap { link -> FeedAlternateLink? in
            guard let href = link.attributes?.href, !href.isEmpty else { return nil }
            let resolved = FeedItem.resolvedMediaURL(from: href, baseURL: source.url)?.absoluteString ?? href
            return FeedAlternateLink(
                url: resolved,
                mimeType: link.attributes?.type,
                language: link.attributes?.hreflang,
                rel: link.attributes?.rel
            )
        }
        return alternates.isEmpty ? nil : alternates
    }

    private func extractJSONAuthors(from jsonItem: JSONFeedItem) -> [FeedItemAuthor]? {
        var authors: [FeedItemAuthor] = []
        if let author = jsonItem.author {
            authors.append(FeedItemAuthor(name: author.name, email: nil, uri: author.url))
        }
        if let authorList = jsonItem.authors {
            for a in authorList {
                authors.append(FeedItemAuthor(name: a.name, email: nil, uri: a.url))
            }
        }
        return authors.isEmpty ? nil : authors
    }

    private func extractJSONCategories(from jsonItem: JSONFeedItem) -> [FeedItemCategory]? {
        guard let tags = jsonItem.tags, !tags.isEmpty else { return nil }
        return tags.map { FeedItemCategory(term: $0, scheme: nil, label: nil) }
    }

    private func extractJSONEnclosures(from jsonItem: JSONFeedItem, source: FeedSource) -> [FeedEnclosure]? {
        guard let attachments = jsonItem.attachments, !attachments.isEmpty else { return nil }
        let enclosures = attachments.compactMap { att -> FeedEnclosure? in
            guard let url = att.url, !url.isEmpty else { return nil }
            return FeedEnclosure(
                url: FeedItem.resolvedMediaURL(from: url, baseURL: source.url)?.absoluteString ?? url,
                mimeType: att.mimeType,
                length: att.sizeInBytes.flatMap(Int64.init),
                duration: att.durationInSeconds,
                medium: classifyMedium(mimeType: att.mimeType, url: url)
            )
        }
        return enclosures.isEmpty ? nil : enclosures
    }

    /// Classify an enclosure as audio/video/image based on MIME type and URL extension.
    private func classifyMedium(mimeType: String?, url: String) -> String? {
        let type = mimeType?.lowercased() ?? ""
        if type.hasPrefix("audio/") { return "audio" }
        if type.hasPrefix("video/") { return "video" }
        if type.hasPrefix("image/") { return "image" }
        let path = (URL(string: url)?.path ?? url).lowercased()
        let audioExts = ["mp3", "m4a", "m4b", "aac", "ogg", "oga", "opus", "wav", "flac"]
        let videoExts = ["mp4", "mov", "webm", "avi", "mkv"]
        let imageExts = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic"]
        if audioExts.contains(where: path.hasSuffix) { return "audio" }
        if videoExts.contains(where: path.hasSuffix) { return "video" }
        if imageExts.contains(where: path.hasSuffix) { return "image" }
        return nil
    }
```

- [ ] **Step 2: Update extractItems to populate metadata for each format**

Update the **RSS** section (inside the `.rss` case) — update the `makeItem` call to include metadata:

```swift
                case .rss(let rssFeed):
                    return (rssFeed.items ?? []).compactMap { item in
                        let audio = extractAudio(from: item, source: source)
                        let duration = extractDuration(from: item) ?? audio?.duration
                        let img = extractImageURL(from: item) ?? feedImage
                        let metadata = ParsedItemMetadata(
                            authors: extractRSSAuthors(from: item),
                            categories: extractRSSCategories(from: item),
                            rights: nil,
                            attribution: extractRSSAttribution(from: item),
                            enclosures: extractRSSEnclosures(from: item, source: source),
                            language: rssFeed.language,
                            alternateLinks: nil,
                            publishedAt: item.pubDate,
                            updatedAt: nil
                        )
                        return makeItem(
                            guid: item.guid?.value,
                            link: item.link,
                            title: item.title,
                            source: source,
                            itemSourceTitle: item.source?.value,
                            rawDescription: item.description,
                            rawContent: item.content?.contentEncoded,
                            imageURL: img,
                            audioURL: audio?.url,
                            duration: duration,
                            metadata: metadata
                        )
                    }
```

Update the **Atom** section:

```swift
                case .atom(let atomFeed):
                    return (atomFeed.entries ?? []).compactMap { entry in
                        let rawContent = entry.content?.value ?? entry.summary?.value ?? ""
                        let audio = extractAtomAudio(from: entry, source: source)
                        let entryLink = entry.links?.first(where: { link in
                            let rel = link.attributes?.rel?.lowercased()
                            let type = link.attributes?.type?.lowercased() ?? ""
                            return (rel == nil || rel == "alternate")
                                && !type.contains("atom")
                                && !type.contains("rss")
                        })?.attributes?.href
                            ?? entry.links?.first(where: {
                                $0.attributes?.rel?.lowercased() != "enclosure"
                            })?.attributes?.href
                        let img = bestMediaImageURL(from: entry.media)
                            ?? extractFirstImageFromHTML(rawContent)
                            ?? feedImage
                        let metadata = ParsedItemMetadata(
                            authors: extractAtomAuthors(from: entry),
                            categories: extractAtomCategories(from: entry),
                            rights: entry.rights,
                            attribution: extractAtomAttribution(from: entry),
                            enclosures: extractAtomEnclosures(from: entry, source: source),
                            language: entry.xmlLang ?? atomFeed.xmlLang,
                            alternateLinks: extractAtomAlternateLinks(from: entry, source: source),
                            publishedAt: entry.published,
                            updatedAt: entry.updated
                        )
                        return makeItem(
                            guid: entry.id,
                            link: entryLink ?? entry.id,
                            title: entry.title,
                            source: source,
                            rawDescription: entry.summary?.value ?? entry.content?.value,
                            rawContent: entry.content?.value,
                            imageURL: img,
                            audioURL: audio,
                            metadata: metadata
                        )
                    }
```

Update the **JSON Feed** section:

```swift
                case .json(let jsonFeed):
                    return (jsonFeed.items ?? []).compactMap { jsonItem in
                        let audio = extractJSONAudio(from: jsonItem, source: source)
                        let attachmentImage = jsonItem.attachments?.first { attachment in
                            Self.isSupportedRasterMIMEType(attachment.mimeType)
                        }?.url
                        let img = jsonItem.image ?? jsonItem.bannerImage ?? attachmentImage ?? feedImage
                        let metadata = ParsedItemMetadata(
                            authors: extractJSONAuthors(from: jsonItem),
                            categories: extractJSONCategories(from: jsonItem),
                            rights: nil,
                            attribution: nil,
                            enclosures: extractJSONEnclosures(from: jsonItem, source: source),
                            language: jsonFeed.language,
                            alternateLinks: nil,
                            publishedAt: jsonItem.datePublished,
                            updatedAt: jsonItem.dateModified
                        )
                        return makeItem(
                            guid: jsonItem.id,
                            link: jsonItem.url,
                            title: jsonItem.title,
                            source: source,
                            rawDescription: jsonItem.summary ?? jsonItem.contentText,
                            rawContent: jsonItem.contentHtml,
                            imageURL: img,
                            audioURL: audio?.url,
                            duration: audio?.duration,
                            metadata: metadata
                        )
                    }
```

- [ ] **Step 3: Update makeItem signature and body to use ParsedItemMetadata**

Replace the existing `makeItem` method signature to accept `metadata: ParsedItemMetadata`:

```swift
    private func makeItem(
        guid: String?,
        link: String?,
        title: String?,
        source: FeedSource,
        itemSourceTitle: String? = nil,
        rawDescription: String?,
        rawContent: String?,
        imageURL: String?,
        audioURL: String? = nil,
        duration: TimeInterval? = nil,
        metadata: ParsedItemMetadata = ParsedItemMetadata()
    ) -> FeedItem? {
        // ... existing validation and sanitization logic stays the same ...
        // ... but the FeedItem construction at the end adds the new fields:

        return FeedItem(
            id: id,
            sourceTitle: sanitizedSource,
            sourceURL: source.url,
            category: source.category,
            title: truncatedTitle,
            excerpt: excerpt,
            url: resolvedLink,
            imageURL: resolvedImageURL,
            publishedAt: metadata.publishedAt ?? publishedAt ?? Date(),
            audioURL: audioURL,
            duration: duration,
            region: source.region,
            language: metadata.language,   // Use feed-declared language when available
            updatedAt: metadata.updatedAt,
            authors: metadata.authors,
            itemCategories: metadata.categories,
            rights: metadata.rights,
            attribution: metadata.attribution,
            enclosures: metadata.enclosures,
            languageFromFeed: metadata.language,
            alternateLinks: metadata.alternateLinks
        )
    }
```

IMPORTANT: Keep all existing validation logic (title sanitization, excerpt extraction, image URL resolution, Google News detection) intact. Only change the final `FeedItem(...)` construction to include the new fields.

- [ ] **Step 4: Verify project compiles**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED
If there are compilation errors about `publishedAt` shadowing, rename the local variable — use `metadata.publishedAt ?? itemPubDate` pattern.

- [ ] **Step 5: Commit**

```bash
git add feedmine/Services/RSSFetcher.swift
git commit -m "feat: add item-level metadata extraction for RSS, Atom, and JSON Feed

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Create AdaptiveScheduler

**Files:**
- Create: `feedmine/Services/AdaptiveScheduler.swift`

**Interfaces:**
- Consumes: `FeedSource`, `FeedItem` (existing), `HTTPValidators` (from Task 1), `CadenceEstimator` (from Task 1), `FeedStore.normalizedLanguageCode` (existing)
- Produces: `AdaptiveScheduler` class with Gate + Strategy + diversity scoring

- [ ] **Step 1: Create AdaptiveScheduler.swift**

This is a large file. The key additions over SourceScheduler are:
1. Gate phase: `shouldSkip(source:validators:estimator:now:)`
2. Strategy selection: `shouldUseConditionalGet(validators:)`
3. `minimumInterval(validators:estimator:)` replaces the hardcoded 30-min timeFactor
4. `urgency(validators:estimator:now:)` replaces the linear timeFactor
5. `isSkipped(validators:now:)` for skipHours/skipDays

```swift
import Foundation

/// Scheduler that learns publication cadence and uses HTTP validators
/// to decide when and how to fetch each source.
@MainActor
final class AdaptiveScheduler {
    private(set) var lastFetchedAt: [String: Date] = [:]
    private(set) var consecutiveFailures: [String: Int] = [:]
    private var validators: [String: HTTPValidators] = [:]
    private var estimators: [String: CadenceEstimator] = [:]
    private var consumptionTimestamps: [Date] = []

    // MARK: - Public API

    func nextBatch(
        reservoir: [FeedItem],
        sourcesByRegion: [String: [FeedSource]],
        activeRegion: String?,
        activeCategory: String?,
        activeContentType: String? = nil,
        prioritySourceURLs: Set<String> = [],
        activeLanguages: Set<String> = [],
        minimumBatchSize: Int = 10,
        presetMultipliers: [String: Double] = [:]
    ) -> [FeedSource] {
        // 1. Determine scope
        let regions = activeRegion.map { [$0] } ?? Array(sourcesByRegion.keys)
        guard !regions.isEmpty else { return [] }

        // 2. Measure consumption (preserved from SourceScheduler)
        let bufferNeeded = estimatedBufferNeeded()
        let currentBuffer: Int
        if let ct = activeContentType {
            let matchingItems = reservoir.filter { item in
                switch ct {
                case "video": return item.isYouTube
                case "audio": return item.isPodcast
                case "text": return !item.isYouTube && !item.isPodcast
                default: return true
                }
            }
            currentBuffer = matchingItems.count
            let sourceBreadth = Set(matchingItems.map(\.sourceURL)).count
            guard currentBuffer < bufferNeeded
                || sourceBreadth < FeedStore.immediateFilteredSourceTarget else { return [] }
        } else {
            let textCount = reservoir.filter { !$0.isYouTube && !$0.isPodcast }.count
            let videoCount = reservoir.filter { $0.isYouTube }.count
            let audioCount = reservoir.filter { $0.isPodcast }.count
            let textTarget = max(bufferNeeded, 300)
            let videoTarget = max(bufferNeeded / 2, 50)
            let audioTarget = max(bufferNeeded / 2, 50)
            let textDeficit = max(textTarget - textCount, 0)
            let videoDeficit = max(videoTarget - videoCount, 0)
            let audioDeficit = max(audioTarget - audioCount, 0)
            let totalDeficit = textDeficit + videoDeficit + audioDeficit
            guard totalDeficit > 0 else { return [] }
            currentBuffer = bufferNeeded - Int(ceil(Double(totalDeficit) / 3.0))
        }

        // 3. Measure entropy (preserved)
        let urlToRegion: [String: String] = sourcesByRegion.flatMap { region, srcs in
            srcs.map { ($0.url, region) }
        }.reduce(into: [:]) { $0[$1.0] = $1.1 }

        let regionDistribution = distribution(of: reservoir, key: { urlToRegion[$0.sourceURL] ?? "unknown" })
        let categoryDistribution = distribution(of: reservoir, key: \.category)
        let regionWeights = sqrtWeights(for: sourcesByRegion)
        let allCategories = Set(sourcesByRegion.values.flatMap { $0 }.map(\.category))
        let idealRegionDist = normalize(regionWeights)
        let idealCategoryDist = normalize(Dictionary(uniqueKeysWithValues: allCategories.map { ($0, 1.0) }))
        let regionDeficits = deficits(ideal: idealRegionDist, actual: regionDistribution)
        let categoryDeficits = deficits(ideal: idealCategoryDist, actual: categoryDistribution)
        var finalCategoryDeficits = categoryDeficits
        if let cat = activeCategory {
            finalCategoryDeficits[cat] = max(finalCategoryDeficits[cat] ?? 0, 1.0)
        }

        let deficitNeeded = Int(ceil(Double(bufferNeeded - currentBuffer) / 3.0))
        let maxSelect = max(deficitNeeded, minimumBatchSize)

        // Phase 1: Priority sources (preserved)
        var selected: [FeedSource] = []
        var selectedURLs = Set<String>()
        selectedURLs.reserveCapacity(maxSelect)

        if !prioritySourceURLs.isEmpty {
            priorityLoop: for region in regions {
                guard let sources = sourcesByRegion[region] else { continue }
                for source in sources {
                    guard selected.count < maxSelect else { break priorityLoop }
                    guard prioritySourceURLs.contains(source.url) else { continue }
                    guard selectedURLs.insert(source.url).inserted else { continue }
                    guard Self.matches(source, contentType: activeContentType) else { continue }
                    if !activeLanguages.isEmpty {
                        let sourceLang = FeedStore.normalizedLanguageCode(
                            source.language.flatMap { $0.isEmpty ? nil : $0 }
                        )
                        if let sourceLang, !activeLanguages.contains(sourceLang) { continue }
                    }
                    lastFetchedAt.removeValue(forKey: source.url)
                    consecutiveFailures.removeValue(forKey: source.url)
                    selected.append(source)
                }
            }
        }

        // Phase 2: Fill remaining slots with adaptive scoring
        let remaining = maxSelect - selected.count
        if remaining > 0 {
            let now = Date()
            var scored: [(source: FeedSource, score: Double)] = []
            scored.reserveCapacity(sourcesByRegion.values.map(\.count).reduce(0, +))

            for region in regions {
                guard let sources = sourcesByRegion[region] else { continue }
                let regionDeficit = max(0, regionDeficits[region] ?? 0)
                for source in sources {
                    guard !selectedURLs.contains(source.url) else { continue }
                    guard Self.matches(source, contentType: activeContentType) else { continue }

                    let v = validators[source.url] ?? HTTPValidators()
                    let e = estimators[source.url] ?? CadenceEstimator()

                    // --- GATE: Skip if throttled, in skip window, or within min interval ---
                    if shouldSkip(source: source, validators: v, estimator: e, now: now) { continue }

                    // Existing failure backoff
                    let failures = consecutiveFailures[source.url] ?? 0
                    if failures >= 3 {
                        let backoff = pow(2.0, Double(failures - 2)) * 60
                        if let last = lastFetchedAt[source.url],
                           now.timeIntervalSince(last) < backoff { continue }
                    }

                    let catDeficit = max(0, finalCategoryDeficits[source.category] ?? 0)

                    // --- STRATEGY: conditional GET possible? (informational, not a gate) ---
                    let canUseConditional = shouldUseConditionalGet(validators: v)

                    let contentTypeBoost: Double = switch activeContentType {
                    case "video": source.isYouTube || source.mediaKind == .video ? 3.0 : 1.0
                    case "audio": source.mediaKind == .audio ? 3.0 : 1.0
                    case "text":  source.mediaKind == .video ? 0.3 : (source.mediaKind == .audio ? 0.3 : 1.0)
                    default:      source.isYouTube ? 2.0 : (source.mediaKind == .audio ? 2.0 : 1.0)
                    }

                    let sourceLang = FeedStore.normalizedLanguageCode(
                        source.language.flatMap { $0.isEmpty ? nil : $0 }
                    )
                    if !activeLanguages.isEmpty,
                       let sourceLang,
                       !activeLanguages.contains(sourceLang) { continue }
                    let languageBoost: Double = activeLanguages.isEmpty ? 1.0
                        : (sourceLang != nil ? 3.0 : 0.8)

                    // ADAPTIVE: urgency replaces hardcoded 30-min timeFactor
                    let u = urgency(validators: v, estimator: e, now: now)

                    let score = regionDeficit * catDeficit * u * contentTypeBoost * languageBoost
                        * (presetMultipliers[source.url] ?? 1.0)
                    let finalScore = max(score, 0.01) * Double.random(in: 0.98...1.02)
                    if finalScore > 0 { scored.append((source, finalScore)) }
                }
            }

            let diverse = AdaptiveScheduler.diverseSources(from: scored, limit: remaining)
            for source in diverse {
                guard selected.count < maxSelect else { break }
                guard selectedURLs.insert(source.url).inserted else { continue }
                selected.append(source)
            }
        }

        return selected
    }

    // MARK: - Gate & Strategy

    /// Whether this source should be skipped right now.
    private func shouldSkip(source: FeedSource, validators: HTTPValidators, estimator: CadenceEstimator, now: Date) -> Bool {
        // Hard block: Retry-After still active
        if let retryAfter = validators.retryAfter, now < retryAfter { return true }

        // skipHours / skipDays
        if isSkipped(validators: validators, now: now) { return true }

        // Within minimum interval?
        let minInterval = minimumInterval(validators: validators, estimator: estimator)
        if let last = lastFetchedAt[source.url] ?? validators.lastFetchAt {
            if now.timeIntervalSince(last) < minInterval { return true }
        }

        return false
    }

    /// Whether we have validators that enable a conditional GET.
    func shouldUseConditionalGet(validators: HTTPValidators) -> Bool {
        validators.etag != nil || validators.lastModified != nil
    }

    /// Minimum interval before next fetch based on all available signals.
    func minimumInterval(validators: HTTPValidators, estimator: CadenceEstimator) -> TimeInterval {
        // Cache-Control: no-store means we should always do a full GET (no min interval from cache)
        if validators.cacheControl?.noStore == true { return 0 }

        var candidates: [TimeInterval] = []
        if let maxAge = validators.cacheControl?.maxAge { candidates.append(maxAge) }
        if let ttl = validators.ttl { candidates.append(TimeInterval(ttl * 60)) }
        if let expires = validators.expires {
            let delta = expires.timeIntervalSinceNow
            if delta > 0 { candidates.append(delta) }
        }
        if estimator.confidence > 0.3 { candidates.append(estimator.minInterval) }
        return candidates.max() ?? 300  // default 5 min
    }

    /// Urgency ramps from 0 at minInterval to 1.0 at 2× minInterval,
    /// or spikes faster when past expected publication time.
    func urgency(validators: HTTPValidators, estimator: CadenceEstimator, now: Date) -> Double {
        let minInterval = minimumInterval(validators: validators, estimator: estimator)
        let elapsed = now.timeIntervalSince(validators.lastFetchAt ?? .distantPast)

        if estimator.confidence > 0.5 && estimator.lastPublication > .distantPast {
            let expectedNext = estimator.lastPublication.addingTimeInterval(estimator.publicationInterval)
            if now > expectedNext {
                return min(1.0, 0.5 + now.timeIntervalSince(expectedNext) / estimator.publicationInterval)
            }
        }

        let excess = elapsed - minInterval
        return min(1.0, max(0, excess / max(minInterval, 1)))
    }

    /// Check if the current time falls into a skipHours/skipDays window.
    func isSkipped(validators: HTTPValidators, now: Date) -> Bool {
        if let skipHours = validators.skipHours {
            let hour = Calendar.current.component(.hour, from: now)
            if skipHours.contains(hour) { return true }
        }
        if let skipDays = validators.skipDays {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            let dayName = formatter.string(from: now)
            if skipDays.contains(dayName) { return true }
        }
        return false
    }

    // MARK: - State Management

    static func matches(_ source: FeedSource, contentType: String?) -> Bool {
        switch contentType {
        case "video": return source.isYouTube || source.mediaKind == .video
        case "audio": return source.mediaKind == .audio
        case "text":  return !source.isYouTube && source.mediaKind != .video
            && source.mediaKind != .audio && source.mediaKind != .forum
        case "forum": return source.mediaKind == .forum
        default: return true
        }
    }

    func recordConsumption() {
        consumptionTimestamps.append(Date())
        let cutoff = Date().addingTimeInterval(-300)
        consumptionTimestamps = consumptionTimestamps.filter { $0 > cutoff }
    }

    func recordFetch(sourceURL: String, outcome: FeedFetchOutcome) {
        lastFetchedAt[sourceURL] = Date()

        switch outcome {
        case .modifiedWithNewItems(let items, let newValidators):
            consecutiveFailures[sourceURL] = 0
            validators[sourceURL] = newValidators
            if let latestItem = items.map(\.publishedAt).max() {
                estimators[sourceURL, default: CadenceEstimator()].recordPublication(latestItem)
            }
        case .modifiedWithoutNewItems(let newValidators):
            consecutiveFailures[sourceURL] = 0
            validators[sourceURL] = newValidators
            estimators[sourceURL, default: CadenceEstimator()].recordNoChange()
        case .notModified:
            consecutiveFailures[sourceURL] = 0
            estimators[sourceURL, default: CadenceEstimator()].recordNoChange()
        case .failed:
            consecutiveFailures[sourceURL, default: 0] += 1
        case .throttled(let until):
            validators[sourceURL, default: HTTPValidators()].retryAfter = until
        }
    }

    func prioritize(sourceURLs: [String]) {
        for url in sourceURLs {
            lastFetchedAt.removeValue(forKey: url)
            consecutiveFailures.removeValue(forKey: url)
        }
    }

    func remove(sourceURLs: [String]) {
        for url in sourceURLs {
            lastFetchedAt.removeValue(forKey: url)
            consecutiveFailures.removeValue(forKey: url)
            validators.removeValue(forKey: url)
            estimators.removeValue(forKey: url)
        }
    }

    // MARK: - Persistence hooks

    func loadHealth(url: String, lastFetchAt: Date, consecutiveFailures: Int) {
        if self.lastFetchedAt[url] == nil {
            self.lastFetchedAt[url] = lastFetchAt
        }
        if self.consecutiveFailures[url] == nil {
            self.consecutiveFailures[url] = consecutiveFailures
        }
    }

    func loadValidators(url: String, _ v: HTTPValidators) {
        if validators[url] == nil { validators[url] = v }
    }

    func loadEstimator(url: String, _ e: CadenceEstimator) {
        if estimators[url] == nil { estimators[url] = e }
    }

    struct HealthSnapshot {
        let lastFetchAt: Date
        let consecutiveFailures: Int
        let lastStatus: String?
        let lastItemCount: Int?
        let validators: HTTPValidators
        let estimator: CadenceEstimator
    }

    func healthSnapshot(for url: String, itemCount: Int? = nil) -> HealthSnapshot {
        HealthSnapshot(
            lastFetchAt: lastFetchedAt[url] ?? Date(timeIntervalSince1970: 0),
            consecutiveFailures: consecutiveFailures[url] ?? 0,
            lastStatus: consecutiveFailures[url, default: 0] > 0 ? "error" : "ok",
            lastItemCount: itemCount,
            validators: validators[url] ?? HTTPValidators(),
            estimator: estimators[url] ?? CadenceEstimator()
        )
    }

    // MARK: - Private (preserved from SourceScheduler)

    private func estimatedBufferNeeded() -> Int {
        let recent = consumptionTimestamps.filter { $0 > Date().addingTimeInterval(-120) }
        let rate = Double(recent.count) / 120.0
        let target = Int(rate * 180)
        return max(50, min(500, target))
    }

    nonisolated static func diverseSources(
        from scoredSources: [(source: FeedSource, score: Double)],
        limit: Int
    ) -> [FeedSource] {
        guard limit > 0, !scoredSources.isEmpty else { return [] }

        var pool = scoredSources.sorted {
            if $0.score == $1.score { return $0.source.url < $1.source.url }
            return $0.score > $1.score
        }
        var selected: [FeedSource] = []
        selected.reserveCapacity(min(limit, pool.count))
        var categoryCounts: [String: Int] = [:]
        var mediaCounts: [String: Int] = [:]
        var regionCounts: [String: Int] = [:]
        var lastCategory: String?

        while selected.count < limit, !pool.isEmpty {
            var bestIndex = pool.startIndex
            var bestRank = -Double.infinity

            for index in pool.indices {
                let candidate = pool[index]
                let source = candidate.source
                let categoryPenalty = 1.0 + Double(categoryCounts[source.category, default: 0]) * 1.85
                let mediaPenalty = 1.0 + Double(mediaCounts[source.mediaKind.rawValue, default: 0]) * 0.18
                let regionKey = diversityRegionKey(source.region)
                let regionPenalty = 1.0 + Double(regionCounts[regionKey, default: 0]) * 0.35
                let immediateRepeatPenalty = source.category == lastCategory ? 0.35 : 1.0
                let rank = candidate.score * immediateRepeatPenalty / categoryPenalty / mediaPenalty / regionPenalty

                if rank > bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }

            let source = pool.remove(at: bestIndex).source
            selected.append(source)
            categoryCounts[source.category, default: 0] += 1
            mediaCounts[source.mediaKind.rawValue, default: 0] += 1
            regionCounts[diversityRegionKey(source.region), default: 0] += 1
            lastCategory = source.category
        }

        return selected
    }

    private nonisolated static func diversityRegionKey(_ region: String) -> String {
        let parts = region.split(separator: "/")
        if parts.count >= 2, parts[0] == "countries" { return "countries/\(parts[1])" }
        if parts.count >= 2, parts[0] == "topic" { return "topic/\(parts[1])" }
        return region
    }

    private func distribution<T: Hashable>(of items: [FeedItem], key: (FeedItem) -> T) -> [T: Double] {
        guard !items.isEmpty else { return [:] }
        var counts: [T: Int] = [:]
        for item in items { counts[key(item), default: 0] += 1 }
        let total = Double(items.count)
        return counts.mapValues { Double($0) / total }
    }

    private func sqrtWeights(for sourcesByRegion: [String: [FeedSource]]) -> [String: Double] {
        sourcesByRegion.mapValues { sqrt(Double($0.count)) }
    }

    private func normalize(_ weights: [String: Double]) -> [String: Double] {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return weights }
        return weights.mapValues { $0 / total }
    }

    private func deficits(ideal: [String: Double], actual: [String: Double]) -> [String: Double] {
        var result: [String: Double] = [:]
        for (key, idealVal) in ideal {
            let actualVal = actual[key] ?? 0
            result[key] = idealVal - actualVal
        }
        return result
    }
}
```

- [ ] **Step 2: Verify project compiles**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/AdaptiveScheduler.swift
git commit -m "feat: create AdaptiveScheduler with cadence learning and HTTP-aware gating

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: DB migration — source_health v2 and feed_item new columns

**Files:**
- Modify: `feedmine/Services/FeedStore.swift`

**Interfaces:**
- Consumes: `HTTPValidators`, `CadenceEstimator` (from Task 1), `AdaptiveScheduler.HealthSnapshot` (from Task 9)
- Produces: Migration vN for source_health v2, migration vN+1 for feed_item new columns

- [ ] **Step 1: Find the existing source_health migration and register a new one**

Search for the existing `v3_source_health` migration in FeedStore.swift:
```bash
grep -n "v3_source_health\|source_health" feedmine/Services/FeedStore.swift | head -10
```

Read the migration registration area of FeedStore.swift to find the pattern for registering new migrations.

- [ ] **Step 2: Add source_health v2 migration**

Below the existing v3_source_health migration, add a new migration that ALTER TABLEs the new columns:

```swift
        migrator.registerMigration("vN_source_health_v2") { db in
            // Add HTTP validator columns to existing source_health table
            let columns: [(String, String)] = [
                ("etag", "TEXT"),
                ("last_modified", "TEXT"),
                ("cache_control_max_age", "REAL"),
                ("cache_control_no_cache", "INTEGER DEFAULT 0"),
                ("cache_control_no_store", "INTEGER DEFAULT 0"),
                ("cache_control_must_revalidate", "INTEGER DEFAULT 0"),
                ("expires", "INTEGER"),
                ("canonical_url", "TEXT"),
                ("last_outcome", "TEXT"),
                ("retry_after", "INTEGER"),
                ("ttl", "INTEGER"),
                ("skip_hours", "TEXT"),
                ("skip_days", "TEXT"),
                ("capabilities", "TEXT"),
                ("last_build_date", "INTEGER"),
                ("publication_interval", "REAL DEFAULT 3600"),
                ("publication_interval_confidence", "REAL DEFAULT 0.0"),
            ]
            for (name, type) in columns {
                try db.execute(sql: "ALTER TABLE source_health ADD COLUMN \(name) \(type)")
            }
        }
```

Replace `vN` with the correct next version number (check the last registered migration).

- [ ] **Step 3: Add feed_item new columns migration**

```swift
        migrator.registerMigration("vN+1_feed_item_metadata") { db in
            let columns: [(String, String)] = [
                ("updated_at", "INTEGER"),
                ("authors", "TEXT"),
                ("item_categories", "TEXT"),
                ("rights", "TEXT"),
                ("attribution_title", "TEXT"),
                ("attribution_url", "TEXT"),
                ("attribution_feed_url", "TEXT"),
                ("enclosures", "TEXT"),
                ("language_from_feed", "TEXT"),
                ("alternate_links", "TEXT"),
            ]
            for (name, type) in columns {
                try db.execute(sql: "ALTER TABLE feed_item ADD COLUMN \(name) \(type)")
            }

            // Rebuild FTS index to include new searchable columns
            try db.execute(sql: "DROP TABLE IF EXISTS feed_item_fts")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE feed_item_fts USING fts5(
                    title, excerpt, source_title, category,
                    authors, item_categories, rights,
                    content='feed_item', content_rowid='rowid'
                )
            """)
        }
```

- [ ] **Step 4: Update SourceHealthRecord to include new columns**

Add the new fields to the existing `SourceHealthRecord` struct:

```swift
    var etag: String?
    var lastModified: String?
    var cacheControlMaxAge: Double?
    var cacheControlNoCache: Bool
    var cacheControlNoStore: Bool
    var cacheControlMustRevalidate: Bool
    var expires: Date?
    var canonicalURL: String?
    var lastOutcome: String?
    var retryAfter: Date?
    var ttl: Int?
    var skipHours: String?       // JSON array
    var skipDays: String?        // JSON array
    var capabilities: String?    // JSON
    var lastBuildDate: Date?
    var publicationInterval: Double?
    var publicationIntervalConfidence: Double?
```

Update the `Column` enums or `init(row:)` / `encode(to:)` accordingly for GRDB.

- [ ] **Step 5: Update FeedItemRecord to include new fields**

Add the new columns to `FeedItemRecord` (search for this struct in FeedStore.swift):

```swift
    var updatedAt: Date?
    var authors: String?          // JSON array
    var itemCategories: String?   // JSON array
    var rights: String?
    var attributionTitle: String?
    var attributionURL: String?
    var attributionFeedURL: String?
    var enclosures: String?       // JSON array
    var languageFromFeed: String?
    var alternateLinks: String?   // JSON array
```

Update the conversion methods to/from `FeedItem`.

- [ ] **Step 6: Update persistence code to save/load validators and estimators**

In `FeedStore`, find where `loadHealth` is called and add validators/estimator loading:

```swift
            for record in records {
                scheduler.loadHealth(
                    url: record.url,
                    lastFetchAt: record.lastFetchAt,
                    consecutiveFailures: record.consecutiveFailures
                )
                // NEW: load validators and estimator from expanded health record
                let v = HTTPValidators(
                    etag: record.etag,
                    lastModified: record.lastModified,
                    cacheControl: record.cacheControlMaxAge.map { _ in
                        HTTPValidators.ParsedCacheControl(
                            maxAge: record.cacheControlMaxAge,
                            noCache: record.cacheControlNoCache,
                            noStore: record.cacheControlNoStore,
                            mustRevalidate: record.cacheControlMustRevalidate
                        )
                    },
                    expires: record.expires,
                    canonicalURL: record.canonicalURL,
                    lastFetchAt: record.lastFetchAt,
                    lastOutcome: record.lastOutcome.flatMap(HTTPValidators.FetchOutcomeKind.init(rawValue:)),
                    retryAfter: record.retryAfter,
                    ttl: record.ttl,
                    skipHours: record.skipHours.flatMap { decodeJSON($0) },
                    skipDays: record.skipDays.flatMap { decodeJSON($0) },
                    lastBuildDate: record.lastBuildDate,
                    capabilities: record.capabilities.flatMap { decodeJSON($0) },
                    publicationInterval: record.publicationInterval,
                    publicationIntervalConfidence: record.publicationIntervalConfidence
                )
                scheduler.loadValidators(url: record.url, v)
                let estimator = CadenceEstimator(
                    publicationInterval: record.publicationInterval ?? 3600,
                    confidence: record.publicationIntervalConfidence ?? 0,
                    lastPublication: record.lastFetchAt ?? .distantPast
                )
                scheduler.loadEstimator(url: record.url, estimator)
            }
```

Add a helper:
```swift
    private func decodeJSON<T: Decodable>(_ text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
```

- [ ] **Step 7: Update health save code**

Find where `healthSnapshot` is called and update to save the new columns. The INSERT/UPDATE must include all new columns.

- [ ] **Step 8: Verify project compiles and existing tests pass**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:feedmineTests/SourceSchedulerTests 2>&1 | tail -30`

Expected: Some tests may fail due to scheduler type change. Update tests in the next task.

- [ ] **Step 9: Commit**

```bash
git add feedmine/Services/FeedStore.swift
git commit -m "feat: add DB migrations for source_health v2 and feed_item metadata columns

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 11: Wire AdaptiveScheduler into FeedStore and fix all callers

**Files:**
- Modify: `feedmine/Services/FeedStore.swift`

**Interfaces:**
- Consumes: `AdaptiveScheduler` (from Task 9), `FeedFetchOutcome` (from Task 4)
- Produces: Updated FeedStore that uses AdaptiveScheduler and handles all outcome cases

- [ ] **Step 1: Replace SourceScheduler with AdaptiveScheduler in FeedStore**

Change the property declaration from:
```swift
let scheduler: SourceScheduler
```
To:
```swift
let scheduler: AdaptiveScheduler
```

And the initialization from:
```swift
self.scheduler = SourceScheduler()
```
To:
```swift
self.scheduler = AdaptiveScheduler()
```

- [ ] **Step 2: Update all recordFetch calls to pass outcome instead of success bool**

Search for `scheduler.recordFetch(sourceURL:` across FeedStore.swift and update each call.

Old pattern:
```swift
scheduler.recordFetch(sourceURL: url, success: status != .failed)
```

New pattern:
```swift
scheduler.recordFetch(sourceURL: url, outcome: result.outcome)
```

- [ ] **Step 3: Update all references to sourceStatuses → sourceOutcomes**

Search for `sourceStatuses` in FeedStore.swift and update to `sourceOutcomes`.

Also update any switch/case that matched on `FeedFetchStatus` to match on `FeedFetchOutcome` instead.

- [ ] **Step 4: Handle new outcome cases in fetch processing**

Where fetch results are processed, ensure all 5 cases are handled:

```swift
switch outcome {
case .notModified:
    // No change — update validators in health, no items to process
    break
case .modifiedWithNewItems(let items, let validators):
    // Process items, persist, update validators
    break
case .modifiedWithoutNewItems(let validators):
    // Feed changed but no items — update validators only
    break
case .failed(let error):
    // Log error, increment failure count
    break
case .throttled(let until):
    // Will retry after `until`
    break
}
```

- [ ] **Step 5: Implement mergeItems for Atom entry update-by-ID**

Add a method to FeedStore:

```swift
    /// Merge incoming items with existing ones by ID.
    /// When an Atom entry has the same id but newer updated date, replace the old.
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

Call this in the persistence pipeline before writing to DB.

- [ ] **Step 6: Verify project compiles**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -20`

Fix any compilation errors. There will likely be many call sites to update. Work through them systematically.

- [ ] **Step 7: Commit**

```bash
git add feedmine/Services/FeedStore.swift feedmine/Services/SourceScheduler.swift
git commit -m "feat: wire AdaptiveScheduler into FeedStore, handle all outcome cases

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 12: Update existing tests and add AdaptiveScheduler tests

**Files:**
- Modify: `feedmineTests/SourceSchedulerTests.swift`
- Create: `feedmineTests/AdaptiveSchedulerTests.swift`

**Interfaces:**
- Consumes: `AdaptiveScheduler` (from Task 9), `HTTPValidators` (from Task 1)
- Produces: Updated test suite

- [ ] **Step 1: Update SourceSchedulerTests to use AdaptiveScheduler**

Replace `SourceScheduler()` with `AdaptiveScheduler()` in all tests. The diversity scoring tests should still pass since AdaptiveScheduler preserves the `diverseSources` method.

The `recordFetch` calls need updating:
```swift
// Old
s.recordFetch(sourceURL: url, success: true)
// New
s.recordFetch(sourceURL: url, outcome: .notModified)  // or appropriate outcome
```

- [ ] **Step 2: Create AdaptiveSchedulerTests.swift**

```swift
import XCTest
@testable import feedmine

@MainActor
final class AdaptiveSchedulerTests: XCTestCase {

    // MARK: - Gate Tests

    func testRetryAfterBlocksSource() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        v.retryAfter = Date().addingTimeInterval(300) // 5 min from now
        s.loadValidators(url: "https://a.com/feed", v)

        let sources: [String: [FeedSource]] = [
            "global": [FeedSource(title: "A", url: "https://a.com/feed", category: "Tech", region: "global")]
        ]
        // Empty reservoir → normally would fetch, but Retry-After blocks
        let batch = s.nextBatch(reservoir: [], sourcesByRegion: sources, activeRegion: nil, activeCategory: nil)
        XCTAssertTrue(batch.isEmpty, "Source with active Retry-After must be skipped")
    }

    func testSkipHoursBlocksSource() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        let currentHour = Calendar.current.component(.hour, from: Date())
        v.skipHours = [currentHour] // block current hour
        s.loadValidators(url: "https://a.com/feed", v)

        let sources: [String: [FeedSource]] = [
            "global": [FeedSource(title: "A", url: "https://a.com/feed", category: "Tech", region: "global")]
        ]
        let batch = s.nextBatch(reservoir: [], sourcesByRegion: sources, activeRegion: nil, activeCategory: nil)
        XCTAssertTrue(batch.isEmpty, "Source in skipHours window must be skipped")
    }

    func testSkipDaysBlocksSource() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        let today = formatter.string(from: Date())
        v.skipDays = [today]
        s.loadValidators(url: "https://a.com/feed", v)

        let sources: [String: [FeedSource]] = [
            "global": [FeedSource(title: "A", url: "https://a.com/feed", category: "Tech", region: "global")]
        ]
        let batch = s.nextBatch(reservoir: [], sourcesByRegion: sources, activeRegion: nil, activeCategory: nil)
        XCTAssertTrue(batch.isEmpty, "Source in skipDays window must be skipped")
    }

    func testMinimumIntervalBlocksSource() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        v.lastFetchAt = Date() // just fetched now
        v.ttl = 60 // 60 minute TTL
        s.loadValidators(url: "https://a.com/feed", v)

        let sources: [String: [FeedSource]] = [
            "global": [FeedSource(title: "A", url: "https://a.com/feed", category: "Tech", region: "global")]
        ]
        let batch = s.nextBatch(reservoir: [], sourcesByRegion: sources, activeRegion: nil, activeCategory: nil)
        XCTAssertTrue(batch.isEmpty, "Source within min interval must be skipped")
    }

    // MARK: - Strategy Tests

    func testShouldUseConditionalGetWhenEtagExists() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        v.etag = "\"abc123\""
        XCTAssertTrue(s.shouldUseConditionalGet(validators: v))
    }

    func testShouldNotUseConditionalGetWithoutValidators() {
        let s = AdaptiveScheduler()
        XCTAssertFalse(s.shouldUseConditionalGet(validators: HTTPValidators()))
    }

    // MARK: - Urgency Tests

    func testUrgencyZeroAtMinInterval() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        v.lastFetchAt = Date().addingTimeInterval(-300) // 5 min ago (exactly min interval)
        let e = CadenceEstimator()
        let u = s.urgency(validators: v, estimator: e, now: Date())
        XCTAssertEqual(u, 0, accuracy: 0.01)
    }

    func testUrgencyOneAtDoubleMinInterval() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        v.lastFetchAt = Date().addingTimeInterval(-600) // 10 min ago (2× default min)
        let e = CadenceEstimator()
        let u = s.urgency(validators: v, estimator: e, now: Date())
        XCTAssertEqual(u, 1.0, accuracy: 0.01)
    }

    func testUrgencySpikesAfterExpectedPublication() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        v.lastFetchAt = Date().addingTimeInterval(-4000)
        var e = CadenceEstimator(publicationInterval: 3600, confidence: 0.8, lastPublication: Date().addingTimeInterval(-3600))
        // Expected next publication = 1h after last = now, but now > expected
        // So urgency should spike above 0.5
        let u = s.urgency(validators: v, estimator: e, now: Date().addingTimeInterval(-3500))
        // Actually let's use a simpler test:
        // lastPublication = 2 hours ago, publicationInterval = 1 hour
        // expectedNext = 1 hour ago, now = now → past expected → urgency > 0.5
        let now = Date()
        e = CadenceEstimator(publicationInterval: 3600, confidence: 0.8, lastPublication: now.addingTimeInterval(-7200))
        v.lastFetchAt = now.addingTimeInterval(-7200)
        let u2 = s.urgency(validators: v, estimator: e, now: now)
        XCTAssertGreaterThan(u2, 0.5)
    }

    // MARK: - Diversity (preserved from SourceScheduler)

    func testDiverseSourcesAvoidsClustering() {
        let scored: [(source: FeedSource, score: Double)] = [
            FeedSource(title: "C1", url: "https://c1.com/feed", category: "Coffee", region: "global"),
            FeedSource(title: "C2", url: "https://c2.com/feed", category: "Coffee", region: "global"),
            FeedSource(title: "C3", url: "https://c3.com/feed", category: "Coffee", region: "global"),
            FeedSource(title: "T1", url: "https://t1.com/feed", category: "Tech", region: "global"),
            FeedSource(title: "S1", url: "https://s1.com/feed", category: "Science", region: "global"),
        ].map { (source: $0, score: 1.0) }

        let selected = AdaptiveScheduler.diverseSources(from: scored, limit: 3)
        XCTAssertEqual(Set(selected.map(\.category)).count, 3)
    }
}
```

- [ ] **Step 3: Run all tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "Test.*passed|Test.*failed|FAILED|PASSED" | tail -30`

Expected: All tests pass, or identify failures to fix.

- [ ] **Step 4: Fix any failing tests and commit**

```bash
git add feedmineTests/
git commit -m "test: update scheduler tests and add AdaptiveScheduler tests

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 13: End-to-end integration and final cleanup

**Files:**
- Modify: `feedmine/Services/FeedStore.swift` (final wiring)
- Modify: `feedmine/Services/RSSFetcher.swift` (cleanup)

**Interfaces:**
- All components now integrated

- [ ] **Step 1: Verify FetchOutcome.swift is in project**

- [ ] **Step 2: Mark SourceScheduler as deprecated**

Add to SourceScheduler.swift:
```swift
@available(*, deprecated, message: "Use AdaptiveScheduler instead")
```

- [ ] **Step 3: Full build verification**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Run complete test suite**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "Test Suite|passed|failed" | tail -30`
Expected: All tests pass

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "feat: complete HTTP sync layer integration

- FeedHTTPSync with conditional GET (ETag/If-None-Match, Last-Modified/If-Modified-Since)
- AdaptiveScheduler with cadence learning, skipHours/Days, Retry-After
- 15+ new metadata fields harvested from FeedKit
- WebSub/RSS Cloud capability detection
- Expanded FeedFetchOutcome (notModified/modifiedWithNewItems/modifiedWithoutNewItems/failed/throttled)
- DB migrations for source_health v2 and feed_item metadata columns

Co-Authored-By: Claude <noreply@anthropic.com>"
```
