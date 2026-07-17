import Foundation

// MARK: - FeedEngine Pagination Types
//
// Keyset pagination with versioned cursors — offset pagination is never used.
// Cursors from an older catalog version are rejected with cursorExpired.

/// Opaque keyset cursor for catalog page navigation.
/// The public cursor is an opaque token — UI code does not depend on its fields.
struct CatalogCursor: Codable, Sendable {
    /// Catalog version this cursor was created against.
    let catalogVersion: Int64
    /// Sort key of the last item on the previous page.
    let sortKey: String
    /// Entity ID of the last item on the previous page.
    let entityID: Int64
}

/// A page of catalog taxonomy nodes.
struct CatalogNodePage: Sendable {
    let items: [CatalogNodeSummary]
    let nextCursor: CatalogCursor?
    /// Approximate total count — may be nil if count query is expensive.
    let estimatedTotalCount: Int?
}

/// A page of sources within a taxonomy node or search result.
struct SourcePage: Sendable {
    let items: [SourceSummary]
    let nextCursor: CatalogCursor?
    let estimatedTotalCount: Int?
}

/// Opaque keyset cursor for timeline pagination.
/// Uses (sortTimestamp, itemID) tuple — date alone is not stable because
/// many items share the same timestamp.
struct TimelineCursor: Codable, Sendable {
    let sortTimestamp: Date
    let itemID: String
}

/// A page of feed items for the content timeline.
struct TimelinePage: Sendable {
    let items: [FeedItem]
    let nextCursor: TimelineCursor?
}

/// Typed content scope — prevents expanding a broad taxonomy node
/// into a massive [SourceID] array in Swift.
enum SourceScope: Sendable {
    /// All currently enabled sources.
    case allEnabled
    /// Sources within the given taxonomy nodes (resolved in SQL).
    case nodes([CatalogNodeID])
    /// An explicit small set (documented limit: ~100). Callers must enforce.
    case explicitSmallSet([SourceID])
    /// A saved query reference.
    case savedQuery(Int64)
}
