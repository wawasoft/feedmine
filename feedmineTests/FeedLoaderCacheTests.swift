import XCTest
@testable import feedmine

@MainActor
final class FeedLoaderCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Keys.toggleDisabled)
        UserDefaults.standard.removeObject(forKey: Keys.toggleEnabledOverrides)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Keys.toggleDisabled)
        UserDefaults.standard.removeObject(forKey: Keys.toggleEnabledOverrides)
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
                try FeedItemRecord(from: item, region: "global").insert(db)
            }
        }

        store.setFilter(region: nil, nodeIDs: [], type: .all, mood: .all, languages: ["zh"])
        let loader = FeedLoader(store: store)

        // Wait for async filter reload.
        let deadline = Date().addingTimeInterval(3)
        while store.visibleItems.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        let sections = loader.dateSections
        XCTAssertEqual(sections.count, 1)
        XCTAssertFalse(try XCTUnwrap(sections.first).showsHeader)
        XCTAssertEqual(sections.flatMap(\.items).map(\.id), orderedItems.map(\.id))
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
