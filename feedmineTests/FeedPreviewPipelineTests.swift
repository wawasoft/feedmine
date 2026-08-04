import XCTest
@testable import feedmine

/// Coverage for `FeedLoader.previewCuratedCards` — the async preview pipeline
/// behind the Composer preview zone.
///
/// Seeding pattern mirrors FeedLoaderCacheTests: register sources, persist
/// items to SQLite, then trigger a filter reload and poll `visibleItems`.
@MainActor
final class FeedPreviewPipelineTests: XCTestCase {

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

    // MARK: - Pipeline behavior

    func testPreviewCuratedCardsReturnsEmptyWhenNoVisibleItems() async throws {
        let store = try FeedStore(inMemory: true)
        let loader = FeedLoader(store: store)

        let cards = await loader.previewCuratedCards(
            recipe: nil,
            evidence: CuratedProfileDefinition(weights: ["topic:news-current-affairs": 3])
        )

        XCTAssertTrue(cards.isEmpty)
    }

    func testPreviewCuratedCardsRanksByMultiplierAndExcludesDisliked() async throws {
        let (_, loader) = try await makeStore(
            sources: [
                source(title: "News A", url: "https://news-a.example/feed", category: "News & Current Affairs"),
                source(title: "Culture A", url: "https://culture-a.example/feed", category: "Arts & Culture"),
                source(title: "Sports A", url: "https://sports-a.example/feed", category: "Sports"),
                source(title: "Ent A", url: "https://ent-a.example/feed", category: "Entertainment"),
            ],
            items: [
                item(id: "sports-1", sourceURL: "https://sports-a.example/feed", category: "Sports", daysAgo: 3),
                item(id: "news-1", sourceURL: "https://news-a.example/feed", category: "News & Current Affairs"),
                item(id: "ent-1", sourceURL: "https://ent-a.example/feed", category: "Entertainment"),
                item(id: "culture-1", sourceURL: "https://culture-a.example/feed", category: "Arts & Culture", daysAgo: 1),
            ]
        )

        let cards = await loader.previewCuratedCards(
            recipe: nil,
            evidence: CuratedProfileDefinition(weights: [
                "topic:news-current-affairs": 3,
                "topic:arts-culture": 2,
                "topic:entertainment": -3,
            ])
        )

        // Distinct multipliers: news (≈1.21) > culture (≈1.16) > sports (1.08).
        // The disliked entertainment source drops below 1.0 and is excluded.
        XCTAssertEqual(cards.map(\.item.id), ["news-1", "culture-1", "sports-1"])
    }

    func testPreviewCuratedCardsRespectsLimit() async throws {
        let (_, loader) = try await makeStore(
            sources: [
                source(title: "News A", url: "https://news-a.example/feed", category: "News & Current Affairs"),
                source(title: "Culture A", url: "https://culture-a.example/feed", category: "Arts & Culture"),
                source(title: "Sports A", url: "https://sports-a.example/feed", category: "Sports"),
            ],
            items: [
                item(id: "sports-1", sourceURL: "https://sports-a.example/feed", category: "Sports"),
                item(id: "news-1", sourceURL: "https://news-a.example/feed", category: "News & Current Affairs"),
                item(id: "culture-1", sourceURL: "https://culture-a.example/feed", category: "Arts & Culture"),
            ]
        )

        let cards = await loader.previewCuratedCards(
            recipe: nil,
            evidence: CuratedProfileDefinition(weights: [
                "topic:news-current-affairs": 3,
                "topic:arts-culture": 2,
            ]),
            limit: 2
        )

        XCTAssertEqual(cards.count, 2)
        XCTAssertEqual(cards.map(\.item.id), ["news-1", "culture-1"])
    }

    func testPreviewCuratedCardsRecipeDrivesRankingOverNeutralEvidence() async throws {
        let (_, loader) = try await makeStore(
            sources: [
                source(title: "News A", url: "https://news-a.example/feed", category: "News & Current Affairs"),
                source(title: "Culture A", url: "https://culture-a.example/feed", category: "Arts & Culture"),
            ],
            items: [
                item(id: "news-1", sourceURL: "https://news-a.example/feed", category: "News & Current Affairs"),
                item(id: "culture-1", sourceURL: "https://culture-a.example/feed", category: "Arts & Culture"),
            ]
        )

        // Explicit recipe choice (.more culture) with no learned evidence —
        // the recipe baseline alone must drive ranking.
        let recipe = FeedRecipeDefinition(topicPreferences: [
            CuratedTopic.artsCulture.featureKey: .more
        ])
        let cards = await loader.previewCuratedCards(
            recipe: recipe,
            evidence: CuratedProfileDefinition()
        )

        XCTAssertEqual(cards.map(\.item.id), ["culture-1", "news-1"])
    }

