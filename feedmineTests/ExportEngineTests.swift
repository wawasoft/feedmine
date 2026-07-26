import XCTest
@testable import feedmine

final class ExportEngineTests: XCTestCase {

    func testOPMLProducesValidXML() {
        let sources = [
            FeedSource(title: "Test Feed", url: "https://example.com/feed",
                       category: "Tech", region: "global", language: "en")
        ]
        let data = ExportEngine.opml(sources: sources, title: "Test Export")
        XCTAssertGreaterThan(data.count, 0, "OPML output should not be empty")

        let string = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(string.contains("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"), "OPML should start with XML declaration")
        XCTAssertTrue(string.contains("<opml version=\"2.0\">"), "OPML should include version")
        XCTAssertTrue(string.contains("<title>Test Export</title>"), "OPML should include the title")
        XCTAssertTrue(string.contains("xmlUrl=\"https://example.com/feed\""), "OPML should include the feed URL")
    }

    func testOPMLDateCreatedIsRFC822() {
        let sources = [FeedSource(title: "T", url: "https://x.com", category: "T")]
        let data = ExportEngine.opml(sources: sources)
        let string = String(data: data, encoding: .utf8) ?? ""

        // RFC 822 format: "Tue, 15 Nov 1994 12:45:26 GMT"
        let pattern = #"<dateCreated>[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} [A-Z]+</dateCreated>"#
        let range = string.range(of: pattern, options: .regularExpression)
        XCTAssertNotNil(range, "dateCreated should be in RFC 822 format, got: \(string)")
    }

    func testShareLinkSingleSourceReturnsText() {
        let source = FeedSource(title: "My Feed", url: "https://example.com/feed",
                                category: "News")
        let result = ExportEngine.shareLink(sources: [source])
        if case .text(let text) = result {
            XCTAssertTrue(text.contains("My Feed"), "Text should contain source title")
            XCTAssertTrue(text.contains("feedmine://import"), "Text should contain deep link")
        } else {
            XCTFail("Single source share should return .text, got \(result)")
        }
    }

    func testShareLinkMultipleSourcesReturnsFile() {
        let sources = [
            FeedSource(title: "Feed A", url: "https://a.com", category: "X"),
            FeedSource(title: "Feed B", url: "https://b.com", category: "Y"),
        ]
        let result = ExportEngine.shareLink(sources: sources)
        if case .file(let url, let label) = result {
            XCTAssertTrue(label.contains("2 feeds"), "Label should mention count")
            XCTAssertTrue(url.lastPathComponent.hasPrefix("feedmine-share-"), "Filename should use feedmine-share- prefix")
            XCTAssertTrue(url.pathExtension == "opml", "File should be .opml")
        } else {
            XCTFail("Multiple source share should return .file, got \(result)")
        }
    }
}
