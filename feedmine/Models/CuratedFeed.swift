import Foundation

// MARK: - Curated feed identity

/// A user-owned, inspectable recommendation preset.
///
/// The definition contains preferences only. It deliberately stores no
/// demographic, religious, political, clinical, or inferred identity labels.
struct CuratedFeed: Identifiable, Sendable, Hashable {
    let id: Int64
    let name: String
    let definition: CuratedProfileDefinition
    let createdAt: Date
    let updatedAt: Date
}

/// The transparent state learned by the onboarding comparison session.
///
/// Keys use stable namespaced identifiers such as `topic:technology-science`,
/// `region:countries/brazil`, `media:text`, and `nature:evergreen`. Keeping the
/// vector open-ended lets the catalogue evolve without a database migration.
struct CuratedProfileDefinition: Codable, Sendable, Hashable {
    static let currentModelVersion = 1

    var languages: [String]
    var weights: [String: Double]
    var evidenceCounts: [String: Int]
    var discoveryLevel: Double
    var learningEnabled: Bool
    var evidence: [CuratedEvidence]
    var modelVersion: Int

    init(
        languages: [String] = [],
        weights: [String: Double] = [:],
        evidenceCounts: [String: Int] = [:],
        discoveryLevel: Double = 0.5,
        learningEnabled: Bool = true,
        evidence: [CuratedEvidence] = [],
        modelVersion: Int = CuratedProfileDefinition.currentModelVersion
    ) {
        self.languages = Array(Set(languages.map {
            $0.lowercased().split(separator: "-").first.map(String.init) ?? $0.lowercased()
        })).sorted()
        self.weights = weights.mapValues { min(3, max(-3, $0)) }
        self.evidenceCounts = evidenceCounts.mapValues { max(0, $0) }
        self.discoveryLevel = min(1, max(0, discoveryLevel))
        self.learningEnabled = learningEnabled
        self.evidence = Array(evidence.suffix(80))
        self.modelVersion = modelVersion
    }

    /// Number of meaningful answers — excludes opened (passive) and skip
    /// (explicit absence of signal). Both and Neither carry signal; Skip does not.
    var responseCount: Int {
        evidence.lazy.filter { $0.outcome != .opened && $0.outcome != .skip }.count
    }

    func weight(for key: String) -> Double {
        weights[key, default: 0]
    }

    func evidenceCount(for key: String) -> Int {
        evidenceCounts[key, default: 0]
    }

    func confidence(for key: String) -> Double {
        let count = Double(evidenceCount(for: key))
        return min(1, 1 - exp(-count / 3.5))
    }
}

enum CuratedChoiceOutcome: String, Codable, Sendable, Hashable, CaseIterable {
    case left
    case right
    case both
    case neither
    case skip
    case opened

    var displayName: String {
        switch self {
        case .left: return "First story"
        case .right: return "Second story"
        case .both: return "Both"
        case .neither: return "Neither"
        case .skip: return "Skipped"
        case .opened: return "Opened"
        }
    }
}

/// Human-readable provenance for a profile update. It powers the open-hood
/// inspector and remains local in `user.sqlite`.
struct CuratedEvidence: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let leftTitle: String
    let leftSource: String
    let rightTitle: String
    let rightSource: String
    let outcome: CuratedChoiceOutcome
    let affectedKeys: [String]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        leftTitle: String,
        leftSource: String,
        rightTitle: String,
        rightSource: String,
        outcome: CuratedChoiceOutcome,
        affectedKeys: [String],
        createdAt: Date = .now
    ) {
        self.id = id
        self.leftTitle = leftTitle
        self.leftSource = leftSource
        self.rightTitle = rightTitle
        self.rightSource = rightSource
        self.outcome = outcome
        self.affectedKeys = affectedKeys.sorted()
        self.createdAt = createdAt
    }
}

// MARK: - Broad, culturally neutral topic vocabulary

