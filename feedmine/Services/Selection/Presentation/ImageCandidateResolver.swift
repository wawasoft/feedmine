import Foundation
import UIKit

// MARK: - Image Candidate Resolver (Etapa 2.1)
//
// Defines the ordered chain of image candidates the CardPreparationCoordinator
// tries for each item. This replaces the single bestImageURL approach with
// a fallback chain that covers all image sources.

/// A single candidate image source to try.
enum ImageCandidate: Sendable {
    /// Already resolved and cached in memory.
    case memoryCache(cacheKey: String)
    /// Already resolved and cached on disk.
    case diskCache(cacheKey: String)
    /// Direct image URL from the feed item (media:content, enclosure, etc.).
    case directImage(URL)
    /// Channel/feed-level artwork (podcast show art, site logo).
    case channelArtwork(URL)
    /// YouTube thumbnail derived from video ID.
    case youTubeThumbnail(URL)
    /// Article/episode page Open Graph image.
    case openGraph(articleURL: URL)
    /// Retry of a previously-failed URL (transient error).
    case retry(URL, attempt: Int)
}

/// Priority-ordered chain of image candidates for a feed item.
/// The coordinator tries each candidate in order until one succeeds.
/// Only after ALL candidates fail does the item get a placeholder.
struct ImageCandidateChain: Sendable {
    let itemID: String
    let candidates: [ImageCandidate]

    /// Build the complete candidate chain for a feed item.
    /// Order: memory → disk → direct → channel → YouTube → OG → retry
    static func forItem(_ item: FeedItem) -> ImageCandidateChain {
        var candidates: [ImageCandidate] = []

        // 1. Memory cache (already resolved this session)
        if let best = item.bestImageURL, let url = URL(string: best) {
            let cacheKey = ImageCacheKey.forURL(url)
            candidates.append(.memoryCache(cacheKey: cacheKey))
        }

        // 2. Disk cache (resolved in a previous session)
        if let best = item.bestImageURL, let url = URL(string: best) {
            let cacheKey = ImageCacheKey.forURL(url)
            candidates.append(.diskCache(cacheKey: cacheKey))
        }

        // 3. Direct image from feed
        if let best = item.bestImageURL, let url = URL(string: best) {
            candidates.append(.directImage(url))
        }

        // 4. YouTube thumbnail
        if item.isYouTube, let ytURL = item.youTubeThumbnailURL.flatMap(URL.init(string:)) {
            candidates.append(.youTubeThumbnail(ytURL))
        }

        // 5. Article/episode page Open Graph (podcasts, articles without feed images)
        if item.canResolveArticleImage, let articleURL = URL(string: item.url) {
            candidates.append(.openGraph(articleURL: articleURL))
        }

        return ImageCandidateChain(itemID: item.id, candidates: candidates)
    }

    /// Number of candidates remaining to try.
    var remaining: Int { candidates.count }
}

// MARK: - Candidate Resolution

/// Resolves image candidates against the available caches and fetchers.
/// Used by CardPreparationCoordinator to try candidates in order.
struct ImageCandidateResolver: Sendable {

    /// Try the next candidate in the chain. Returns the resolved asset
    /// if successful, or nil to advance to the next candidate.
    func resolve(
        _ candidate: ImageCandidate,
        mediaStore: MediaAssetStore
    ) async -> ResolvedImageAsset? {
        switch candidate {
        case .memoryCache(let cacheKey):
            // Already in memory — MediaAssetStore handles this
            return nil  // Handled by coordinator's memory check

        case .diskCache(let cacheKey):
            // Try disk cache via media store
            let request = ImageResolutionRequest(
                itemID: "",  // candidate chain doesn't know item ID
                url: nil,
                cacheKey: cacheKey,
                source: .directImageURL
            )
            return await mediaStore.resolve(request: request)

        case .directImage(let url):
            let cacheKey = ImageCacheKey.forURL(url)
            let request = ImageResolutionRequest(
                itemID: "",
                url: url,
                cacheKey: cacheKey,
                source: .directImageURL
            )
            return await mediaStore.resolve(request: request)

        case .channelArtwork(let url):
            let cacheKey = ImageCacheKey.forURL(url)
            let request = ImageResolutionRequest(
                itemID: "",
                url: url,
                cacheKey: cacheKey,
                source: .directImageURL
            )
            return await mediaStore.resolve(request: request)

        case .youTubeThumbnail(let url):
            let cacheKey = ImageCacheKey.forURL(url)
            let request = ImageResolutionRequest(
                itemID: "",
                url: url,
                cacheKey: cacheKey,
                source: .youTubeThumbnail
            )
            return await mediaStore.resolve(request: request)

        case .openGraph(let articleURL):
            let cacheKey = ImageCacheKey.forURL(articleURL)
            let request = ImageResolutionRequest(
                itemID: "",
                url: articleURL,
                cacheKey: cacheKey,
                source: .articleOpenGraph
            )
            return await mediaStore.resolve(request: request)

        case .retry(let url, _):
            let cacheKey = ImageCacheKey.forURL(url)
            let request = ImageResolutionRequest(
                itemID: "",
                url: url,
                cacheKey: cacheKey,
                source: .unknown
            )
            return await mediaStore.resolve(request: request)
        }
    }
}
