import Foundation

// MARK: - Search Selection Adapter

struct SearchSelectionAdapter: Sendable {
    let idGenerator: SelectionIDGenerator

    func makeSearchRequest(
        expression: SearchExpression,
        sourceScope: SourceUniversePolicy,
        languages: Set<String>,
        contentFilterKeywords: Set<String>
    ) -> ContentSelectionRequest {
        ContentSelectionRequest(
            id: idGenerator.nextID(),
            surface: .search(expression),
            sourceUniverse: sourceScope,
            criteria: ItemCriteria(
                regions: [],
                taxonomyNodeIDs: [],
                languages: languages,
                contentTypes: [],
                mood: .all,
                searchExpression: expression,
                excludedKeywords: [],
                contentFilterKeywords: contentFilterKeywords
            ),
            ranking: RankingProfile(signals: [.freshness(weight: 1.0)]),
            mix: .defaultFeed,
            history: .defaultFeed,
            acquisition: .cacheThenSweep,
            presentation: .defaultFeed,
            completion: .mainFeedWarm
        )
    }
}
