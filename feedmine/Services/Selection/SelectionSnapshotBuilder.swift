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

        // Cache disabled keys once — read from UserDefaults ground truth
        let disabledKeys = registry.allDisabledKeys
        let overrideKeys = registry.allEnabledOverrideKeys

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
            let sourceKey = SourceRegistry.sourceKey(OPMLParser.normalizeURL(source.url))
            let isExplicitOff = disabledKeys.contains(sourceKey)
            let isEnabled = registry.isSourceEnabled(source.url)

            if isExplicitOff {
                // Already in explicitlyDisabled, skip further classification
                continue
            }

            // Check override
            if overrideKeys.contains(sourceKey) {
                explicitlyEnabled.insert(sid)
            }

            // Default-enabled sources
            if source.defaultEnabled {
                defaultEnabled.insert(sid)
            }

            // If source is not enabled but not explicitly off, it's disabled
            // by region or category cascade. Find which one (O(1) checks).
            if !isEnabled {
                // Check region cascade using cached disabled keys
                let regionKey = SourceRegistry.regionKey(source.region)
                if disabledKeys.contains(regionKey) {
                    regionDisabled.insert(sid)
                }
                // Check parent country
                if source.region.hasPrefix("countries/") {
                    let parts = source.region.split(separator: "/")
                    if parts.count >= 2 {
                        let countryKey = SourceRegistry.regionKey("countries/\(parts[1])")
                        if disabledKeys.contains(countryKey) {
                            regionDisabled.insert(sid)
                        }
                    }
                }

                // Check category cascade
                let categoryKey = SourceRegistry.categoryKey(source.category)
                if disabledKeys.contains(categoryKey) {
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

// MARK: - SourceRegistry extension for O(1) enablement classification
//
/// Reads disabled/enabled-override state from UserDefaults (ground truth
/// that SourceRegistry.saveState() writes to). This avoids the O(n²)
/// sources.filter() pattern used in the old heuristic methods.

extension SourceRegistry {

    /// The full disabled set (url:, region:, cat: keys).
    var allDisabledKeys: Set<String> {
        let stored: [String: Bool] = UserDefaults.standard.dictionary(forKey: Keys.toggleDisabled)
            as? [String: Bool] ?? [:]
        return Set(stored.keys)
    }

    /// The enabled overrides set (url: keys only).
    var allEnabledOverrideKeys: Set<String> {
        let stored: [String: Bool] = UserDefaults.standard.dictionary(forKey: Keys.toggleEnabledOverrides)
            as? [String: Bool] ?? [:]
        return Set(stored.keys)
    }
}
