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
        await mediaStore.cancelAll()
        orderedItems = items
        stateByID.removeAll()
        resolvedByID.removeAll()
        renderReadyByID.removeAll()
        nextPrepareIndex = 0
        nextPublishIndex = 0
        activeContext = context
    }

    /// Append items to the end of the editorial sequence. Filters out
    /// items whose IDs are already known (single source of truth for
    /// deduplication — callers don't need to pre-filter).
    func appendEditorialSequence(
        _ items: [FeedItem],
        context: FeedPresentationContext
    ) async {
        guard context == activeContext else { return }
        let existingIDs = Set(orderedItems.map(\.id))
        let newItems = items.filter { !existingIDs.contains($0.id) }
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
    func takeRenderReadyPrefix(
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
                break  // Not contiguous — stop here
            }
        }

        // Remove published cards from internal maps. The UI now owns the
        // UIImage reference; keeping cards here inflates runway counters.
        for card in ready {
            renderReadyByID.removeValue(forKey: card.id)
            resolvedByID.removeValue(forKey: card.id)
            stateByID.removeValue(forKey: card.id)
        }

        nextPublishIndex = idx
        return ready
    }

    /// Discard all state for a context that's no longer active.
    func invalidate(context: FeedPresentationContext) {
        guard context != activeContext else { return }
        stateByID.removeAll()
        resolvedByID.removeAll()
        renderReadyByID.removeAll()
    }

    func handleMemoryPressure() {
        // Discard render-ready cards beyond the publish window
        let keepUpTo = nextPublishIndex + policy.publishedAheadTarget
        let keysToRemove = renderReadyByID.keys.filter { id in
            guard let idx = orderedItems.firstIndex(where: { $0.id == id }) else { return true }
            return idx >= keepUpTo
        }
        for key in keysToRemove {
            renderReadyByID.removeValue(forKey: key)
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
    }

    private func resolveImageAsset(
        for item: FeedItem,
        context: FeedPresentationContext,
        deadline: ContinuousClock.Instant
    ) async -> ResolvedImageAsset? {
        guard let imageURL = item.bestImageURL.flatMap(URL.init(string:)) else {
            return nil
        }

        let request = ImageResolutionRequest(
            itemID: item.id,
            url: imageURL,
            cacheKey: ImageCacheKey.forURL(imageURL),
            source: .directImageURL
        )

        // Race: resolution vs deadline
        return await raceWithDeadline(deadline: deadline) {
            await self.limiter.withSlot(category: "direct_image") {
                await self.mediaStore.resolve(request: request)
            }
        }
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

/// Race an async operation against a deadline. Returns the operation result
/// if it completes before the deadline, or nil if the deadline expires first.
///
/// Uses detached Tasks so the deadline doesn't wait for the operation to
/// finish. The download inside MediaAssetStore is a non-structured Task that
/// doesn't respond to cooperative cancellation — we abandon the wait without
/// cancelling the shared download (which continues in the background and
/// benefits future requests).
private func raceWithDeadline<T: Sendable>(
    deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable () async -> T?
) async -> T? {
    await withCheckedContinuation { continuation in
        let clock = ContinuousClock()
        let task = Task.detached {
            await operation()
        }
        let timeoutTask = Task.detached {
            try? await Task.sleep(until: deadline, clock: clock)
            // Deadline fired — resolve with nil. The operation Task
            // continues running (shared download populates disk cache).
            continuation.resume(returning: nil)
            task.cancel()
        }
        Task {
            let result = await task.value
            // Operation completed first — resolve with its result.
            continuation.resume(returning: result)
            timeoutTask.cancel()
        }
    }
}
