import Foundation

// MARK: - Onboarding intent

/// What the user wants from Feedmine — asked once, single-select, before any
/// topic or language selection. Influences discovery level and the balance
/// between breadth and depth in the curated feed.
enum OnboardingIntent: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case stayInformed
    case deepUnderstanding
    case discoverNewIdeas
    case entertainment
    case professionalNeed
    case justBrowsing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stayInformed: return "Stay informed"
        case .deepUnderstanding: return "Deep understanding"
        case .discoverNewIdeas: return "Discover new ideas"
        case .entertainment: return "Entertainment"
        case .professionalNeed: return "Professional need"
        case .justBrowsing: return "Just browsing"
        }
    }

    var subtitle: String {
        switch self {
        case .stayInformed: return "Know what's happening in the world"
        case .deepUnderstanding: return "Go deep on subjects that matter to me"
        case .discoverNewIdeas: return "Be surprised by things I didn't know existed"
        case .entertainment: return "Light, interesting reads that delight"
        case .professionalNeed: return "Track my industry and area of work"
        case .justBrowsing: return "Show me what you've got — I'll figure it out"
        }
    }

    var icon: String {
        switch self {
        case .stayInformed: return "globe.americas.fill"
        case .deepUnderstanding: return "magnifyingglass.circle.fill"
        case .discoverNewIdeas: return "sparkles"
        case .entertainment: return "face.smiling.fill"
        case .professionalNeed: return "briefcase.fill"
        case .justBrowsing: return "binoculars.fill"
        }
    }

    /// Discovery level implied by this intent. Higher = more exploratory.
    var impliedDiscoveryLevel: Double {
        switch self {
        case .discoverNewIdeas: return 0.8
        case .justBrowsing: return 0.65
        case .stayInformed: return 0.5
        case .entertainment: return 0.45
        case .professionalNeed: return 0.35
        case .deepUnderstanding: return 0.25
        }
    }
}

// MARK: - Onboarding seed

/// Lightweight seed collected from the pre-duel intent + topics screens.
/// Applied to the CuratedOnboardingSession before the first comparison so
/// duels start from relevant content rather than raw discovery.
struct OnboardingSeed: Sendable, Hashable {
    var intent: OnboardingIntent?
    var topicIDs: Set<String>

    init(intent: OnboardingIntent? = nil, topicIDs: Set<String> = []) {
        self.intent = intent
        self.topicIDs = topicIDs
    }

    var isEmpty: Bool {
        intent == nil && topicIDs.isEmpty
    }
}
