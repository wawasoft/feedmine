import Foundation
import Observation

// MARK: - FeedStore Selection Bridge
//
// Bridges the unified SelectionEngine into FeedStore's Observable state.
// When unifiedSelectionEngine is enabled, FeedStore delegates state
// management to this bridge instead of managing loadingState, visibleItems,
// visibleCards, and counters directly.
//
// Gated behind Settings.unifiedSelectionState (Phase 2) and
// Settings.unifiedSelectionMainFeed (Phase 3).

/// Observable bridge that exposes SelectionState through FeedStore's
/// existing property interface. This allows the UI to read from the
/// same properties while the selection engine runs underneath.
@MainActor
@Observable
final class FeedStoreSelectionBridge {

    // MARK: - Selection Engine

    let coordinator: SelectionCoordinator
    let adapter: MainFeedSelectionAdapter

    // MARK: - Exposed state (mirrors FeedStore's public interface)

    private(set) var visibleItems: [FeedItem] = []
    private(set) var visibleCards: [FeedCardPresentation] = []
    private(set) var visibleItemsGeneration: UInt64 = 0
    private(set) var loadingState: FeedLoadingState = .idle
    private(set) var hasPreviouslyLoadedContent: Bool = false
    private(set) var reservoirCount: Int = 0

    // MARK: - Unified metrics

    private(set) var selectionMetrics: SelectionMetrics = .zero
    private(set) var selectionState: SelectionState = .idle

    /// The active session for the main feed. Nil until the first request.
    private(set) var activeSession: SelectionSession?

    // MARK: - Filter state (mirrors FeedStore for adapter use)

    var activeRegion: String?
    var activeNodeIDs: Set<String> = []
    var activeContentType: FeedLoader.ContentType = .all
    var activeMood: FeedLoader.MoodFilter = .all
    var activeLanguages: Set<String> = []
    var activePreset: PresetSelector = .everything
    var contentFilterKeywords: Set<String> = []

    // MARK: - Init

    init(
        catalog: any SelectionCatalogReading,
        idGenerator: SelectionIDGenerator = SelectionIDGenerator()
    ) {
        self.coordinator = SelectionCoordinator(catalog: catalog, idGenerator: idGenerator)
        self.adapter = MainFeedSelectionAdapter(idGenerator: idGenerator)
    }

    // MARK: - Request submission

    /// Submit a new main feed request. Called when filters/presets change.
    func submitMainFeedRequest(
        sourceUniverse: SourceUniversePolicy = .enabledLibrary,
        taxonomyNodeIDs: Set<String>? = nil,
        contentTypes: Set<ContentType>? = nil,
        region: String? = nil,
        mood: MoodFilter? = nil,
        ranking: RankingProfile? = nil
    ) {
        let criteria = ItemCriteria(
            regions: region.map { [$0] } ?? [],
            taxonomyNodeIDs: taxonomyNodeIDs ?? activeNodeIDs,
            languages: activeLanguages,
            contentTypes: contentTypes ?? (activeContentType == .all ? [] : [activeContentType]),
            mood: mood ?? activeMood,
            searchExpression: nil,
            excludedKeywords: [],
            contentFilterKeywords: contentFilterKeywords
        )

        let request = ContentSelectionRequest(
            id: coordinator.idGenerator.nextID(),
            surface: .main,
            sourceUniverse: sourceUniverse,
            criteria: criteria,
            ranking: ranking ?? .none,
            mix: .defaultFeed,
            history: .defaultFeed,
            acquisition: .cacheThenNetwork,
            presentation: .defaultFeed,
            completion: hasPreviouslyLoadedContent ? .mainFeedWarm : .mainFeedColdStart
        )

        let session = coordinator.submit(request)
        activeSession = session
        observeSession(session)
    }

    /// Submit a reset request (clear all filters).
    func submitResetRequest() {
        let request = adapter.makeResetRequest(
            preservingSourceLibrary: true,
            contentFilterKeywords: contentFilterKeywords
        )
        let session = coordinator.submit(request)
        activeSession = session
        observeSession(session)
    }

    /// Submit a shake-to-refresh on the current session.
    func refreshActiveSession() {
        guard let session = activeSession else { return }
        Task { await session.refresh() }
    }

    /// Load more on the current session.
    func loadMoreOnActiveSession() {
        guard let session = activeSession else { return }
        Task { await session.loadMore() }
    }

    // MARK: - Session observation

