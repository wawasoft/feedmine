import Foundation

// MARK: - Selection Catalog Reading
//
// The interface through which the selection engine queries the catalog.
// During migration, SourceRegistry and TaxonomyStore implement this via adapters.
// After migration, FeedEngine becomes the canonical implementation.

/// Protocol for reading source metadata needed by the selection engine.
protocol SelectionCatalogReading: Sendable {
    /// Resolve a source scope specification into a concrete scope.
    func resolveSourceScope(
        _ specification: SourceScopeSpecification
    ) async throws -> ResolvedSourceScope

    /// Fetch metadata for a specific set of sources.
    func sourceMetadata(
        for ids: some Collection<SourceID>
    ) async throws -> [SourceSelectionMetadata]

    /// Look up a SourceID from a legacy normalized URL.
    /// Returns nil if the URL is not in the catalog.
    func sourceID(for normalizedURL: String) async throws -> SourceID?

    /// Look up a SourceKey from a SourceID.
    func sourceKey(for id: SourceID) async throws -> SourceKey?
}

// MARK: - Legacy URL Bridge

/// Transient bridge between legacy normalized URLs and catalog identities.
/// Only exists during migration. Not a permanent identity.
struct LegacySourceURL: Hashable, Sendable {
    let normalizedValue: String

    init(_ rawURL: String) {
        normalizedValue = OPMLParser.normalizeURL(rawURL)
    }

    /// Resolve to the canonical catalog identity.
    func resolve(in catalog: some SelectionCatalogReading) async throws -> SourceID? {
        try await catalog.sourceID(for: normalizedValue)
    }
}
