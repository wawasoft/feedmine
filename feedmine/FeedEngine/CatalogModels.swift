import Foundation

// MARK: - FeedEngine Catalog Models
//
// Lightweight Sendable structs for catalog browsing and search.
// SourceSummary is ~100 bytes — minimal fields for a browse row.
// SourceDetails is loaded on demand when the user taps a source.

/// Lightweight summary for catalog listing — one per source in a page.
/// Does NOT include the full request URL or all placements; use
/// `sourceDetails(id:)` to load those on demand.
struct SourceSummary: Identifiable, Sendable {
    let id: SourceID
    let title: String
    /// Display-only host for presentation/search.
    let displayHost: String?
    let mediaKind: MediaKind
    let language: String?
}

/// Full metadata for a single source, loaded on demand.
struct SourceDetails: Identifiable, Sendable {
    let id: SourceID
    let title: String
    let declaredURL: URL
    let requestURL: URL
    let mediaKind: MediaKind
    let language: String?
    /// Every editorial placement of this source across OPML files.
    let placements: [SourcePlacementSummary]
}

/// Summary of one editorial placement — which OPML file, which node,
/// and any per-placement metadata overrides.
struct SourcePlacementSummary: Identifiable, Sendable {
    let id: Int64
    let nodeID: CatalogNodeID
    let nodeName: String
    let opmlFile: String
    let sortOrder: Int
    let titleOverride: String?
    let languageOverride: String?
    let mediaKindOverride: MediaKind?
}

/// Summary of a catalog taxonomy node for browsing.
struct CatalogNodeSummary: Identifiable, Sendable {
    let id: CatalogNodeID
    let name: String
    let kind: CatalogNodeKind
    /// Total feed sources in this subtree.
    let sourceCount: Int
    /// Direct child nodes (not feeds).
    let childCount: Int
    /// ISO 639-1 language code if this node has an explicit language.
    let language: String?
}
