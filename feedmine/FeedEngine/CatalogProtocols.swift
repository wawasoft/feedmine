import Foundation

// MARK: - FeedEngine Stage 1 Protocols
//
// This boundary is intentionally small: UI asks for bounded pages, identities
// are numeric, details are loaded on demand, and implementation can coexist
// beside the legacy FeedStore path.

// MARK: - Facade

protocol FeedEngineProtocol: Sendable {
    func browseCatalog(
        query: CatalogBrowseQuery,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> CatalogPage

    func searchCatalog(
        query: CatalogSearchQuery,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> CatalogPage

    func loadSourceDetails(
        sourceID: SourceID
    ) async throws -> SourceDetails

    func loadTimeline(
        query: ContentQuery,
        cursor: TimelineCursor?,
        limit: Int
    ) async throws -> TimelinePage
}

// MARK: - Catalog

/// Paginated, read-only access to the compiled catalog.
/// All queries are SQLite-backed, returning bounded pages.
protocol CatalogRepository: Sendable {
    func browseCatalog(
        query: CatalogBrowseQuery,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> CatalogPage

    func loadSourceDetails(
        sourceID: SourceID
    ) async throws -> SourceDetails
}

/// Full-text catalog search backed by SQLite FTS5.
protocol CatalogSearch: Sendable {
    func searchCatalog(
        query: CatalogSearchQuery,
        cursor: CatalogCursor?,
        limit: Int
    ) async throws -> CatalogPage
}

/// Transforms OPML files + folder structure into a versioned SQLite catalog.
/// Produces a staging candidate; publication is atomic and separate.
protocol CatalogCompiler: Sendable {
    /// Full rebuild from the complete OPML corpus.
    func compileFull() async throws -> CatalogCompileReport

    /// Incremental update from changed OPML files.
    func compileIncremental(
        changes: [CatalogFileChange]
    ) async throws -> CatalogCompileReport
}

// MARK: - Timeline / Content

protocol TimelineRepository: Sendable {
    func loadTimeline(
        query: ContentQuery,
        cursor: TimelineCursor?,
        limit: Int
    ) async throws -> TimelinePage
}

protocol FeedFetcher: Sendable {
    func fetchFeed(
        sourceID: SourceID,
        requestURL: URL
    ) async throws -> Data
}

protocol FeedParsing: Sendable {
    func parseFeed(
        data: Data,
        sourceID: SourceID
    ) async throws -> [ParsedFeedItem]
}

protocol FeedIngestion: Sendable {
    func ingest(
        items: [ParsedFeedItem],
        sourceID: SourceID
    ) async throws -> FeedIngestionReport
}

protocol UserStateRepository: Sendable {
    func loadLastContentQuery() async throws -> (query: ContentQuery, cursor: TimelineCursor?)?
    func saveLastContentQuery(_ query: ContentQuery, cursor: TimelineCursor?) async throws
}

// MARK: - Supporting Types

/// Search filters applied to catalog source search.
struct CatalogSearchFilters: Equatable, Sendable {
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
struct CatalogFileChange: Equatable, Sendable {
    let relativePath: String
    let change: FileChangeKind

    enum FileChangeKind: Equatable, Sendable {
        case added
        case modified
        case deleted
    }
}

/// Compilation result report — contains counts and timing for diagnostics.
struct CatalogCompileReport: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
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

struct ParsedFeedItem: Equatable, Sendable {
    let id: String
    let title: String
    let excerpt: String
    let url: URL
    let publishedAt: Date
    let imageURL: URL?
    let audioURL: URL?
    let language: String?
}

struct FeedIngestionReport: Equatable, Sendable {
    let insertedCount: Int
    let updatedCount: Int
    let duplicateCount: Int
    let rejectedCount: Int
    let elapsed: TimeInterval
}

// Backward-compatible names from the initial FeedEngine sketch.
typealias CatalogReading = CatalogRepository
typealias CatalogCompiling = CatalogCompiler
