import Foundation
import UIKit

// MARK: - Placeholder Kind

/// Explicit content-type placeholder. Replaces the generic `.placeholder`
/// case with actionable information for the renderer.
enum PlaceholderKind: String, Codable, Sendable {
    case article
    case video
    case podcast
    case forum
}

// MARK: - Resolved Asset (disk-level, no UIImage)

/// Metadata for a fully resolved and cached image. The image data lives on
/// disk; this struct is small and safe to store in the deep resolved runway.
struct ResolvedImageAsset: Sendable, Equatable {
    let cacheKey: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let source: ImageResolutionSource
}

enum ImageResolutionSource: String, Sendable, Equatable {
    case directImageURL
    case articleOpenGraph
    case youTubeThumbnail
    case unknown
}

// MARK: - Resolved Card Asset

/// Terminal decision for a card's media slot at the disk level. No UIImage
/// here — safe for the deep runway.
enum ResolvedCardAsset: Sendable, Equatable {
    case image(ResolvedImageAsset)
    case placeholder(PlaceholderKind)
    case none
}

// MARK: - Render-Ready Media (decoded, bounded window)

/// Fully decoded media ready for immediate display. The `.image` case holds
/// a strong reference to the UIImage — only kept for published + render-ready
/// window, not the deep runway.
enum RenderReadyMedia: @unchecked Sendable {
    case image(RenderImage)
    case placeholder(PlaceholderKind)
    case none
}

extension RenderReadyMedia: Equatable {
    static func == (lhs: RenderReadyMedia, rhs: RenderReadyMedia) -> Bool {
        switch (lhs, rhs) {
        case (.image(let a), .image(let b)):
            return a.cacheKey == b.cacheKey && a.image === b.image
        case (.placeholder(let a), .placeholder(let b)):
            return a == b
        case (.none, .none):
            return true
        default:
            return false
        }
    }
}

struct RenderImage: @unchecked Sendable {
    let cacheKey: String
    let image: UIImage
}

// MARK: - Layout

enum PreparedCardLayout: Sendable, Equatable {
    case hero
    case thumbnail
    case textOnly
}

// MARK: - Preparation State (internal, never observed by UI)

enum CardPreparationState: Sendable {
    case queued
    case resolvingDirectImage
    case resolvingArticle
    case writingCache
    case resolved(ResolvedCardAsset)
    case decoding
    case renderReady(PreparedFeedCard)
}

// MARK: - Prepared Feed Card (published to UI)

/// A fully-prepared feed card ready for immediate display with zero async
/// work. The view renders this directly — no loading states, no .task
/// modifiers, no opacity animations for image arrival.
///
/// `item.isRead` and `item.isBookmarked` are mutable independently of
/// `media` — no presentation rebuild on bookmark toggle.
struct PreparedFeedCard: Identifiable, @unchecked Sendable {
    var id: String { item.id }

    /// The original feed content. Read/bookmark state is mutated directly
    /// on `item` without rebuilding the presentation.
    var item: FeedItem

    /// Terminal media — `.image`, `.placeholder(kind)`, or `.none`.
    let media: RenderReadyMedia

    /// Deterministic layout for this card.
    let layout: PreparedCardLayout

    /// The epoch of the context that produced this card. Used to discard
    /// stale promotions when filters/presets change.
    let presentationEpoch: UInt64
}
