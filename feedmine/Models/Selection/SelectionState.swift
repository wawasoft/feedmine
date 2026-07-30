import Foundation

// MARK: - Selection State
//
// The complete state of a selection session, published to the UI.
// Replaces the scattered loadingState, visibleItems, visibleCards,
// and various counter properties on FeedStore.

/// Reason why a selection produced zero cards.
enum SelectionEmptyReason: Hashable, Sendable {
    /// No sources match the current filters.
    case noEligibleSources
    /// Sources exist but produced no items after eligibility rules.
    case noItemsAfterRules
    /// Items exist but none passed ranking/mix.
    case noItemsAfterComposition
    /// Network unavailable and cache is empty.
    case offlineWithEmptyCache
    /// Active search returned no results.
    case searchNoResults(SearchExpression)
}

/// Failure information when a selection cannot complete.
struct SelectionFailure: Hashable, Sendable {
    let message: String
    let recoverable: Bool
    let underlyingError: String?

    static func networkError(_ message: String) -> SelectionFailure {
        SelectionFailure(message: message, recoverable: true, underlyingError: message)
    }

    static func fatalError(_ message: String) -> SelectionFailure {
        SelectionFailure(message: message, recoverable: false, underlyingError: message)
    }
}

/// The complete state of a selection session.
/// Views render this enum directly — they never compute source universes,
/// progress, empty state, or ranking themselves.
///
/// Note: Not Hashable because FeedSnapshot contains PreparedFeedCard
/// which holds RenderReadyMedia (UIImage) via @unchecked Sendable.
enum SelectionState: Sendable {
    /// Nothing has started yet.
    case idle

    /// Initial preparation in progress.
    case preparing(SelectionProgress)

    /// Feed is ready with the given snapshot.
    case ready(FeedSnapshot)

    /// Refreshing while preserving the previous snapshot.
    case refreshing(previous: FeedSnapshot?, progress: SelectionProgress)

    /// Loading more items onto the current snapshot.
    case loadingMore(current: FeedSnapshot, progress: SelectionProgress)

    /// Selection completed with zero cards and a specific reason.
    case empty(SelectionEmptyReason, SelectionMetrics)

    /// Selection failed. Previous snapshot preserved if available.
    case failed(previous: FeedSnapshot?, SelectionFailure)

    /// User cancelled the selection.
    case cancelled
}
