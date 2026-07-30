import Foundation

// MARK: - Feed Snapshot
//
// The atomic unit of publication. A snapshot contains fully-prepared cards
// (using the existing PreparedFeedCard from Models/PreparedFeedCard.swift)
// plus metrics and state. The UI renders exactly what's in the snapshot —
// it never joins items and cards by ID after the fact.

/// Atomic snapshot published to the UI.
/// Every card has a terminal presentation. Never publish a snapshot
/// where images are still being resolved.
struct FeedSnapshot: Sendable {
    /// Which selection produced this snapshot.
    let selectionID: SelectionID

    /// Fully-prepared cards in display order.
    /// Uses the existing PreparedFeedCard from Models/PreparedFeedCard.swift
    /// which already carries item + terminal media + layout + epoch.
    let cards: [PreparedFeedCard]

    /// Metrics describing how this snapshot was produced.
    let metrics: SelectionMetrics

    /// Whether more content can be loaded.
    let hasMore: Bool

    /// When this snapshot was created.
    let createdAt: Date

    /// Convenience: item IDs in display order.
    var itemIDs: [String] { cards.map(\.id) }

    /// Convenience: count of cards.
    var count: Int { cards.count }

    /// Empty snapshot for the given selection.
    static func empty(selectionID: SelectionID) -> FeedSnapshot {
        FeedSnapshot(
            selectionID: selectionID,
            cards: [],
            metrics: .zero,
            hasMore: false,
            createdAt: Date()
        )
    }
}

// MARK: - Selection Context

/// Opaque context passed to card preparation to validate that
/// the preparation is still relevant.
struct SelectionContext: Hashable, Sendable {
    let selectionID: SelectionID
    let surface: SelectionSurface
}
