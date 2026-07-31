import Foundation

// MARK: - Source Registry Catalog Adapter
//
// Bridges SourceRegistry into the SelectionCatalogReading protocol.
// SourceRegistry is @MainActor — all accesses are awaited from this
// non-isolated adapter. After migration, FeedEngine becomes the
// canonical implementation.

/// Adapts SourceRegistry to conform to SelectionCatalogReading.
/// Uses await for all @MainActor SourceRegistry accesses.
final class SourceRegistryCatalogAdapter: SelectionCatalogReading {
    private let registry: SourceRegistry

    init(registry: SourceRegistry) {
        self.registry = registry
    }

    func resolveSourceScope(
        _ specification: SourceScopeSpecification
    ) async throws -> ResolvedSourceScope {
        // 4.3: .expandedCatalogRespectingExplicitOff uses ALL sources
        // (bypassing inherited disables), not just enabledSources.
        // The resolver applies explicit-off filtering downstream.
        let allSources = await registry.sources
        let enabledSources = await registry.enabledSources
        let sources: [FeedSource]
        switch specification.policy {
        case .expandedCatalogRespectingExplicitOff:
            sources = allSources  // full catalog — resolver handles explicit off
        default:
            sources = enabledSources  // user's library
        }
        var filtered = sources

        // Filter by content type
        if !specification.contentTypes.isEmpty {
            filtered = filtered.filter { source in
                specification.contentTypes.contains(where: { $0.matches(source) })
            }
        }

        // Filter by language
        if !specification.languages.isEmpty {
            filtered = filtered.filter { source in
                guard let lang = source.language else { return true }
                return specification.languages.contains(lang)
            }
        }

        // Filter by region
        if !specification.regions.isEmpty {
            filtered = filtered.filter { source in
                specification.regions.contains(source.region)
                    || specification.regions.contains(where: { source.region.hasPrefix($0 + "/") })
            }
        }

        // Convert to SourceIDs
        let enabledIDs: Set<SourceID> = Set(filtered.compactMap { sourceID(for: $0.url) })

        // Build preview metadata
        var metadata: [SourceSelectionMetadata] = []
        for source in filtered.prefix(100) {
            guard let sid = sourceID(for: source.url) else { continue }
            let isEnabled = await registry.isSourceEnabled(source.url)
            let isDisabled = await registry.isSourceExplicitlyDisabled(source.url)
            metadata.append(SourceSelectionMetadata(
                sourceID: sid,
                isEnabled: isEnabled,
                isExplicitlyDisabled: isDisabled,
                providerName: source.title,
                countryCode: nil,
                regionCode: nil,
                contentType: source.contentTypeStr.flatMap { ContentType(rawValue: $0) }
            ))
        }

        let handle: SourceScopeHandle
        if enabledIDs.count <= 500 {
            handle = .materialized(enabledIDs)
        } else {
            handle = .catalogQuery(CatalogSourceQuery(
                taxonomyNodeIDs: specification.taxonomyNodeIDs,
                contentTypes: specification.contentTypes,
                languages: specification.languages,
                regions: specification.regions,
                respectInheritedDisables: specification.policy != .expandedCatalogRespectingExplicitOff,
                pageSize: CatalogSourceQuery.defaultPageSize
            ))
        }

        return ResolvedSourceScope(handle: handle, totalCount: enabledIDs.count, previewMetadata: metadata)
    }

    func sourceMetadata(
        for ids: some Collection<SourceID>
    ) async throws -> [SourceSelectionMetadata] {
        let allSources = await registry.enabledSources
        var result: [SourceSelectionMetadata] = []

        for id in ids {
            guard let source = allSources.first(where: { sourceID(for: $0.url) == id }) else {
                continue
            }
            let isEnabled = await registry.isSourceEnabled(source.url)
            let isDisabled = await registry.isSourceExplicitlyDisabled(source.url)
            result.append(SourceSelectionMetadata(
                sourceID: id,
                isEnabled: isEnabled,
                isExplicitlyDisabled: isDisabled,
                providerName: source.title,
                countryCode: nil,
                regionCode: nil,
                contentType: source.contentTypeStr.flatMap { ContentType(rawValue: $0) }
            ))
        }

        return result
    }

    func sourceID(for normalizedURL: String) -> SourceID? {
        CatalogIdentity.sourceID(for: CatalogIdentity.sourceKey(for: normalizedURL))
    }

    func sourceKey(for id: SourceID) -> SourceKey? {
        CatalogIdentity.sourceKey(for: String(id.rawValue))
    }
}

// MARK: - ContentType matching helper

private extension ContentType {
    func matches(_ source: FeedSource) -> Bool {
        switch self {
        case .video: return source.mediaKind == .video
        case .audio: return source.mediaKind == .audio
        case .text:  return source.mediaKind == .text
        default: return true
        }
    }
}

// MARK: - FeedSource helpers

private extension FeedSource {
    var contentTypeStr: String? {
        switch mediaKind {
        case .video: return "Video"
        case .audio: return "Audio"
        case .text:  return "Text"
        default: return nil
        }
    }
}
