import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.feedmine.app", category: "DisplayState")

/// Manages the visible feed state — what the UI renders right now.
/// Extracted from FeedStore (P0-01 audit R1).
///
/// FeedStore delegates display state mutations here so the 7,204-line
/// monolith shrinks by ~200 lines and the display phase lifecycle has
/// a single, focused owner.
///
/// ## Behavioral Contracts
/// - **Stamping**: Every visible item is stamped with `isRead`/`isBookmarked`
///   so views don't observe the global sets directly — reading one item
///   won't invalidate all cards.
/// - **No-op detection**: Redundant updates are dropped before bumping
///   `visibleItemsGeneration`, preventing spurious cache invalidations.
/// - **Atomic epoch**: `advanceEpoch` always bumps the epoch and captures
///   a fresh context in one call — the two are never split.
/// - **First-paint transition**: `publishCards` couples `loadingState ==
///   .initial → .idle` with the phase flip to `.ready`/`.empty`.
///
/// Marked `@Observable` so the FeedStore → FeedLoader → SwiftUI view
/// observation chain tracks property-level dependencies through all
/// three layers. `@unchecked Sendable` is dropped — `@MainActor` classes
/// are implicitly `Sendable`.
@MainActor
@Observable
final class FeedDisplayState {
    /// Items currently rendered in the feed.
    private(set) var visibleItems: [FeedItem] = []

    /// Pre-resolved card presentations for the visible page.
    /// Published alongside `visibleItems` so views can render images
    /// synchronously (no post-insertion downloads). Search and onboarding
    /// paths that skip the pipeline will have an empty `visibleCards` —
    /// views fall back to `CachedAsyncImage`.
    private(set) var visibleCards: [FeedCardPresentation] = []

    /// Monotonic counter incremented on every `visibleItems` change.
    /// `FeedLoader` uses this for cache invalidation instead of item count.
    private(set) var visibleItemsGeneration: UInt64 = 0

    /// Monotonic counter incremented whenever `visibleCards` is replaced
    /// or swapped in place (image resolution upgrades). `FeedLoader` caches
    /// keyed only on `visibleItemsGeneration` would keep rendering stale
    /// card media after `replaceVisibleCard` — cards can change without
    /// items changing.
    private(set) var visibleCardsGeneration: UInt64 = 0

    /// Monotonic counter incremented on in-place item mutations that skip
    /// the generation bump (`mutateVisibleItem(bumpGeneration: false)`),
    /// e.g. read-state toggles. `FeedLoader` includes this in its cache
    /// keys so stamped read/bookmark state always re-renders.
    private(set) var readStateRevision: UInt64 = 0

    /// Loading indicator state exposed to the UI.
    private(set) var loadingState: FeedLoadingState = .idle

    /// Current lifecycle phase of the feed (startup, ready, refreshing).
    /// Replaces the error-prone pattern of inferring state from
    /// `items.isEmpty + loadingState`.
    private(set) var feedDisplayPhase: FeedDisplayPhase = .preparing(contextID: 0, reason: .startup)

    /// `true` while the cold-start runway is still being built.
    private(set) var isPreparingInitialRunway = false

    /// Monotonic epoch incremented on every filter/preset change.
    /// Every async preparation task captures this; results are discarded
    /// if the epoch changes before the task completes.
    private(set) var presentationEpoch: UInt64 = 0

    /// Context snapshot captured at filter/preset boundaries.
    /// Identifies a specific feed composition session — async tasks that
    /// captured a different context discard their results.
    private(set) var activePresentationContext = FeedPresentationContext(
        epoch: 0, mode: .main,
        filterGeneration: 0, presetGeneration: 0
    )

    // MARK: - Mutations

