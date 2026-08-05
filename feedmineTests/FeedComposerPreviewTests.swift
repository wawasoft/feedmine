import XCTest
@testable import feedmine

/// Integration coverage for the Composer preview pipeline
/// (`FeedLoader.previewCuratedCards`): limit enforcement, cancellation,
/// neutral vs. restrictive recipe behavior, and the 1.5s performance budget.
///
/// Seeding mirrors FeedPreviewPipelineTests: in-memory SQLite store,
/// registered sources, then a filter reload polled via `store.visibleItems`.
/// No network — seeded items carry no image/article URLs, so media resolves
/// to `.none` without ImageLoader downloads.
@MainActor
final class FeedComposerPreviewTests: XCTestCase {

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

    // MARK: - Limit enforcement

    func testPreviewCuratedCardsReturnsCorrectLimit() async throws {
        let (_, loader) = try await makeStore(
            sources: [
                source(title: "News A", url: "https://news-a.example/feed", category: "News & Current Affairs"),
                source(title: "Culture A", url: "https://culture-a.example/feed", category: "Arts & Culture"),
                source(title: "Sports A", url: "https://sports-a.example/feed", category: "Sports"),
                source(title: "Ent A", url: "https://ent-a.example/feed", category: "Entertainment"),
            ],
            items: [
                item(id: "news-1", sourceURL: "https://news-a.example/feed", category: "News & Current Affairs"),
                item(id: "culture-1", sourceURL: "https://culture-a.example/feed", category: "Arts & Culture"),
                item(id: "sports-1", sourceURL: "https://sports-a.example/feed", category: "Sports"),
                item(id: "ent-1", sourceURL: "https://ent-a.example/feed", category: "Entertainment"),
            ]
        )

        let cards = await loader.previewCuratedCards(
            recipe: FeedRecipeDefinition.neutral(languages: ["en"]),
            evidence: CuratedProfileDefinition(languages: ["en"]),
            limit: 2
        )

        XCTAssertEqual(cards.count, 2, "preview must return exactly the requested limit")
        for card in cards {
            XCTAssertFalse(card.item.id.isEmpty, "cards carry real items")
            // Media resolves to a terminal state with no network access.
            XCTAssertEqual(card.media, .none)
            XCTAssertEqual(card.layout, .textOnly)
        }
    }

    // MARK: - Cancellability

    func testPreviewIsCancellable() async throws {
        let (_, loader) = try await makeStore(
            sources: [
                source(title: "News A", url: "https://news-a.example/feed", category: "News & Current Affairs"),
                source(title: "Culture A", url: "https://culture-a.example/feed", category: "Arts & Culture"),
                source(title: "Sports A", url: "https://sports-a.example/feed", category: "Sports"),
                source(title: "Ent A", url: "https://ent-a.example/feed", category: "Entertainment"),
            ],
            items: [
                item(id: "news-1", sourceURL: "https://news-a.example/feed", category: "News & Current Affairs"),
                item(id: "culture-1", sourceURL: "https://culture-a.example/feed", category: "Arts & Culture"),
                item(id: "sports-1", sourceURL: "https://sports-a.example/feed", category: "Sports"),
                item(id: "ent-1", sourceURL: "https://ent-a.example/feed", category: "Entertainment"),
            ]
        )

        let task = Task {
            await loader.previewCuratedCards(
                recipe: FeedRecipeDefinition.neutral(languages: ["en"]),
                evidence: CuratedProfileDefinition(languages: ["en"]),
                limit: 3
            )
        }
        task.cancel()
        let result = await task.value

        // Cancellation must not crash or exceed the limit — the result is
        // empty or a partial slice of already-resolved presentations.
        XCTAssertLessThanOrEqual(result.count, 3)
    }

    // MARK: - Recipe behavior

    func testNeutralRecipeProducesCards() async throws {
        let (_, loader) = try await makeStore(
            sources: [
                source(title: "News A", url: "https://news-a.example/feed", category: "News & Current Affairs"),
                source(title: "Culture A", url: "https://culture-a.example/feed", category: "Arts & Culture"),
                source(title: "Sports A", url: "https://sports-a.example/feed", category: "Sports"),
            ],
            items: [
                item(id: "news-1", sourceURL: "https://news-a.example/feed", category: "News & Current Affairs"),
                item(id: "culture-1", sourceURL: "https://culture-a.example/feed", category: "Arts & Culture"),
                item(id: "sports-1", sourceURL: "https://sports-a.example/feed", category: "Sports"),
            ]
        )

        let cards = await loader.previewCuratedCards(
            recipe: FeedRecipeDefinition.neutral(languages: ["en"]),
            evidence: CuratedProfileDefinition(languages: ["en"]),
            limit: 3
        )

        XCTAssertFalse(cards.isEmpty, "Neutral recipe should return cards")
        XCTAssertEqual(cards.count, 3)
    }

