import Foundation

// MARK: - Scoped Surface Adapters
//
// Adapters for fixed-scope surfaces: Source View, Collection View,
// Bookmarks, and Last Clicked. Each creates its own SelectionSession.
//
// Adapters can ONLY create requests. They must NOT:
//   - Query SQLite directly
//   - Call fetcher
//   - Filter arrays
//   - Publish items
//   - Prepare images

// MARK: - Source View Adapter

struct SourceViewSelectionAdapter: Sendable {
    let idGenerator: SelectionIDGenerator

    func makeRequest(sourceID: SourceID) -> ContentSelectionRequest {
        ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .source(sourceID),
            sourceUniverse: .single(sourceID),
            criteria: .none,
            ranking: RankingProfile(signals: [.freshness(weight: 1.0)]),
            mix: .defaultFeed,
            history: .includeAll,
            acquisition: .refreshExactSources,
            presentation: .sourceView,
            completion: .sourceView
        )
    }
}

// MARK: - Collection View Adapter

struct CollectionSelectionAdapter: Sendable {
    let idGenerator: SelectionIDGenerator

    func makeRequest(
        collectionID: Int64,
        memberIDs: Set<SourceID>,
        languages: Set<String>,
        contentFilterKeywords: Set<String>
    ) -> ContentSelectionRequest {
        ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .collection(collectionID),
            sourceUniverse: .explicitAllowlist(memberIDs),
            criteria: ItemCriteria(
                regions: [],
                taxonomyNodeIDs: [],
                languages: languages,
                contentTypes: [],
                mood: .all,
                searchExpression: nil,
                excludedKeywords: [],
                contentFilterKeywords: contentFilterKeywords
            ),
            ranking: .none,
            mix: .defaultFeed,
            history: .defaultFeed,
            acquisition: .cacheThenNetwork,
            presentation: .defaultFeed,
            completion: .mainFeedWarm
        )
    }

    /// Collection used as a preset — same request, but allowlist-driven.
    func makePresetRequest(
        collectionID: Int64,
        memberIDs: Set<SourceID>,
        languages: Set<String>,
        contentFilterKeywords: Set<String>
    ) -> ContentSelectionRequest {
        makeRequest(
            collectionID: collectionID,
            memberIDs: memberIDs,
            languages: languages,
            contentFilterKeywords: contentFilterKeywords
        )
    }
}

// MARK: - Bookmarks Adapter

struct BookmarksSelectionAdapter: Sendable {
    let idGenerator: SelectionIDGenerator

    func makeRequest(
        listID: Int64?,
        sourceIDs: Set<SourceID>,
        bookmarkedItemIDs: Set<String>
    ) -> ContentSelectionRequest {
        var history = HistoryPolicy.includeAll
        history.includeBookmarked = true  // We want bookmarked items
        // Only bookmarked items — handled by the caller filtering the cache query

        return ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .bookmarks(listID),
            sourceUniverse: .fixedSnapshot(sourceIDs),
            criteria: .none,
            ranking: .none,
            mix: .defaultFeed,
            history: history,
            acquisition: .cacheOnly,
            presentation: .defaultFeed,
            completion: .bookmarks
        )
    }
}

// MARK: - Last Clicked Adapter

struct LastClickedSelectionAdapter: Sendable {
    let idGenerator: SelectionIDGenerator

    func makeRequest(clickedItemIDs: Set<String>, clickedSourceIDs: Set<SourceID>) -> ContentSelectionRequest {
        ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .lastClicked,
            sourceUniverse: .fixedSnapshot(clickedSourceIDs),
            criteria: .none,
            ranking: RankingProfile(signals: [.freshness(weight: 1.0)]),
            mix: .defaultFeed,
            history: .includeAll,
            acquisition: .cacheOnly,
            presentation: .defaultFeed,
            completion: .bookmarks
        )
    }
}

// MARK: - Smart Feed Adapter

struct SmartFeedSelectionAdapter: Sendable {
    let idGenerator: SelectionIDGenerator

