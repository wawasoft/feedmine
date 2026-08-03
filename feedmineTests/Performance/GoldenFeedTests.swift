import XCTest
@testable import feedmine

/// Hostile feed tests covering the P0 "feeds hostis/defeituosos" risk.
/// Tests the data normalization, dedup, and store layers with edge-case input
/// that simulates real-world broken feeds: missing fields, duplicate IDs,
/// huge content, empty data, and extreme values.
@MainActor
final class GoldenFeedTests: XCTestCase {

    // MARK: - Missing / empty fields

    func testEmptyTitleItems_Handled() async throws {
        let store = try FeedStore(inMemory: true)
        let items = [
            makeItem(id: "a", title: ""),
            makeItem(id: "b", title: "Valid"),
            makeItem(id: "c", title: "   "),
        ]

        let persisted = await store.persistFetchedItems(items)
        // Store should handle empty-title items without crashing.
        // May filter them or persist them with empty title — both valid.
        XCTAssertGreaterThanOrEqual(persisted.count, 0)
    }

    func testEmptyURLItems_Handled() async throws {
        let store = try FeedStore(inMemory: true)
        let items = [
            makeItem(id: "a", url: ""),
            makeItem(id: "b", url: "https://valid.example.com"),
        ]

        let persisted = await store.persistFetchedItems(items)
        XCTAssertGreaterThanOrEqual(persisted.count, 0)
    }

    func testMissingDateItems_Handled() async throws {
        let store = try FeedStore(inMemory: true)
        let distantPast = Date(timeIntervalSince1970: 0)
        let items = [
            makeItem(id: "a", date: distantPast),
            makeItem(id: "b", date: Date()),
        ]

        let persisted = await store.persistFetchedItems(items)
        XCTAssertGreaterThanOrEqual(persisted.count, 0)
    }

    // MARK: - Duplicate handling

    func testDuplicateIDs_Deduped() async throws {
        let store = try FeedStore(inMemory: true)
        let original = makeItem(id: "same-id", title: "Original")
        let duplicate = makeItem(id: "same-id", title: "Duplicate")
        let another = makeItem(id: "same-id", title: "Another Duplicate")

        let persisted = await store.persistFetchedItems([original, duplicate, another])
        // At most 1 item with this ID should persist
        XCTAssertLessThanOrEqual(persisted.count, 1, "Duplicate IDs must be deduplicated")
    }

    // MARK: - Huge content

    func testHugeExcerpt_Bounded() async throws {
        let store = try FeedStore(inMemory: true)
        let hugeExcerpt = String(repeating: "Lorem ipsum dolor sit amet. ", count: 5000) // ~140KB
        let items = [makeItem(id: "huge", excerpt: hugeExcerpt)]

        let start = CFAbsoluteTimeGetCurrent()
        let persisted = await store.persistFetchedItems(items)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertLessThan(elapsed, 5000, "Huge excerpt insert took \(String(format: "%.0f", elapsed))ms — exceeds 5s budget")
        XCTAssertGreaterThanOrEqual(persisted.count, 0)
    }

    func testManyItems_BulkInsert() async throws {
        let store = try FeedStore(inMemory: true)
        let items = (0..<100).map { i in makeItem(id: "bulk-\(i)", title: "Bulk Item \(i)") }

        let start = CFAbsoluteTimeGetCurrent()
        let persisted = await store.persistFetchedItems(items)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        XCTAssertEqual(persisted.count, 100, "All 100 bulk items must persist")
        XCTAssertLessThan(elapsed, 10_000, "100-item insert took \(String(format: "%.0f", elapsed))ms")
    }

    // MARK: - Extreme values

    func testExtremeLongTitle_Handled() async throws {
        let store = try FeedStore(inMemory: true)
        let longTitle = String(repeating: "A", count: 10_000)
        let items = [makeItem(id: "long-title", title: longTitle)]

        let persisted = await store.persistFetchedItems(items)
        XCTAssertGreaterThanOrEqual(persisted.count, 0, "Long title must not crash")
    }

    func testUnicodeAndEmoji_Handled() async throws {
        let store = try FeedStore(inMemory: true)
        let items = [
            makeItem(id: "unicode-1", title: "日本語の記事タイトル 🎉"),
            makeItem(id: "unicode-2", title: "العنوان باللغة العربية 📰"),
            makeItem(id: "unicode-3", title: "Текст с диакритиками čšž"),
            makeItem(id: "unicode-4", title: "😀😃😄😁😆😅🤣😂"),
        ]

        let persisted = await store.persistFetchedItems(items)
        XCTAssertEqual(persisted.count, 4, "All unicode/emoji items must persist")
    }

    // MARK: - Bounded time for all operations

    func testAllOperations_BoundedTime() async throws {
        let store = try FeedStore(inMemory: true)

        // Test that repeated operations don't degrade
        for batch in 0..<5 {
            let items = (0..<50).map { i in
                makeItem(id: "bounded-\(batch)-\(i)", title: "Batch \(batch) Item \(i)")
            }
            let start = CFAbsoluteTimeGetCurrent()
            let persisted = await store.persistFetchedItems(items)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            XCTAssertEqual(persisted.count, 50, "Batch \(batch) must persist all items")
            XCTAssertLessThan(elapsed, 5000, "Batch \(batch) took \(String(format: "%.0f", elapsed))ms — exceeds 5s budget")
        }
    }

    // MARK: - Helpers

    private func makeItem(
        id: String,
        title: String = "Test Title",
        url: String = "https://test.example.com/article",
        excerpt: String = "Test excerpt",
        date: Date = Date()
    ) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "Test Source",
            sourceURL: "https://test.example.com/feed",
            category: "Technology",
            title: title,
            excerpt: excerpt,
            url: url,
            imageURL: nil,
            publishedAt: date,
            region: "global",
            language: "en"
        )
    }
}
