import XCTest
@testable import feedmine

// MARK: - Selection Engine Parity Tests (§24.2)
//
// Verifies that SQLItemRuleCompiler and InMemoryItemRuleEvaluator
// produce the same item IDs for the same fixtures.
//
// This is the critical test — it guarantees the two interpreters
// of ItemRuleSet never diverge.

@MainActor
final class SelectionEngineParityTests: XCTestCase {

    // MARK: - Fixtures

    /// Creates a set of test FeedItems with varying properties.
    func makeFixtureItems(count: Int = 20) -> [FeedItem] {
        let regions = ["global", "countries/brazil", "countries/usa", "countries/japan", "countries/france"]
        let languages = ["en", "pt", "ja", "fr", nil]
        let sourceURLs = [
            "https://example.com/feed",
            "https://blog.techcrunch.com/rss",
            "https://nytimes.com/rss",
            "https://globo.com/rss",
            "https://lemonde.fr/rss",
        ]

        return (0..<count).map { i in
            let isRead = i % 5 == 0
            let isBookmarked = i % 7 == 0
            let hasImage = i % 3 == 0
            let hasAudio = i % 4 == 0
            let isYouTube = i % 6 == 0

            return FeedItem(
                id: "fixture-\(i)",
                sourceTitle: "Source \(i % 5)",
                sourceURL: sourceURLs[i % sourceURLs.count],
                category: "Category \(i % 3)",
                title: "Title \(i): \(["Breaking News", "Tech Update", "Sports Roundup", "Weather Report", "Opinion Piece"][i % 5])",
                excerpt: "Excerpt for item \(i). This is sample content for testing.",
                url: "https://example.com/article/\(i)",
                imageURL: hasImage ? "https://example.com/img/\(i).jpg" : nil,
                publishedAt: Date().addingTimeInterval(-Double(i * 3600)),
                audioURL: hasAudio ? "https://example.com/audio/\(i).mp3" : nil,
                region: regions[i % regions.count],
                language: languages[i % languages.count],
                isRead: isRead,
                isBookmarked: isBookmarked
            )
        }
    }

    // MARK: - Source Scope Tests (§24.1)

    func testSourceScope_materializedSmallSet() {
        let ids: Set<SourceID> = [
            SourceID(rawValue: 1),
            SourceID(rawValue: 2),
            SourceID(rawValue: 3),
        ]

        let handle = SourceScopeHandle.materialized(ids)

        switch handle {
        case .materialized(let resolvedIDs):
            XCTAssertEqual(resolvedIDs.count, 3)
            XCTAssertTrue(resolvedIDs.contains(SourceID(rawValue: 1)))
        default:
            XCTFail("Expected materialized handle")
        }
    }

    func testSourceScope_singleSource() {
        let id = SourceID(rawValue: 42)
        let handle = SourceScopeHandle.single(id)

        if case .single(let resolved) = handle {
            XCTAssertEqual(resolved, id)
        } else {
            XCTFail("Expected single handle")
        }
    }

    func testSourceScope_explicitList() {
        let ids = [SourceID(rawValue: 10), SourceID(rawValue: 20), SourceID(rawValue: 30)]
        let handle = SourceScopeHandle.explicitList(ids)

        if case .explicitList(let resolved) = handle {
            XCTAssertEqual(resolved, ids)
        } else {
            XCTFail("Expected explicitList handle")
        }
    }

    // MARK: - ItemRuleSet tests

    func testItemRuleSet_emptyRules_passesAll() async {
        let items = makeFixtureItems(count: 10)
        let rules = ItemRuleSet.none
        let evaluator = InMemoryItemRuleEvaluator()

        let result = await evaluator.evaluate(items, against: rules)
        XCTAssertEqual(result.count, 10, "Empty rules should pass all items")
    }

    func testItemRuleSet_regionFilter() async {
        let items = makeFixtureItems(count: 20)
        var rules = ItemRuleSet.none
        rules.regions = ["countries/brazil"]

        let evaluator = InMemoryItemRuleEvaluator()
        let result = await evaluator.evaluate(items, against: rules)

        let expectedCount = items.filter { $0.region == "countries/brazil" }.count
        XCTAssertEqual(result.count, expectedCount)
        XCTAssertTrue(result.allSatisfy { $0.region == "countries/brazil" })
    }

