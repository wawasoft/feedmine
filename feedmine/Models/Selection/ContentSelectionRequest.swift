import Foundation

// MARK: - Content Selection Request
//
// The immutable description of what a surface wants to display.
// One request → one ResolvedSelectionPlan → one FeedSnapshot.

/// Identifies which UI surface is making the request.
/// Extends FeedPresentationMode with the missing cases.
enum SelectionSurface: Hashable, Sendable {
    case main
    case source(SourceID)
    case collection(Int64)
    case smartFeed(Int64)
    case bookmarks(Int64?)
    case lastClicked
    case search(SearchExpression)
    case onboardingComparison
    case curatedPreview
    case whatsNew
}

/// Policy that defines which sources can contribute to this selection.
enum SourceUniversePolicy: Hashable, Sendable {
    /// Normally-enabled sources (user defaults + explicit toggles).
    case enabledLibrary
    /// Full catalog, ignoring inherited disables but respecting explicit off.
    case expandedCatalogRespectingExplicitOff
    /// Fixed allowlist (collection members).
    case explicitAllowlist(Set<SourceID>)
    /// Single source inspection.
    case single(SourceID)
    /// Fixed snapshot (bookmarks, Last Clicked).
    case fixedSnapshot(Set<SourceID>)
}

/// Criteria that items must satisfy to be eligible.
struct ItemCriteria: Hashable, Sendable {
    var regions: Set<String> = []
    var taxonomyNodeIDs: Set<String> = []
    var languages: Set<String> = []
    var contentTypes: Set<ContentType> = []
    var mood: MoodFilter = .all
    var searchExpression: SearchExpression?
    var excludedKeywords: Set<String> = []
    /// User-defined content filter keywords (from ContentFilterStore).
    var contentFilterKeywords: Set<String> = []

    /// Empty criteria — no restrictions.
    static let none = ItemCriteria()
}

/// Defines how previously-seen items are treated.
struct HistoryPolicy: Hashable, Sendable {
    var includeRead: Bool = false
    var includeConsumed: Bool = false
    var includeBookmarked: Bool = false
    /// Exclude items already loaded in this session (the current loadedIDs set).
    var excludeAlreadyLoaded: Bool = true
    /// Exclude items already surfaced to the user.
    var excludeSurfaced: Bool = false
    var dateRange: ClosedRange<Date>?

    /// Show everything — used for Source View.
    static let includeAll = HistoryPolicy(
        includeRead: true, includeConsumed: true, includeBookmarked: true,
        excludeAlreadyLoaded: false, excludeSurfaced: false, dateRange: nil
    )

    /// Default feed: exclude read/consumed, last 30 days.
    static let defaultFeed = HistoryPolicy(
        includeRead: false, includeConsumed: false, includeBookmarked: false,
        excludeAlreadyLoaded: true, excludeSurfaced: false,
        dateRange: Calendar.current.date(byAdding: .day, value: -30, to: Date())!...Date()
    )
}

/// Signals that influence item ordering.
enum RankingSignal: Hashable, Sendable {
    case freshness(weight: Double)
    case sourceQuality(weight: Double)
    case editorialPreset(PresetSelector)
    case curatedProfile(CuratedProfileDefinition)
    case sourceAffinity([SourceID: Double])
    case imageAvailability(weight: Double)
    case mediaPreference(ContentType, weight: Double)
    case topicPreference(CuratedTopic, weight: Double)
    case nature(String, weight: Double)
    case activity(String, weight: Double)
}

/// Collection of ranking signals for a request.
struct RankingProfile: Hashable, Sendable {
    var signals: [RankingSignal] = []

    static let none = RankingProfile()
}

/// Quota targets for mix diversity.
enum MixQuota: Hashable, Sendable {
    case media(ContentType, target: ClosedRange<Double>)
    case topic(CuratedTopic, target: ClosedRange<Double>)
    case illustrated(target: ClosedRange<Double>)
    case region(String, target: ClosedRange<Double>)
}

/// Defines diversity and composition targets for the output.
struct MixPolicy: Hashable, Sendable {
    var quotas: [MixQuota] = []
    var providerCooldown: Int = 2
    var categoryCooldown: Int = 2
    var regionCooldown: Int = 3
    var mediaCooldown: Int = 2
    var discoveryShare: Double = 0.15

    static let defaultFeed = MixPolicy()
}

/// How content is acquired for this selection.
enum AcquisitionPolicy: Hashable, Sendable {
    /// Cache first, then network for remaining slots.
    case cacheThenNetwork
    /// Cache only (bookmarks, Last Clicked).
    case cacheOnly
    /// Refresh all exact sources (Source View).
    case refreshExactSources
    /// Cache followed by optional exhaustive remote sweep (search).
    case cacheThenSweep
}

/// How cards should be presented.
struct PresentationPolicy: Hashable, Sendable {
    var initialPageSize: Int = 20
    var loadMorePageSize: Int = 20
    var requireTerminalPresentation: Bool = true

    static let defaultFeed = PresentationPolicy()
    static let compactCarousel = PresentationPolicy(initialPageSize: 10, loadMorePageSize: 10)
    static let sourceView = PresentationPolicy(initialPageSize: 20, loadMorePageSize: 20)
}

/// When a selection is considered "ready enough" to show.
struct CompletionPolicy: Hashable, Sendable {
    var minimumCardCount: Int = 20
    var preferredCardCount: Int = 60
    var minimumDistinctSources: Int = 5
    var minimumDistinctProviders: Int = 3
    var maximumWait: Duration = .seconds(4)
    var allowPartialAfterDeadline: Bool = true

    static let mainFeedColdStart = CompletionPolicy(
        minimumCardCount: 20, minimumDistinctSources: 10,
        minimumDistinctProviders: 8, maximumWait: .seconds(4)
    )
    static let mainFeedWarm = CompletionPolicy(
        minimumCardCount: 20, minimumDistinctSources: 5,
        minimumDistinctProviders: 3, maximumWait: .seconds(2)
    )
    static let sourceView = CompletionPolicy(
        minimumCardCount: 1, minimumDistinctSources: 1,
        minimumDistinctProviders: 1, maximumWait: .seconds(5)
    )
    static let bookmarks = CompletionPolicy(
        minimumCardCount: 1, minimumDistinctSources: 0,
        minimumDistinctProviders: 0, maximumWait: .zero,
        allowPartialAfterDeadline: true
    )
}

// MARK: - Content Selection Request

/// The immutable description of what a surface wants to display.
/// This is intent — the compiler turns it into an executable ResolvedSelectionPlan.
struct ContentSelectionRequest: Hashable, Sendable {
    let id: SelectionID
    let surface: SelectionSurface
    let sourceUniverse: SourceUniversePolicy
    let criteria: ItemCriteria
    let ranking: RankingProfile
    let mix: MixPolicy
    let history: HistoryPolicy
    let acquisition: AcquisitionPolicy
    let presentation: PresentationPolicy
    let completion: CompletionPolicy
}

// MARK: - Type aliases for referenced types
// These reference existing Feedmine types. When those types move to Models/,
// these aliases become unnecessary.

typealias ContentType = FeedLoader.ContentType
typealias MoodFilter = FeedLoader.MoodFilter
