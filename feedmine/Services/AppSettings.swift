import Foundation

// MARK: - UserDefaults Key Registry
// Every key used anywhere in the app is defined here.
// Views use @AppStorage(Keys.x) for reactive reads.
// Services use Settings.x for typed get/set.

enum Keys {
    // Filters
    static let filterRegion = "filterRegion"
    static let filterTaxonomyNodes = "filterTaxonomyNodes"
    static let filterContentType = "filterContentType"
    static let filterMood = "filterMood"
    static let filterSetAt = "filterSetAt"
    static let filterAutoExpire = "filterAutoExpire"
    static let filterLanguages = "filterLanguages"
    static let hasInitializedLanguageDefault = "hasInitializedLanguageDefault"

    // Appearance
    static let circadianPaletteOn = "circadianPaletteOn"
    static let paletteFamily = "paletteFamily"
    static let circadianTypographyOn = "circadianTypographyOn"
    static let fontStyle = "fontStyle"
    static let fontSize = "fontSize"
    static let nightMode = "nightMode"

    // Behavior
    static let prefetchImages = "prefetchImages"
    static let showDebugBar = "showDebugBar"
    static let hasSeenOnboarding = "hasSeenOnboarding"
    static let contentFiltersEnabled = "contentFiltersEnabled"

    // Session & Streaks
    static let sessionStreak = "sessionStreak"
    static let sessionMinutesToday = "sessionMinutesToday"
    static let daysWithAppTotal = "daysWithAppTotal"
    static let lastOpenDate = "lastOpenDate"

    // Feed preset
    static let activePreset = "activePreset"

    // Source registry
    static let toggleDisabled = "toggleDisabled"
    static let toggleEnabledOverrides = "toggleEnabledOverrides"
    static let hasInitializedSourceDefaults = "hasInitializedSourceDefaults"

    // What's New
    static let lastWhatsNewSeenAt = "last_whats_new_seen_at"

    // Maintenance
    static let lastHeavyMaintenance = "lastHeavyMaintenance"

    // Audio
    static let lastPodcastItemID = "lastPodcastItemID"
    static let lastPodcastPosition = "lastPodcastPosition"

    // Prepared Feed Pipeline
    static let preparedFeedPipelineEnabled = "preparedFeedPipelineEnabled"

    // Unified Selection Engine — feature flags per migration phase
    static let unifiedSelectionEngine = "unifiedSelectionEngine"       // Master flag (off in production until Phase 3)
    static let unifiedSelectionShadow = "unifiedSelectionShadow"       // Phase 1 — shadow mode
    static let unifiedSelectionState = "unifiedSelectionState"         // Phase 2 — unified state & counters
    static let unifiedSelectionMainFeed = "unifiedSelectionMainFeed"   // Phase 3 — main feed
    static let unifiedSelectionRankingMix = "unifiedSelectionRankingMix" // Phase 4 — ranking & mix
    static let unifiedSelectionOnboarding = "unifiedSelectionOnboarding" // Phase 5 — onboarding
    static let unifiedSelectionSurfaces = "unifiedSelectionSurfaces"   // Phase 6A — fixed scopes
    static let unifiedSelectionSearchSmart = "unifiedSelectionSearchSmart" // Phase 6B — search & smart feed
    static let unifiedSelectionWhatsNew = "unifiedSelectionWhatsNew"   // Phase 6C — what's new
    static let unifiedSelectionLegacyRemoved = "unifiedSelectionLegacyRemoved" // Phase 7 — legacy removal
}

// MARK: - Typed Settings Accessor
// Convenience for non-view code. Reads/writes UserDefaults with type safety.

enum Settings {
    private static nonisolated(unsafe) let d = UserDefaults.standard