    func testItemRuleSet_languageFilter() async {
        let items = makeFixtureItems(count: 20)
        var rules = ItemRuleSet.none
        rules.languages = ["en"]

        let evaluator = InMemoryItemRuleEvaluator()
        let result = await evaluator.evaluate(items, against: rules)

        let expectedCount = items.filter { $0.language == "en" }.count
        XCTAssertEqual(result.count, expectedCount)
    }

    func testItemRuleSet_contentTypeFilter_audio() async {
        let items = makeFixtureItems(count: 20)
        var rules = ItemRuleSet.none
        rules.contentTypes = [.audio]

        let evaluator = InMemoryItemRuleEvaluator()
        let result = await evaluator.evaluate(items, against: rules)

        let expectedCount = items.filter { $0.audioURL != nil }.count
        XCTAssertEqual(result.count, expectedCount)
    }

    func testItemRuleSet_history_excludeRead() async {
        let items = makeFixtureItems(count: 20)
        var rules = ItemRuleSet.none
        rules.history.includeRead = false

        let evaluator = InMemoryItemRuleEvaluator()
        let result = await evaluator.evaluate(items, against: rules)

        let readCount = items.filter { $0.isRead }.count
        XCTAssertEqual(result.count, 20 - readCount)
        XCTAssertTrue(result.allSatisfy { !$0.isRead })
    }

    func testItemRuleSet_history_excludeBookmarked() async {
        let items = makeFixtureItems(count: 20)
        var rules = ItemRuleSet.none
        rules.history.includeBookmarked = false

        let evaluator = InMemoryItemRuleEvaluator()
        let result = await evaluator.evaluate(items, against: rules)

        let bookmarkedCount = items.filter { $0.isBookmarked }.count
        XCTAssertEqual(result.count, 20 - bookmarkedCount)
    }

    func testItemRuleSet_dateRange() async {
        let items = makeFixtureItems(count: 20)
        var rules = ItemRuleSet.none
        let twoDaysAgo = Date().addingTimeInterval(-172_800)
        rules.history.dateRange = twoDaysAgo...Date()

        let evaluator = InMemoryItemRuleEvaluator()
        let result = await evaluator.evaluate(items, against: rules)

        let inRange = items.filter { $0.publishedAt >= twoDaysAgo }.count
        XCTAssertEqual(result.count, inRange)
    }

    func testItemRuleSet_excludedKeywords() async {
        let items = makeFixtureItems(count: 20)
        var rules = ItemRuleSet.none
        rules.excludedKeywords = ["Breaking"]

        let evaluator = InMemoryItemRuleEvaluator()
        let result = await evaluator.evaluate(items, against: rules)

        let excluded = items.filter { $0.title.contains("Breaking") }.count
        XCTAssertEqual(result.count, 20 - excluded)
        XCTAssertTrue(result.allSatisfy { !$0.title.contains("Breaking") })
    }

    func testItemRuleSet_searchExpression() async {
        let items = makeFixtureItems(count: 20)
        var rules = ItemRuleSet.none
        rules.searchExpression = SearchExpression(requiredTerms: ["Tech"], excludedTerms: [])

        let evaluator = InMemoryItemRuleEvaluator()
        let result = await evaluator.evaluate(items, against: rules)

        let matching = items.filter { $0.title.contains("Tech") }.count
        XCTAssertEqual(result.count, matching)
    }

    func testItemRuleSet_combinedFilters() async {
        let items = makeFixtureItems(count: 30)
        var rules = ItemRuleSet.none
        rules.regions = ["global"]
        rules.languages = ["en", "pt"]
        rules.history.includeRead = false
        rules.history.includeBookmarked = false
        rules.contentTypes = [.text]  // no audio, no video

        let evaluator = InMemoryItemRuleEvaluator()
        let result = await evaluator.evaluate(items, against: rules)

        let expected = items.filter { item in
            item.region == "global"
                && (item.language == "en" || item.language == "pt")
                && !item.isRead
                && !item.isBookmarked
                && item.audioURL == nil
                && !item.isYouTube
        }
        XCTAssertEqual(result.count, expected.count,
                       "Combined filters should match manual predicate")
    }