    func makeRequest(
        smartFeedID: Int64,
        query: String,
        region: String?,
        taxonomyNodeIDs: Set<String>,
        languages: Set<String>,
        contentType: ContentType?,
        mood: MoodFilter,
        collectionMemberIDs: Set<SourceID>?,
        excludedKeywords: Set<String>,
        contentFilterKeywords: Set<String>,
        allowlistSourceIDs: Set<SourceID>,
        allowlistItemIDs: Set<String>
    ) -> ContentSelectionRequest {
        let sourceUniverse: SourceUniversePolicy = {
            if let members = collectionMemberIDs, !members.isEmpty {
                return .explicitAllowlist(members)
            }
            if !allowlistSourceIDs.isEmpty {
                return .explicitAllowlist(allowlistSourceIDs)
            }
            return .enabledLibrary
        }()

        let searchExpr = query.isEmpty ? nil : SearchExpression(legacyQuery: query)

        return ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .smartFeed(smartFeedID),
            sourceUniverse: sourceUniverse,
            criteria: ItemCriteria(
                regions: region.map { [$0] } ?? [],
                taxonomyNodeIDs: taxonomyNodeIDs,
                languages: languages,
                contentTypes: contentType.map { [$0] } ?? [],
                mood: mood,
                searchExpression: searchExpr,
                excludedKeywords: excludedKeywords,
                contentFilterKeywords: contentFilterKeywords
            ),
            ranking: .none,
            mix: .defaultFeed,
            history: HistoryPolicy(
                includeRead: true,
                includeConsumed: true,  // Smart Feeds keep consumed items
                includeBookmarked: true,
                excludeAlreadyLoaded: false,
                excludeSurfaced: false,
                dateRange: nil
            ),
            acquisition: .cacheThenNetwork,
            presentation: .defaultFeed,
            completion: .mainFeedWarm
        )
    }
}

// MARK: - Onboarding Adapter

struct OnboardingSelectionAdapter: Sendable {
    let idGenerator: SelectionIDGenerator

    func makeComparisonRequest(
        languages: Set<String>
    ) -> ContentSelectionRequest {
        ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .onboardingComparison,
            sourceUniverse: .enabledLibrary,
            criteria: ItemCriteria(
                regions: [],
                taxonomyNodeIDs: [],
                languages: languages,
                contentTypes: [],
                mood: .all,
                searchExpression: nil,
                excludedKeywords: [],
                contentFilterKeywords: []
            ),
            ranking: RankingProfile(signals: [
                .sourceQuality(weight: 0.5),
                .imageAvailability(weight: 0.3)
            ]),
            mix: MixPolicy(
                quotas: [],
                providerCooldown: 1,
                categoryCooldown: 1,
                regionCooldown: 1,
                mediaCooldown: 1,
                discoveryShare: 0.5
            ),
            history: .defaultFeed,
            acquisition: .cacheThenNetwork,
            presentation: PresentationPolicy(initialPageSize: 10, loadMorePageSize: 10),
            completion: CompletionPolicy(
                minimumCardCount: 2,
                preferredCardCount: 10,
                minimumDistinctSources: 2,
                minimumDistinctProviders: 1,
                maximumWait: .seconds(5),
                allowPartialAfterDeadline: true
            )
        )
    }

    func makeCuratedPreviewRequest(
        languages: Set<String>,
        contentFilterKeywords: Set<String>
    ) -> ContentSelectionRequest {
        ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .curatedPreview,
            sourceUniverse: .enabledLibrary,
            criteria: ItemCriteria(
                regions: [],
                taxonomyNodeIDs: [],
                languages: languages,
                contentTypes: [],
                mood: .all,
                searchExpression: nil,
                excludedKeywords: [],
                contentFilterKeywords: contentFilterKeywords
            ),
            ranking: .none,
            mix: .defaultFeed,
            history: .defaultFeed,
            acquisition: .cacheOnly,
            presentation: PresentationPolicy(initialPageSize: 3, loadMorePageSize: 0),
            completion: CompletionPolicy(
                minimumCardCount: 1,
                preferredCardCount: 3,
                minimumDistinctSources: 1,
                minimumDistinctProviders: 1,
                maximumWait: .seconds(2),
                allowPartialAfterDeadline: true
            )
        )
    }
}

// MARK: - What's New Adapter

struct WhatsNewSelectionAdapter: Sendable {
    let idGenerator: SelectionIDGenerator

    func makeRequest(
        baseCriteria: ItemCriteria,
        fetchedAfter: Date
    ) -> ContentSelectionRequest {
        ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .whatsNew,
            sourceUniverse: .enabledLibrary,
            criteria: baseCriteria,
            ranking: RankingProfile(signals: [.freshness(weight: 2.0)]),
            mix: MixPolicy(
                quotas: [],
                providerCooldown: 1,
                categoryCooldown: 1,
                regionCooldown: 2,
                mediaCooldown: 1,
                discoveryShare: 0.3
            ),
            history: HistoryPolicy(
                includeRead: false,
                includeConsumed: false,
                includeBookmarked: false,
                excludeAlreadyLoaded: true,
                excludeSurfaced: true,
                dateRange: fetchedAfter...Date()
            ),
            acquisition: .cacheThenNetwork,
            presentation: .compactCarousel,
            completion: CompletionPolicy(
                minimumCardCount: 1,
                preferredCardCount: 10,
                minimumDistinctSources: 1,
                minimumDistinctProviders: 1,
                maximumWait: .seconds(3),
                allowPartialAfterDeadline: true
            )
        )
    }
}
