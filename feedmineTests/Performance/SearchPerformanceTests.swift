import XCTest
@testable import feedmine

/// Performance tests for FTS5 search. Uses fresh stores per measure iteration.
@MainActor
final class SearchPerformanceTests: XCTestCase {

    // MARK: - PERF-CAT-004/005/006: Search at scale

    func testSearchCommonTerm_10K() async throws {
        let store = try! FeedStore(inMemory: true)
        let items = makeFixtureItems(count: 10_000, seed: 801)
        _ = await store.persistFetchedItems(items)

        measure(metrics: [XCTClockMetric()]) {
            let expectation = self.expectation(description: "search")
            Task {
                let results = await store.searchEngine.search(
                    "Technology", region: nil, category: nil
                )
                XCTAssertFalse(results.isEmpty)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 10.0)
        }
    }

    func testSearchNoResults_10K() async throws {
        let store = try! FeedStore(inMemory: true)
        let items = makeFixtureItems(count: 10_000, seed: 802)
        _ = await store.persistFetchedItems(items)

        measure(metrics: [XCTClockMetric()]) {
            let expectation = self.expectation(description: "empty search")
            Task {
                let results = await store.searchEngine.search(
                    "xyznonexistent987654", region: nil, category: nil
                )
                XCTAssertTrue(results.isEmpty)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 5.0)
        }
    }

    // MARK: - Curve: 1K vs 10K vs 100K

    func testSearchCurve_1K_vs_10K_vs_100K() async throws {
        var times: [Int: TimeInterval] = [:]

        for (count, seed) in [(1_000, 42), (10_000, 42), (100_000, 42)] {
            let store = try! FeedStore(inMemory: true)
            let items = makeFixtureItems(count: count, seed: seed)
            _ = await store.persistFetchedItems(items)

            let start = CFAbsoluteTimeGetCurrent()
            let results = await store.searchEngine.search(
                "Technology", region: nil, category: nil
            )
            times[count] = CFAbsoluteTimeGetCurrent() - start
            XCTAssertFalse(results.isEmpty, "Must find results at \(count)")
        }

        let ratio10K = (times[10_000] ?? 0.001) / max(times[1_000] ?? 0.001, 0.001)
        let ratio100K = (times[100_000] ?? 0.001) / max(times[1_000] ?? 0.001, 0.001)

        // 10x data → ≤5x search time (tightened from 20x)
        XCTAssertLessThan(ratio10K, 5.0, "10x data search ratio \(String(format: "%.1f", ratio10K))x exceeds 5x budget")
        // 100x data → ≤15x search time (FTS5 should be sub-linear)
        XCTAssertLessThan(ratio100K, 15.0, "100x data search ratio \(String(format: "%.1f", ratio100K))x exceeds 15x budget")
    }
}