    /// Observe the session's state and mirror it into FeedStore-compatible properties.
    /// In Phase 2 this is poll-based (willChange). In Phase 3 this becomes
    /// a proper async sequence driven by the session's state machine.
    private func observeSession(_ session: SelectionSession) {
        // For now, the bridge reads session.state directly.
        // Phase 3 will wire in the actual pipeline (cache → fetch → prepare → publish).
        // Phase 2 just ensures state and counters flow correctly.
        updateFromSession(session)
    }

    /// Mirror session state into the legacy properties the UI reads.
    private func updateFromSession(_ session: SelectionSession) {
        selectionState = session.state

        switch session.state {
        case .idle:
            loadingState = .idle

        case .preparing(let progress):
            loadingState = hasPreviouslyLoadedContent ? .refreshing : .initial
            selectionMetrics = SelectionMetrics(
                sources: SourceSelectionMetrics(
                    catalogTotal: progress.sourcesEligible,
                    enabledLibraryTotal: 0,
                    eligibleTotal: progress.sourcesEligible,
                    scheduledTotal: progress.sourcesScheduled,
                    checked: progress.sourcesChecked,
                    responding: 0,
                    contributing: 0,
                    representedInCache: 0,
                    representedOnScreen: visibleItems.count
                ),
                itemCandidates: progress.itemsFound,
                itemsAfterEligibility: 0,
                itemsAfterRanking: 0,
                itemsAfterMix: 0,
                cardsPrepared: progress.cardsPrepared,
                publishedCards: visibleItems.count,
                hasMore: true,
                eligibleSourceHash: 0
            )

        case .ready(let snapshot):
            loadingState = .idle
            visibleItems = snapshot.cards.map(\.item)
            visibleCards = snapshot.cards.map { card in
                FeedCardPresentation(
                    from: card,
                    isRead: card.item.isRead,
                    isBookmarked: card.item.isBookmarked
                )
            }
            visibleItemsGeneration &+= 1
            hasPreviouslyLoadedContent = true
            selectionMetrics = snapshot.metrics
            reservoirCount = snapshot.metrics.sources.contributing

        case .refreshing(let previous, let progress):
            loadingState = .refreshing
            if let prev = previous {
                visibleItems = prev.cards.map(\.item)
                visibleCards = prev.cards.map { card in
                    FeedCardPresentation(
                        from: card,
                        isRead: card.item.isRead,
                        isBookmarked: card.item.isBookmarked
                    )
                }
            }

        case .loadingMore(let current, _):
            loadingState = .loadingMore
            visibleItems = current.cards.map(\.item)
            visibleCards = current.cards.map { card in
                FeedCardPresentation(
                    from: card,
                    isRead: card.item.isRead,
                    isBookmarked: card.item.isBookmarked
                )
            }

        case .empty(let reason, let metrics):
            loadingState = .idle
            selectionMetrics = metrics
            // Empty state reason available for UI via selectionState

        case .failed(let previous, let failure):
            loadingState = .idle
            if let prev = previous {
                visibleItems = prev.cards.map(\.item)
                visibleCards = prev.cards.map { card in
                    FeedCardPresentation(
                        from: card,
                        isRead: card.item.isRead,
                        isBookmarked: card.item.isBookmarked
                    )
                }
            }
            // Error state available for UI via selectionState

        case .cancelled:
            loadingState = .idle
        }
    }

    // MARK: - Metrics accessors (for header, loading, empty state)

    /// Eligible source count for the active selection.
    var eligibleSourceCount: Int {
        selectionMetrics.sources.eligibleTotal
    }

    /// Scheduled source count for the current batch.
    var scheduledSourceCount: Int {
        selectionMetrics.sources.scheduledTotal
    }

    /// Checked source count.
    var checkedSourceCount: Int {
        selectionMetrics.sources.checked
    }

    /// Contributing source count.
    var contributingSourceCount: Int {
        selectionMetrics.sources.contributing
    }

    /// Whether the selection is in a loading state.
    var isLoading: Bool {
        switch selectionState {
        case .preparing, .refreshing(_, _), .loadingMore(_, _):
            return true
        default:
            return false
        }
    }

    /// Whether the selection is empty (not just loading).
    var isEmpty: Bool {
        if case .empty = selectionState { return true }
        return false
    }

    /// Empty reason, if empty.
    var emptyReason: SelectionEmptyReason? {
        if case .empty(let reason, _) = selectionState { return reason }
        return nil
    }
}
