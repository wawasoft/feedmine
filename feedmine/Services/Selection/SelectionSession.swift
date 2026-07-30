import Foundation

// MARK: - Selection Session
//
// State machine for one selection lifecycle. Each surface gets its own session.
// Per the architecture doc §14, the first version is @MainActor — the session
// owns observable state and publication. Heavy work is delegated to Sendable
// components (SelectionCompiler, ContentRepository, etc.).

/// Manages the lifecycle of one content selection.
/// Each UI surface (main feed, source view, search, etc.) creates its own session.
@MainActor
final class SelectionSession {

    // MARK: - Identity

    let id: SelectionID
    let request: ContentSelectionRequest
    private let compiler: SelectionCompiler
    private let traceLogger: SelectionTraceLogger

    // MARK: - State

    private(set) var state: SelectionState = .idle
    private var trace: SelectionTrace
    private var startedAt: Date = .now

    /// The currently active selection ID for context validation.
    var activeSelectionID: SelectionID { id }

    // MARK: - Init

    init(
        request: ContentSelectionRequest,
        compiler: SelectionCompiler,
        traceLogger: SelectionTraceLogger = SelectionTraceLogger()
    ) {
        self.id = request.id
        self.request = request
        self.compiler = compiler
        self.traceLogger = traceLogger
        self.trace = SelectionTrace.started(
            selectionID: request.id,
            request: request,
            eligibleSourceHash: 0,
            catalogTotal: 0,
            enabledTotal: 0,
            eligibleTotal: 0
        )
    }

    // MARK: - Lifecycle

    /// Start the selection. Compiles the plan and begins acquisition.
    func start() async {
        startedAt = .now
        state = .preparing(SelectionProgress(
            sourcesChecked: 0, sourcesScheduled: 0, sourcesEligible: 0,
            itemsFound: 0, cardsPrepared: 0, phase: .loadingCache
        ))

        do {
            let plan = try await compiler.compile(request)
            // Phase 3 will wire this into actual acquisition + preparation
            // For now (Phase 1) — just compile and trace
            let elapsed = Duration(
                secondsComponent: Int64(Date.now.timeIntervalSince(startedAt)),
                attosecondsComponent: 0
            )
            trace = trace.completed(
                state: "compiled",
                metrics: SelectionMetrics(
                    sources: plan.sourceMetrics,
                    itemCandidates: 0, itemsAfterEligibility: 0,
                    itemsAfterRanking: 0, itemsAfterMix: 0,
                    cardsPrepared: 0, publishedCards: 0,
                    hasMore: false,
                    eligibleSourceHash: plan.itemRules.ruleDigest
                ),
                elapsed: elapsed
            )
            await traceLogger.record(trace)
        } catch {
            state = .failed(previous: nil, SelectionFailure.fatalError(error.localizedDescription))
        }
    }

    /// Refresh the current selection (shake-to-refresh).
    func refresh() async {
        guard case .ready(let snapshot) = state else { return }
        state = .refreshing(
            previous: snapshot,
            progress: SelectionProgress(
                sourcesChecked: 0, sourcesScheduled: 0, sourcesEligible: 0,
                itemsFound: 0, cardsPrepared: 0, phase: .fetchingNetwork
            )
        )
        // Phase 3 will re-execute the plan
    }

    /// Load more content (pagination).
    func loadMore() async {
        guard case .ready(let snapshot) = state, snapshot.hasMore else { return }
        state = .loadingMore(
            current: snapshot,
            progress: SelectionProgress(
                sourcesChecked: 0, sourcesScheduled: 0, sourcesEligible: 0,
                itemsFound: 0, cardsPrepared: 0, phase: .fetchingNetwork
            )
        )
        // Phase 3 will fetch next page
    }

    /// Cancel the current selection.
    func cancel() {
        state = .cancelled
    }

    // MARK: - Publication (called by SelectionCoordinator)

    /// Publish a snapshot — called when cards are prepared.
    func publish(_ snapshot: FeedSnapshot) {
        state = .ready(snapshot)
    }

    /// Transition to empty state with a reason.
    func publishEmpty(reason: SelectionEmptyReason, metrics: SelectionMetrics) {
        state = .empty(reason, metrics)
    }

    /// Transition to failed state, preserving previous snapshot if available.
    func publishFailure(_ failure: SelectionFailure, previousSnapshot: FeedSnapshot?) {
        state = .failed(previous: previousSnapshot, failure)
    }
}