    func testPreviewCuratedCardsEvidenceLayersOnTopOfRecipe() async throws {
        let (_, loader) = try await makeStore(
            sources: [
                source(title: "News A", url: "https://news-a.example/feed", category: "News & Current Affairs"),
                source(title: "Culture A", url: "https://culture-a.example/feed", category: "Arts & Culture"),
            ],
            items: [
                item(id: "news-1", sourceURL: "https://news-a.example/feed", category: "News & Current Affairs"),
                item(id: "culture-1", sourceURL: "https://culture-a.example/feed", category: "Arts & Culture"),
            ]
        )

        // Recipe says culture, but strong learned evidence for news outranks it.
        let recipe = FeedRecipeDefinition(topicPreferences: [
            CuratedTopic.artsCulture.featureKey: .more
        ])
        let evidence = CuratedProfileDefinition(weights: [
            "topic:news-current-affairs": 3
        ])
        let cards = await loader.previewCuratedCards(
            recipe: recipe,
            evidence: evidence
        )

        XCTAssertEqual(cards.map(\.item.id), ["news-1", "culture-1"])
    }

    func testPreviewCuratedCardsFallsBackToVisiblePrefixWhenMultipliersEmpty() async throws {
        // qualityScore 50 makes every multiplier exactly 1.0, so the
        // sourceMultipliers dict is empty and the fallback path applies.
        let (_, loader) = try await makeStore(
            sources: [
                source(title: "A", url: "https://a.example/feed", category: "Sports", qualityScore: 50),
                source(title: "B", url: "https://b.example/feed", category: "Sports", qualityScore: 50),
                source(title: "C", url: "https://c.example/feed", category: "Sports", qualityScore: 50),
            ],
            items: [
                item(id: "a-1", sourceURL: "https://a.example/feed", category: "Sports", daysAgo: 0),
                item(id: "b-1", sourceURL: "https://b.example/feed", category: "Sports", daysAgo: 1),
                item(id: "c-1", sourceURL: "https://c.example/feed", category: "Sports", daysAgo: 2),
                item(id: "a-2", sourceURL: "https://a.example/feed", category: "Sports", daysAgo: 3),
            ]
        )

        let cards = await loader.previewCuratedCards(
            recipe: nil,
            evidence: CuratedProfileDefinition()
        )

        // Fallback takes the visible prefix and caps at the limit.
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards.map(\.item.id), Array(loader.items.prefix(3).map(\.id)))
    }

    func testPreviewPresentationsAreFreshAndTerminal() async throws {
        let (_, loader) = try await makeStore(
            sources: [
                source(title: "A", url: "https://a.example/feed", category: "Sports", qualityScore: 50),
            ],
            items: [
                item(id: "a-1", sourceURL: "https://a.example/feed", category: "Sports"),
                item(id: "a-2", sourceURL: "https://a.example/feed", category: "Sports"),
            ]
        )

        let cards = await loader.previewCuratedCards(
            recipe: nil,
            evidence: CuratedProfileDefinition()
        )

        XCTAssertEqual(cards.count, 2)
        for card in cards {
            // Preview items never inherit read/bookmark state.
            XCTAssertFalse(card.isRead, "preview cards must be stamped unread")
            XCTAssertFalse(card.isBookmarked, "preview cards must be stamped unbookmarked")
            // Items without image or article URLs resolve to terminal .none.
            XCTAssertEqual(card.media, .none)
            XCTAssertEqual(card.layout, .textOnly)
        }
    }

    // MARK: - Seeding helpers

    private func makeStore(
        sources: [FeedSource],
        items: [FeedItem]
    ) async throws -> (FeedStore, FeedLoader) {
        let store = try FeedStore(inMemory: true)
        store.registry.sources = sources
        try await store.db.write { db in
            for item in items {
                try FeedItemRecord(from: item, region: "global").insert(db)
            }
        }
        store.setFilter(region: nil, nodeIDs: [], type: .all, mood: .all, languages: [])

        // Poll for the async filter reload (300ms debounce + SQLite flush).
        let deadline = Date().addingTimeInterval(5)
        while store.visibleItems.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(store.visibleItems.isEmpty, "seeding should populate visibleItems")
        let loader = FeedLoader(store: store)
        return (store, loader)
    }

    private func source(
        title: String,
        url: String,
        category: String,
        qualityScore: Int? = 90
    ) -> FeedSource {
        FeedSource(
            title: title,
            url: url,
            category: category,
            region: "global",
            language: "en",
            qualityScore: qualityScore
        )
    }

    private func item(
        id: String,
        sourceURL: String,
        category: String,
        daysAgo: Int = 0
    ) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "Source \(id)",
            sourceURL: sourceURL,
            category: category,
            title: "Story \(id)",
            excerpt: "Excerpt for \(id)",
            url: "",   // no article URL → terminal .none media, no network in tests
            imageURL: nil,
            publishedAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!,
            region: "global",
            language: "en"
        )
    }
}