/// These are catalogue-facing content families, not audience identities.
/// They provide readable labels for the open preference vector and a stable
/// fallback when a source's taxonomy placement is incomplete.
enum CuratedTopic: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case newsCurrentAffairs = "news-current-affairs"
    case artsCulture = "arts-culture"
    case entertainment
    case technologyScience = "technology-science"
    case businessIndustry = "business-industry"
    case healthWellness = "health-wellness"
    case sports
    case foodDrink = "food-drink"
    case homeLiving = "home-living"
    case travelTransport = "travel-transport"
    case educationKnowledge = "education-knowledge"
    case societyIdentity = "society-identity"
    case religionSpirituality = "religion-spirituality"
    case gamesHobbies = "games-hobbies"
    case natureAnimals = "nature-animals"
    case musicAudio = "music-audio"
    case generalInterests = "general-interests"

    var id: String { rawValue }
    var featureKey: String { "topic:\(rawValue)" }

    var displayName: String {
        switch self {
        case .newsCurrentAffairs: return "News & Current Affairs"
        case .artsCulture: return "Arts & Culture"
        case .entertainment: return "Entertainment"
        case .technologyScience: return "Technology & Science"
        case .businessIndustry: return "Business & Industry"
        case .healthWellness: return "Health & Wellness"
        case .sports: return "Sports"
        case .foodDrink: return "Food & Drink"
        case .homeLiving: return "Home & Living"
        case .travelTransport: return "Travel & Transport"
        case .educationKnowledge: return "Education & Knowledge"
        case .societyIdentity: return "Society & Identity"
        case .religionSpirituality: return "Religion & Spirituality"
        case .gamesHobbies: return "Games & Hobbies"
        case .natureAnimals: return "Nature & Animals"
        case .musicAudio: return "Music & Audio"
        case .generalInterests: return "General Interests"
        }
    }

    var shortName: String {
        switch self {
        case .newsCurrentAffairs: return "News"
        case .artsCulture: return "Culture"
        case .technologyScience: return "Tech & Science"
        case .businessIndustry: return "Business"
        case .healthWellness: return "Health"
        case .foodDrink: return "Food"
        case .homeLiving: return "Home"
        case .travelTransport: return "Travel"
        case .educationKnowledge: return "Knowledge"
        case .societyIdentity: return "Society"
        case .religionSpirituality: return "Spirituality"
        case .gamesHobbies: return "Games"
        case .natureAnimals: return "Nature"
        case .musicAudio: return "Music"
        case .entertainment, .sports, .generalInterests: return displayName
        }
    }

    var icon: String {
        switch self {
        case .newsCurrentAffairs: return "newspaper.fill"
        case .artsCulture: return "theatermasks.fill"
        case .entertainment: return "film.fill"
        case .technologyScience: return "atom"
        case .businessIndustry: return "briefcase.fill"
        case .healthWellness: return "heart.text.square.fill"
        case .sports: return "sportscourt.fill"
        case .foodDrink: return "fork.knife"
        case .homeLiving: return "house.fill"
        case .travelTransport: return "airplane"
        case .educationKnowledge: return "books.vertical.fill"
        case .societyIdentity: return "person.3.fill"
        case .religionSpirituality: return "sparkles"
        case .gamesHobbies: return "gamecontroller.fill"
        case .natureAnimals: return "leaf.fill"
        case .musicAudio: return "music.note"
        case .generalInterests: return "circle.grid.3x3.fill"
        }
    }

    /// Multilingual catalogue and editorial vocabulary. Matching is performed
    /// after case/diacritic folding, so these remain compact and readable.
    var keywords: [String] {
        switch self {
        case .newsCurrentAffairs:
            return ["news", "current affairs", "world", "politics", "noticias", "actualidad", "journal"]
        case .artsCulture:
            return ["arts", "culture", "books", "literature", "history", "design", "photography", "cultura", "livros"]
        case .entertainment:
            return ["entertainment", "film", "television", "movies", "celebrity", "cinema", "tv"]
        case .technologyScience:
            return ["technology", "science", "software", "computing", "programming", "space", "engineering", "tech"]
        case .businessIndustry:
            return ["business", "industry", "economy", "finance", "markets", "startup", "entrepreneur"]
        case .healthWellness:
            return ["health", "medicine", "wellness", "psychology", "fitness", "medical", "saude"]
        case .sports:
            return ["sports", "football", "soccer", "basketball", "baseball", "tennis", "hockey", "esportes"]
        case .foodDrink:
            return ["food", "drink", "cooking", "recipes", "wine", "restaurant", "culinaria"]
        case .homeLiving:
            return ["home", "living", "architecture", "garden", "diy", "family", "lifestyle"]
        case .travelTransport:
            return ["travel", "transport", "aviation", "cars", "tourism", "viagem"]
        case .educationKnowledge:
            return ["education", "knowledge", "academic", "research", "learning", "university", "philosophy"]
        case .societyIdentity:
            return ["society", "identity", "communities", "gender", "human rights", "social"]
        case .religionSpirituality:
            return ["religion", "spirituality", "christian", "jewish", "islam", "buddh", "hindu", "faith", "church"]
        case .gamesHobbies:
            return ["games", "gaming", "hobbies", "craft", "comics", "board games"]
        case .natureAnimals:
            return ["nature", "animals", "environment", "climate", "wildlife", "pets", "ecology"]
        case .musicAudio:
            return ["music", "audio", "radio", "musica", "jazz", "classical"]
        case .generalInterests:
            return ["general interests", "magazine", "personal", "life"]
        }
    }
}

