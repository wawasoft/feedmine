import Foundation

// MARK: - FeedEngine Stage 1 Protocols
//
// First migration vertical: catalog compilation, browse, and search only.
// Timeline, fetching, and the reservoir remain on the legacy FeedStore path
// until the catalog vertical is proven.

// MARK: - Catalog Reading

/// Paginated, read-only access to the compiled catalog.
/// All queries are SQLite-backed, returning bounded pages.
/// No public API returns the entire catalog or a complete subtree as an array.
protocol CatalogReading: Sendable {
    /// Browse the children of a catalog node. Pass nil for root.
    func childNodes(
        of parentID: CatalogNodeID?,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> CatalogNodePage

    /// Browse sources within a taxonomy node.
    func sources(
        in nodeID: CatalogNodeID,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> SourcePage

    /// Full-text search over source titles, hosts, and editorial paths.
    func searchSources(
        text: String,
        filters: CatalogSearchFilters,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> SourcePage

    /// Load full details for a single source.
    func sourceDetails(id: SourceID) async throws -> SourceDetails?
}

// MARK: - Catalog Compiling

/// Transforms OPML files + folder structure into a versioned SQLite catalog.
/// Runs offline (at build time or on first launch after OPML update).
/// Produces a staging candidate — publication is atomic and separate.
protocol CatalogCompiling: Sendable {
    /// Full rebuild from the complete OPML corpus.
    func compileFull() async throws -> CatalogCompileReport

    /// Incremental update from changed OPML files.
    func compileIncremental(
        changes: [CatalogFileChange]
    ) async throws -> CatalogCompileReport
}

// MARK: - Supporting Types

/// Search filters applied to catalog source search.
struct CatalogSearchFilters: Sendable {
    let kind: CatalogNodeKind?
    let language: String?
    let region: String?

    init(kind: CatalogNodeKind? = nil, language: String? = nil, region: String? = nil) {
        self.kind = kind
        self.language = language
        self.region = region
    }
}

/// A changed OPML file for incremental compilation.
struct CatalogFileChange: Sendable {
    let relativePath: String
    let change: FileChangeKind

    enum FileChangeKind: Sendable {
        case added
        case modified
        case deleted
    }
}

/// Compilation result report — contains counts and timing for diagnostics.
struct CatalogCompileReport: Sendable {
    enum Mode: Sendable {
        case full
        case incremental
    }

    let mode: Mode
    let catalogVersion: Int64
    let sourceCount: Int
    let nodeCount: Int
    let placementCount: Int
    let aliasCount: Int
    let duplicateOccurrenceCount: Int
    let invalidSourceCount: Int
    let changedFileCount: Int
    let deletedFileCount: Int
    let failedFileCount: Int
    let logicalDigest: String
    let elapsed: TimeInterval
}
