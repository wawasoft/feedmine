import Foundation

// MARK: - Source Scope Resolver
//
// The single component authorized to decide which sources are eligible
// for a given selection. Replaces the scattered source-enablement checks
// in FeedStore, FeedLoader, and search paths.

/// Snapshot of source enablement state at resolution time.
struct SourceEnablementSnapshot: Hashable, Sendable {
    /// Sources explicitly disabled by the user.
    let explicitlyDisabled: Set<SourceID>
    /// Sources explicitly enabled by the user (overrides).
    let explicitlyEnabled: Set<SourceID>
    /// Sources disabled by parent region.
    let regionDisabled: Set<SourceID>
    /// Sources disabled by parent category.
    let categoryDisabled: Set<SourceID>
    /// Sources that are default-enabled.
    let defaultEnabled: Set<SourceID>

    static let empty = SourceEnablementSnapshot(
        explicitlyDisabled: [], explicitlyEnabled: [],
        regionDisabled: [], categoryDisabled: [], defaultEnabled: []
    )
}

/// Snapshot of taxonomy state at resolution time.
struct TaxonomySnapshot: Hashable, Sendable {
    /// Source IDs that belong to each taxonomy node.
    let nodeSourceMap: [String: Set<SourceID>]

    static let empty = TaxonomySnapshot(nodeSourceMap: [:])
}

/// Resolves a SourceUniversePolicy + criteria into a concrete ResolvedSourceScope.
/// This is the ONLY component authorized to decide source eligibility.
struct SourceScopeResolver: Sendable {

    /// Resolve the source scope for a request.
    func resolve(
        policy: SourceUniversePolicy,
        criteria: SourceCriteria,
        catalog: some SelectionCatalogReading,
        taxonomy: TaxonomySnapshot,
        userState: SourceEnablementSnapshot
    ) async throws -> ResolvedSourceScope {
        let spec = SourceScopeSpecification(
            policy: policy,
            taxonomyNodeIDs: criteria.taxonomyNodeIDs,
            contentTypes: criteria.contentTypes,
            languages: criteria.languages,
            regions: criteria.regions
        )

        let scope = try await catalog.resolveSourceScope(spec)

        // Apply enablement filtering regardless of scope size.
        // For large catalogs, enablement rules are folded into the query
        // so disabled sources are excluded at the DB level; for small scopes
        // we materialize and filter in-memory.
        if case .catalogQuery(let query) = scope.handle {
            let filteredQuery = CatalogSourceQuery(
                taxonomyNodeIDs: query.taxonomyNodeIDs,
                contentTypes: query.contentTypes,
                languages: query.languages,
                regions: query.regions,
                respectInheritedDisables: true,
                pageSize: query.pageSize
            )
            return ResolvedSourceScope(
                handle: .catalogQuery(filteredQuery),
                totalCount: scope.totalCount,
                previewMetadata: scope.previewMetadata
            )
        }

        // For small scopes, apply enablement filtering and materialize
        let filteredIDs = applyEnablementRules(
            scopeHandle: scope.handle,
            policy: policy,
            userState: userState,
            taxonomy: taxonomy,
            criteria: criteria
        )

        let metadata = Array(filteredIDs.prefix(100))

        return ResolvedSourceScope(
            handle: finalHandle(for: filteredIDs, original: scope.handle),
            totalCount: filteredIDs.count,
            previewMetadata: try await catalog.sourceMetadata(for: metadata)
        )
    }

    // MARK: - Enablement Rules

    private func applyEnablementRules(
        scopeHandle: SourceScopeHandle,
        policy: SourceUniversePolicy,
        userState: SourceEnablementSnapshot,
        taxonomy: TaxonomySnapshot,
        criteria: SourceCriteria
    ) -> Set<SourceID> {
        let allIDs = extractSourceIDs(from: scopeHandle)

        switch policy {
        case .enabledLibrary:
            return allIDs.filter { id in
                isEnabledInLibrary(id, userState: userState)
            }

        case .expandedCatalogRespectingExplicitOff:
            // Bypass inherited disables (region, category) but respect explicit off
            let taxonomyExpandedIDs = taxonomySourceIDs(
                nodeIDs: criteria.taxonomyNodeIDs, taxonomy: taxonomy
            )
            let isExplicitQuery = !criteria.taxonomyNodeIDs.isEmpty
                || !criteria.contentTypes.isEmpty

            return allIDs.filter { id in
                if isExplicitQuery && taxonomyExpandedIDs.contains(id) {
                    // Taxonomy expansion — only explicit off matters
                    return !userState.explicitlyDisabled.contains(id)
                }
                return isEnabledInLibrary(id, userState: userState)
            }

        case .explicitAllowlist(let allowedIDs):
            return allowedIDs

        case .single(let sourceID):
            return [sourceID]

        case .fixedSnapshot(let snapshotIDs):
            return snapshotIDs
        }
    }

    private func isEnabledInLibrary(
        _ id: SourceID,
        userState: SourceEnablementSnapshot
    ) -> Bool {
        // Explicit override takes precedence
        if userState.explicitlyEnabled.contains(id) { return true }
        if userState.explicitlyDisabled.contains(id) { return false }
        // Region/ category disables
        if userState.regionDisabled.contains(id) { return false }
        if userState.categoryDisabled.contains(id) { return false }
        // Default
        return userState.defaultEnabled.contains(id)
    }

    private func taxonomySourceIDs(
        nodeIDs: Set<String>,
        taxonomy: TaxonomySnapshot
    ) -> Set<SourceID> {
        guard !nodeIDs.isEmpty else { return [] }
        return nodeIDs.reduce(into: Set<SourceID>()) { acc, nodeID in
            if let ids = taxonomy.nodeSourceMap[nodeID] {
                acc.formUnion(ids)
            }
        }
    }

    private func extractSourceIDs(from handle: SourceScopeHandle) -> Set<SourceID> {
        switch handle {
        case .materialized(let ids): return ids
        case .explicitList(let ids): return Set(ids)
        case .single(let id): return [id]
        case .catalogQuery: return []  // Will be resolved lazily via the catalog
        }
    }

    private func finalHandle(
        for ids: Set<SourceID>,
        original: SourceScopeHandle
    ) -> SourceScopeHandle {
        if case .catalogQuery = original {
            return .materialized(ids)
        }
        if case .explicitList = original {
            return .explicitList(Array(ids))
        }
        return .materialized(ids)
    }
}

// MARK: - Source Criteria (subset of ItemCriteria for source resolution)

/// The subset of criteria needed for source-level resolution.
struct SourceCriteria: Hashable, Sendable {
    var taxonomyNodeIDs: Set<String> = []
    var contentTypes: Set<ContentType> = []
    var languages: Set<String> = []
    var regions: Set<String> = []

    static let none = SourceCriteria()
}