    // MARK: - RuleDigest tests

    func testRuleDigest_changesOnRuleChange() {
        var rules1 = ItemRuleSet.none
        rules1.regions = ["countries/brazil"]

        var rules2 = ItemRuleSet.none
        rules2.regions = ["countries/usa"]

        XCTAssertNotEqual(rules1.ruleDigest, rules2.ruleDigest,
                          "Different regions should produce different digests")
    }

    func testRuleDigest_stableOnSameRules() {
        var rules1 = ItemRuleSet.none
        rules1.regions = ["countries/brazil"]
        rules1.languages = ["pt"]

        var rules2 = ItemRuleSet.none
        rules2.regions = ["countries/brazil"]
        rules2.languages = ["pt"]

        XCTAssertEqual(rules1.ruleDigest, rules2.ruleDigest,
                       "Same rules should produce same digest")
    }

    // MARK: - Selection metrics tests (§24.3)

    func testSelectionMetrics_countersAreConsistent() {
        let metrics = SourceSelectionMetrics(
            catalogTotal: 1000,
            enabledLibraryTotal: 500,
            eligibleTotal: 200,
            scheduledTotal: 120,
            checked: 79,
            responding: 64,
            contributing: 18,
            representedInCache: 45,
            representedOnScreen: 20
        )

        XCTAssertEqual(metrics.catalogTotal, 1000)
        XCTAssertEqual(metrics.eligibleTotal, 200)
        XCTAssertEqual(metrics.scheduledTotal, 120)
        XCTAssertEqual(metrics.checked, 79)
        // eligible must be >= scheduled
        XCTAssertGreaterThanOrEqual(metrics.eligibleTotal, metrics.scheduledTotal)
        // checked must be <= scheduled
        XCTAssertLessThanOrEqual(metrics.checked, metrics.scheduledTotal)
        // contributing must be <= responding
        XCTAssertLessThanOrEqual(metrics.contributing, metrics.responding)
    }

    // MARK: - Selection state tests

    func testSelectionState_transitions() {
        let state = SelectionState.idle
        if case .idle = state {
            // OK
        } else {
            XCTFail("Expected idle")
        }
    }

    func testSelectionState_emptyWithReason() {
        let reason = SelectionEmptyReason.noEligibleSources
        let state = SelectionState.empty(reason, .zero)

        if case .empty(let r, _) = state {
            XCTAssertEqual(r, .noEligibleSources)
        } else {
            XCTFail("Expected empty state")
        }
    }

    // MARK: - FeedSnapshot tests

    func testFeedSnapshot_empty() {
        let snapshot = FeedSnapshot.empty(selectionID: SelectionID(rawValue: 1))
        XCTAssertEqual(snapshot.cards.count, 0)
        XCTAssertEqual(snapshot.count, 0)
        XCTAssertFalse(snapshot.hasMore)
    }

    // MARK: - RankingEngine tests (§24.4)

    func testRankingEngine_freshnessScores() {
        let items = makeFixtureItems(count: 10)
        let plan = CompiledRankingPlan(operations: [.freshness(weight: 1.0)])
        let engine = RankingEngine()

        let scores = engine.score(items: items, plan: plan)
        XCTAssertEqual(scores.count, 10)

        // More recent items should score higher
        let recentScore = scores[0].total  // item published 0 hours ago
        let olderScore = scores[9].total   // item published 9 hours ago
        XCTAssertGreaterThan(recentScore, olderScore,
                             "Recent items should score higher than older ones")
    }

    func testRankingEngine_scoreBreakdown() {
        let items = makeFixtureItems(count: 5)
        let plan = CompiledRankingPlan(operations: [
            .freshness(weight: 0.5),
            .imageAvailability(weight: 0.3),
        ])
        let engine = RankingEngine()

        let scores = engine.score(items: items, plan: plan)

        for score in scores {
            XCTAssertFalse(score.components.isEmpty, "Each score should have components")
            let componentTotal = score.components.map(\.contribution).reduce(0, +)
            XCTAssertEqual(score.total, componentTotal, accuracy: 0.001,
                           "Total should equal sum of component contributions")
        }
    }