/// Editorial roles used only to describe content, never the reader.
///
/// Every source admitted to onboarding must clear the same quality floor.
/// These roles let the preference model distinguish familiarity, specialist
/// depth, and appetite for excellent independent or local voices.
enum CuratedEditorialStyle: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case reference
    case specialist
    case distinctive

    var id: String { rawValue }
    var featureKey: String { "editorial:\(rawValue)" }

    var displayName: String {
        switch self {
        case .reference: return "Recognized references"
        case .specialist: return "Specialist depth"
        case .distinctive: return "Distinctive voices"
        }
    }

    var shortName: String {
        switch self {
        case .reference: return "Reference"
        case .specialist: return "Specialist"
        case .distinctive: return "Distinctive"
        }
    }

    var icon: String {
        switch self {
        case .reference: return "checkmark.seal.fill"
        case .specialist: return "scope"
        case .distinctive: return "sparkles"
        }
    }
}

extension String {
    /// A readable label for a namespaced Curated Feed feature.
    var curatedFeatureDisplayName: String {
        if hasPrefix("topic:"),
           let topic = CuratedTopic(rawValue: String(dropFirst("topic:".count))) {
            return topic.displayName
        }
        if hasPrefix("media:") {
            return String(dropFirst("media:".count)).capitalized
        }
        if hasPrefix("nature:") {
            return String(dropFirst("nature:".count))
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
        }
        if hasPrefix("region:") {
            let raw = String(dropFirst("region:".count))
                .replacingOccurrences(of: "countries/", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            return raw == "global" ? "Global perspectives" : raw.capitalized
        }
        if hasPrefix("scope:") {
            return dropFirst("scope:".count) == "regional"
                ? "Regional perspectives"
                : "Global perspectives"
        }
        if hasPrefix("editorial:"),
           let style = CuratedEditorialStyle(
               rawValue: String(dropFirst("editorial:".count))
           ) {
            return style.displayName
        }
        if hasPrefix("prominence:") {
            return dropFirst("prominence:".count) == "recognized"
                ? "Recognized sources"
                : "Discovery sources"
        }
        if hasPrefix("depth:") {
            return dropFirst("depth:".count) == "specialist"
                ? "Specialist depth"
                : "Broad-audience coverage"
        }
        return replacingOccurrences(of: "-", with: " ").capitalized
    }
}
