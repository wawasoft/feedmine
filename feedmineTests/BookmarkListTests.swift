import XCTest
@testable import feedmine

final class BookmarkListTests: XCTestCase {

    func testIsPersistentSearchTrue() {
        var list = BookmarkList(id: 1, name: "Search", sortOrder: 0,
                                createdAt: Date(), isDefault: false,
                                searchQuery: "test query", searchRegion: nil,
                                searchCategory: nil, searchActive: true, itemCount: 0)
        XCTAssertTrue(list.isPersistentSearch)
    }

    func testIsPersistentSearchFalse() {
        let list = BookmarkList(id: 1, name: "Favorites", sortOrder: 0,
                                createdAt: Date(), isDefault: true,
                                searchQuery: nil, searchRegion: nil,
                                searchCategory: nil, searchActive: false, itemCount: 5)
        XCTAssertFalse(list.isPersistentSearch)
    }

    func testBookmarkListIsHashable() {
        let a = BookmarkList(id: 1, name: "A", sortOrder: 0, createdAt: Date(),
                             isDefault: false, searchQuery: nil, searchRegion: nil,
                             searchCategory: nil, searchActive: false, itemCount: 0)
        let b = BookmarkList(id: 1, name: "A", sortOrder: 0, createdAt: a.createdAt,
                             isDefault: false, searchQuery: nil, searchRegion: nil,
                             searchCategory: nil, searchActive: false, itemCount: 0)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }
}
