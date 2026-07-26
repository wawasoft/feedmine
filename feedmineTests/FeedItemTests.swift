import XCTest
@testable import feedmine

final class FeedItemTests: XCTestCase {

    func testSearchableTextReturnsLowercased() {
        let item = FeedItem(
            id: "1", sourceTitle: "Source", sourceURL: "https://x.com",
            category: "News", title: "Hello World", excerpt: "Some text",
            url: "https://x.com/1", imageURL: nil, publishedAt: Date(),
            region: "global", language: "en"
        )
        let text = item.searchableText
        XCTAssertTrue(text.contains("hello world"))
        XCTAssertTrue(text.contains("some text"))
    }

    func testGoogleNewsPublisherExtraction() {
        let publisher = FeedStore.googleNewsPublisher(fromArticleTitle: "Breaking News - BBC News")
        XCTAssertEqual(publisher, "BBC News")
    }

    func testGoogleNewsPublisherNoSeparator() {
        let publisher = FeedStore.googleNewsPublisher(fromArticleTitle: "Regular Title Without Separator")
        XCTAssertNil(publisher)
    }

    func testNormalizedLanguageCode() {
        XCTAssertEqual(FeedStore.normalizedLanguageCode("pt-BR"), "pt")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("en_US"), "en")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("zh-Hant"), "zh")
        XCTAssertEqual(FeedStore.normalizedLanguageCode("en"), "en")
    }

    func testNormalizedLanguageCodeNil() {
        XCTAssertNil(FeedStore.normalizedLanguageCode(nil))
        XCTAssertNil(FeedStore.normalizedLanguageCode(""))
        XCTAssertNil(FeedStore.normalizedLanguageCode("  "))
    }
}
