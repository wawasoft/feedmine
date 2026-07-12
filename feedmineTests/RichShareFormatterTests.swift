import XCTest
import Foundation
@testable import feedmine

@MainActor
final class RichShareFormatterTests: XCTestCase {

    func testPlainText_containsTitleAndURL() {
        let item = FeedItem(
            id: "test-id",
            sourceTitle: "Test Source",
            sourceURL: "https://source.example.com",
            category: "tech",
            title: "A Great Article",
            excerpt: "Something interesting happened.",
            url: "https://example.com/article",
            imageURL: nil,
            publishedAt: Date(),
            audioURL: nil,
            duration: nil,
            region: "global"
        )

        let text = RichShareFormatter.plainText(for: item)
        XCTAssertTrue(text.contains("A Great Article"))
        XCTAssertTrue(text.contains("Something interesting happened."))
        XCTAssertTrue(text.contains("Read on Feedmine:"))
        XCTAssertTrue(text.contains("https://example.com/article"))
    }

    func testAttributedString_containsDeepLink() {
        let item = FeedItem(
            id: "abc-123",
            sourceTitle: "Test",
            sourceURL: "https://s.example.com",
            category: "news",
            title: "Title",
            excerpt: "Excerpt",
            url: "https://e.com/a",
            imageURL: nil,
            publishedAt: Date(),
            audioURL: nil,
            duration: nil,
            region: "global"
        )

        let attr = RichShareFormatter.attributedString(for: item)
        let string = String(attr.characters)
        XCTAssertTrue(string.contains("feedmine://article/abc-123"))
    }
}
