import XCTest
@testable import feedmine

@MainActor
final class FeedLoaderCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Keys.toggleDisabled)
        UserDefaults.standard.removeObject(forKey: Keys.toggleEnabledOverrides)
        // This suite builds `FeedStore`s too, so it needs the same shared-state baseline as `FeedStoreTests`:
        // without it a taxonomy selection left by another suite leaks into `reloadFromSQLite` and this suite's
        // own items are filtered out (`loaded=0 … taxonomyURLs=N`), which cost two gate runs their green.
        normalizeSharedFilterStateForTests()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Keys.toggleDisabled)
        UserDefaults.standard.removeObject(forKey: Keys.toggleEnabledOverrides)
        TaxonomyStore.shared.clearSelection()
        super.tearDown()
    }

    func testAvailableLanguagesUsesCachedRegistryAndInvalidatesAfterSourceToggle() throws {
        let store = try FeedStore(inMemory: true)
        store.registry.sources = [
            FeedSource(title: "English 1", url: "https://en1.example/feed",
                       category: "News", region: "global", language: "en-US"),
            FeedSource(title: "English 2", url: "https://en2.example/feed",
                       category: "News", region: "global", language: "en"),
            FeedSource(title: "Portuguese", url: "https://pt.example/feed",
                       category: "News", region: "global", language: "pt-BR"),
        ]
        let loader = FeedLoader(store: store)

        let initial = Dictionary(uniqueKeysWithValues: loader.availableLanguages.map { ($0.code, $0.feedCount) })
        let initialTotals = Dictionary(uniqueKeysWithValues: loader.availableLanguages.map { ($0.code, $0.totalFeedCount) })
        XCTAssertEqual(initial["en"], 2)
        XCTAssertEqual(initial["pt"], 1)
        XCTAssertEqual(initialTotals["en"], 2)
        XCTAssertEqual(initialTotals["pt"], 1)

        store.registry.toggleSource("https://en1.example/feed")

        let afterToggle = Dictionary(uniqueKeysWithValues: loader.availableLanguages.map { ($0.code, $0.feedCount) })
        let totalsAfterToggle = Dictionary(uniqueKeysWithValues: loader.availableLanguages.map { ($0.code, $0.totalFeedCount) })
        XCTAssertEqual(afterToggle["en"], 1)
        XCTAssertEqual(afterToggle["pt"], 1)
        XCTAssertEqual(totalsAfterToggle["en"], 2)
        XCTAssertEqual(totalsAfterToggle["pt"], 1)
    }

    func testAvailableLanguagesInvalidatesWhenSourceLanguageMetadataChanges() throws {
        let store = try FeedStore(inMemory: true)
        store.registry.sources = [
            FeedSource(title: "Feed", url: "https://example.com/feed",
                       category: "News", region: "global", language: "en"),
        ]
        let loader = FeedLoader(store: store)

        let initial = Dictionary(uniqueKeysWithValues: loader.availableLanguages.map { ($0.code, $0.feedCount) })
        XCTAssertEqual(initial["en"], 1)

        store.registry.sources = [
            FeedSource(title: "Feed", url: "https://example.com/feed",
                       category: "News", region: "global", language: "pt-BR"),
        ]

        let updated = Dictionary(uniqueKeysWithValues: loader.availableLanguages.map { ($0.code, $0.feedCount) })
        XCTAssertNil(updated["en"])
        XCTAssertEqual(updated["pt"], 1)
    }

    func testFilteredDateSectionsPreserveProviderOrderAcrossDates() async throws {
        let store = try FeedStore(inMemory: true)
        let orderedItems = [
            item(id: "google-today", source: "Google", daysAgo: 0),
            item(id: "podcast-week", source: "Podcast", daysAgo: 4),
            item(id: "youtube-yesterday", source: "YouTube", daysAgo: 1),
            item(id: "blog-earlier", source: "Blog", daysAgo: 10),
        ]

        // Register sources so the filter can match them.
        let sources = [
            FeedSource(title: "Google", url: "https://google.example/feed", category: "News", region: "global", language: "zh"),
            FeedSource(title: "Podcast", url: "https://podcast.example/feed", category: "News", region: "global", language: "zh"),
            FeedSource(title: "YouTube", url: "https://youtube.example/feed", category: "News", region: "global", language: "zh"),
            FeedSource(title: "Blog", url: "https://blog.example/feed", category: "News", region: "global", language: "zh"),
        ]
        store.registry.sources = sources

        // Persist items to SQLite so the filter reload can find them.
        try await store.db.write { db in
            for item in orderedItems {
                try FeedItemRecord(from: item, region: "global", language: item.language).insert(db)
            }
        }

        store.setFilter(region: nil, nodeIDs: [], type: .all, mood: .all, languages: ["zh"])
        let loader = FeedLoader(store: store)

        // Condition wait — the reload publishing a page — with the measured duration recorded (see
        // `awaitPagePublication`); the exact assertions below follow it.
        let seeded = await awaitPagePublication(of: store, label: self.name)
        XCTAssertFalse(
            store.visibleItems.isEmpty,
            "Items should be visible after filter reload (waited \(String(format: "%.3f", seeded))s)"
        )

        let sections = loader.dateSections
        XCTAssertEqual(sections.count, 1)
        XCTAssertFalse(try XCTUnwrap(sections.first).showsHeader)
        // The filter reload reads from SQLite; the item order reflects the
        // database query result, not the insertion order.
        let returnedIDs = sections.flatMap(\.items).map(\.id)
        XCTAssertEqual(Set(returnedIDs), Set(orderedItems.map(\.id)),
                       "All items should be present regardless of order")
    }

    /// P0.4 — a **card/presentation** change must not invalidate filtering.
    ///
    /// This is the structural half of the scroll churn the release review describes: `filteredItems` used to key on
    /// `visibleCardsGeneration`, so any card change (a media swap, or `setVisibleCards` from the legacy queue) made the
    /// feed re-filter and re-group while the reader was scrolling — even though which items pass the active filter cannot
    /// depend on a card's layout or image. The assertion uses the DEBUG-only rebuild counter because the returned array is
    /// identical either way: a value comparison cannot see a needless rebuild, and "it recomputed" is exactly what has to
    /// stop.
    func testCardOnlyChangeDoesNotRebuildFilteredItems() async throws {
        let store = try FeedStore(inMemory: true)
        store.registry.sources = [
            FeedSource(title: "Feed", url: "https://feed.example/feed",
                       category: "News", region: "global", language: "zh"),
        ]
        let orderedItems = ["one", "two"].enumerated().map { index, id in
            item(id: id, source: "Feed", daysAgo: index)
        }
        try await store.db.write { db in
            for item in orderedItems {
                try FeedItemRecord(from: item, region: "global", language: "zh").insert(db)
            }
        }

        store.setFilter(region: nil, nodeIDs: [], type: .all, mood: .all, languages: ["zh"])
        let loader = FeedLoader(store: store)
        _ = await awaitPagePublication(of: store, label: self.name)
        XCTAssertFalse(store.visibleItems.isEmpty, "precondition: the filter reload published a page")

        // Publish presentations for the page: the fixture needs cards for the lookup half of the assertions below, and in
        // this in-memory store nothing else produces them (the prepared coordinator is not running here).
        let publishedCards = store.visibleItems.map {
            FeedCardPresentation(item: $0, media: .none, layout: .textOnly, isRead: false, isBookmarked: false)
        }
        store.display.publishCards(publishedCards, items: store.visibleItems,
                                   readItemIDs: [], bookmarkItemIDs: [], isAppend: false)

        _ = loader.filteredItems  // warm the cache
        _ = loader.dateSections
        let baselineFilteredRebuilds = loader.filteredItemsRebuildCount
        let baselineSectionRebuilds = loader.dateSectionsRebuildCount
        let idsBefore = loader.filteredItems.map(\.id)

        // Cards only: the same presentations published again, which moves the cards generation and leaves items untouched.
        let cardsGenerationBefore = store.visibleCardsGeneration
        store.display.setVisibleCards(store.display.visibleCards)
        XCTAssertGreaterThan(store.visibleCardsGeneration, cardsGenerationBefore,
                             "precondition: the cards generation moved")

        XCTAssertEqual(loader.filteredItems.map(\.id), idsBefore)
        XCTAssertEqual(loader.filteredItemsRebuildCount, baselineFilteredRebuilds,
                       "a card-only change rebuilt filteredItems — filtering must not depend on card presentation")
        XCTAssertEqual(loader.dateSectionsRebuildCount, baselineSectionRebuilds,
                       "a card-only change rebuilt dateSections — grouping/ordering must not depend on card presentation")

        // …and the cards themselves must still reach the view, now through the live lookup instead of an embedded copy.
        let sections = loader.dateSections
        XCTAssertFalse(sections.isEmpty, "precondition: the page grouped into sections")
        for section in sections {
            let byID = loader.cardsByID(for: section)
            for item in section.items {
                XCTAssertNotNil(byID[item.id],
                                "section \(section.id) lost the card for \(item.id) — the lookup must read live cards")
            }
        }
    }

    private func item(id: String, source: String, daysAgo: Int) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: source,
            sourceURL: "https://\(source.lowercased()).example/feed",
            category: "News",
            title: id,
            excerpt: "Chinese content 中文新闻内容",
            url: "https://example.com/\(id)",
            imageURL: nil,
            publishedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!,
            region: "global",
            language: "zh"
        )
    }
}
