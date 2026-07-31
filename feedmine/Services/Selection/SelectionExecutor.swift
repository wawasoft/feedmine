import Foundation
import GRDB

// MARK: - Selection Executor
//
// Executes a ResolvedSelectionPlan: cache query → eligibility → ranking →
// mix → acquisition → merge → preparation → snapshot.
//
// This is the component that makes the SelectionSession actually produce content.
// Without it, the session compiles plans but never executes them.

/// Executes a ResolvedSelectionPlan against real data sources (SQLite cache,
/// network fetcher) and produces a FeedSnapshot with terminal cards.
@MainActor
final class SelectionExecutor {

    // MARK: - Dependencies

    let db: DatabaseQueue
    let fetcher: RSSFetcher
    let scheduler: AdaptiveScheduler
    let preparationCoordinator: CardPreparationCoordinator
    let runwayPolicy: RunwayPolicy

    // MARK: - Engines

    let rankingEngine = RankingEngine()
    let mixAllocator = MixAllocator()
    let inMemoryEvaluator = InMemoryItemRuleEvaluator()

    // MARK: - State

    private var loadedItemIDs: Set<String> = []

    // MARK: - Init

    init(
        db: DatabaseQueue,
        fetcher: RSSFetcher,
        scheduler: AdaptiveScheduler,
        preparationCoordinator: CardPreparationCoordinator,
        runwayPolicy: RunwayPolicy
    ) {
        self.db = db
        self.fetcher = fetcher
        self.scheduler = scheduler
        self.preparationCoordinator = preparationCoordinator
        self.runwayPolicy = runwayPolicy
    }

    // MARK: - Execute

    /// Execute a resolved plan and produce a FeedSnapshot.
    /// This is the main entry point called by SelectionSession.start().
    func execute(
        plan: ResolvedSelectionPlan,
        presentationContext: FeedPresentationContext
    ) async throws -> FeedSnapshot {
        let startedAt = Date()

        // 1. Query cache (SQLite)
        let cachedItems = try await queryCache(plan: plan)
        let cachedCount = cachedItems.count

        // 2. Apply in-memory eligibility to cached items
        let eligibleCacheItems = await inMemoryEvaluator.evaluate(
            cachedItems, against: plan.itemRules
        )
        let eligibleCount = eligibleCacheItems.count

        // 3. Ranking
        let scored = rankingEngine.score(
            items: eligibleCacheItems,
            plan: plan.rankingPlan,
            alreadySurfacedIDs: loadedItemIDs
        )

        // 4. Mix allocation
        let candidates = Array(zip(eligibleCacheItems, scored))
            .sorted { $0.1.total > $1.1.total }

        let allocation = mixAllocator.allocate(
            candidates: candidates.map { ($0.0, $0.1) },
            plan: plan.mixPlan,
            targetCount: plan.presentationPlan.initialPageSize
        )

        // 5. Prepare cards
        let orderedItems = allocation.orderedItemIDs.compactMap { id in
            eligibleCacheItems.first { $0.id == id }
        }

        // Replace editorial sequence and fill runway
        await preparationCoordinator.replaceEditorialSequence(
            orderedItems, context: presentationContext
        )

        // Wait for contiguous prefix
        let ready = await preparationCoordinator.waitForContiguousPrefix(
            minimumCount: min(plan.presentationPlan.initialPageSize, orderedItems.count),
            maximumCount: plan.presentationPlan.initialPageSize,
            deadline: .now.advanced(by: .seconds(6)),
            context: presentationContext
        )

        // Commit published
        let committed = await preparationCoordinator.commitPublished(
            expectedIDs: ready.map(\.id),
            context: presentationContext
        )

        let publishedCards: [PreparedFeedCard]
        if committed {
            publishedCards = ready
        } else {
            publishedCards = []
        }

        // Track loaded IDs
        for item in orderedItems {
            loadedItemIDs.insert(item.id)
        }

        // 6. Start network acquisition for remaining slots (fire-and-forget)
        if plan.acquisitionPlan.useAdaptiveScheduling && !plan.acquisitionPlan.sourceScope.isEmpty {
            startNetworkAcquisition(plan: plan, presentationContext: presentationContext)
        }

        // 7. Build metrics
        let metrics = SelectionMetrics(
            sources: SourceSelectionMetrics(
                catalogTotal: plan.sourceMetrics.catalogTotal,
                enabledLibraryTotal: plan.sourceMetrics.enabledLibraryTotal,
                eligibleTotal: plan.sourceMetrics.eligibleTotal,
                scheduledTotal: plan.acquisitionPlan.batchSize,
                checked: 0,
                responding: 0,
                contributing: 0,
                representedInCache: cachedCount > 0 ? 1 : 0,
                representedOnScreen: publishedCards.count
            ),
            itemCandidates: cachedCount,
            itemsAfterEligibility: eligibleCount,
            itemsAfterRanking: scored.count,
            itemsAfterMix: allocation.totalAllocated,
            cardsPrepared: publishedCards.count,
            publishedCards: publishedCards.count,
            hasMore: allocation.totalAllocated < eligibleCount,
            eligibleSourceHash: plan.itemRules.ruleDigest
        )

        return FeedSnapshot(
            selectionID: plan.selectionID,
            cards: publishedCards,
            metrics: metrics,
            hasMore: allocation.totalAllocated < eligibleCount,
            createdAt: Date()
        )
    }

