import XCTest
import Foundation
@testable import feedmine

final class PendingQueueTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PendingQueue.clear()
    }

    override func tearDown() {
        PendingQueue.clear()
        super.tearDown()
    }

    func testAppendThenReadRoundTrip() {
        let item = PendingItem(
            id: "test-1",
            type: .feedDirect,
            sourceURL: "https://example.com/feed.xml",
            foundFeeds: [PendingItem.DiscoveredFeed(title: "Test", url: "https://example.com/feed.xml")],
            fileName: nil,
            feedCount: nil,
            receivedAt: Int(Date().timeIntervalSince1970)
        )

        PendingQueue.append([item])
        let read = PendingQueue.readAll()

        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read[0].id, "test-1")
        XCTAssertEqual(read[0].type, .feedDirect)
    }

    func testClearRemovesFile() {
        let item = PendingItem(
            id: "test-clear",
            type: .feedDirect,
            sourceURL: "https://example.com/feed.xml",
            foundFeeds: [],
            fileName: nil,
            feedCount: nil,
            receivedAt: Int(Date().timeIntervalSince1970)
        )
        PendingQueue.append([item])
        XCTAssertFalse(PendingQueue.readAll().isEmpty)

        PendingQueue.clear()
        XCTAssertTrue(PendingQueue.readAll().isEmpty)
    }

    func testOverflowDropsOldest() {
        // Fill beyond the 100-item cap
        var items: [PendingItem] = []
        for i in 0..<150 {
            items.append(PendingItem(
                id: "overflow-\(i)",
                type: .feedDirect,
                sourceURL: "https://example.com/feed\(i).xml",
                foundFeeds: [],
                fileName: nil,
                feedCount: nil,
                receivedAt: Int(Date().timeIntervalSince1970)
            ))
        }
        PendingQueue.append(items)

        let read = PendingQueue.readAll()
        XCTAssertLessThanOrEqual(read.count, 100)
        // Oldest items (0-49) should have been dropped
        XCTAssertFalse(read.contains { $0.id == "overflow-0" })
    }
}
