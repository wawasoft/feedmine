import XCTest
@testable import feedmine

@MainActor
final class CountryStoreTests: XCTestCase {

    func testCountryNameKnownRegion() {
        let name = CountryStore.countryName(for: "brazil")
        XCTAssertFalse(name.isEmpty)
        XCTAssertTrue(name.contains("Brazil") || name.contains("Brasil"))
    }

    func testCountryNameUnknownFallback() {
        let name = CountryStore.countryName(for: "nonexistent")
        XCTAssertFalse(name.isEmpty)
        // Should capitalize and replace hyphens
        XCTAssertEqual(name, "Nonexistent")
    }

    func testCountryFlagKnownCountry() {
        let flag = CountryStore.countryFlag(for: "brazil")
        XCTAssertEqual(flag, "\u{1F1E7}\u{1F1F7}") // 🇧🇷
    }

    func testCountryFlagUnknownFallback() {
        let flag = CountryStore.countryFlag(for: "nonexistent")
        XCTAssertEqual(flag, "\u{1F310}") // 🌐
    }

    func testCountrySlugStripsPrefix() {
        let country = Country(region: "countries/brazil", name: "Brazil",
                              flag: "🇧🇷", feedCount: 100, categories: [], regions: [])
        XCTAssertEqual(country.slug, "brazil")
    }

    func testCountrySlugNonPrefixReturnsFullString() {
        let country = Country(region: "topic/sports", name: "Sports",
                              flag: "🏅", feedCount: 10, categories: [], regions: [])
        XCTAssertEqual(country.slug, "topic/sports", "Non-countries/ prefix should return full region")
    }
}
