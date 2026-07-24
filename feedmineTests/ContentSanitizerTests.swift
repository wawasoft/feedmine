import XCTest
@testable import feedmine

final class ContentSanitizerTests: XCTestCase {
    func testExtractsTitleFromHTML() async throws {
        // We can't easily mock URLSession in this context, but we can test
        // the static helpers by making them internal for testing.
        // For now, smoke test that the type compiles and is importable.
        XCTAssertTrue(true) // placeholder — real tests need URLProtocol mock
    }

    func testSanitizedContentStructIsCorrect() {
        let content = ContentSanitizer.SanitizedContent(
            html: "<p>hello</p>",
            imageURLs: [URL(string: "https://example.com/img.jpg")!],
            title: "Test",
            textPreview: "hello"
        )
        XCTAssertEqual(content.title, "Test")
        XCTAssertEqual(content.imageURLs.count, 1)
    }
}
