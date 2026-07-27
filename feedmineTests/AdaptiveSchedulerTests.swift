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
        // Empty reservoir — normally would fetch, but Retry-After blocks
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

    func testShouldUseConditionalGetWhenLastModifiedExists() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        v.lastModified = "Mon, 13 Jul 2026 12:00:00 GMT"
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
        v.lastFetchAt = Date().addingTimeInterval(-600) // 10 min ago (2x default min)
        let e = CadenceEstimator()
        let u = s.urgency(validators: v, estimator: e, now: Date())
        XCTAssertEqual(u, 1.0, accuracy: 0.01)
    }

    func testUrgencySpikesAfterExpectedPublication() {
        let s = AdaptiveScheduler()
        let now = Date()
        var v = HTTPValidators()
        v.lastFetchAt = now.addingTimeInterval(-7200)
        let e = CadenceEstimator(publicationInterval: 3600, confidence: 0.8, lastPublication: now.addingTimeInterval(-7200))
        // lastPublication = 2 hours ago, publicationInterval = 1 hour
        // expectedNext = 1 hour ago → past expected → urgency > 0.5
        let u = s.urgency(validators: v, estimator: e, now: now)
        XCTAssertGreaterThan(u, 0.5)
    }

    func testUrgencyIsZeroForNeverFetchedSource() {
        let s = AdaptiveScheduler()
        // No lastFetchAt set → distantPast → large elapsed → urgency 1.0
        let e = CadenceEstimator()
        let u = s.urgency(validators: HTTPValidators(), estimator: e, now: Date())
        // Fresh source (no validators) should have max urgency
        XCTAssertGreaterThan(u, 0.5, "Never-fetched source should have high urgency")
    }

    // MARK: - Minimum Interval Tests

    func testMinimumIntervalDefaultsToFiveMinutes() {
        let s = AdaptiveScheduler()
        let interval = s.minimumInterval(validators: HTTPValidators(), estimator: CadenceEstimator())
        XCTAssertEqual(interval, 300, accuracy: 1, "Default minimum interval should be 300s")
    }

    func testMinimumIntervalRespectsTTL() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        v.ttl = 30 // 30 minutes
        let interval = s.minimumInterval(validators: v, estimator: CadenceEstimator())
        XCTAssertEqual(interval, 1800, accuracy: 1, "TTL of 30 min should produce 1800s interval")
    }

    func testMinimumIntervalIsZeroWithNoStore() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        v.cacheControl = HTTPValidators.ParsedCacheControl(noStore: true)
        let interval = s.minimumInterval(validators: v, estimator: CadenceEstimator())
        XCTAssertEqual(interval, 0, "no-store should force minimum interval to 0")
    }

    // MARK: - isSkipped Tests

    func testIsSkippedReturnsTrueForCurrentHour() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        v.skipHours = [hour]
        XCTAssertTrue(s.isSkipped(validators: v, now: now))
    }

    func testIsSkippedReturnsTrueForCurrentDay() {
        let s = AdaptiveScheduler()
        var v = HTTPValidators()
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        let today = formatter.string(from: Date())
        v.skipDays = [today]
        XCTAssertTrue(s.isSkipped(validators: v, now: Date()))
    }

    func testIsSkippedReturnsFalseWithoutRestrictions() {
        let s = AdaptiveScheduler()
        XCTAssertFalse(s.isSkipped(validators: HTTPValidators(), now: Date()))
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

    func testDiverseSourcesReturnsEmptyForEmptyInput() {
        let selected = AdaptiveScheduler.diverseSources(from: [], limit: 3)
        XCTAssertTrue(selected.isEmpty)
    }

    func testDiverseSourcesRespectsLimit() {
        let scored: [(source: FeedSource, score: Double)] = [
            FeedSource(title: "A", url: "https://a.com/feed", category: "Tech", region: "global"),
            FeedSource(title: "B", url: "https://b.com/feed", category: "Science", region: "global"),
            FeedSource(title: "C", url: "https://c.com/feed", category: "Health", region: "global"),
        ].map { (source: $0, score: 1.0) }

        let selected = AdaptiveScheduler.diverseSources(from: scored, limit: 2)
        XCTAssertEqual(selected.count, 2)
    }

    // MARK: - Record Fetch Tests

    func testRecordFetchNotModifiedUpdatesLastFetched() {
        let s = AdaptiveScheduler()
        let url = "https://a.com/feed"
        s.recordFetch(sourceURL: url, outcome: .notModified)
        let health = s.healthSnapshot(for: url)
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertEqual(health.lastStatus, "ok")
    }

    func testRecordFetchThrottledSetsRetryAfter() {
        let s = AdaptiveScheduler()
        let url = "https://a.com/feed"
        let future = Date().addingTimeInterval(120)
        s.recordFetch(sourceURL: url, outcome: .throttled(until: future))
        // The source should now be blocked by Retry-After
        let source = FeedSource(title: "A", url: url, category: "Tech", region: "global")
        let sources: [String: [FeedSource]] = ["global": [source]]
        let batch = s.nextBatch(reservoir: [], sourcesByRegion: sources, activeRegion: nil, activeCategory: nil)
        XCTAssertTrue(batch.isEmpty, "Throttled source must be skipped")
    }

    // MARK: - Health Snapshot Tests

    func testHealthSnapshotReturnsDefaultsForUnknownURL() {
        let s = AdaptiveScheduler()
        let health = s.healthSnapshot(for: "https://unknown.com/feed")
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertEqual(health.lastStatus, "ok")
        XCTAssertNotNil(health.validators)
        XCTAssertNotNil(health.estimator)
    }

    func testHealthSnapshotReturnsErrorStatusAfterFailures() {
        let s = AdaptiveScheduler()
        let url = "https://a.com/feed"
        s.recordFetch(sourceURL: url, outcome: .failed(NSError(domain: "test", code: 0)))
        s.recordFetch(sourceURL: url, outcome: .failed(NSError(domain: "test", code: 0)))
        s.recordFetch(sourceURL: url, outcome: .failed(NSError(domain: "test", code: 0)))
        let health = s.healthSnapshot(for: url)
        XCTAssertEqual(health.consecutiveFailures, 3)
        XCTAssertEqual(health.lastStatus, "error")
    }

    func testHealthSnapshotClearsAfterSuccessfulFetch() {
        let s = AdaptiveScheduler()
        let url = "https://a.com/feed"
        s.recordFetch(sourceURL: url, outcome: .failed(NSError(domain: "test", code: 0)))
        s.recordFetch(sourceURL: url, outcome: .failed(NSError(domain: "test", code: 0)))
        s.recordFetch(sourceURL: url, outcome: .notModified) // success resets
        let health = s.healthSnapshot(for: url)
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertEqual(health.lastStatus, "ok")
    }

    // MARK: - Load/Persist Hooks

    func testLoadHealthRestoresPersistedState() {
        let s = AdaptiveScheduler()
        let url = "https://a.com/feed"
        let pastDate = Date().addingTimeInterval(-3600)
        s.loadHealth(url: url, lastFetchAt: pastDate, consecutiveFailures: 2)
        let health = s.healthSnapshot(for: url)
        XCTAssertEqual(health.lastFetchAt.timeIntervalSince1970, pastDate.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(health.consecutiveFailures, 2)
    }

    func testLoadValidatorsDoesNotOverwriteExisting() {
        let s = AdaptiveScheduler()
        let url = "https://a.com/feed"
        var v1 = HTTPValidators()
        v1.etag = "\"first\""
        s.loadValidators(url: url, v1)
        var v2 = HTTPValidators()
        v2.etag = "\"second\""
        s.loadValidators(url: url, v2) // should NOT overwrite
        let health = s.healthSnapshot(for: url)
        XCTAssertEqual(health.validators.etag, "\"first\"")
    }

    // MARK: - State Management

    func testPrioritizeRemovesCooldown() {
        let s = AdaptiveScheduler()
        let url = "https://a.com/feed"
        s.recordFetch(sourceURL: url, outcome: .notModified)
        // After fetching, source has lastFetchedAt set
        let source = FeedSource(title: "A", url: url, category: "Tech", region: "global")
        let sources: [String: [FeedSource]] = ["global": [source]]
        let blocked = s.nextBatch(reservoir: [], sourcesByRegion: sources, activeRegion: nil, activeCategory: nil)
        XCTAssertTrue(blocked.isEmpty, "Source within min interval should be blocked")
        s.prioritize(sourceURLs: [url])
        let unblocked = s.nextBatch(reservoir: [], sourcesByRegion: sources, activeRegion: nil, activeCategory: nil)
        XCTAssertFalse(unblocked.isEmpty, "Prioritized source should be eligible again")
    }

    func testRemoveClearsAllState() {
        let s = AdaptiveScheduler()
        let url = "https://a.com/feed"
        s.recordFetch(sourceURL: url, outcome: .notModified)
        s.remove(sourceURLs: [url])
        let health = s.healthSnapshot(for: url)
        XCTAssertEqual(health.consecutiveFailures, 0)
        XCTAssertEqual(health.lastStatus, "ok")
    }
}
