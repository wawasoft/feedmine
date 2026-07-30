import Foundation

// MARK: - Selection Card Preparation Service
//
// Protocol that wraps CardPreparationCoordinator behind a selection-aware
// interface. The adapter translates ResolvedSelectionPlan into the existing
// coordinator calls without rewriting the coordinator itself.

/// Result of preparing an initial snapshot of cards.
struct PreparedSnapshotResult: Sendable {
    let cards: [PreparedFeedCard]
    let allTerminal: Bool  // true if every card has a terminal presentation
    let pendingCount: Int  // cards still being prepared
}

/// Protocol for preparing cards within a selection context.
/// The existing CardPreparationCoordinator is wrapped by an adapter
/// that conforms to this protocol.
protocol SelectionCardPreparing: Sendable {
    /// Prepare the initial snapshot from a batch of items.
    func prepareInitialSnapshot(
        items: [FeedItem],
        policy: PresentationPolicy,
        context: SelectionContext
    ) async -> PreparedSnapshotResult

    /// Prepare additional cards for pagination.
    func prepareAdditionalCards(
        items: [FeedItem],
        policy: PresentationPolicy,
        context: SelectionContext
    ) async -> [PreparedFeedCard]

    /// Cancel preparation for a selection context.
    func cancel(context: SelectionContext) async
}

// MARK: - Card Preparation Coordinator Adapter
//
// Wraps the existing CardPreparationCoordinator to conform to
// SelectionCardPreparing. Does NOT rewrite the coordinator —
// only translates between the selection model and the coordinator's API.

/// Adapter that bridges the existing CardPreparationCoordinator to the
/// SelectionCardPreparing protocol. This is a thin wrapper — the coordinator's
/// contiguous-prefix promotion, deadline hierarchy, memory pressure demotion,
/// and wake-on-render-ready behavior are all preserved.
@MainActor
final class CardPreparationCoordinatorAdapter: SelectionCardPreparing {

    private let coordinator: CardPreparationCoordinator

    init(coordinator: CardPreparationCoordinator) {
        self.coordinator = coordinator
    }

    func prepareInitialSnapshot(
        items: [FeedItem],
        policy: PresentationPolicy,
        context: SelectionContext
    ) async -> PreparedSnapshotResult {
        // Delegate to the existing coordinator's initial preparation.
        // The coordinator already handles:
        // - Deadline hierarchy (6s first paint, 15s runway, 30s deep)
        // - Contiguous prefix promotion
        // - Memory pressure demotion
        // - Wake-on-render-ready via CheckedContinuation

        // For Phase 1 (shadow mode), this is a pass-through.
        // In Phase 3, we wire the coordinator to receive ResolvedPresentationPlan
        // and return PreparedFeedCards keyed by SelectionContext.

        // Placeholder — will be wired in Phase 3
        return PreparedSnapshotResult(cards: [], allTerminal: false, pendingCount: items.count)
    }

    func prepareAdditionalCards(
        items: [FeedItem],
        policy: PresentationPolicy,
        context: SelectionContext
    ) async -> [PreparedFeedCard] {
        // Placeholder — will be wired in Phase 3
        return []
    }

    func cancel(context: SelectionContext) async {
        // Cancel preparation for this context
    }
}
