import XCTest
@testable import feedmine

final class CountryModelTests: XCTestCase {

    func testCountrySlugStripsPrefix() {
        let country = Country(region: "countries/brazil", name: "Brazil",
                              flag: "🇧🇷", feedCount: 100, categories: ["News"], regions: [])
        XCTAssertEqual(country.slug, "brazil")
    }

    func testCountrySlugNonPrefixReturnsFullRegion() {
        let country = Country(region: "topic/sports", name: "Sports",
                              flag: "🏅", feedCount: 10, categories: [], regions: [])
        XCTAssertEqual(country.slug, "topic/sports")
    }

    func testCountryIdentityFromRegion() {
        let country = Country(region: "countries/france", name: "France",
                              flag: "🇫🇷", feedCount: 50, categories: [], regions: [])
        XCTAssertEqual(country.id, "countries/france")
    }

    func testCountryHasRegions() {
        let region = Region(path: "countries/brazil/sp", countrySlug: "brazil",
                            slug: "sp", name: "SP", feedCount: 1, categories: [])
        let country = Country(region: "countries/brazil", name: "Brazil",
                              flag: "🇧🇷", feedCount: 100, categories: ["News"],
                              regions: [region])
        XCTAssertTrue(country.hasRegions)
    }

    func testCountryNoRegions() {
        let country = Country(region: "countries/malta", name: "Malta",
                              flag: "🇲🇹", feedCount: 5, categories: [], regions: [])
        XCTAssertFalse(country.hasRegions)
    }
}