    func testRestrictiveRecipeMayReturnEmpty() async throws {
        let (_, loader) = try await makeStore(
            sources: [
                source(title: "News A", url: "https://news-a.example/feed", category: "News & Current Affairs"),
                source(title: "Culture A", url: "https://culture-a.example/feed", category: "Arts & Culture"),
                source(title: "Sports A", url: "https://sports-a.example/feed", category: "Sports"),
                source(title: "Ent A", url: "https://ent-a.example/feed", category: "Entertainment"),
            ],
            items: [
                item(id: "news-1", sourceURL: "https://news-a.example/feed", category: "News & Current Affairs"),
                item(id: "culture-1", sourceURL: "https://culture-a.example/feed", category: "Arts & Culture"),
                item(id: "sports-1", sourceURL: "https://sports-a.example/feed", category: "Sports"),
                item(id: "ent-1", sourceURL: "https://ent-a.example/feed", category: "Entertainment"),
            ]
        )

        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        for topic in CuratedTopic.allCases {
            recipe.topicPreferences[topic.featureKey] = .less
        }
        for style in CuratedEditorialStyle.allCases {
            recipe.editorialPreferences[style.featureKey] = .less
        }
        recipe.mediaTypes = []

        let evidence = CuratedProfileDefinition(languages: ["en"])
        let cards = await loader.previewCuratedCards(
            recipe: recipe,
            evidence: evidence,
            limit: 3
        )

        // Empty or partial is valid behavior — but restrictive must never
        // broaden the preview relative to the neutral recipe on the same store.
        let neutralCards = await loader.previewCuratedCards(
            recipe: FeedRecipeDefinition.neutral(languages: ["en"]),
            evidence: evidence,
            limit: 3
        )
        XCTAssertLessThanOrEqual(cards.count, 3)
        XCTAssertLessThan(cards.count, neutralCards.count,
            "restrictive recipe must narrow the preview")
    }

    // MARK: - Performance benchmark

    func testPreviewPerformance() async throws {
        let (_, loader) = try await makeStore(
            sources: [
                source(title: "News A", url: "https://news-a.example/feed", category: "News & Current Affairs"),
                source(title: "Culture A", url: "https://culture-a.example/feed", category: "Arts & Culture"),
                source(title: "Sports A", url: "https://sports-a.example/feed", category: "Sports"),
                source(title: "Ent A", url: "https://ent-a.example/feed", category: "Entertainment"),
            ],
            items: [
                item(id: "news-1", sourceURL: "https://news-a.example/feed", category: "News & Current Affairs"),
                item(id: "news-2", sourceURL: "https://news-a.example/feed", category: "News & Current Affairs"),
                item(id: "news-3", sourceURL: "https://news-a.example/feed", category: "News & Current Affairs"),
                item(id: "culture-1", sourceURL: "https://culture-a.example/feed", category: "Arts & Culture"),
                item(id: "culture-2", sourceURL: "https://culture-a.example/feed", category: "Arts & Culture"),
                item(id: "sports-1", sourceURL: "https://sports-a.example/feed", category: "Sports"),
                item(id: "sports-2", sourceURL: "https://sports-a.example/feed", category: "Sports"),
                item(id: "ent-1", sourceURL: "https://ent-a.example/feed", category: "Entertainment"),
                item(id: "ent-2", sourceURL: "https://ent-a.example/feed", category: "Entertainment"),
                item(id: "ent-3", sourceURL: "https://ent-a.example/feed", category: "Entertainment"),
            ]
        )

        let recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        let evidence = CuratedProfileDefinition(languages: ["en"])

        let start = CFAbsoluteTimeGetCurrent()
        let cards = await loader.previewCuratedCards(
            recipe: recipe,
            evidence: evidence,
            limit: 3
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThanOrEqual(
            elapsed, 1.5,
            "Preview must complete within 1.5s on test device (took \(elapsed)s)"
        )
        XCTAssertFalse(cards.isEmpty)
        XCTAssertEqual(cards.count, 3)
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
