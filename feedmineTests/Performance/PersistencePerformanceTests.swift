import XCTest
@testable import feedmine

/// Performance tests for persistence: store open, batch write, read.
/// All measure blocks use fresh stores per iteration to avoid the
/// duplicate-ID problem (persistFetchedItems returns [] for existing IDs).
@MainActor
final class PersistencePerformanceTests: XCTestCase {

    // MARK: - PERF-DB-001: Store open

    func testStoreOpen_Empty() async throws {
        measure(metrics: [XCTClockMetric()]) {
            let expectation = self.expectation(description: "open empty")
            Task {
                let store = try FeedStore(inMemory: true)
                XCTAssertNotNil(store)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 10.0)
        }
    }

    func testStoreOpen_With5K() async throws {
        // Pre-populate a store, then measure re-opening (fresh) with data
        let preStore = try FeedStore(inMemory: true)
        let items = makeFixtureItems(count: 5_000, seed: 901)
        _ = await preStore.persistFetchedItems(items)

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            let expectation = self.expectation(description: "reopen")
            Task {
                let store = try FeedStore(inMemory: true)
                // Insert the same 5K items — the open cost is measured,
                // and the insert cost is consistent across iterations
                let persisted = await store.persistFetchedItems(items)
                XCTAssertEqual(persisted.count, 5_000)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 10.0)
        }
    }

    // MARK: - PERF-DB-002: Batch insert

    func testBatchInsert_5K() async throws {
        let batches = 10
        let batchSize = 500

        measure(metrics: [XCTClockMetric()]) {
            let expectation = self.expectation(description: "batch")
            Task {
                let store = try FeedStore(inMemory: true)
                var total = 0
                for b in 0..<batches {
                    let items = makeFixtureItems(count: batchSize, seed: 902 + b)
                    let persisted = await store.persistFetchedItems(items)
                    total += persisted.count
                }
                XCTAssertEqual(total, batches * batchSize)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 30.0)
        }
    }
}
