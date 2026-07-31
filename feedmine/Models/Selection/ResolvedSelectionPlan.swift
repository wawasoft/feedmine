import Foundation

// MARK: - Resolved Selection Plan
//
// The compiler transforms a ContentSelectionRequest (intent) into a
// ResolvedSelectionPlan (executable). The plan is immutable and can be
// shared across sessions that have the same source scope.

// MARK: - Source Scope

/// Specification for resolving which sources are in scope.
/// Deliberately abstract — the compiler decides how to materialize it.
struct SourceScopeSpecification: Hashable, Sendable {
    let policy: SourceUniversePolicy
    let taxonomyNodeIDs: Set<String>
    let contentTypes: Set<ContentType>
    let languages: Set<String>
    let regions: Set<String>
}

/// The resolved set of eligible sources.
enum SourceScopeHandle: Hashable, Sendable {
    /// Fully materialized set (small scopes, up to ~500 sources).
    case materialized(Set<SourceID>)
    /// Query for large catalogs — paginated access.
    case catalogQuery(CatalogSourceQuery)
    /// Explicit ordered list (collection, bookmarks).
    case explicitList([SourceID])
    /// Single source inspection.
    case single(SourceID)
}

/// Query specification for paginated catalog access.
struct CatalogSourceQuery: Hashable, Sendable {
    let taxonomyNodeIDs: Set<String>
    let contentTypes: Set<ContentType>
    let languages: Set<String>
    let regions: Set<String>
    /// Whether to respect inherited disables or only explicit off.
    let respectInheritedDisables: Bool
    let pageSize: Int

    static let defaultPageSize = 100
}

/// Requirements for source metadata in a selection.
struct SourceSelectionMetadata: Hashable, Sendable {
    let sourceID: SourceID
    let isEnabled: Bool
    let isExplicitlyDisabled: Bool
    let providerName: String?
    let countryCode: String?
    let regionCode: String?
    let contentType: ContentType?
}

// MARK: - Compiled Plans

/// Compiled ranking plan — the sequence of scoring operations.
struct CompiledRankingPlan: Hashable, Sendable {
    /// Ordered list of scoring operations to apply.
    let operations: [RankingOperation]

    /// Whether the plan is a no-op (pass-through).
    var isIdentity: Bool { operations.isEmpty }
}

/// A single ranking operation in the compiled plan.
enum RankingOperation: Hashable, Sendable {
    case freshness(weight: Double)
    case sourceQuality(weight: Double)
    case presetMultiplier([SourceID: Double])
    case curatedProfileMultiplier([SourceID: Double])
    case imageAvailability(weight: Double)
    case mediaPreference(ContentType, weight: Double)
}

/// Compiled mix plan — the diversity and allocation strategy.
struct CompiledMixPlan: Hashable, Sendable {
    let quotas: [MixQuota]
    let providerCooldown: Int
    let categoryCooldown: Int
    let regionCooldown: Int
    let mediaCooldown: Int
    let discoveryShare: Double
    let maxItemsPerSource: Int

    static let defaultPlan = CompiledMixPlan(
        quotas: [],
        providerCooldown: 2,
        categoryCooldown: 2,
        regionCooldown: 3,
        mediaCooldown: 2,
        discoveryShare: 0.15,
        maxItemsPerSource: 5
    )
}

// MARK: - Cache Query

/// Specification for querying the local cache.
/// The executor recompiles the SQL fresh from the rule digest at execution time.
/// This avoids the binding serialization problem (5.6) — StatementArguments
/// values can't be stored in a Hashable struct.
struct CacheQuerySpecification: Hashable, Sendable {
    /// Digest of the ItemRuleSet. The executor uses this to validate
    /// that the rules haven't changed since plan compilation.
    let ruleDigest: UInt64
    /// Maximum number of items to return.
    let limit: Int
    /// Offset for pagination.
    let offset: Int
    /// Sort order for results.
    let orderBy: CacheQueryOrder
}

enum CacheQueryOrder: Hashable, Sendable {
    case fetchedAtDescending
    case clickedAtDescending
    case relevance
}

// MARK: - Acquisition Plan

/// Resolved plan for what needs to be fetched from the network.
struct ResolvedAcquisitionPlan: Hashable, Sendable {
    /// The source scope to fetch from.
    let sourceScope: SourceScopeHandle
    /// How many sources to schedule per batch.
    let batchSize: Int
    /// Maximum concurrent fetches.
    let maxConcurrency: Int
    /// Whether to use the adaptive scheduler.
    let useAdaptiveScheduling: Bool

    static func forCacheOnly() -> ResolvedAcquisitionPlan {
        ResolvedAcquisitionPlan(
            sourceScope: .materialized([]),
            batchSize: 0, maxConcurrency: 0, useAdaptiveScheduling: false
        )
    }
}

// MARK: - Presentation Plan

/// Resolved plan for card preparation.
struct ResolvedPresentationPlan: Hashable, Sendable {
    let initialPageSize: Int
    let loadMorePageSize: Int
    let requireTerminalPresentation: Bool
    let deadlineHierarchy: PresentationDeadlineHierarchy

    static let defaultPlan = ResolvedPresentationPlan(
        initialPageSize: 20,
        loadMorePageSize: 20,
        requireTerminalPresentation: true,
        deadlineHierarchy: .standard
    )
}

/// Deadlines for card preparation phases.
struct PresentationDeadlineHierarchy: Hashable, Sendable {
    let firstPaint: Duration
    let runway: Duration
    let deep: Duration

    static let standard = PresentationDeadlineHierarchy(
        firstPaint: .seconds(6),
        runway: .seconds(15),
        deep: .seconds(30)
    )
}

// MARK: - Resolved Selection Plan

/// The executable plan produced by SelectionCompiler from a ContentSelectionRequest.
/// Immutable and shareable across sessions that share the same scope.
struct ResolvedSelectionPlan: Hashable, Sendable {
    /// Which selection this plan is for.
    let selectionID: SelectionID

    /// The resolved source scope.
    let sourceScope: ResolvedSourceScope
    /// Source-side metrics.
    let sourceMetrics: SourceSelectionMetrics

    /// Rules for item eligibility.
    let itemRules: ItemRuleSet
    /// Compiled cache query.
    let cacheQuery: CacheQuerySpecification

    /// Compiled ranking plan.
    let rankingPlan: CompiledRankingPlan
    /// Compiled mix plan.
    let mixPlan: CompiledMixPlan

    /// How to acquire content.
    let acquisitionPlan: ResolvedAcquisitionPlan
    /// How to prepare cards.
    let presentationPlan: ResolvedPresentationPlan

    /// When the selection is considered complete.
    let completionPolicy: CompletionPolicy
}

// MARK: - Resolved Source Scope

/// The fully-resolved source scope for a selection.
struct ResolvedSourceScope: Hashable, Sendable {
    /// How the source IDs are represented (materialized, query, or explicit).
    let handle: SourceScopeHandle
    /// Total count of sources in scope.
    let totalCount: Int
    /// Metadata for on-screen sources (first page).
    let previewMetadata: [SourceSelectionMetadata]
}

// MARK: - Fetch Target

/// A specific source to fetch, with its priority and scheduling info.
struct FetchTarget: Hashable, Sendable {
    let sourceID: SourceID
    let requestURL: URL
    let priority: FetchPriority
    let deadline: Duration?

    enum FetchPriority: Int, Hashable, Sendable, Comparable {
        case urgent = 0
        case high = 1
        case normal = 2
        case low = 3

        static func < (lhs: FetchPriority, rhs: FetchPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}