    /// Stamp and publish items directly (legacy / non-pipeline path).
    ///
    /// Stamps each item with `isRead`/`isBookmarked` so views don't
    /// observe the global sets directly. Guards against no-op updates
    /// to prevent spurious `visibleItemsGeneration` bumps that would
    /// force full cache invalidations in `FeedLoader`.
    ///
    /// This is the legacy replace-only path — FeedStore's legacy
    /// `setVisibleItems` never appends. The prepared pipeline should
    /// use ``publishCards(_:items:readItemIDs:bookmarkItemIDs:isAppend:)``
    /// which supports both append and replace with card publication.
    func setVisibleItems(
        _ items: [FeedItem],
        readItemIDs: Set<String>,
        bookmarkItemIDs: Set<String>,
        shouldCache: Bool = false
    ) {
        var stamped = items
        for i in stamped.indices {
            stamped[i].stamp(readItemIDs: readItemIDs, bookmarkItemIDs: bookmarkItemIDs)
        }

        // First-paint transition: settle .preparing → .ready/.empty.
        // Keyed on the phase (not loadingState) because a defer in
        // fetchNextBatch can set loadingState = .idle before the async
        // card-prep publish lands — the old loadingState==.initial gate
        // was permanently missed, causing the "Loading your feed" hang.
        //
        // Skip when loadingState == .refreshing: setFilter/shakeToRefresh
        // deliberately enter .preparing + .refreshing, then publish empty
        // transiently before the reload completes. Settling to .empty here
        // would defeat that intent and flash the empty state.
        let isFirstPaint: Bool
        if case .preparing = feedDisplayPhase,
           loadingState != .refreshing {
            isFirstPaint = true
            feedDisplayPhase = stamped.isEmpty
                ? .empty(contextID: presentationEpoch)
                : .ready(contextID: presentationEpoch)
            if loadingState == .initial { loadingState = .idle }
            logger.info("setVisibleItems firstPaint: phase=\(String(describing: self.feedDisplayPhase))")
        } else {
            isFirstPaint = false
        }

        guard stamped != visibleItems else { return }
        visibleItems = stamped
        if stamped.isEmpty { visibleCards = [] }
        visibleItemsGeneration &+= 1
        logger.info("setVisibleItems: items=\(self.visibleItems.count) generation=\(self.visibleItemsGeneration)")

        // Cache the first page for instant warm-start restore. Runs after
        // the assignment so the snapshot includes the published items.
        if shouldCache, isFirstPaint {
            cacheVisiblePageIfNeeded(isAppend: false)
        }
    }

    /// Publish render-ready cards alongside their items (prepared pipeline).
    ///
    /// Items and cards are published atomically — the UI never sees a card
    /// without its resolved media. Re-stamps items to capture any read/bookmark
    /// state changes that occurred during card preparation.
    ///
    /// On first paint (`loadingState == .initial`), transitions to `.idle`
    /// and flips `feedDisplayPhase` to `.ready` or `.empty` together —
    /// the two are never desynchronized.
    func publishCards(
        _ cards: [FeedCardPresentation],
        items: [FeedItem],
        readItemIDs: Set<String>,
        bookmarkItemIDs: Set<String>,
        isAppend: Bool,
        shouldCache: Bool = false
    ) {
        // Re-stamp: read/bookmark state may have changed during preparation.
        var stampedItems = items
        for i in stampedItems.indices {
            stampedItems[i].stamp(readItemIDs: readItemIDs, bookmarkItemIDs: bookmarkItemIDs)
        }

        if isAppend {
            let existingIDs = Set(visibleCards.map(\.id))
            let newCards = cards.filter { !existingIDs.contains($0.id) }
            guard !newCards.isEmpty else { return }
            // Filter items by the same set of new card IDs so visibleItems
            // and visibleCards stay 1:1 — never append an item without a
            // matching card (review finding: items/cards divergence).
            let newIDs = Set(newCards.map(\.id))
            let newItems = stampedItems.filter { newIDs.contains($0.id) }
            visibleCards.append(contentsOf: newCards)
            visibleItems.append(contentsOf: newItems)
        } else {
            visibleCards = cards
            visibleItems = stampedItems
        }

        visibleItemsGeneration &+= 1
        visibleCardsGeneration &+= 1

        // First-paint transition: settle .preparing → .ready/.empty.
        // Skips when loadingState == .refreshing to avoid flashing the
        // empty state during setFilter/shakeToRefresh transient clears.
        if case .preparing = feedDisplayPhase,
           loadingState != .refreshing {
            feedDisplayPhase = visibleItems.isEmpty
                ? .empty(contextID: presentationEpoch)
                : .ready(contextID: presentationEpoch)
            if loadingState == .initial { loadingState = .idle }
            logger.info("publishCards firstPaint: items=\(self.visibleItems.count) cards=\(self.visibleCards.count)")
        }

        // Persist the first page so the next launch paints instantly while
        // the async OPML → taxonomy → SQLite → card-prep pipeline rebuilds.
        // Cache with filter signature so filtered/config-specific pages
        // are also restored instantly on restart.
        if shouldCache {
            cacheVisiblePageIfNeeded(isAppend: isAppend)
        }
    }

