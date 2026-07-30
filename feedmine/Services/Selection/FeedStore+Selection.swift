import Foundation

// MARK: - FeedStore + Unified Selection
//
// Integrates the unified selection engine into FeedStore.
// Gated behind Settings.unifiedSelectionState (Phase 2) and
// Settings.unifiedSelectionMainFeed (Phase 3).
//
// When enabled, FeedStore delegates state management to
// FeedStoreSelectionBridge instead of managing loadingState,
// visibleItems, and counters directly.

extension FeedStore {

    // MARK: - Selection Engine Access

    /// Whether the unified selection engine is active for the main feed.
    var isUnifiedSelectionActive: Bool {
        Settings.unifiedSelectionMainFeed && selectionBridge != nil
    }

    /// Whether unified state and counters are active (Phase 2+).
    var isUnifiedStateActive: Bool {
        Settings.unifiedSelectionState && selectionBridge != nil
    }

    // MARK: - Bridge Initialization

    /// Initialize the selection bridge. Called after the catalog is ready.
    /// In Phase 1 (shadow mode), the bridge runs alongside the legacy path.
    /// In Phase 3 (main feed), the bridge replaces the legacy path.
    func initializeSelectionEngine(catalog: any SelectionCatalogReading) {
        guard Settings.unifiedSelectionShadow || Settings.unifiedSelectionState
                || Settings.unifiedSelectionMainFeed else { return }
        guard selectionBridge == nil else { return }
        selectionBridge = FeedStoreSelectionBridge(catalog: catalog)
    }

    // MARK: - Unified Filter Operations

    /// Submit a filter change through the unified engine.
    /// Called by setFilter when unifiedSelectionMainFeed is active.
    func submitUnifiedFilter(
        region: String?,
        nodeIDs: Set<String>,
        type: FeedLoader.ContentType,
        mood: FeedLoader.MoodFilter,
        languages: Set<String>
    ) {
        guard let bridge = selectionBridge else { return }

        bridge.activeRegion = region
        bridge.activeNodeIDs = nodeIDs
        bridge.activeContentType = type
        bridge.activeMood = mood
        bridge.activeLanguages = languages

        let sourceUniverse: SourceUniversePolicy = nodeIDs.isEmpty && type == .all
            ? .enabledLibrary
            : .expandedCatalogRespectingExplicitOff

        bridge.submitMainFeedRequest(
            sourceUniverse: sourceUniverse,
            taxonomyNodeIDs: nodeIDs.isEmpty ? nil : nodeIDs,
            contentTypes: type == .all ? nil : [type],
            region: region,
            mood: mood
        )
    }

    /// Submit a preset change through the unified engine.
    func submitUnifiedPreset(_ preset: PresetSelector) {
        guard let bridge = selectionBridge else { return }

        bridge.activePreset = preset

        var ranking = RankingProfile()
        ranking.signals.append(.editorialPreset(preset))

        bridge.submitMainFeedRequest(ranking: ranking)
    }

    /// Submit a clear-all-filters through the unified engine.
    func submitUnifiedReset() {
        guard let bridge = selectionBridge else { return }

        bridge.activeRegion = nil
        bridge.activeNodeIDs = []
        bridge.activeContentType = .all
        bridge.activeMood = .all
        bridge.activeLanguages = []

        bridge.submitResetRequest()
    }

    /// Submit a shake-to-refresh through the unified engine.
    func submitUnifiedRefresh() {
        selectionBridge?.refreshActiveSession()
    }

    /// Submit a load-more through the unified engine.
    func submitUnifiedLoadMore() {
        selectionBridge?.loadMoreOnActiveSession()
    }

    // MARK: - Unified State Accessors (Phase 2)

    /// Unified eligible source count — replaces direct activeSources.count reads.
    var unifiedEligibleSourceCount: Int {
        selectionBridge?.eligibleSourceCount ?? 0
    }

    /// Unified checked source count.
    var unifiedCheckedSourceCount: Int {
        selectionBridge?.checkedSourceCount ?? 0
    }

    /// Unified scheduled source count.
    var unifiedScheduledSourceCount: Int {
        selectionBridge?.scheduledSourceCount ?? 0
    }

    /// Unified contributing source count.
    var unifiedContributingSourceCount: Int {
        selectionBridge?.contributingSourceCount ?? 0
    }

    /// Whether the unified engine considers the selection loading.
    var unifiedIsLoading: Bool {
        selectionBridge?.isLoading ?? false
    }

    /// Whether the unified engine considers the selection empty.
    var unifiedIsEmpty: Bool {
        selectionBridge?.isEmpty ?? false
    }

    /// Selection metrics for the active session.
    var unifiedSelectionMetrics: SelectionMetrics? {
        selectionBridge?.selectionMetrics
    }

