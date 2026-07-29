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

    /// Replace the entire editorial sequence. Cancels all in-flight work
    /// for any previous context.
    func replaceEditorialSequence(
        _ items: [FeedItem],
        context: FeedPresentationContext
    ) async {
        await mediaStore.cancelAll()
        orderedItems = items
        stateByID.removeAll()
        resolvedByID.removeAll()
        renderReadyByID.removeAll()
        nextPrepareIndex = 0
        nextPublishIndex = 0
        activeContext = context
    }

    /// Append items to the end of the editorial sequence.
    func appendEditorialSequence(
        _ items: [FeedItem],
        context: FeedPresentationContext
    ) async {
        guard context == activeContext else { return }
        orderedItems.append(contentsOf: items)
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

    /// Number of cards currently render-ready (for metrics).
    var renderReadyCount: Int { renderReadyByID.count }
    var resolvedCount: Int { resolvedByID.count }
    var editorialCount: Int { orderedItems.count }

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
        deadline: Date
    ) async -> ResolvedImageAsset? {
        guard let imageURL = item.bestImageURL.flatMap(URL.init(string:)) else {
            return nil
        }

        let request = ImageResolutionRequest(
            itemID: item.id,
            url: imageURL,
            cacheKey: nil,
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
            if let data = await mediaStore.diskData(for: resolvedAsset.cacheKey),
               let image = UIImage(data: data) {
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

    private func deadlineForIndex(_ index: Int) -> Date {
        let duration: Duration
        if index < policy.initialPublishedCount {
            duration = policy.initialViewportDeadline
        } else if index < policy.renderReadyTarget {
            duration = policy.nearRunwayDeadline
        } else {
            duration = policy.deepRunwayDeadline
        }
        return Date().addingTimeInterval(TimeInterval(duration.components.seconds))
    }

    private func placeholderKind(for item: FeedItem) -> PlaceholderKind {
        if item.isYouTube { return .video }
        if item.isPodcast { return .podcast }
        if item.isForum { return .forum }
        return .article
    }
}

// MARK: - Deadline Helper

/// Race an async operation against a deadline. If the operation completes
/// first, returns its result. If the deadline expires first, returns nil.
/// The operation task is cancelled when the deadline fires.
private func raceWithDeadline<T: Sendable>(
    deadline: Date,
    operation: @escaping @Sendable () async -> T?
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            return await operation()
        }
        group.addTask {
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            return nil
        }
        // Return the first result (operation wins) or nil (deadline wins)
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
