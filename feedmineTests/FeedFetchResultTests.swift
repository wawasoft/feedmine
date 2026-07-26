import XCTest
@testable import feedmine

final class FeedFetchResultTests: XCTestCase {

    func testFeedFetchStatusAllCases() {
        XCTAssertEqual(FeedFetchStatus.allCases.count, 3)
        XCTAssertTrue(FeedFetchStatus.allCases.contains(.success))
        XCTAssertTrue(FeedFetchStatus.allCases.contains(.empty))
        XCTAssertTrue(FeedFetchStatus.allCases.contains(.failed))
    }

    func testFeedFetchResultStoresValues() {
        let source = FeedSource(title: "T", url: "https://x.com", category: "X")
        let result = FeedFetchResult(source: source, items: [], status: .success)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.source.title, "T")
    }

    func testFeedFetchBatchCounts() {
        let batch = FeedFetchBatch(items: [], fetchedSourceCount: 5,
                                   failedSourceCount: 2, emptySourceCount: 1,
                                   sourceStatuses: [:])
        XCTAssertEqual(batch.fetchedSourceCount, 5)
        XCTAssertEqual(batch.failedSourceCount, 2)
        XCTAssertEqual(batch.emptySourceCount, 1)
    }
}