    /// Active selection state for the UI.
    var unifiedSelectionState: SelectionState? {
        selectionBridge?.selectionState
    }

    // MARK: - Shadow Mode (Phase 1)

    /// Run shadow comparison between legacy and unified source resolution.
    /// Logs differences without affecting the UI.
    func runShadowComparison(
        legacySourceIDs: Set<String>,
        legacyHeaderCount: Int,
        legacyFetchCount: Int
    ) {
        guard Settings.unifiedSelectionShadow, let bridge = selectionBridge else { return }

        let unifiedEligible = bridge.eligibleSourceCount
        let legacyEligible = legacySourceIDs.count

        if unifiedEligible != legacyEligible {
            Log.feed.warning("""
                [SelectionShadow] Source count mismatch:
                legacy=\(legacyEligible) unified=\(unifiedEligible)
                header=\(legacyHeaderCount) fetch=\(legacyFetchCount)
                """)
        }

        // Shadow trace is recorded in SelectionTraceLogger for later analysis
    }

    // MARK: - Surface Wiring (Phases 6A-C)

    /// Submit a source view request. Called by SourceFeedView when
    /// unifiedSelectionSurfaces is enabled.
    func submitUnifiedSourceView(sourceID: SourceID) {
        guard let bridge = selectionBridge else { return }
        let adapter = SourceViewSelectionAdapter(idGenerator: bridge.coordinator.idGenerator)
        let request = adapter.makeRequest(sourceID: sourceID)
        let session = bridge.coordinator.submit(request)
        // Source view gets its own session — does not replace main session
    }

    /// Submit a collection view/preset request.
    func submitUnifiedCollection(
        collectionID: Int64,
        memberIDs: Set<SourceID>,
        languages: Set<String>,
        contentFilterKeywords: Set<String>
    ) {
        guard let bridge = selectionBridge else { return }
        let adapter = CollectionSelectionAdapter(idGenerator: bridge.coordinator.idGenerator)
        let request = adapter.makeRequest(
            collectionID: collectionID,
            memberIDs: memberIDs,
            languages: languages,
            contentFilterKeywords: contentFilterKeywords
        )
        let _ = bridge.coordinator.submit(request)
    }

    /// Submit a bookmarks request.
    func submitUnifiedBookmarks(
        listID: Int64?,
        sourceIDs: Set<SourceID>,
        bookmarkedItemIDs: Set<String>
    ) {
        guard let bridge = selectionBridge else { return }
        let adapter = BookmarksSelectionAdapter(idGenerator: bridge.coordinator.idGenerator)
        let request = adapter.makeRequest(
            listID: listID, sourceIDs: sourceIDs, bookmarkedItemIDs: bookmarkedItemIDs
        )
        let _ = bridge.coordinator.submit(request)
    }

    /// Submit a search request.
    func submitUnifiedSearch(
        expression: SearchExpression,
        sourceScope: SourceUniversePolicy,
        languages: Set<String>,
        contentFilterKeywords: Set<String>
    ) {
        guard let bridge = selectionBridge else { return }
        let adapter = SearchSelectionAdapter(idGenerator: bridge.coordinator.idGenerator)
        let request = adapter.makeSearchRequest(
            expression: expression,
            sourceScope: sourceScope,
            languages: languages,
            contentFilterKeywords: contentFilterKeywords
        )
        let _ = bridge.coordinator.submit(request)
    }

    /// Submit a Smart Feed request.
    func submitUnifiedSmartFeed(
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
    ) {
        guard let bridge = selectionBridge else { return }
        let adapter = SmartFeedSelectionAdapter(idGenerator: bridge.coordinator.idGenerator)
        let request = adapter.makeRequest(
            smartFeedID: smartFeedID,
            query: query,
            region: region,
            taxonomyNodeIDs: taxonomyNodeIDs,
            languages: languages,
            contentType: contentType,
            mood: mood,
            collectionMemberIDs: collectionMemberIDs,
            excludedKeywords: excludedKeywords,
            contentFilterKeywords: contentFilterKeywords,
            allowlistSourceIDs: allowlistSourceIDs,
            allowlistItemIDs: allowlistItemIDs
        )
        let _ = bridge.coordinator.submit(request)
    }

    /// Submit a What's New request.
    func submitUnifiedWhatsNew(
        baseCriteria: ItemCriteria,
        fetchedAfter: Date
    ) {
        guard let bridge = selectionBridge else { return }
        let adapter = WhatsNewSelectionAdapter(idGenerator: bridge.coordinator.idGenerator)
        let request = adapter.makeRequest(
            baseCriteria: baseCriteria,
            fetchedAfter: fetchedAfter
        )
        let _ = bridge.coordinator.submit(request)
    }
}

// MARK: - Private Storage
// selectionBridge is now a direct property on FeedStore (see FeedStore.swift line ~65)
