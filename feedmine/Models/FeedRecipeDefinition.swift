import Foundation

// MARK: - Explicit preference levels

/// A three-state explicit preference used by the Composer.
///
/// The UI translates each level per context: topics display "Normal" while
/// source balance displays "Balanced" — both are `.neutral` internally.
enum PreferenceLevel: String, Codable, Sendable, CaseIterable {
    case less
    case neutral
    case more

    /// UI label for topic rows (Less / Normal / More)
    var topicLabel: String {
        switch self {
        case .less: return String(localized: "Less")
        case .neutral: return String(localized: "Normal")
        case .more: return String(localized: "More")
        }
    }

    /// UI label for source balance rows (Less / Balanced / More)
    var balanceLabel: String {
        switch self {
        case .less: return String(localized: "Less")
        case .neutral: return String(localized: "Balanced")
        case .more: return String(localized: "More")
        }
    }

    /// Maps to profile weight
    var profileWeight: Double {
        switch self {
        case .less: return -1.5
        case .neutral: return 0
        case .more: return 1.5
        }
    }

    /// Cycle to next state: neutral → more → less → neutral
    func next() -> PreferenceLevel {
        switch self {
        case .neutral: return .more
        case .more: return .less
        case .less: return .neutral
        }
    }
}

// MARK: - Content media types

enum MediaType: String, Codable, Sendable, CaseIterable {
    case article
    case podcast
    case video

    var displayName: String {
        switch self {
        case .article: return String(localized: "Articles")
        case .podcast: return String(localized: "Podcasts")
        case .video: return String(localized: "Video")
        }
    }

    var featureKey: String { "media:\(rawValue)" }
}

// MARK: - Explicit feed recipe

/// The persistent, round-trippable record of explicit Composer choices.
///
/// Distinct from `CuratedProfileDefinition` (learned evidence). The recipe is
/// the baseline the user explicitly chose; learned signals layer on top at
/// ranking time via `FeedRecipeResolver`.
struct FeedRecipeDefinition: Codable, Sendable, Hashable {
    var languages: [String]
    var discoveryLevel: Double
    var topicPreferences: [String: PreferenceLevel]
    var editorialPreferences: [String: PreferenceLevel]
    var mediaTypes: Set<MediaType>
    var adjustFromOpens: Bool
    var modelVersion: Int

    static let currentModelVersion = 1

    init(
        languages: [String] = [],
        discoveryLevel: Double = 0.5,
        topicPreferences: [String: PreferenceLevel] = [:],
        editorialPreferences: [String: PreferenceLevel] = [:],
        mediaTypes: Set<MediaType> = [.article, .podcast, .video],
        adjustFromOpens: Bool = false,
        modelVersion: Int = FeedRecipeDefinition.currentModelVersion
    ) {
        self.languages = Array(Set(languages.map {
            $0.lowercased().split(separator: "-").first.map(String.init) ?? $0.lowercased()
        })).sorted()
        self.discoveryLevel = min(1, max(0, discoveryLevel))
        self.topicPreferences = topicPreferences
        self.editorialPreferences = editorialPreferences
        self.mediaTypes = mediaTypes.isEmpty
            ? [.article, .podcast, .video]
            : mediaTypes
        self.adjustFromOpens = adjustFromOpens
        self.modelVersion = modelVersion
    }

    /// The neutral, broad recipe used by "Start broad" and "Reset to neutral."
    /// Languages default to device language at call site.
    static func neutral(languages: [String]) -> FeedRecipeDefinition {
        FeedRecipeDefinition(
            languages: languages,
            discoveryLevel: 0.55,
            topicPreferences: [:],
            editorialPreferences: [:],
            mediaTypes: [.article, .podcast, .video],
            adjustFromOpens: false,
            modelVersion: currentModelVersion
        )
    }
}
