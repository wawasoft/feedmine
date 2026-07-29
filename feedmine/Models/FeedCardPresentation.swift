import Foundation
import UIKit

// MARK: - Deprecation Notice
// FeedCardPresentation, ResolvedCardMedia, and FeedCardLayout are being
// replaced by PreparedFeedCard, RenderReadyMedia, and PreparedCardLayout
// respectively (see PreparedFeedCard.swift). During migration, both coexist.
// After Phase 9, this file will be removed.

// MARK: - Resolved Card Media

/// Terminal visual state for a card's media slot. Once resolved, it never
/// changes — no post-insertion downloads, no placeholder→image swaps, no
/// resolution upgrades while visible.
///
/// Equatable uses pointer identity for `.image` — two `.image` cases are
/// equal if they reference the same UIImage instance (which they will, since
/// the pipeline returns the cached NSCache object).
enum ResolvedCardMedia: @unchecked Sendable {
    /// Fully resolved, cached, and downsampled image ready for display.
    /// The UIImage is already in the NSCache — rendering is synchronous.
    case image(UIImage)

    /// No image could be resolved. The card shows its content-type placeholder
    /// (the existing heroBase logic in FeedItemCardView).
    case placeholder

    /// The item has no image slot at all (text-only card, compact layout).
    case none
}

extension ResolvedCardMedia: Equatable {
    static func == (lhs: ResolvedCardMedia, rhs: ResolvedCardMedia) -> Bool {
        switch (lhs, rhs) {
        case (.image(let a), .image(let b)):
            return a === b  // pointer identity — same cached instance
        case (.placeholder, .placeholder), (.none, .none):
            return true
        default:
            return false
        }
    }
}

// MARK: - Card Layout

/// Structural layout of a feed card. Decided before preparation so the
/// pipeline knows whether to allocate an image slot.
enum FeedCardLayout: Equatable, Sendable {
    /// Full-width hero image (16:9) with title + excerpt below.
    case hero

    /// Compact thumbnail (90×90) with text beside it.
    case thumbnail

    /// Text only — no image slot reserved.
    case textOnly
}

// MARK: - Feed Card Presentation

/// A fully-prepared feed card, ready for immediate display with zero async
/// work. The view renders this directly — no loading states, no .task
/// modifiers, no opacity animations for image arrival.
struct FeedCardPresentation: Identifiable, Equatable, @unchecked Sendable {
    /// Maps to FeedItem.id so SwiftUI diffing works identically.
    var id: String { item.id }

    /// The original feed content (title, excerpt, source, link, etc.).
    let item: FeedItem

    /// Resolved media state — `.image`, `.placeholder`, or `.none`.
    let media: ResolvedCardMedia

    /// Structural layout for this card.
    let layout: FeedCardLayout

    /// Read/bookmark state stamped at preparation time (snapshot — doesn't
    /// update after publication; the next refresh rebuilds the presentation).
    let isRead: Bool
    let isBookmarked: Bool

    /// When this presentation was resolved. Used for metrics
    /// (queue depth age, preparation latency).
    let preparedAt: Date

    init(item: FeedItem, media: ResolvedCardMedia, layout: FeedCardLayout,
         isRead: Bool, isBookmarked: Bool, preparedAt: Date = Date()) {
        self.item = item
        self.media = media
        self.layout = layout
        self.isRead = isRead
        self.isBookmarked = isBookmarked
        self.preparedAt = preparedAt
    }
}

// MARK: - Backward Compatibility Bridge

extension FeedCardPresentation {
    /// Create a legacy FeedCardPresentation from the new PreparedFeedCard.
    /// Used during migration while views still consume the legacy type.
    init(from prepared: PreparedFeedCard, isRead: Bool, isBookmarked: Bool) {
        let legacyMedia: ResolvedCardMedia
        switch prepared.media {
        case .image(let ri):
            legacyMedia = .image(ri.image)
        case .placeholder:
            legacyMedia = .placeholder
        case .none:
            legacyMedia = .none
        }
        self.init(
            item: prepared.item,
            media: legacyMedia,
            layout: FeedCardLayout(from: prepared.layout),
            isRead: isRead,
            isBookmarked: isBookmarked
        )
    }
}

extension FeedCardLayout {
    init(from layout: PreparedCardLayout) {
        switch layout {
        case .hero: self = .hero
        case .thumbnail: self = .thumbnail
        case .textOnly: self = .textOnly
        }
    }
}