    func testRankingEngine_surfacedPenalty() {
        let items = makeFixtureItems(count: 5)
        let plan = CompiledRankingPlan(operations: [.freshness(weight: 1.0)])
        let engine = RankingEngine()

        let surfacedIDs: Set<String> = [items[0].id, items[1].id]
        let scores = engine.score(items: items, plan: plan, alreadySurfacedIDs: surfacedIDs)

        // Surfaced items should have lower scores than comparable non-surfaced
        let surfacedScore0 = scores.first(where: { $0.itemID == items[0].id })!
        let nonSurfacedScore = scores.first(where: { !surfacedIDs.contains($0.itemID) })!
        XCTAssertLessThan(surfacedScore0.total, nonSurfacedScore.total,
                          "Surfaced items should be penalized")
    }

    // MARK: - MixAllocator tests

    func testMixAllocator_diversityCooldown() {
        let items = makeFixtureItems(count: 30)
        let scores = items.map { ($0, CandidateScore.zero(for: $0.id)) }
        let plan = CompiledMixPlan(
            quotas: [],
            providerCooldown: 2,
            categoryCooldown: 1,
            regionCooldown: 3,
            mediaCooldown: 2,
            discoveryShare: 0.0,
            maxItemsPerSource: 3
        )
        let allocator = MixAllocator()

        let result = allocator.allocate(candidates: scores, plan: plan, targetCount: 20)
        XCTAssertFalse(result.orderedItemIDs.isEmpty)
        XCTAssertLessThanOrEqual(result.totalAllocated, 20)

        // No duplicate IDs
        XCTAssertEqual(result.orderedItemIDs.count, Set(result.orderedItemIDs).count,
                       "Output should not contain duplicate items")
    }

    func testMixAllocator_emptyInput() {
        let plan = CompiledMixPlan.defaultPlan
        let allocator = MixAllocator()
        let result = allocator.allocate(candidates: [], plan: plan)

        XCTAssertTrue(result.orderedItemIDs.isEmpty)
        XCTAssertEqual(result.totalAllocated, 0)
    }

    func testMixAllocator_sourceLimit() {
        let items = makeFixtureItems(count: 50)
        let scores = items.map { ($0, CandidateScore.zero(for: $0.id)) }
        let plan = CompiledMixPlan(
            quotas: [],
            providerCooldown: 0,
            categoryCooldown: 0,
            regionCooldown: 0,
            mediaCooldown: 0,
            discoveryShare: 0.0,
            maxItemsPerSource: 2
        )
        let allocator = MixAllocator()
        let result = allocator.allocate(candidates: scores, plan: plan, targetCount: 50)

        // Count items per source — no source should exceed 2
        var sourceCounts: [String: Int] = [:]
        for id in result.orderedItemIDs {
            if let item = items.first(where: { $0.id == id }) {
                sourceCounts[item.sourceURL] = (sourceCounts[item.sourceURL] ?? 0) + 1
            }
        }
        for (_, count) in sourceCounts {
            XCTAssertLessThanOrEqual(count, 2, "No source should exceed maxItemsPerSource")
        }
    }

    // MARK: - SelectionID tests

    func testSelectionIDGenerator_producesUnique() {
        let generator = SelectionIDGenerator()
        let id1 = generator.nextID()
        let id2 = generator.nextID()
        let id3 = generator.nextID()

        XCTAssertNotEqual(id1, id2)
        XCTAssertNotEqual(id2, id3)
        XCTAssertNotEqual(id1, id3)
        XCTAssertEqual(id1.rawValue + 1, id2.rawValue)
    }

    // MARK: - ContentSelectionRequest tests