    /// Mutate a single visible item in-place.
    ///
    /// Unlike ``setVisibleItems(_:readItemIDs:bookmarkItemIDs:)``, this method
    /// does **not** re-stamp the item — it applies the transform directly.
    /// Callers that need read/bookmark state updated should set `isRead` /
    /// `isBookmarked` inside the transform after updating the corresponding
    /// `readItemIDs` / `bookmarkItemIDs` sets on FeedStore.
    ///
    /// - Parameters:
    ///   - index: Index in `visibleItems` to mutate. Guards out-of-bounds.
    ///   - bumpGeneration: If `true`, increments `visibleItemsGeneration`
    ///     so `FeedLoader` caches invalidate. Set to `false` for read-state
    ///     changes that should only re-render the affected card without
    ///     shifting the feed or invalidating the cache.
    ///   - transform: Closure that receives an `inout FeedItem` to modify.
    func mutateVisibleItem(
        at index: Int,
        bumpGeneration: Bool = false,
        _ transform: (inout FeedItem) -> Void
    ) {
        guard visibleItems.indices.contains(index) else { return }
        transform(&visibleItems[index])
        // Always bump the read-state revision: in-place mutations (e.g.
        // read toggles with bumpGeneration: false) must invalidate
        // FeedLoader's filteredItems/dateSections caches, or the UI keeps
        // rendering the pre-mutation stamp.
        readStateRevision &+= 1
        if bumpGeneration {
            visibleItemsGeneration &+= 1
        }
    }

    /// Replace visible cards directly (legacy queue path).
    ///
    /// Used when the legacy `cardQueue` produces card presentations
    /// separately from item publication. Does not touch `visibleItems`
    /// or bump `visibleItemsGeneration` — the caller is responsible
    /// for keeping items and cards in sync.
    func setVisibleCards(_ cards: [FeedCardPresentation]) {
        visibleCards = cards
        visibleCardsGeneration &+= 1
    }

    /// Replace a single visible card in-place without bumping generation.
    ///
    /// Used for visual-only upgrades (e.g., placeholder → resolved image
    /// from `imageResolutionQueue(didResolveImageFor:)`) that must not
    /// shift the feed or invalidate `FeedLoader` caches.
    ///
    /// Does **not** touch `visibleItems` — only swaps the card presentation.
    /// For full item+card publication, use ``publishCards(_:items:readItemIDs:bookmarkItemIDs:isAppend:)``.
    func replaceVisibleCard(at index: Int, with card: FeedCardPresentation) {
        guard visibleCards.indices.contains(index) else { return }
        visibleCards[index] = card
        // Card-only swap (placeholder → resolved image): bump the cards
        // generation so FeedLoader's card-derived caches re-render even
        // though items didn't change.
        visibleCardsGeneration &+= 1
    }

    /// Bump the presentation epoch and capture a fresh context atomically.
    ///
    /// FeedStore always performs these two operations together — splitting
    /// them would let a caller bump the epoch without refreshing the context,
    /// causing every epoch-guarded prepare task to discard valid work.
    ///
    /// - Returns: The old and new contexts so the caller can stop/start
    ///   the runway controller (matching FeedStore's pattern).
    func advanceEpoch(
        mode: FeedPresentationMode,
        filterGeneration: Int64,
        presetGeneration: Int64
    ) -> (old: FeedPresentationContext, new: FeedPresentationContext) {
        presentationEpoch &+= 1
        let old = activePresentationContext
        activePresentationContext = FeedPresentationContext(
            epoch: presentationEpoch, mode: mode,
            filterGeneration: filterGeneration, presetGeneration: presetGeneration
        )
        return (old, activePresentationContext)
    }

