import Foundation

// MARK: - Main Feed Selection Adapter
//
// Creates ContentSelectionRequests for the main feed surface.
// Adapters can ONLY create requests. They must NOT:
//   - Query SQLite
//   - Call fetcher
//   - Filter arrays
//   - Publish items
//   - Prepare images

/// Builds ContentSelectionRequests for the main feed under various
/// filter/preset/mode combinations. This replaces the scattered
/// decision logic currently in FeedStore startup, setFilter, setPreset, etc.
struct MainFeedSelectionAdapter: Sendable {

    let idGenerator: SelectionIDGenerator

    // MARK: - Default (no filters)

    func makeDefaultRequest(
        languages: Set<String>,
        contentFilterKeywords: Set<String>
    ) -> ContentSelectionRequest {
        ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .main,
            sourceUniverse: .enabledLibrary,
            criteria: ItemCriteria(
                regions: [],
                taxonomyNodeIDs: [],
                languages: languages,
                contentTypes: [],

                searchExpression: nil,
                excludedKeywords: [],
                contentFilterKeywords: contentFilterKeywords
            ),
            ranking: .none,
            mix: .defaultFeed,
            history: .defaultFeed,
            acquisition: .cacheThenNetwork,
            presentation: .defaultFeed,
            completion: .mainFeedColdStart
        )
    }

    // MARK: - With taxonomy filter

    func makeTaxonomyRequest(
        nodeIDs: Set<String>,
        languages: Set<String>,
        contentFilterKeywords: Set<String>
    ) -> ContentSelectionRequest {
        ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .main,
            sourceUniverse: .expandedCatalogRespectingExplicitOff,
            criteria: ItemCriteria(
                regions: [],
                taxonomyNodeIDs: nodeIDs,
                languages: languages,
                contentTypes: [],

                searchExpression: nil,
                excludedKeywords: [],
                contentFilterKeywords: contentFilterKeywords
            ),
            ranking: .none,
            mix: .defaultFeed,
            history: .defaultFeed,
            acquisition: .cacheThenNetwork,
            presentation: .defaultFeed,
            completion: .mainFeedColdStart
        )
    }

    // MARK: - With content type

    func makeContentTypeRequest(
        contentType: ContentType,
        languages: Set<String>,
        contentFilterKeywords: Set<String>
    ) -> ContentSelectionRequest {
        ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .main,
            sourceUniverse: .expandedCatalogRespectingExplicitOff,
            criteria: ItemCriteria(
                regions: [],
                taxonomyNodeIDs: [],
                languages: languages,
                contentTypes: contentType == .all ? [] : [contentType],

                searchExpression: nil,
                excludedKeywords: [],
                contentFilterKeywords: contentFilterKeywords
            ),
            ranking: .none,
            mix: .defaultFeed,
            history: .defaultFeed,
            acquisition: .cacheThenNetwork,
            presentation: .defaultFeed,
            completion: .mainFeedColdStart
        )
    }

    // MARK: - With editorial preset

    func makePresetRequest(
        preset: PresetSelector,
        languages: Set<String>,
        contentFilterKeywords: Set<String>
    ) -> ContentSelectionRequest {
        var ranking = RankingProfile()
        ranking.signals.append(.editorialPreset(preset))

        return ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .main,
            sourceUniverse: .enabledLibrary,
            criteria: ItemCriteria(
                regions: [],
                taxonomyNodeIDs: [],
                languages: languages,
                contentTypes: [],

                searchExpression: nil,
                excludedKeywords: [],
                contentFilterKeywords: contentFilterKeywords
            ),
            ranking: ranking,
            mix: .defaultFeed,
            history: .defaultFeed,
            acquisition: .cacheThenNetwork,
            presentation: .defaultFeed,
            completion: .mainFeedWarm
        )
    }

    // MARK: - Reset (clear all filters)

    func makeResetRequest(
        preservingSourceLibrary: Bool,
        contentFilterKeywords: Set<String>
    ) -> ContentSelectionRequest {
        ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .main,
            sourceUniverse: preservingSourceLibrary ? .enabledLibrary : .expandedCatalogRespectingExplicitOff,
            criteria: ItemCriteria(
                regions: [],
                taxonomyNodeIDs: [],
                languages: [],
                contentTypes: [],

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

    // MARK: - Region filter

    func makeRegionRequest(
        region: String,
        languages: Set<String>,
        contentFilterKeywords: Set<String>
    ) -> ContentSelectionRequest {
        ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .main,
            sourceUniverse: .enabledLibrary,
            criteria: ItemCriteria(
                regions: [region],
                taxonomyNodeIDs: [],
                languages: languages,
                contentTypes: [],

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

}
