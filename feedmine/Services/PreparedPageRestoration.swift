import Foundation
import UIKit

/// Rebuilds the cards of a persisted page from its stored media projection.
///
/// Extracted from `FeedStore` (review P1.4). This is a pure transformation — projection + locally decodable assets →
/// cards in the caller's order — with no feed state of its own, and it is the single place that decides what a restored
/// card looks like. `FeedStore` keeps the orchestration: which page applies, the filter pass, publication and phase.
///
/// The decode is the only expensive part and it is bounded and concurrent by design: on a cold launch every lookup is a
/// memory miss (actor hop + disk read) and the cached page holds the whole previous page, so decoding sequentially would
/// sit directly in front of the first frame. Rows past the bound stay text-only and the pipeline fills them in as it
/// reaches them, off screen.
enum PreparedPageRestoration {

    /// How many rows of a restored page get their media decoded before the first paint.
    static let mediaDecodeLimit = 30

    /// - Parameters:
    ///   - items: the caller's **already filtered** list, in publication order. The display keeps `visibleItems` and
    ///     `visibleCards` 1:1, so the cards must follow this list — never the cached projection, whose order and
    ///     membership belong to whatever composition wrote it.
    ///   - projection: the page's stored media projection. `nil` (or an entry without a key) restores as text.
    ///   - mediaAssets: the store that resolves the cache keys to decoded images.
    nonisolated static func cards(
        for items: [FeedItem],
        projection: [FeedDisplayState.CachedCardMedia]?,
        mediaAssets: MediaAssetStore
    ) async -> [FeedCardPresentation] {
        // `reduce(into:)`, never `Dictionary(uniqueKeysWithValues:)`: a duplicated id must not be a crash. That is
        // exactly how the reverted append-merge died (`Duplicate values for key`).
        let keys = (projection ?? []).reduce(into: [String: String]()) { acc, entry in
            if let key = entry.cacheKey { acc[entry.itemID] = key }
        }
        // The persisted terminal layout, when the page was written by a build that records it (review P0.2). A card whose
        // image decodes locally keeps the shape the previous session published instead of being re-derived as `.hero`.
        let persistedLayouts = (projection ?? []).reduce(into: [String: FeedCardLayout]()) { acc, entry in
            if let key = entry.layout, let layout = FeedDisplayState.layout(from: key) { acc[entry.itemID] = layout }
        }

        var decoded: [String: UIImage] = [:]
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for item in items.prefix(mediaDecodeLimit) {
                guard let key = keys[item.id] else { continue }
                group.addTask { (item.id, await mediaAssets.decodedImage(for: key)) }
            }
            for await (id, image) in group {
                if let image { decoded[id] = image }
            }
        }

        var cards: [FeedCardPresentation] = []
        cards.reserveCapacity(items.count)
        for item in items {
            if let image = decoded[item.id] {
                cards.append(FeedCardPresentation(
                    item: item,
                    media: .image(image),
                    layout: persistedLayouts[item.id] ?? .hero,
                    isRead: item.isRead,
                    isBookmarked: item.isBookmarked
                ))
            } else {
                cards.append(FeedCardPresentation(
                    item: item,
                    media: .none,
                    layout: .textOnly,
                    isRead: item.isRead,
                    isBookmarked: item.isBookmarked
                ))
            }
        }
        return cards
    }
}
