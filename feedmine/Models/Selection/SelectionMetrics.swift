import Foundation

// MARK: - Selection Metrics
//
// Counters that describe the selection lifecycle: from catalog total
// through eligibility, scheduling, acquisition, and final contribution.
// Every UI surface (header, loading, empty state) reads the same structure.

/// Metrics for the source side of a selection.
struct SourceSelectionMetrics: Hashable, Sendable {
    /// Total sources in the catalog.
    let catalogTotal: Int
    /// Sources in the user's enabled library (defaults + toggles).
    let enabledLibraryTotal: Int
    /// Sources eligible for this selection (after applying filters + policy).
    let eligibleTotal: Int
    /// Sources scheduled for fetch in the current batch.
    let scheduledTotal: Int
    /// Sources that have been checked (fetch attempted).
    let checked: Int
    /// Sources that responded with data.
    let responding: Int
    /// Sources that contributed at least one item to the final result.
    let contributing: Int
    /// Sources with items available in cache.
    let representedInCache: Int
    /// Sources with items currently on screen.
    let representedOnScreen: Int

    static let zero = SourceSelectionMetrics(
        catalogTotal: 0, enabledLibraryTotal: 0, eligibleTotal: 0,
        scheduledTotal: 0, checked: 0, responding: 0, contributing: 0,
        representedInCache: 0, representedOnScreen: 0
    )
}

/// Complete metrics for a selection session.
struct SelectionMetrics: Hashable, Sendable {
    /// Source-side counters.
    let sources: SourceSelectionMetrics

    /// Total item candidates considered (before eligibility).
    let itemCandidates: Int
    /// Items that passed eligibility rules.
    let itemsAfterEligibility: Int
    /// Items after ranking.
    let itemsAfterRanking: Int
    /// Items after mix allocation.
    let itemsAfterMix: Int
    /// Cards that were fully prepared.
    let cardsPrepared: Int
    /// Cards published to the UI.
    let publishedCards: Int

    /// Whether more content is available.
    let hasMore: Bool

    /// Ordered hash of eligible source IDs — for cross-checking
    /// that header, cache, and fetch agree on the same universe.
    let eligibleSourceHash: UInt64

    static let zero = SelectionMetrics(
        sources: .zero,
        itemCandidates: 0, itemsAfterEligibility: 0,
        itemsAfterRanking: 0, itemsAfterMix: 0,
        cardsPrepared: 0, publishedCards: 0,
        hasMore: false, eligibleSourceHash: 0
    )
}

// MARK: - Selection Progress

/// Progress of a selection session, for loading/refreshing UI.
struct SelectionProgress: Hashable, Sendable {
    /// Sources checked so far.
    let sourcesChecked: Int
    /// Sources scheduled in this batch.
    let sourcesScheduled: Int
    /// Total eligible sources.
    let sourcesEligible: Int
    /// Items found so far.
    let itemsFound: Int
    /// Cards prepared so far.
    let cardsPrepared: Int
    /// Phase description for the UI.
    let phase: SelectionPhase

    var sourceFraction: Double {
        guard sourcesScheduled > 0 else { return 0 }
        return Double(sourcesChecked) / Double(sourcesScheduled)
    }
}

enum SelectionPhase: Hashable, Sendable {
    case loadingCache
    case fetchingNetwork
    case preparingCards
    case ranking
    case mixing
    case complete
}
