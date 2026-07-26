import XCTest
@testable import feedmine

final class InputParserTests: XCTestCase {

    func testParseValidURL() {
        let result = InputParser.parse("https://example.com/feed.xml")
        XCTAssertFalse(result.isEmpty)
    }

    func testParseEmptyInput() {
        let result = InputParser.parse("")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseWhitespaceOnly() {
        let result = InputParser.parse("   \n  ")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseDeduplicatesURLs() {
        let result = InputParser.parse("https://a.com https://a.com https://b.com")
        // Should not have duplicate a.com entries
        let urls = result.map { $0.url }
        XCTAssertEqual(Set(urls).count, urls.count)
    }

    func testParseHandlesMixedContent() {
        let result = InputParser.parse("https://a.com garbage https://b.com")
        // Should extract the two valid URLs, ignoring "garbage"
        XCTAssertFalse(result.isEmpty)
    }
}