    // MARK: Filters
    static var filterRegion: String? {
        get { d.string(forKey: Keys.filterRegion) }
        set { d.set(newValue, forKey: Keys.filterRegion) }
    }
    static var filterTaxonomyNodes: [String] {
        get { d.stringArray(forKey: Keys.filterTaxonomyNodes) ?? [] }
        set { d.set(newValue, forKey: Keys.filterTaxonomyNodes) }
    }
    static var filterContentType: String {
        get { d.string(forKey: Keys.filterContentType) ?? "All" }
        set { d.set(newValue, forKey: Keys.filterContentType) }
    }
    static var filterAutoExpire: Bool {
        get { d.bool(forKey: Keys.filterAutoExpire) }
        set { d.set(newValue, forKey: Keys.filterAutoExpire) }
    }
    static var filterSetAt: TimeInterval {
        get { d.double(forKey: Keys.filterSetAt) }
        set { d.set(newValue, forKey: Keys.filterSetAt) }
    }
    static var filterLanguages: [String] {
        get { d.stringArray(forKey: Keys.filterLanguages) ?? [] }
        set { d.set(newValue, forKey: Keys.filterLanguages) }
    }
    static var filterMood: String {
        get { d.string(forKey: Keys.filterMood) ?? FeedLoader.MoodFilter.all.rawValue }
        set { d.set(newValue, forKey: Keys.filterMood) }
    }
    static var hasInitializedLanguageDefault: Bool {
        get { d.bool(forKey: Keys.hasInitializedLanguageDefault) }
        set { d.set(newValue, forKey: Keys.hasInitializedLanguageDefault) }
    }
    // MARK: Appearance
    static var circadianPaletteOn: Bool {
        get { d.object(forKey: Keys.circadianPaletteOn) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.circadianPaletteOn) }
    }
    static var paletteFamily: String {
        get { d.string(forKey: Keys.paletteFamily) ?? "warmEarth" }
        set { d.set(newValue, forKey: Keys.paletteFamily) }
    }
    static var prefetchImages: Bool {
        get { d.object(forKey: Keys.prefetchImages) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.prefetchImages) }
    }
    static var showDebugBar: Bool {
        get { d.bool(forKey: Keys.showDebugBar) }
        set { d.set(newValue, forKey: Keys.showDebugBar) }
    }

    // MARK: Session
    static var sessionStreak: Int {
        get { d.integer(forKey: Keys.sessionStreak) }
        set { d.set(newValue, forKey: Keys.sessionStreak) }
    }
    static var sessionMinutesToday: Int {
        get { d.integer(forKey: Keys.sessionMinutesToday) }
        set { d.set(newValue, forKey: Keys.sessionMinutesToday) }
    }
    static var daysWithAppTotal: Int {
        get { d.integer(forKey: Keys.daysWithAppTotal) }
        set { d.set(newValue, forKey: Keys.daysWithAppTotal) }
    }
    static var lastOpenDate: TimeInterval {
        get { d.double(forKey: Keys.lastOpenDate) }
        set { d.set(newValue, forKey: Keys.lastOpenDate) }
    }

    // MARK: Feed Preset
    static var activePreset: PresetSelector {
        get {
            guard let data = d.data(forKey: Keys.activePreset),
                  let preset = try? JSONDecoder().decode(PresetSelector.self, from: data)
            else { return .everything }
            return preset
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                d.set(data, forKey: Keys.activePreset)
            }
        }
    }

    // MARK: Sources
    static var hasInitializedSourceDefaults: Bool {
        get { d.bool(forKey: Keys.hasInitializedSourceDefaults) }
        set { d.set(newValue, forKey: Keys.hasInitializedSourceDefaults) }
    }

    // MARK: Maintenance
    static var lastHeavyMaintenance: TimeInterval {
        get { d.double(forKey: Keys.lastHeavyMaintenance) }
        set { d.set(newValue, forKey: Keys.lastHeavyMaintenance) }
    }

    // MARK: Content Filters
    static var contentFiltersEnabled: Bool {
        get { d.object(forKey: Keys.contentFiltersEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Keys.contentFiltersEnabled) }
    }

    // MARK: Prepared Feed Pipeline
    /// Defaults to true — the prepared feed pipeline is the primary path.
    /// Can be disabled via UserDefaults or launch argument for debugging.
    static var preparedFeedPipelineEnabled: Bool {
        get {
            if d.object(forKey: Keys.preparedFeedPipelineEnabled) == nil {
                return true  // enabled by default after Phase 9
            }
            return d.bool(forKey: Keys.preparedFeedPipelineEnabled)
        }
        set { d.set(newValue, forKey: Keys.preparedFeedPipelineEnabled) }
    }

    // MARK: Unified Selection Engine — feature flags per migration phase
    // All default to false in production. Debug builds auto-enable shadow + state.

    /// Master flag for the unified selection engine. Off in production until Phase 3.
    static var unifiedSelectionEngine: Bool {
        get {
#if DEBUG
            // In debug, check launch argument first, then fall back to UserDefaults
            if ProcessInfo.processInfo.arguments.contains("--unified-selection-engine") {
                return true
            }
            if d.object(forKey: Keys.unifiedSelectionEngine) == nil {
                return true  // default on in debug
            }
#endif
            return d.bool(forKey: Keys.unifiedSelectionEngine)
        }
        set { d.set(newValue, forKey: Keys.unifiedSelectionEngine) }
    }

    /// Phase 1 — shadow mode: run new compiler alongside legacy, compare results.
    static var unifiedSelectionShadow: Bool {
        get {
#if DEBUG
            if d.object(forKey: Keys.unifiedSelectionShadow) == nil {
                return true  // default on in debug
            }
#endif
            return d.bool(forKey: Keys.unifiedSelectionShadow)
        }
        set { d.set(newValue, forKey: Keys.unifiedSelectionShadow) }
    }

    /// Phase 2 — unified state, counters, loading/empty/error states.
    static var unifiedSelectionState: Bool {
        get {
#if DEBUG
            if d.object(forKey: Keys.unifiedSelectionState) == nil {
                return true  // default on in debug
            }
#endif
            return d.bool(forKey: Keys.unifiedSelectionState)
        }
        set { d.set(newValue, forKey: Keys.unifiedSelectionState) }
    }

    /// Phase 3 — main feed driven by SelectionSession.
    /// In debug, requires launch argument --unified-main-feed to activate.
    static var unifiedSelectionMainFeed: Bool {
        get {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--unified-main-feed") {
                return true
            }
#endif
            return d.bool(forKey: Keys.unifiedSelectionMainFeed)
        }
        set { d.set(newValue, forKey: Keys.unifiedSelectionMainFeed) }
    }

    /// Phase 4 — RankingEngine and MixAllocator.
    static var unifiedSelectionRankingMix: Bool {
        get {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--unified-ranking-mix") {
                return true
            }
            if d.object(forKey: Keys.unifiedSelectionRankingMix) == nil {
                return true  // default on in debug (engines are pure, no side effects)
            }
#endif
            return d.bool(forKey: Keys.unifiedSelectionRankingMix)
        }
        set { d.set(newValue, forKey: Keys.unifiedSelectionRankingMix) }
    }

    /// Phase 5 — onboarding, preview, and curated feed.
    static var unifiedSelectionOnboarding: Bool {
        get { d.bool(forKey: Keys.unifiedSelectionOnboarding) }
        set { d.set(newValue, forKey: Keys.unifiedSelectionOnboarding) }
    }

    /// Phase 6A — fixed scopes: Source View, Collection View, Bookmarks, Last Clicked.
    static var unifiedSelectionSurfaces: Bool {
        get { d.bool(forKey: Keys.unifiedSelectionSurfaces) }
        set { d.set(newValue, forKey: Keys.unifiedSelectionSurfaces) }
    }

    /// Phase 6B — search and Smart Feed.
    static var unifiedSelectionSearchSmart: Bool {
        get { d.bool(forKey: Keys.unifiedSelectionSearchSmart) }
        set { d.set(newValue, forKey: Keys.unifiedSelectionSearchSmart) }
    }

    /// Phase 6C — What's New.
    static var unifiedSelectionWhatsNew: Bool {
        get { d.bool(forKey: Keys.unifiedSelectionWhatsNew) }
        set { d.set(newValue, forKey: Keys.unifiedSelectionWhatsNew) }
    }

    /// Phase 7 — legacy removal, CI enforcement.
    static var unifiedSelectionLegacyRemoved: Bool {
        get { d.bool(forKey: Keys.unifiedSelectionLegacyRemoved) }
        set { d.set(newValue, forKey: Keys.unifiedSelectionLegacyRemoved) }
    }
}
