import Foundation

// MARK: - Selection Session
//
// State machine for one selection lifecycle. Each surface gets its own session.
// Per the architecture doc §14, the first version is @MainActor — the session
// owns observable state and publication. Heavy work is delegated to Sendable
// components (SelectionCompiler, SelectionExecutor, etc.).

/// Manages the lifecycle of one content selection.
/// Each UI surface (main feed, source view, search, etc.) creates its own session.
@MainActor
final class SelectionSession {

    // MARK: - Identity

    let id: SelectionID
    let request: ContentSelectionRequest
    private let compiler: SelectionCompiler
    private let traceLogger: SelectionTraceLogger

    // MARK: - Executor (Phase 3+)

    /// The executor that runs the actual pipeline. Nil in shadow mode.
    /// Set after compilation when a real executor is available.
    var executor: SelectionExecutor?

    /// The presentation context for card preparation. Set by the coordinator.
    var presentationContext: FeedPresentationContext?

    // MARK: - State

    private(set) var state: SelectionState = .idle
    private var trace: SelectionTrace
    private var startedAt: Date = .now
    private var compiledPlan: ResolvedSelectionPlan?

    /// The currently active selection ID for context validation.
    var activeSelectionID: SelectionID { id }

    // MARK: - State stream (Phase 6 — bridge observation)

    /// Continuation for broadcasting state changes to the bridge.
    private var stateContinuation: AsyncStream<SelectionState>.Continuation?
    /// Stream of state changes for the bridge to observe.
    private(set) lazy var stateStream: AsyncStream<SelectionState> = {
        AsyncStream { continuation in
            self.stateContinuation = continuation
        }
    }()

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

    /// Start the selection. Compiles the plan and executes it if an executor
    /// is available. Falls back to trace-only (shadow mode) if no executor.
    func start() async {
        startedAt = .now
        setState(.preparing(SelectionProgress(
            sourcesChecked: 0, sourcesScheduled: 0, sourcesEligible: 0,
            itemsFound: 0, cardsPrepared: 0, phase: .loadingCache
        )))

        do {
            let plan = try await compiler.compile(request)
            compiledPlan = plan

            // If we have an executor, run the real pipeline
            if let executor, let ctx = presentationContext {
                let snapshot = try await executor.execute(plan: plan, presentationContext: ctx)

                if snapshot.cards.isEmpty {
                    // Determine why it's empty
                    let reason: SelectionEmptyReason
                    if plan.sourceMetrics.eligibleTotal == 0 {
                        reason = .noEligibleSources
                    } else if snapshot.metrics.itemsAfterEligibility == 0 {
                        reason = .noItemsAfterRules
                    } else {
                        reason = .noItemsAfterComposition
                    }
                    setState(.empty(reason, snapshot.metrics))
                } else {
                    setState(.ready(snapshot))
                }

                let elapsed = Duration(
                    secondsComponent: Int64(Date.now.timeIntervalSince(startedAt)),
                    attosecondsComponent: 0
                )
                trace = trace.completed(
                    state: snapshot.cards.isEmpty ? "empty" : "ready",
                    metrics: snapshot.metrics,
                    elapsed: elapsed
                )
            } else {
                // Shadow mode: compile only, no execution
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
            }
            await traceLogger.record(trace)
        } catch {
            setState(.failed(previous: nil, SelectionFailure.fatalError(error.localizedDescription)))
        }
    }

    /// Refresh the current selection (shake-to-refresh).
    /// Re-executes the compiled plan, preserving the previous snapshot on failure.
    func refresh() async {
        guard let plan = compiledPlan else { return }
        let previousSnapshot: FeedSnapshot?
        if case .ready(let snap) = state { previousSnapshot = snap }
        else { previousSnapshot = nil }

        setState(.refreshing(
            previous: previousSnapshot,
            progress: SelectionProgress(
                sourcesChecked: 0, sourcesScheduled: 0, sourcesEligible: 0,
                itemsFound: 0, cardsPrepared: 0, phase: .fetchingNetwork
            )
        ))

        do {
            guard let executor, let ctx = presentationContext else { return }
            let snapshot = try await executor.execute(plan: plan, presentationContext: ctx)

            if snapshot.cards.isEmpty, let prev = previousSnapshot {
                // Refresh produced empty result — restore previous snapshot
                setState(.ready(prev))
            } else if snapshot.cards.isEmpty {
                setState(.empty(.noItemsAfterRules, snapshot.metrics))
            } else {
                setState(.ready(snapshot))
            }
        } catch {
            // On failure, restore previous snapshot if available
            if let prev = previousSnapshot {
                setState(.ready(prev))
            } else {
                setState(.failed(previous: previousSnapshot,
                                  SelectionFailure.networkError(error.localizedDescription)))
            }
        }
    }

    /// Load more content (pagination).
    func loadMore() async {
        guard let plan = compiledPlan else { return }
        guard case .ready(let snapshot) = state, snapshot.hasMore else { return }

        setState(.loadingMore(
            current: snapshot,
            progress: SelectionProgress(
                sourcesChecked: 0, sourcesScheduled: 0, sourcesEligible: 0,
                itemsFound: 0, cardsPrepared: 0, phase: .fetchingNetwork
            )
        ))

        do {
            guard let executor, let ctx = presentationContext else { return }
            let newSnapshot = try await executor.loadMore(
                plan: plan, currentSnapshot: snapshot, presentationContext: ctx
            )
            setState(.ready(newSnapshot))
        } catch {
            // On load-more failure, keep current snapshot
            setState(.ready(snapshot))
        }
    }

    /// Cancel the current selection.
    func cancel() {
        setState(.cancelled)
    }

    // MARK: - State broadcast

    private func setState(_ newState: SelectionState) {
        state = newState
        stateContinuation?.yield(newState)
    }

    // MARK: - Publication (called by SelectionCoordinator)

    /// Publish a snapshot — called when cards are prepared.
    func publish(_ snapshot: FeedSnapshot) {
        setState(.ready(snapshot))
    }

    /// Transition to empty state with a reason.
    func publishEmpty(reason: SelectionEmptyReason, metrics: SelectionMetrics) {
        setState(.empty(reason, metrics))
    }

    /// Transition to failed state, preserving previous snapshot if available.
    func publishFailure(_ failure: SelectionFailure, previousSnapshot: FeedSnapshot?) {
        setState(.failed(previous: previousSnapshot, failure))
    }
}