    /// Persisted snapshot of the first visible page — written after every
    /// non-append publish so warm starts can paint instantly while the async
    /// pipeline rebuilds the runway. When filters are active, the cache key
    /// includes a filter signature so each configuration gets its own slot.
    private static let pageCacheBaseURL: URL? = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first
    }()

    /// Returns the cache URL for the given filter signature (empty = main).
    private static func pageCacheURL(filterSignature: String) -> URL? {
        guard let base = pageCacheBaseURL else { return nil }
        if filterSignature.isEmpty {
            return base.appendingPathComponent("visible-page-cache.json")
        }
        // Hash the signature to keep filenames safe
        let hash = filterSignature.hashValue
        return base.appendingPathComponent("visible-page-cache-\(hash).json")
    }

    struct CachedPage: Codable {
        let items: [FeedItem]
        var visibleItemsGeneration: UInt64
    }

    /// Save the current first page so the next cold launch paints instantly.
    /// Only caches replace-published pages (not appends) to avoid drifting.
    /// JSON encode + write run off the main actor so the UI never freezes.
    /// Now saves with filter signature so filtered/config-specific pages
    /// are also cached for instant restore.
    func cacheVisiblePageIfNeeded(isAppend: Bool, filterSignature: String = "") {
        guard !isAppend, !visibleItems.isEmpty, let url = Self.pageCacheURL(filterSignature: filterSignature) else { return }
        let page = CachedPage(items: visibleItems, visibleItemsGeneration: visibleItemsGeneration)
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(page)
                try data.write(to: url, options: .atomic)
            } catch {
                logger.warning("Failed to cache visible page: \(error)")
            }
        }
    }

    /// Restore a previously-cached first page so the UI paints instantly.
    /// Returns nil when no cache exists or decoding fails.
    /// File read + JSON decode run off the main actor so startup never janks.
    /// Pass a filter signature to restore a filtered/config-specific page.
    func restoreCachedPage(filterSignature: String = "") async -> (items: [FeedItem], generation: UInt64)? {
        guard let url = Self.pageCacheURL(filterSignature: filterSignature) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url),
                  let page = try? JSONDecoder().decode(CachedPage.self, from: data),
                  !page.items.isEmpty else { return nil }
            return (page.items, page.visibleItemsGeneration)
        }.value
    }

    func setLoadingState(_ state: FeedLoadingState) {
        let old = loadingState
        loadingState = state
        if old != state {
            logger.info("loadingState: \(String(describing: old)) → \(String(describing: state))")
        }
    }

    func setFeedDisplayPhase(_ phase: FeedDisplayPhase) {
        let old = feedDisplayPhase
        feedDisplayPhase = phase
        if case .preparing = old, case .preparing = phase { return }
        logger.info("feedDisplayPhase: \(String(describing: old)) → \(String(describing: phase))")
    }

    func setIsPreparingInitialRunway(_ value: Bool) {
        isPreparingInitialRunway = value
    }

    /// Reset all display state consistently.
    ///
    /// Resets `activePresentationContext` alongside `presentationEpoch`
    /// so epoch-guarded tasks don't encounter a stale context after a reset.
    func clear() {
        visibleItems = []
        visibleCards = []
        loadingState = .idle
        feedDisplayPhase = .preparing(contextID: 0, reason: .startup)
        isPreparingInitialRunway = false
        presentationEpoch = 0
        visibleItemsGeneration = 0
        visibleCardsGeneration = 0
        readStateRevision = 0
        activePresentationContext = FeedPresentationContext(
            epoch: 0, mode: .main,
            filterGeneration: 0, presetGeneration: 0
        )
    }
}
