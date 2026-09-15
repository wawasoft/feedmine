import Foundation
import UIKit

/// Actor that resolves batches of `FeedItem` values into terminal
/// `FeedCardPresentation` values. Each item's media is fully resolved
/// (memory → disk → network → article OG) before the presentation is
/// returned — no post-insertion downloads or upgrades.
///
/// Concurrency is bounded to avoid saturating the network and memory:
/// - 8 concurrent image resolutions (shared with ImagePrefetcher's 16 via
///   the shared ImageDownloadTracker dedup)
/// - Article OG resolution inherits ArticleImageResolver's own 4-concurrent cap
actor CardPreparationPipeline {

    /// Maximum concurrent image resolutions. Images are downsampled to
    /// 800px (~200-400 KB JPEG, ~2-3 MB decoded), so 8 concurrent = ~24 MB
    /// peak memory overhead for this pipeline.
    private let maxConcurrent = 8

    // MARK: - Public API

    /// Prepare a batch of items for display. Returns presentations in the
    /// same order as the input array so the reservoir's diversity order
    /// is preserved.
    func prepare(
        _ items: [FeedItem],
        isRead: Bool = false,
        isBookmarked: Bool = false
    ) async -> [FeedCardPresentation] {
        guard !items.isEmpty else { return [] }

        // Resolve all items concurrently, tracking original positions so
        // we can reassemble in input order.
        typealias IndexedResult = (index: Int, presentation: FeedCardPresentation)
        // Collected outside the group so a cancellation throw mid-drain
        // returns the results collected so far instead of discarding them.
        var collected: [IndexedResult] = []
        do {
            // Throwing group: lets the drain loop surface cancellation via
            // Task.checkCancellation() and bail out immediately.
            try await withThrowingTaskGroup(of: IndexedResult.self) { group in
                var iterator = items.enumerated().makeIterator()
                var started = 0

                // Prime the window
                while started < maxConcurrent, let (idx, item) = iterator.next() {
                    let deadline = deadlineForIndex(idx)
                    group.addTask {
                        let presentation = await self.prepareSingle(
                            item,
                            isRead: isRead,
                            isBookmarked: isBookmarked,
                            deadline: deadline
                        )
                        return (idx, presentation)
                    }
                    started += 1
                }

                while let result = try await group.next() {
                    // Respect cancellation: stop draining immediately. The
                    // group cancels the remaining children on body exit.
                    try Task.checkCancellation()
                    collected.append(result)
                    if let (idx, item) = iterator.next() {
                        let deadline = deadlineForIndex(idx)
                        group.addTask {
                            let presentation = await self.prepareSingle(
                                item,
                                isRead: isRead,
                                isBookmarked: isBookmarked,
                                deadline: deadline
                            )
                            return (idx, presentation)
                        }
                    }
                }
            }
        } catch {
            // Cancelled — the caller no longer wants the batch.
        }

        // Reassemble in original order
        return collected.sorted { $0.index < $1.index }.map(\.presentation)
    }

    /// Prepare a single item. The core unit of work. `deadline` bounds the
    /// media resolution so a stuck image URL can't stall the batch.
    func prepareSingle(
        _ item: FeedItem,
        isRead: Bool = false,
        isBookmarked: Bool = false,
        deadline: ContinuousClock.Instant
    ) async -> FeedCardPresentation {
        let media = await resolveMedia(for: item, deadline: deadline)
        let layout = cardLayout(for: item, media: media)

        return FeedCardPresentation(
            item: item,
            media: media,
            layout: layout,
            isRead: isRead,
            isBookmarked: isBookmarked
        )
    }

    // MARK: - Private

    private func resolveMedia(
        for item: FeedItem,
        deadline: ContinuousClock.Instant
    ) async -> ResolvedCardMedia {
        // Items without any image potential get .none immediately — no
        // need to allocate an image slot or run the pipeline.
        guard item.hasPotentialImage else { return .none }

        let imageURL = item.bestImageURL.flatMap(URL.init(string:))
        let articleURL = item.canResolveArticleImage ? URL(string: item.url) : nil

        // Hard deadline on the network work — a hung fetch degrades to a
        // placeholder instead of stalling the batch.
        return await raceWithDeadline(deadline: deadline) { () -> ResolvedCardMedia? in
            guard let image = await ImageLoader.resolveImage(
                url: imageURL, articleURL: articleURL
            ) else { return nil }
            return .image(image)
        } ?? .placeholder
    }

    /// Per-item deadline, mirroring RunwayPolicy's tiers (initial viewport,
    /// near runway, deep runway). `index` is the position within the batch.
    private func deadlineForIndex(_ index: Int) -> ContinuousClock.Instant {
        let duration: Duration
        if index < 20 {
            duration = .seconds(6)
        } else if index < 120 {
            duration = .seconds(15)
        } else {
            duration = .seconds(30)
        }
        return ContinuousClock().now.advanced(by: duration)
    }

    private func cardLayout(for item: FeedItem, media: ResolvedCardMedia) -> FeedCardLayout {
        switch media {
        case .image:
            // Layout decision: hero vs thumbnail is driven by the view's
            // horizontalSizeClass at render time. We default to hero here;
            // the view can adapt.
            return .hero
        case .placeholder, .none:
            return .textOnly
        }
    }
}

// MARK: - Deadline Helper

/// Race an async operation against a deadline. Uses TaskGroup so the first
/// to complete wins — the deadline is a hard guarantee, not a cooperative
/// cancellation request. If the deadline fires first, the operation's
/// TaskGroup child is cancelled (but the actual download may continue in
/// shared ImageLoader state — that's fine; this caller abandons the wait
/// and returns nil, which the caller converts to a placeholder).
///
/// Mirrors CardPreparationCoordinator's deadline pattern so every network
/// hop in the card pipeline is bounded.
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
