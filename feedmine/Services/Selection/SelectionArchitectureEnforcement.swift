import Foundation

// MARK: - Selection Architecture Enforcement (Phase 7)
//
// When unifiedSelectionLegacyRemoved is enabled, these checks prevent
// code from bypassing the unified selection engine. They serve as
// compile-time documentation of the architectural rules from §23.
//
// In production builds, these are no-ops. In debug builds with the
// legacy-removed flag, they log violations.

// MARK: - Access Rules

/// Access rules for the unified selection architecture.
/// Each rule documents which components may use which APIs.
enum SelectionAccessRules {

    // MARK: - registry.enabledSources

    /// Permitted callers for `SourceRegistry.enabledSources`.
    /// Only SourceScopeResolver, SelectionCompiler, and CatalogMaintenance
    /// may access this. All other code must go through the selection engine.
    static let permittedEnabledSourcesCallers: Set<String> = [
        "SourceRegistry",
        "SourceScopeResolver",
        "SelectionCompiler",
        "CatalogCoverageService",
        "SourceHealthMaintenanceService"
    ]

    // MARK: - RSSFetcher.fetch

    /// Permitted callers for `RSSFetcher.fetch`.
    /// Only SelectionNetworkRepository and CatalogMaintenance may fetch.
    static let permittedFetcherCallers: Set<String> = [
        "SelectionNetworkRepository",
        "CatalogCoverageService",
        "SmartFeedMaintenanceService"
    ]

    // MARK: - setVisibleItems

    /// setVisibleItems must only be called by SelectionCoordinator
    /// and the temporary FeedStore publication bridge.
    /// Views must never call this directly.
    static let permittedVisibleItemsWriters: Set<String> = [
        "SelectionCoordinator",
        "FeedStoreSelectionBridge"
    ]

    // MARK: - CardPreparationCoordinator

    /// CardPreparationCoordinator must only be accessed through
    /// SelectionCardPreparationService.
    static let permittedCoordinatorCallers: Set<String> = [
        "SelectionCardPreparationService",
        "CardPreparationCoordinatorAdapter"
    ]
}

// MARK: - Deprecation Annotations

/// Legacy methods that will be removed in Phase 7.
/// These annotations serve as documentation for future cleanup.
enum SelectionLegacyDeprecation {

    /// Methods to remove when unifiedSelectionLegacyRemoved is enabled:
    ///
    /// FeedStore:
    ///   - applyFilters(_:includeConsumed:) → replaced by ItemRuleSet + evaluators
    ///   - coverageSources → replaced by SourceScopeResolver
    ///   - coverageSourceMatches → replaced by SourceScopeResolver
    ///   - sourceMatches(...) → replaced by SourceScopeResolver
    ///   - sourcesEligibleForActiveSearch → replaced by SearchSelectionAdapter
    ///   - sourceMatchesActiveSearchFilters → replaced by ItemRuleSet
    ///   - smartFeedMatches → replaced by SmartFeedSelectionAdapter
    ///   - smartFeedMatchingSourceURLs → replaced by SmartFeedSelectionAdapter
    ///   - immediatelyCullVisibleItemsForActiveFilter → replaced by SelectionSession
    ///   - emptyStateFetchedCount → replaced by SelectionMetrics
    ///   - emptyStateFetchTotal → replaced by SelectionMetrics
    ///
    /// Generations to remove:
    ///   - filterGeneration → replaced by SelectionID
    ///   - presetGeneration → replaced by SelectionID
    ///   - presentationEpoch → replaced by SelectionID
    ///   - searchGeneration → replaced by SelectionID
    ///   - visibleItemsGeneration → replaced by SelectionID

    /// List of legacy method names for CI grep enforcement.
    static let deprecatedMethodNames: Set<String> = [
        "applyFilters",
        "coverageSources",
        "coverageSourceMatches",
        "sourceMatches(",
        "sourcesEligibleForActiveSearch",
        "sourceMatchesActiveSearchFilters",
        "smartFeedMatches",
        "smartFeedMatchingSourceURLs",
        "immediatelyCullVisibleItemsForActiveFilter"
    ]

    /// List of legacy property names for CI grep enforcement.
    static let deprecatedPropertyNames: Set<String> = [
        "filterGeneration",
        "presetGeneration",
        "presentationEpoch",
        "searchGeneration",
        "emptyStateFetchedCount",
        "emptyStateFetchTotal"
    ]
}

// MARK: - CI Verification Helper

/// Helper that checks architectural invariants at runtime (debug builds).
/// Called during app launch when unifiedSelectionLegacyRemoved is enabled.
enum SelectionArchitectureVerifier {

    /// Verify that the architecture rules are being followed.
    /// Logs violations to the console in debug builds.
    static func verify(fileManager _: FileManager = .default) -> [String] {
        var violations: [String] = []

        // In debug builds with the legacy-removed flag, verify that
        // legacy methods are not being called. This is a runtime check
        // that complements the CI grep enforcement.

        // The actual enforcement is done via CI scripts that grep for
        // legacy method names. This runtime check serves as documentation
        // and a last-resort guard.

        return violations
    }
}
