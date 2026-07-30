import Foundation

// MARK: - Selection Trace
//
// Observability for every selection session. Emitted at session completion
// and used for debugging, regression testing, and shadow-mode comparison.

/// A complete trace of a selection session from request to snapshot.
struct SelectionTrace: Hashable, Sendable {
    // MARK: Identity
    let selectionID: SelectionID
    let surface: String  // SelectionSurface description
    let startedAt: Date
    let completedAt: Date?

    // MARK: Source universe
    let sourceUniversePolicy: String
    let catalogTotal: Int
    let enabledTotal: Int
    let eligibleTotal: Int
    let scheduledTotal: Int

    // MARK: Acquisition
    let cachedContributors: Int
    let networkContributors: Int

    // MARK: Pipeline stages
    let itemCandidates: Int
    let itemsAfterEligibility: Int
    let itemsAfterRanking: Int
    let itemsAfterMix: Int
    let cardsPrepared: Int
    let publishedCards: Int

    // MARK: Verification
    /// Ordered hash of eligible source IDs — if header and fetch produce
    /// different hashes, the mismatch is immediately visible.
    let eligibleSourceHash: UInt64

    // MARK: Outcome
    let terminalState: String
    let elapsedTime: Duration?
    let errorMessage: String?

    // MARK: Request snapshot
    let requestDescription: String

    // MARK: - Factory

    static func started(
        selectionID: SelectionID,
        request: ContentSelectionRequest,
        eligibleSourceHash: UInt64,
        catalogTotal: Int,
        enabledTotal: Int,
        eligibleTotal: Int
    ) -> SelectionTrace {
        SelectionTrace(
            selectionID: selectionID,
            surface: String(describing: request.surface),
            startedAt: Date(),
            completedAt: nil,
            sourceUniversePolicy: String(describing: request.sourceUniverse),
            catalogTotal: catalogTotal,
            enabledTotal: enabledTotal,
            eligibleTotal: eligibleTotal,
            scheduledTotal: 0,
            cachedContributors: 0,
            networkContributors: 0,
            itemCandidates: 0,
            itemsAfterEligibility: 0,
            itemsAfterRanking: 0,
            itemsAfterMix: 0,
            cardsPrepared: 0,
            publishedCards: 0,
            eligibleSourceHash: eligibleSourceHash,
            terminalState: "started",
            elapsedTime: nil,
            errorMessage: nil,
            requestDescription: String(describing: request)
        )
    }

    func completed(
        state: String,
        metrics: SelectionMetrics,
        elapsed: Duration,
        error: String? = nil
    ) -> SelectionTrace {
        SelectionTrace(
            selectionID: selectionID,
            surface: surface,
            startedAt: startedAt,
            completedAt: Date(),
            sourceUniversePolicy: sourceUniversePolicy,
            catalogTotal: catalogTotal,
            enabledTotal: enabledTotal,
            eligibleTotal: eligibleTotal,
            scheduledTotal: metrics.sources.scheduledTotal,
            cachedContributors: metrics.sources.representedInCache,
            networkContributors: metrics.sources.contributing,
            itemCandidates: metrics.itemCandidates,
            itemsAfterEligibility: metrics.itemsAfterEligibility,
            itemsAfterRanking: metrics.itemsAfterRanking,
            itemsAfterMix: metrics.itemsAfterMix,
            cardsPrepared: metrics.cardsPrepared,
            publishedCards: metrics.publishedCards,
            eligibleSourceHash: metrics.eligibleSourceHash,
            terminalState: state,
            elapsedTime: elapsed,
            errorMessage: error,
            requestDescription: requestDescription
        )
    }
}

// MARK: - Trace Logger

/// Collects and persists selection traces for debugging.
actor SelectionTraceLogger {
    private var traces: [SelectionID: SelectionTrace] = [:]
    private let maxTraces = 100

    func record(_ trace: SelectionTrace) {
        traces[trace.selectionID] = trace
        if traces.count > maxTraces {
            // Evict oldest traces
            let sorted = traces.values.sorted { a, b in
                (a.startedAt) < (b.startedAt)
            }
            let toRemove = sorted.prefix(traces.count - maxTraces)
            for trace in toRemove {
                traces[trace.selectionID] = nil
            }
        }
    }

    func trace(for selectionID: SelectionID) -> SelectionTrace? {
        traces[selectionID]
    }

    func allTraces() -> [SelectionTrace] {
        traces.values.sorted { $0.startedAt > $1.startedAt }
    }

    func clear() {
        traces.removeAll()
    }
}