    // MARK: - Cache Query

    /// Query SQLite for items matching the plan's rules.
    private func queryCache(plan: ResolvedSelectionPlan) async throws -> [FeedItem] {
        let (sql, _) = SQLItemRuleCompiler().compile(
            plan.itemRules,
            limit: plan.presentationPlan.initialPageSize,
            offset: 0
        )

        return try await db.read { db in
            try FeedItemRecord.fetchAll(db, sql: sql).map { $0.toFeedItem() }
        }
    }

    // MARK: - Network Acquisition

    /// Start background network fetch for remaining slots.
    /// Fire-and-forget — results are merged on next refresh/load-more.
    private func startNetworkAcquisition(
        plan: ResolvedSelectionPlan,
        presentationContext: FeedPresentationContext
    ) {
        let sourceScope = plan.acquisitionPlan.sourceScope
        let batchSize = plan.acquisitionPlan.batchSize

        Task { [weak self] in
            guard let self else { return }

            // Extract source IDs to fetch
            let ids: [SourceID]
            switch sourceScope {
            case .materialized(let set):
                ids = Array(set.prefix(batchSize))
            case .explicitList(let list):
                ids = Array(list.prefix(batchSize))
            case .single(let id):
                ids = [id]
            case .catalogQuery:
                return  // Lazy query not yet resolved
            }

            // Resolve URLs from IDs (Phase 4+ will have proper index)
            // For now, skip — network acquisition is Phase 3+
            guard !ids.isEmpty else { return }

            // TODO: Resolve SourceID → FeedSource → requestURL, then fetch
            // let sources = await resolveSources(for: ids)
            // let results = await fetcher.fetchAll(sources, maxConcurrent: 8)
            // await persistItems(results)
            // await mergeIntoVisibleItems(results, plan: plan, context: presentationContext)
        }
    }

    // MARK: - Load More

    /// Execute the next page of results.
    func loadMore(
        plan: ResolvedSelectionPlan,
        currentSnapshot: FeedSnapshot,
        presentationContext: FeedPresentationContext
    ) async throws -> FeedSnapshot {
        let nextOffset = currentSnapshot.cards.count

        // Query next page from cache
        let (sql, _) = SQLItemRuleCompiler().compile(
            plan.itemRules,
            limit: plan.presentationPlan.loadMorePageSize,
            offset: nextOffset
        )

        let items = try await db.read { db in
            try FeedItemRecord.fetchAll(db, sql: sql).map { $0.toFeedItem() }
        }

        guard !items.isEmpty else {
            // No more items — return current snapshot with hasMore = false
            return FeedSnapshot(
                selectionID: plan.selectionID,
                cards: currentSnapshot.cards,
                metrics: currentSnapshot.metrics,
                hasMore: false,
                createdAt: Date()
            )
        }

        // Eligibility
        let eligible = await inMemoryEvaluator.evaluate(items, against: plan.itemRules)

        // Append to coordinator
        await preparationCoordinator.appendEditorialSequence(
            eligible, context: presentationContext
        )

        // Wait for ready cards
        let ready = await preparationCoordinator.waitForContiguousPrefix(
            minimumCount: 1,
            maximumCount: plan.presentationPlan.loadMorePageSize,
            deadline: .now.advanced(by: .seconds(3)),
            context: presentationContext
        )

        let committed = await preparationCoordinator.commitPublished(
            expectedIDs: ready.map(\.id),
            context: presentationContext
        )

        let newCards: [PreparedFeedCard] = committed ? ready : []

        // Track loaded IDs
        for item in eligible {
            loadedItemIDs.insert(item.id)
        }

        // Build merged snapshot
        let allCards = currentSnapshot.cards + newCards
        let hasMore = eligible.count >= plan.presentationPlan.loadMorePageSize

        var metrics = currentSnapshot.metrics
        let newMetrics = SelectionMetrics(
            sources: metrics.sources,
            itemCandidates: metrics.itemCandidates + items.count,
            itemsAfterEligibility: metrics.itemsAfterEligibility + eligible.count,
            itemsAfterRanking: metrics.itemsAfterRanking + eligible.count,
            itemsAfterMix: metrics.itemsAfterMix + newCards.count,
            cardsPrepared: metrics.cardsPrepared + newCards.count,
            publishedCards: allCards.count,
            hasMore: hasMore,
            eligibleSourceHash: metrics.eligibleSourceHash
        )

        return FeedSnapshot(
            selectionID: plan.selectionID,
            cards: allCards,
            metrics: newMetrics,
            hasMore: hasMore,
            createdAt: Date()
        )
    }
}

// MARK: - Source Scope emptiness check

private extension SourceScopeHandle {
    var isEmpty: Bool {
        switch self {
        case .materialized(let ids): return ids.isEmpty
        case .explicitList(let ids): return ids.isEmpty
        case .single: return false
        case .catalogQuery: return false  // Assume non-empty — will be resolved lazily
        }
    }
}