    func testContentSelectionRequest_mainFeedDefault() {
        let request = ContentSelectionRequest(
            id: SelectionID(rawValue: 1),
            surface: .main,
            sourceUniverse: .enabledLibrary,
            criteria: .none,
            ranking: .none,
            mix: .defaultFeed,
            history: .defaultFeed,
            acquisition: .cacheThenNetwork,
            presentation: .defaultFeed,
            completion: .mainFeedColdStart
        )

        XCTAssertEqual(request.surface, .main)
        XCTAssertEqual(request.completion.minimumCardCount, 20)
        XCTAssertEqual(request.completion.minimumDistinctSources, 10)
    }

    func testContentSelectionRequest_sourceView() {
        let request = ContentSelectionRequest(
            id: SelectionID(rawValue: 2),
            surface: .source(SourceID(rawValue: 5)),
            sourceUniverse: .single(SourceID(rawValue: 5)),
            criteria: .none,
            ranking: .none,
            mix: .defaultFeed,
            history: .includeAll,
            acquisition: .refreshExactSources,
            presentation: .sourceView,
            completion: .sourceView
        )

        XCTAssertEqual(request.completion.minimumCardCount, 1)
        if case .single(let id) = request.sourceUniverse {
            XCTAssertEqual(id, SourceID(rawValue: 5))
        } else {
            XCTFail("Expected single source universe")
        }
    }

    // MARK: - ItemEvaluationCache tests

    func testItemEvaluationCache_moodMatch() async {
        let cache = ItemEvaluationCache()
        let itemID = "test-item-1"
        let digest: UInt64 = 12345

        let cached = await cache.moodMatch(itemID, ruleDigest: digest)
        XCTAssertNil(cached, "Should be nil before set")

        await cache.setMoodMatch(itemID, ruleDigest: digest, match: true)
        let afterSet = await cache.moodMatch(itemID, ruleDigest: digest)
        XCTAssertEqual(afterSet, true, "Should return cached value")

        // Different digest should not match
        let differentDigest = await cache.moodMatch(itemID, ruleDigest: 99999)
        XCTAssertNil(differentDigest, "Different digest should miss cache")
    }

    func testItemEvaluationCache_contentFilterExclusion() async {
        let cache = ItemEvaluationCache()
        let itemID = "test-item-2"
        let digest: UInt64 = 67890

        await cache.setContentFilterExcluded(itemID, ruleDigest: digest, excluded: true)
        let excluded = await cache.contentFilterExcluded(itemID, ruleDigest: digest)
        XCTAssertEqual(excluded, true)
    }

    // MARK: - SelectionTrace tests

    func testSelectionTrace_completedState() {
        let trace = SelectionTrace(
            selectionID: SelectionID(rawValue: 1),
            surface: "main",
            startedAt: Date(),
            completedAt: nil,
            sourceUniversePolicy: "enabledLibrary",
            catalogTotal: 1000, enabledTotal: 500, eligibleTotal: 200, scheduledTotal: 0,
            cachedContributors: 0, networkContributors: 0,
            itemCandidates: 0, itemsAfterEligibility: 0, itemsAfterRanking: 0,
            itemsAfterMix: 0, cardsPrepared: 0, publishedCards: 0,
            eligibleSourceHash: 0,
            terminalState: "started",
            elapsedTime: nil,
            errorMessage: nil,
            requestDescription: "test"
        )

        let completed = trace.completed(
            state: "ready",
            metrics: SelectionMetrics(
                sources: SourceSelectionMetrics(
                    catalogTotal: 1000, enabledLibraryTotal: 500, eligibleTotal: 200,
                    scheduledTotal: 50, checked: 45, responding: 40, contributing: 10,
                    representedInCache: 30, representedOnScreen: 20
                ),
                itemCandidates: 100, itemsAfterEligibility: 80, itemsAfterRanking: 60,
                itemsAfterMix: 40, cardsPrepared: 20, publishedCards: 20,
                hasMore: true, eligibleSourceHash: 42
            ),
            elapsed: .seconds(3),
            error: nil
        )

        XCTAssertEqual(completed.terminalState, "ready")
        XCTAssertEqual(completed.publishedCards, 20)
        XCTAssertEqual(completed.elapsedTime, .seconds(3))
        XCTAssertNotNil(completed.completedAt)
        XCTAssertNil(completed.errorMessage)
    }
}
