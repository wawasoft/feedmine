import XCTest
@testable import feedmine

final class RegionTests: XCTestCase {

    func testRegionIdentityIsPath() {
        let region = Region(path: "countries/brazil/sao-paulo", countrySlug: "brazil",
                            slug: "sao-paulo", name: "São Paulo",
                            feedCount: 10, categories: ["News", "Sports"])
        XCTAssertEqual(region.id, "countries/brazil/sao-paulo")
    }

    func testRegionHasCategories() {
        let region = Region(path: "test", countrySlug: "x", slug: "test",
                            name: "Test", feedCount: 5, categories: ["A", "B"])
        XCTAssertEqual(region.categories.count, 2)
        XCTAssertTrue(region.categories.contains("A"))
    }

    func testRegionIsHashable() {
        let r1 = Region(path: "a", countrySlug: "x", slug: "a", name: "A", feedCount: 1, categories: [])
        let r2 = Region(path: "a", countrySlug: "x", slug: "a", name: "A", feedCount: 1, categories: [])
        XCTAssertEqual(r1, r2)
        XCTAssertEqual(r1.hashValue, r2.hashValue)
    }
}
