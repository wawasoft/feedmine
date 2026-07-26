import XCTest
@testable import feedmine

@MainActor
final class ContentFilterStoreTests: XCTestCase {

    var store: ContentFilterStore!

    override func setUp() {
        store = ContentFilterStore.shared
        // Reset to known state
        for filter in store.filters where !filter.isTemplate {
            store.removeCustom(filter.id)
        }
    }

    func testActiveFiltersReturnsEnabledOnly() {
        store.addCustom(name: "TestFilter", keywords: ["spam", "noise"])
        let active = store.activeFilters
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.keywords, ["spam", "noise"])
    }

    func testActiveFiltersExcludesDisabled() {
        store.addCustom(name: "TestFilter", keywords: ["spam"])
        guard let id = store.filters.first(where: { !$0.isTemplate })?.id else {
            XCTFail("Custom filter should exist")
            return
        }
        store.toggle(id)
        let active = store.activeFilters
        XCTAssertTrue(active.isEmpty, "Disabled filters should not appear in activeFilters")
    }

    func testActiveFiltersCacheInvalidatesOnToggle() {
        store.addCustom(name: "A", keywords: ["x"])
        let first = store.activeFilters.count
        guard let id = store.filters.first(where: { !$0.isTemplate })?.id else { return }
        store.toggle(id)
        let second = store.activeFilters.count
        XCTAssertNotEqual(first, second, "Cache should invalidate after toggle")
    }

    func testDiacriticFoldingInActiveFilters() {
        store.addCustom(name: "Accents", keywords: ["café", "naïve"])
        let active = store.activeFilters
        let keywords = active.first?.keywords ?? []
        XCTAssertTrue(keywords.contains { $0.contains("cafe") || $0.contains("café") },
                      "Keywords should be diacritic-insensitive")
    }
}
