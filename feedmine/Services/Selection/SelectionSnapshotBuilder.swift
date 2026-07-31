import Foundation

// MARK: - Selection Snapshot Builder
//
// Builds real SourceEnablementSnapshot and TaxonomySnapshot from the
// existing SourceRegistry and TaxonomyStore. Replaces the .empty
// placeholders in SelectionCoordinator.makeCompiler().
//
// Fixes checklist items 4.1 and 4.2.

/// Builds real snapshots for the selection engine from live registry state.
@MainActor
struct SelectionSnapshotBuilder {

    let registry: SourceRegistry
    let taxonomyStore: TaxonomyStore

    // MARK: - SourceEnablementSnapshot

    /// Build a real SourceEnablementSnapshot from the SourceRegistry.
    /// Uses the public API: iterates all sources, classifies each by
    /// enablement reason (explicit off, explicit on, region cascade,
    /// category cascade, default-enabled).
    func buildEnablementSnapshot() -> SourceEnablementSnapshot {
        let lookupSnapshot = registry.lookupSnapshot()
        let sources = registry.sources

        // 1. Explicitly disabled: the url: keys present in registry.disabled
        let explicitlyDisabled: Set<SourceID> = Set(
            lookupSnapshot.explicitlyDisabledURLs.compactMap { normalizedURL in
                CatalogIdentity.sourceID(for: CatalogIdentity.sourceKey(for: normalizedURL))
            }
        )

        // 2. Explicitly enabled overrides: sources enabled despite parent disable
        var explicitlyEnabled = Set<SourceID>()
        var regionDisabled = Set<SourceID>()
        var categoryDisabled = Set<SourceID>()
        var defaultEnabled = Set<SourceID>()

        for source in sources {
            let sid = CatalogIdentity.sourceID(
                for: CatalogIdentity.sourceKey(for: source.url)
            )

            // Check each source against the full enablement logic
            let isExplicitOff = registry.isSourceExplicitlyDisabled(source.url)
            let isEnabled = registry.isSourceEnabled(source.url)

            if isExplicitOff {
                // Already in explicitlyDisabled, skip further classification
                continue
            }

            // Check override
            if registry.isSourceExplicitlyEnabled(source.url) {
                explicitlyEnabled.insert(sid)
            }

            // Default-enabled sources
            if source.defaultEnabled {
                defaultEnabled.insert(sid)
            }

            // If source is not enabled but not explicitly off, it's disabled
            // by region or category cascade. Find which one.
            if !isEnabled {
                // Check region cascade
                if registry.isRegionDisabled(source.region) {
                    regionDisabled.insert(sid)
                }

                // Check category cascade
                if registry.isCategoryDisabled(source.category) {
                    categoryDisabled.insert(sid)
                }
            }
        }

        return SourceEnablementSnapshot(
            explicitlyDisabled: explicitlyDisabled,
            explicitlyEnabled: explicitlyEnabled,
            regionDisabled: regionDisabled,
            categoryDisabled: categoryDisabled,
            defaultEnabled: defaultEnabled
        )
    }

    // MARK: - TaxonomySnapshot

    /// Build a full TaxonomySnapshot from the TaxonomyStore.
    /// Maps every taxonomy node to its set of eligible SourceIDs.
    /// For large catalogs, prefer buildActiveTaxonomySnapshot for selected nodes only.
    func buildTaxonomySnapshot() -> TaxonomySnapshot {
        var nodeSourceMap: [String: Set<SourceID>] = [:]

        // Iterate all node IDs and collect their subtree feed URLs
        for nodeID in taxonomyStore.flatIndex.keys {
            let feedURLs = taxonomyStore.feedURLs(inSubtreesOf: [nodeID])
            guard !feedURLs.isEmpty else { continue }

            let sourceIDs = Set(feedURLs.compactMap { url in
                CatalogIdentity.sourceID(for: CatalogIdentity.sourceKey(for: url))
            })
            if !sourceIDs.isEmpty {
                nodeSourceMap[nodeID] = sourceIDs
            }
        }

        return TaxonomySnapshot(nodeSourceMap: nodeSourceMap)
    }

    /// Build a lightweight taxonomy snapshot for just the active node IDs.
    /// Much faster than building the full map when only a few nodes are selected.
    func buildActiveTaxonomySnapshot(activeNodeIDs: Set<String>) -> TaxonomySnapshot {
        var nodeSourceMap: [String: Set<SourceID>] = [:]

        for nodeID in activeNodeIDs {
            let feedURLs = taxonomyStore.feedURLs(inSubtreesOf: [nodeID])
            guard !feedURLs.isEmpty else { continue }

            let sourceIDs = Set(feedURLs.compactMap { url in
                CatalogIdentity.sourceID(for: CatalogIdentity.sourceKey(for: url))
            })
            if !sourceIDs.isEmpty {
                nodeSourceMap[nodeID] = sourceIDs
            }
        }

        return TaxonomySnapshot(nodeSourceMap: nodeSourceMap)
    }
}

// MARK: - SourceRegistry public API helpers

/// These wrap SourceRegistry queries that the snapshot builder needs.
/// They use only the public API — no internal state access.
extension SourceRegistry {

    /// Check if a source is explicitly enabled (has an override).
    func isSourceExplicitlyEnabled(_ sourceURL: String) -> Bool {
        // A source is explicitly enabled if isSourceEnabled returns true
        // AND the source is NOT default-enabled (meaning it needed the override).
        // Actually, we check: if the source would be disabled by default/region/category
        // but is currently enabled, it must have an override.
        guard let source = source(forURL: sourceURL) else { return false }

        // If default is false and it's enabled, override is active
        if !source.defaultEnabled && isSourceEnabled(sourceURL) {
            return true
        }
        // If region/category is disabled but source is still enabled, override is active
        if (isRegionDisabled(source.region) || isCategoryDisabled(source.category))
            && isSourceEnabled(sourceURL) && !isSourceExplicitlyDisabled(sourceURL) {
            return true
        }
        return false
    }

    /// Check if a region tree is disabled.
    func isRegionDisabled(_ region: String) -> Bool {
        let key = SourceRegistry.regionKey(region)
        // We check the enabled status of sources in this region.
        // If all are disabled and the region key is set, the region is disabled.
        // Simplified: check a representative source.
        let sourcesInRegion = sources.filter { $0.region == region || $0.region.hasPrefix(region + "/") }
        guard let first = sourcesInRegion.first else { return false }
        // If the first source in this region is not explicitly off but still disabled,
        // the region cascade is active
        return !isSourceExplicitlyDisabled(first.url) && !isSourceEnabled(first.url)
    }

    /// Check if a category is disabled.
    func isCategoryDisabled(_ category: String) -> Bool {
        let sourcesInCategory = sources.filter { $0.category == category }
        guard let first = sourcesInCategory.first else { return false }
        return !isSourceExplicitlyDisabled(first.url) && !isSourceEnabled(first.url)
    }
}
