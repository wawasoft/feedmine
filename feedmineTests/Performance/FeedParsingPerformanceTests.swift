import XCTest
@testable import feedmine

/// Performance tests for feed parsing, deduplication, and cancellation.
/// All measure blocks use fresh stores per iteration.
@MainActor
final class FeedParsingPerformanceTests: XCTestCase {

    // MARK: - PERF-PARSE-001: Bulk insert

    func testBulkInsert_1K() async throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let expectation = self.expectation(description: "insert")
            Task {
                let store = try! FeedStore(inMemory: true)
                let items = makeFixtureItems(count: 1_000, seed: 101)
                let persisted = await store.persistFetchedItems(items)
                XCTAssertEqual(persisted.count, 1_000)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 30.0)
        }
    }

    // MARK: - PERF-PARSE-007: Duplicate handling

    func testDeduplicationPerformance() async throws {
        // Manual timing — measure() blocks with async inserts are too slow
        // on the simulator for 5 iterations of persistFetchedItems.
        let base = makeFixtureItems(count: 500, seed: 202)
        let duplicates = base.prefix(200).map { item in
            FeedItem(id: item.id, sourceTitle: item.sourceTitle,
                     sourceURL: item.sourceURL, category: item.category,
                     title: item.title + " (updated)", excerpt: item.excerpt,
                     url: item.url, imageURL: item.imageURL,
                     publishedAt: item.publishedAt)
        }
        let all = base + duplicates

        let store = try! FeedStore(inMemory: true)
        let start = CFAbsoluteTimeGetCurrent()
        let persisted = await store.persistFetchedItems(all)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertLessThanOrEqual(persisted.count, 500, "Must deduplicate 200 duplicates down to 500 max")
        // Dedup + insert of 700 items must complete in reasonable time
        XCTAssertLessThan(elapsed, 5000, "Dedup of 700 items took \(String(format: "%.0f", elapsed))ms — exceeds 5s budget")
    }

    // MARK: - Cancel during insert

    func testCancellationPreservesIntegrity() async throws {
        let store = try! FeedStore(inMemory: true)
        let items = makeFixtureItems(count: 5_000, seed: 303)
        let task = Task { await store.persistFetchedItems(items) }
        task.cancel()
        _ = await task.value

        // Store must remain functional after cancellation
        let newItems = makeFixtureItems(count: 100, seed: 999)
        let persisted = await store.persistFetchedItems(newItems)
        XCTAssertEqual(persisted.count, 100, "Store must accept inserts after cancellation")
    }

    // MARK: - Curve: 1K vs 10K

    func testInsertCurve_1K_vs_10K() async throws {
        let small = makeFixtureItems(count: 1_000, seed: 42)
        let large = makeFixtureItems(count: 10_000, seed: 42)

        let store1 = try! FeedStore(inMemory: true)
        let smallStart = CFAbsoluteTimeGetCurrent()
        _ = await store1.persistFetchedItems(small)
        let smallElapsed = CFAbsoluteTimeGetCurrent() - smallStart

        let store2 = try! FeedStore(inMemory: true)
        let largeStart = CFAbsoluteTimeGetCurrent()
        _ = await store2.persistFetchedItems(large)
        let largeElapsed = CFAbsoluteTimeGetCurrent() - largeStart

        let ratio = largeElapsed / max(smallElapsed, 0.001)
        // Tightened from 50x to 15x — 10x data should not cost >15x time
        XCTAssertLessThan(ratio, 15.0,
            "10x data took \(String(format: "%.1f", ratio))x time (budget: 15x)")
    }
}
