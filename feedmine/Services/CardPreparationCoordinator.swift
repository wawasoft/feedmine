import Foundation
import UIKit

/// Actor that manages the editorial sequence, concurrent preparation,
/// and contiguous-prefix promotion. Replaces ReadyCardQueue.
///
/// Key invariant: cards finish preparation out of order, but are only
/// promoted in contiguous editorial order. A slow item at position 3
/// blocks promotion of items 4..N until it reaches a terminal state.
actor CardPreparationCoordinator {

    // MARK: - Internal state

    private var orderedItems: [FeedItem] = []
    private var stateByID: [String: CardPreparationState] = [:]
    private var resolvedByID: [String: ResolvedCardAsset] = [:]
    private var renderReadyByID: [String: PreparedFeedCard] = [:]

    /// Index of the next item that hasn't started preparation.
    private var nextPrepareIndex: Int = 0

    /// Index of the first item whose render-ready card hasn't been taken
    /// by a call to `takeRenderReadyPrefix`.
    private var nextPublishIndex: Int = 0

    /// Continuations waiting for the contiguous prefix to grow.
    /// Woken by storeRenderReady when a new card joins the prefix.
    private var prefixWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// The context this coordinator is currently serving.
    private var activeContext: FeedPresentationContext?

    // MARK: - Dependencies

    private let mediaStore: MediaAssetStore
    private let policy: RunwayPolicy
    private let limiter: AsyncLimiter

    // MARK: - Initialization

    init(mediaStore: MediaAssetStore, policy: RunwayPolicy) {
        self.mediaStore = mediaStore
        self.policy = policy
        self.limiter = AsyncLimiter(categories: [
            ("direct_image", 8),
            ("article_html", 3),
            ("disk_decode", 4),
            ("background_retry", 2),
        ])
    }

    // MARK: - Public API

    /// Replace the entire editorial sequence. An older context (lower epoch)
    /// can never replace a newer one — this prevents stale tasks from
    /// resurrecting a discarded feed composition.
    func replaceEditorialSequence(
        _ items: [FeedItem],
        context: FeedPresentationContext
    ) async {
        // Guard: never let an older epoch overwrite a newer one.
        if let current = activeContext, context.epoch < current.epoch {
            return
        }
        // cancelAll is intentionally a no-op — downloads are shared across
        // contexts. But it's an actor call that creates a suspension point.
        // Re-validate the epoch guard after resuming to prevent a race where
        // a newer context was installed during the suspension.
        await mediaStore.cancelAll()
        if let current = activeContext, context.epoch < current.epoch {
            return
        }
        // Deduplicate within the batch itself — duplicate IDs in the same
        // batch would corrupt renderReadyByID and permanently block the
        // publish index when the first commit removes the shared card.
        var seenIDs = Set<String>()
        let uniqueItems = items.filter { seenIDs.insert($0.id).inserted }
        orderedItems = uniqueItems
        stateByID.removeAll()
        resolvedByID.removeAll()
        renderReadyByID.removeAll()
        nextPrepareIndex = 0
        nextPublishIndex = 0
        activeContext = context

        // Wake any prefix waiters — the sequence changed so they should
        // re-evaluate whether their prefix condition is met.
        let waiters = prefixWaiters
        prefixWaiters.removeAll()
        for (_, cont) in waiters { cont.resume() }
    }

    /// Append items to the end of the editorial sequence. Filters out
    /// items whose IDs are already known (single source of truth for
    /// deduplication — callers don't need to pre-filter).
    func appendEditorialSequence(
        _ items: [FeedItem],
        context: FeedPresentationContext
    ) async {
        guard context == activeContext else { return }
        // Track both existing and newly-seen IDs within this batch so
        // intra-batch duplicates are also filtered.
        var seenIDs = Set(orderedItems.map(\.id))
        let newItems = items.filter { seenIDs.insert($0.id).inserted }
        guard !newItems.isEmpty else { return }
        orderedItems.append(contentsOf: newItems)
    }

    /// Fill the runway up to the specified target count of render-ready cards.
    func fillRunway(targetRenderReady: Int, context: FeedPresentationContext) async {
        guard context == activeContext else { return }
        let currentReady = renderReadyByID.count
        guard currentReady < targetRenderReady else { return }

        // Start preparation for items up to targetRenderReady * 2 (buffer)
        let prepareUpTo = min(orderedItems.count, nextPublishIndex + targetRenderReady * 2)
        while nextPrepareIndex < prepareUpTo {
            let idx = nextPrepareIndex
            let item = orderedItems[idx]
            nextPrepareIndex += 1
            prepareItem(at: idx, item: item, context: context)
        }
    }

    /// Take the longest contiguous prefix of render-ready cards starting
    /// from `nextPublishIndex`. Returns cards in editorial order.
    /// Published cards are removed from internal maps — the UI holds a strong
    /// reference to the UIImage, so the coordinator doesn't need to retain it.
    ///
    /// Prefer `peekRenderReadyPrefix` + `commitPublished` for callers that
    /// need to validate cancellation/context before consuming cards.
    func takeRenderReadyPrefix(
        maximumCount: Int,
        context: FeedPresentationContext
    ) -> [PreparedFeedCard] {
        let cards = peekRenderReadyPrefix(maximumCount: maximumCount, context: context)
        let ids = cards.map(\.id)
        guard commitPublished(expectedIDs: ids, context: context) else { return [] }
        return cards
    }

    /// Non-destructive peek at the contiguous render-ready prefix. Does NOT
    /// advance nextPublishIndex or remove cards from maps. Useful for waiting
    /// loops that need to check readiness without risking card loss on cancel.
    func peekRenderReadyPrefix(
        maximumCount: Int,
        context: FeedPresentationContext
    ) -> [PreparedFeedCard] {
        guard context == activeContext else { return [] }
        var ready: [PreparedFeedCard] = []
        var idx = nextPublishIndex

        while ready.count < maximumCount, idx < orderedItems.count {
            let item = orderedItems[idx]
            if let card = renderReadyByID[item.id] {
                ready.append(card)
                idx += 1
            } else {
                break
            }
        }
        return ready
    }

    /// Suspend until the contiguous prefix reaches `minimumCount`, or the
    /// deadline expires, or the context changes. Returns the prefix at that
    /// point (may be shorter than minimumCount if the deadline fired).
    ///
    /// Unlike the old polling loop in FeedStore, this suspends passively —
    /// `storeRenderReady` wakes waiters when a new card joins the prefix.
    /// This eliminates the 300ms polling interval and the race window at
    /// the deadline instant.
    func waitForContiguousPrefix(
        minimumCount: Int,
        maximumCount: Int,
        deadline: ContinuousClock.Instant,
        context: FeedPresentationContext
    ) async -> [PreparedFeedCard] {
        while true {
            let cards = peekRenderReadyPrefix(
                maximumCount: maximumCount, context: context
            )
            if cards.count >= minimumCount { return cards }
            guard context == activeContext else { return [] }
            guard ContinuousClock().now < deadline else { return cards }

            // Suspend until storeRenderReady signals or cancellation.
            let waiterID = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { cont in
                    prefixWaiters[waiterID] = cont
                }
            } onCancel: {
                Task { [weak self] in
                    await self?.removePrefixWaiter(waiterID)
                }
            }
        }
    }

    /// Commit previously peeked cards as published. Validates that the
    /// context is still active and that the expected IDs match the actual
    /// contiguous prefix — a stale or duplicate commit is rejected.
    /// Returns true if the commit succeeded (cards were removed and
    /// nextPublishIndex advanced); false if the context changed or the
    /// prefix no longer matches.
    func commitPublished(
        expectedIDs: [String],
        context: FeedPresentationContext
    ) -> Bool {
        guard context == activeContext else { return false }

        // Verify expectedIDs match the actual contiguous prefix.
        let actual = peekRenderReadyPrefix(
            maximumCount: expectedIDs.count,
            context: context
        ).map(\.id)
        guard actual == expectedIDs else { return false }

        // Commit: advance publish index and clean up maps in one pass.
        nextPublishIndex += expectedIDs.count
        for id in expectedIDs {
            renderReadyByID.removeValue(forKey: id)
            resolvedByID.removeValue(forKey: id)
            stateByID.removeValue(forKey: id)
        }
        return true
    }

    /// Discard all state for a context that's no longer active.
    func invalidate(context: FeedPresentationContext) {
        guard context != activeContext else { return }
        stateByID.removeAll()
        resolvedByID.removeAll()
        renderReadyByID.removeAll()
    }

    func handleMemoryPressure() {
        // Demote distant render-ready cards back to resolved (disk-level)
        // instead of deleting them permanently. If they're deleted, the
        // feed stops at the first missing card because fillRunway only
        // advances nextPrepareIndex forward. Demotion allows re-decode
        // when the user scrolls closer.
        let keepUpTo = nextPublishIndex + policy.publishedAheadTarget
        for (id, _) in renderReadyByID {
            guard let idx = orderedItems.firstIndex(where: { $0.id == id }),
                  idx >= keepUpTo else { continue }
            // Demote: revert state to resolved so fillRunway can re-decode.
            if let asset = resolvedByID[id] {
                stateByID[id] = .resolved(asset)
            }
            renderReadyByID.removeValue(forKey: id)
            // Reset nextPrepareIndex so fillRunway picks this item up again.
            if idx < nextPrepareIndex {
                nextPrepareIndex = idx
            }
        }
        Task { await mediaStore.clearMemoryCache() }
    }

    /// Number of render-ready cards ahead of the publish index (not yet published).
    var renderReadyCount: Int {
        renderReadyByID.keys.filter { id in
            guard let idx = orderedItems.firstIndex(where: { $0.id == id }) else { return false }
            return idx >= nextPublishIndex
        }.count
    }

    /// Number of resolved (disk-level) cards ahead of the publish index.
    var resolvedCount: Int {
        resolvedByID.keys.filter { id in
            guard let idx = orderedItems.firstIndex(where: { $0.id == id }) else { return false }
            return idx >= nextPublishIndex
        }.count
    }

    /// Total items in the editorial sequence (includes published + pending).
    var editorialCount: Int { orderedItems.count }

    /// Remaining editorial items after the publish index.
    var editorialAheadCount: Int {
        max(0, orderedItems.count - nextPublishIndex)
    }

    // MARK: - Private

    private func prepareItem(
        at index: Int, item: FeedItem, context: FeedPresentationContext
    ) {
        setState(item.id, to: .queued)
        let deadline = deadlineForIndex(index)
        let kind = placeholderKind(for: item)

        Task { [weak self] in
            guard let self else { return }

            // Resolve to disk-level asset
            await self.setState(item.id, to: .resolvingDirectImage)
            let asset = await self.resolveImageAsset(
                for: item, context: context, deadline: deadline
            )
            guard await self.isContextActive(context) else { return }

            let resolved: ResolvedCardAsset
            if let asset {
                resolved = .image(asset)
            } else if item.hasPotentialImage {
                resolved = .placeholder(kind)
            } else {
                resolved = .none
            }

            await self.storeResolved(item.id, asset: resolved)

            // Decode to render-ready
            await self.setState(item.id, to: .decoding)
            let renderReady = await self.decodeToRenderReady(
                item: item, asset: resolved, context: context
            )
            guard await self.isContextActive(context) else { return }

            await self.storeRenderReady(item.id, card: renderReady)
        }
    }

    // MARK: - Actor state helpers (called from Task closures)

    private func setState(_ id: String, to state: CardPreparationState) {
        stateByID[id] = state
    }

    private func isContextActive(_ context: FeedPresentationContext) -> Bool {
        context == activeContext
    }

    private func storeResolved(_ id: String, asset: ResolvedCardAsset) {
        resolvedByID[id] = asset
        stateByID[id] = .resolved(asset)
    }

    private func storeRenderReady(_ id: String, card: PreparedFeedCard) {
        renderReadyByID[id] = card
        stateByID[id] = .renderReady(card)

        // Wake any callers suspended in waitForContiguousPrefix so they
        // can re-evaluate whether the prefix is now long enough.
        let waiters = prefixWaiters
        prefixWaiters.removeAll()
        for (_, cont) in waiters { cont.resume() }
    }

    private func removePrefixWaiter(_ id: UUID) {
        prefixWaiters.removeValue(forKey: id)
    }

    private func resolveImageAsset(
        for item: FeedItem,
        context: FeedPresentationContext,
        deadline: ContinuousClock.Instant
    ) async -> ResolvedImageAsset? {
        // Primary path: direct image URL from feed item
        if let imageURL = item.bestImageURL.flatMap(URL.init(string:)) {
            let request = ImageResolutionRequest(
                itemID: item.id,
                url: imageURL,
                cacheKey: ImageCacheKey.forURL(imageURL),
                source: .directImageURL
            )
            let result = await raceWithDeadline(deadline: deadline) {
                await self.limiter.withSlot(category: "direct_image") {
                    await self.mediaStore.resolve(request: request)
                }
            }
            if result != nil { return result }
        }

        // Fallback: podcast episodes and articles without feed images
        // can have artwork on their episode/article page (Open Graph).
        // This is essential for podcasts — many RSS feeds have no
        // per-episode <itunes:image> but the episode page has artwork.
        //
        // Skip direct audio links (MP3/M4A/WAV/AAC) — downloading the full
        // audio file as an "image" wastes bandwidth and always fails validation.
        if item.canResolveArticleImage,
           !item.isDirectAudioLink,
           let articleURL = URL(string: item.url) {
            let cacheKey = ImageCacheKey.forURL(articleURL)
            let request = ImageResolutionRequest(
                itemID: item.id,
                url: articleURL,
                cacheKey: cacheKey,
                source: .articleOpenGraph
            )
            return await raceWithDeadline(deadline: deadline) {
                await self.limiter.withSlot(category: "article_image") {
                    await self.mediaStore.resolve(request: request)
                }
            }
        }

        return nil
    }

    private func decodeToRenderReady(
        item: FeedItem,
        asset: ResolvedCardAsset,
        context: FeedPresentationContext
    ) async -> PreparedFeedCard {
        let media: RenderReadyMedia
        let layout: PreparedCardLayout

        switch asset {
        case .image(let resolvedAsset):
            if let image = await mediaStore.decodedImage(for: resolvedAsset.cacheKey) {
                let renderImage = RenderImage(cacheKey: resolvedAsset.cacheKey, image: image)
                media = .image(renderImage)
                layout = .hero
            } else {
                media = .placeholder(placeholderKind(for: item))
                layout = .textOnly
            }

        case .placeholder(let kind):
            media = .placeholder(kind)
            layout = item.hasPotentialImage ? .hero : .textOnly

        case .none:
            media = .none
            layout = .textOnly
        }

        return PreparedFeedCard(
            item: item,
            media: media,
            layout: layout,
            presentationEpoch: context.epoch
        )
    }

    private func deadlineForIndex(_ index: Int) -> ContinuousClock.Instant {
        let duration: Duration
        if index < policy.initialPublishedCount {
            duration = policy.initialViewportDeadline
        } else if index < policy.renderReadyTarget {
            duration = policy.nearRunwayDeadline
        } else {
            duration = policy.deepRunwayDeadline
        }
        return ContinuousClock().now.advanced(by: duration)
    }

    private func placeholderKind(for item: FeedItem) -> PlaceholderKind {
        if item.isYouTube { return .video }
        if item.isPodcast { return .podcast }
        if item.isForum { return .forum }
        return .article
    }
}

// MARK: - Deadline Helper

/// Race an async operation against a deadline. Uses TaskGroup so the first
/// to complete wins — the deadline is a hard guarantee, not a cooperative
/// cancellation request. If the deadline fires first, the operation's
/// TaskGroup child is cancelled (but the actual download may continue in
/// shared MediaAssetStore state — that's fine; this caller abandons the
/// wait and returns nil, which the coordinator converts to a placeholder).
///
/// The operation's result is returned only if it completes before the
/// deadline. Otherwise nil is returned and the operation is abandoned.
private func raceWithDeadline<T: Sendable>(
    deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable () async -> T?
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        // Runner: the actual operation
        group.addTask {
            return await operation()
        }
        // Timer: fires at deadline, returns nil
        group.addTask {
            try? await Task.sleep(until: deadline, clock: .continuous)
            return nil
        }
        // First to complete wins; cancel the other
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

