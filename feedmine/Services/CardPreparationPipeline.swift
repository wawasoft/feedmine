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
        let results: [IndexedResult] = await withTaskGroup(of: IndexedResult.self) { group in
            var iterator = items.enumerated().makeIterator()
            var started = 0

            // Prime the window
            while started < maxConcurrent, let (idx, item) = iterator.next() {
                group.addTask {
                    let presentation = await self.prepareSingle(
                        item, isRead: isRead, isBookmarked: isBookmarked
                    )
                    return (idx, presentation)
                }
                started += 1
            }

            var collected: [IndexedResult] = []
            while let result = await group.next() {
                collected.append(result)
                if let (idx, item) = iterator.next() {
                    group.addTask {
                        let presentation = await self.prepareSingle(
                            item, isRead: isRead, isBookmarked: isBookmarked
                        )
                        return (idx, presentation)
                    }
                }
            }
            return collected
        }

        // Reassemble in original order
        return results.sorted { $0.index < $1.index }.map(\.presentation)
    }

    /// Prepare a single item. The core unit of work.
    func prepareSingle(
        _ item: FeedItem,
        isRead: Bool = false,
        isBookmarked: Bool = false
    ) async -> FeedCardPresentation {
        let media = await resolveMedia(for: item)
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

    private func resolveMedia(for item: FeedItem) async -> ResolvedCardMedia {
        // Items without any image potential get .none immediately — no
        // need to allocate an image slot or run the pipeline.
        guard item.hasPotentialImage else { return .none }

        let imageURL = item.bestImageURL.flatMap(URL.init(string:))
        let articleURL = item.canResolveArticleImage ? URL(string: item.url) : nil

        if let resolved = await ImageLoader.resolveImage(url: imageURL, articleURL: articleURL) {
            return .image(resolved)
        }

        return .placeholder
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
