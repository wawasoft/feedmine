import XCTest
@testable import feedmine

final class ActiveSearchTests: XCTestCase {

    func testDimensionCountFull() {
        let search = ActiveSearch(id: 1, name: "Test", searchQuery: "query",
                                  region: "countries/brazil", category: "Tech")
        XCTAssertEqual(search.dimensionCount, 3)
    }

    func testDimensionCountOnlyQuery() {
        let search = ActiveSearch(id: 1, name: "Test", searchQuery: "query",
                                  region: nil, category: nil)
        XCTAssertEqual(search.dimensionCount, 1)
    }

    func testDimensionCountEmptyQuery() {
        let search = ActiveSearch(id: 1, name: "Test", searchQuery: "",
                                  region: "countries/brazil", category: "Tech")
        XCTAssertEqual(search.dimensionCount, 2, "Empty searchQuery should not count as dimension")
    }

    func testMatchesRegion() {
        let search = ActiveSearch(id: 1, name: "Test", searchQuery: "q",
                                  region: "countries/brazil", category: nil)
        let item = FeedItem(id: "1", sourceTitle: "S", sourceURL: "x", category: "News",
                            title: "T", excerpt: "E", url: "x", imageURL: nil,
                            publishedAt: Date(), region: "global", language: "en")
        XCTAssertEqual(search.matches(item, itemRegion: "countries/brazil"), 1)
    }

    func testMatchesCategory() {
        let search = ActiveSearch(id: 1, name: "Test", searchQuery: "q",
                                  region: nil, category: "Tech")
        let item = FeedItem(id: "1", sourceTitle: "S", sourceURL: "x", category: "Tech",
                            title: "T", excerpt: "E", url: "x", imageURL: nil,
                            publishedAt: Date(), region: "global", language: "en")
        XCTAssertEqual(search.matches(item, itemRegion: "countries/brazil"), 1)
    }
}
