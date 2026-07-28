import Foundation
import NaturalLanguage
import Observation

struct CuratedEditorialAssessment: Sendable {
    let style: CuratedEditorialStyle
    let isRecognized: Bool
    let isSpecialist: Bool
    let score: Double
    let reason: String
    let isEligible: Bool

    var featureKeys: Set<String> {
        var keys: Set<String> = [style.featureKey]
        if isRecognized { keys.insert(CuratedEditorialStyle.reference.featureKey) }
        if isSpecialist { keys.insert(CuratedEditorialStyle.specialist.featureKey) }
        if !isRecognized && !isSpecialist {
            keys.insert(CuratedEditorialStyle.distinctive.featureKey)
        }
        return keys
    }
}

struct CuratedCandidate: Identifiable, Sendable {
    var id: String { item.id }
    let item: FeedItem
    let source: SourceReference
    let topic: CuratedTopic
    let featureKeys: Set<String>
    let quality: Double
    let contentLanguage: String?
    let editorial: CuratedEditorialAssessment

    init(
        item: FeedItem,
        source: SourceReference,
        topic: CuratedTopic,
        featureKeys: Set<String>,
        quality: Double,
        contentLanguage: String?,
        editorial: CuratedEditorialAssessment? = nil
    ) {
        let assessment = editorial
            ?? CuratedPreferenceEngine.editorialAssessment(for: source.feedSource)
        self.item = item
        self.source = source
        self.topic = topic
        self.featureKeys = featureKeys.union(assessment.featureKeys)
        self.quality = quality
        self.contentLanguage = contentLanguage
        self.editorial = assessment
    }

    var language: String {
        contentLanguage
            ?? CuratedPreferenceEngine.baseLanguage(item.language ?? source.language)
            ?? "und"
    }
}

struct CuratedComparisonPair: Identifiable, Sendable {
    let left: CuratedCandidate
    let right: CuratedCandidate
    let distinguishingKeys: [String]

    var id: String {
        [left.id, right.id].sorted().joined(separator: "|")
    }
}

/// Pure, on-device preference elicitation and scoring.
///
/// The engine starts from a flat prior. It never infers an identity: it only
/// updates content attributes that were actually present in a comparison.
enum CuratedPreferenceEngine {
    /// The bundled catalogue's quality score is technical: recency, activity,
    /// and fetch health. These signals add an independent editorial gate for
    /// the high-stakes first-run showcase.
    private static let recognizedPublisherSignals = [
        "associated press", "ap news", "reuters", "bbc", "npr", "pbs",
        "cbc", "radio canada", "abc news", "abc australia", "sbs australia",
        "deutsche welle", "france 24", "radio france", "arte", "al jazeera",
        "euronews", "the guardian", "financial times", "the economist",
        "bloomberg", "propublica", "pew research center", "the conversation",
        "nature journal", "nature.com", "science magazine", "science.org",
        "scientific american", "new scientist",
        "national geographic", "smithsonian", "mit technology review", "wired",
        "ars technica", "nasa", "european space agency", "world health organization",
        "united nations", "unesco", "agencia brasil", "agencia efe", "nexo jornal",
        "folha de s paulo", "estadao", "publico", "rtp", "el pais", "rtve",
        "la nacion", "le monde", "franceinfo", "tagesschau", "der spiegel",
        "die zeit", "deutschlandfunk", "ansa", "rai news", "la repubblica",
        "corriere della sera", "il sole 24 ore", "nhk", "asahi shimbun",
        "mainichi", "nikkei", "yomiuri", "svt", "sveriges radio", "nrk",
        "danmarks radio", "yle", "ruv", "channel newsasia", "the hindu",
        "indian express", "dawn", "rappler", "yonhap", "africa check",
        "daily maverick", "mail guardian", "premium times", "balkan insight",
    ]

    private static let institutionalSignals = [
        "university", "universidade", "universidad", "universite", "universitat",
        "universita", "universiteit", "universitet", "college", "academy",
        "institute", "instituto", "institut", "research center", "research centre",
        "museum", "museu", "museo", "library", "biblioteca", "foundation",
        "fundacao", "fondation", "public radio", "public media", "public broadcaster",
        "national radio", "national museum", "national library", "observatory",
        "medical journal", "scientific journal", "fact check", "fact checking",
    ]

    private static let specialistSignals = [
        "research", "science", "scientific", "analysis", "in depth", "longform",
        "journal", "review", "criticism", "essays", "history", "literature",
        "architecture", "design", "medicine", "medical", "law", "economics",
        "philosophy", "documentary", "investigation", "investigative",
        "data journalism", "expert", "scholar", "academic",
    ]

    private static let publishingSignals = [
        "news", "reporting", "journalism", "coverage", "stories", "interviews",
        "analysis", "explores", "magazine", "journal", "documentary", "reviews",
        "criticism", "essays", "research", "education", "history", "culture",
        "science", "music", "books", "literature", "sports", "cooking",
    ]

    private static let commercialSignals = [
        "coupon", "discount code", "affiliate", "buy now", "online store",
        "real estate listings", "marketing agency", "sales funnel", "casino",
        "betting tips", "forex signals", "product promotion", "distributor",
        "sponsored offers", "price alerts", "luxury products",
    ]

    private static let aggregationSignals = [
        "news aggregator", "content aggregator", "feed aggregating all",
        "aggregates stories", "aggregates articles",
    ]

    private static let genericSourceTitleSignals = [
        "latest newsfeed articles", "rss feed", "all articles",
        "top stories google news",
    ]

    private static let excludedShowcaseHosts = [
        "news.google.com", "flipboard.com",
    ]

    private static let genericDistributionHosts = [
        "anchor.fm", "buzzsprout.com", "libsyn.com", "podbean.com",
        "spotify.com", "soundcloud.com", "simplecast.com", "acast.com",
        "megaphone.fm", "transistor.fm", "rss.com", "ivoox.com",
        "podomatic.com", "redcircle.com",
    ]

    private static let sensitiveOnboardingTerms = [
        "graphic", "murder", "killed", "shooting", "massacre", "suicide",
        "rape", "sexual assault", "war casualties", "dead bodies",
    ]

    private static let promotionalStoryTerms = [
        "sponsored", "promo code", "limited time offer", "buy now",
        "best prices", "free trial", "register now", "sign up now",
    ]

    static func baseLanguage(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let normalized = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        return normalized.split(separator: "-").first.map(String.init)
    }

    static func editorialAssessment(for source: FeedSource) -> CuratedEditorialAssessment {
        let host = URL(string: source.url)?.host?
            .lowercased()
            .replacingOccurrences(of: "www.", with: "") ?? ""
        let identity = editorialText("\(source.title) \(host)")
        let context = editorialText([
            source.title,
            source.sourceDescription ?? "",
            source.tags.joined(separator: " "),
        ].joined(separator: " "))

        let recognized = recognizedPublisherSignals.contains {
            identity.contains($0)
        }
        let institutionalDomain = [
            ".edu", ".ac.uk", ".gov", ".int",
        ].contains(where: host.hasSuffix)
        let institutional = institutionalDomain || institutionalSignals.contains {
            context.contains($0)
        }
        let specialist = specialistSignals.contains {
            context.contains($0)
        }
        let hasPublishingPurpose = publishingSignals.contains {
            context.contains($0)
        }
        let commercial = commercialSignals.contains {
            context.contains($0)
        }
        let aggregator = excludedShowcaseHosts.contains(host)
            || aggregationSignals.contains(where: context.contains)
        let genericTitle = genericSourceTitleSignals.contains {
            editorialText(source.title).contains($0)
        }
        let genericHost = genericDistributionHosts.contains {
            host == $0 || host.hasSuffix(".\($0)")
        }

        let technicalQuality = min(1, max(0, Double(source.qualityScore ?? 70) / 100))
        let activityFactor: Double = switch source.activity?.lowercased() {
        case "prolific": 1
        case "active": 0.94
        case "quiet": 0.76
        case "dormant": 0.35
        default: 0.82
        }
        let editorialAuthority: Double
        if recognized {
            editorialAuthority = 1
        } else if institutional {
            editorialAuthority = 0.92
        } else if specialist {
            editorialAuthority = 0.83
        } else {
            editorialAuthority = 0.70
        }
        let directPublisherFactor = genericHost ? 0.62 : 1
        let score = min(
            1,
            technicalQuality * 0.30
                + editorialAuthority * 0.42
                + activityFactor * 0.18
                + directPublisherFactor * 0.10
        )

        let evidenceFloor: Bool
        if recognized || institutional {
            evidenceFloor = technicalQuality >= 0.70
        } else if specialist && hasPublishingPurpose {
            evidenceFloor = technicalQuality >= 0.80
        } else {
            evidenceFloor = technicalQuality >= 0.87
                && hasPublishingPurpose
                && !genericHost
        }
        let isEligible = source.defaultEnabled
            && source.activity?.lowercased() != "dormant"
            && !commercial
            && !aggregator
            && (!genericTitle || recognized || institutional)
            && evidenceFloor

        let style: CuratedEditorialStyle
        if specialist && !(recognized && !institutional) {
            style = .specialist
        } else if recognized || institutional {
            style = .reference
        } else {
            style = .distinctive
        }
        let reason: String
        switch style {
        case .reference:
            reason = "Established reference with a public editorial record"
        case .specialist:
            reason = "Subject expertise and greater editorial depth"
        case .distinctive:
            reason = "Strong independent or local editorial voice"
        }

        return CuratedEditorialAssessment(
            style: style,
            isRecognized: recognized || institutional,
            isSpecialist: specialist,
            score: score,
            reason: reason,
            isEligible: isEligible
        )
    }

    /// A deterministic, editorially screened first-run source runway.
    /// Sources are round-robined across language, topic, role, geography, and
    /// medium so a prolific category cannot occupy the whole first impression.
    static func showcaseSources(
        from sources: [FeedSource],
        limit: Int
    ) -> [FeedSource] {
        guard limit > 0 else { return [] }
        let styleOrder: [CuratedEditorialStyle: Int] = [
            .reference: 0,
            .specialist: 1,
            .distinctive: 2,
        ]
        let topicOrder = Dictionary(
            uniqueKeysWithValues: CuratedTopic.allCases.enumerated().map { ($1, $0) }
        )
        let assessed = sources.compactMap { source -> (FeedSource, CuratedEditorialAssessment, CuratedTopic)? in
            let assessment = editorialAssessment(for: source)
            guard assessment.isEligible, let topic = topic(for: source) else {
                return nil
            }
            return (source, assessment, topic)
        }.sorted { lhs, rhs in
            // Hand-picked onboarding showcase domains first
            let lhsShowcase = Self.isOnboardingShowcase(url: lhs.0.url, language: lhs.0.language ?? "en")
            let rhsShowcase = Self.isOnboardingShowcase(url: rhs.0.url, language: rhs.0.language ?? "en")
            if lhsShowcase != rhsShowcase { return lhsShowcase }
            if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
            if lhs.0.qualityScore != rhs.0.qualityScore {
                return (lhs.0.qualityScore ?? 0) > (rhs.0.qualityScore ?? 0)
            }
            if lhs.0.title != rhs.0.title {
                return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
            }
            return lhs.0.url < rhs.0.url
        }

        var buckets: [String: [FeedSource]] = [:]
        for (source, assessment, topic) in assessed {
            let language = baseLanguage(source.language) ?? "und"
            let scope = source.region.hasPrefix("countries/") ? "regional" : "global"
            let key = [
                language,
                String(styleOrder[assessment.style] ?? 9),
                scope,
                source.mediaKind.rawValue,
                String(format: "%02d", topicOrder[topic] ?? 99),
            ].joined(separator: "|")
            buckets[key, default: []].append(source)
        }

        let keys = buckets.keys.sorted()
        var result: [FeedSource] = []
        var offsets = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
        while result.count < limit {
            var appended = false
            for key in keys where result.count < limit {
                guard let bucket = buckets[key],
                      let offset = offsets[key],
                      offset < bucket.count else { continue }
                result.append(bucket[offset])
                offsets[key] = offset + 1
                appended = true
            }
            if !appended { break }
        }
        return result
    }

    static func topic(for source: FeedSource) -> CuratedTopic? {
        if let exact = CuratedTopic.allCases.first(where: {
            source.category == $0.displayName || source.category == $0.rawValue
        }) {
            return exact
        }
        let category = normalizedText(source.category)
        if let direct = CuratedTopic.allCases.first(where: {
            category == normalizedText($0.displayName)
                || category == normalizedText($0.rawValue)
        }) {
            return direct
        }

        let regionPath = normalizedText(
            source.region.replacingOccurrences(of: "_", with: " ")
        )
        if let pathMatch = CuratedTopic.allCases.first(where: { topic in
            regionPath.contains(normalizedText(topic.rawValue))
                || regionPath.contains(normalizedText(topic.displayName))
        }) {
            return pathMatch
        }

        // Category is the most deliberate editorial signal, followed by tags
        // and the source description. A keyword must be a meaningful substring,
        // so tiny ambiguous tokens are not part of the vocabulary.
        let fields = [
            category,
            normalizedText(source.tags.joined(separator: " ")),
            normalizedText(source.sourceDescription ?? ""),
            normalizedText(source.title),
        ]
        for field in fields where !field.isEmpty {
            if let match = CuratedTopic.allCases.first(where: { topic in
                topic.keywords.contains(where: {
                    field.contains(normalizedText($0))
                })
            }) {
                return match
            }
        }
        return nil
    }

    static func featureKeys(for source: FeedSource, topic: CuratedTopic) -> Set<String> {
        var keys: Set<String> = [
            topic.featureKey,
            "media:\(source.mediaKind.rawValue)",
        ]
        keys.formUnion(editorialAssessment(for: source).featureKeys)
        if let nature = source.nature?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nature.isEmpty {
            keys.insert("nature:\(nature.lowercased())")
        }

        let parts = source.region.lowercased().split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "countries" {
            keys.insert("region:countries/\(parts[1])")
            keys.insert("scope:regional")
        } else {
            keys.insert("region:global")
            keys.insert("scope:global")
        }
        return keys
    }

    // MARK: - Hardcoded Onboarding Curation

    /// Hand-picked source domains that produce excellent comparison cards:
    /// great images, compelling headlines, diverse topics, editorial quality.
    /// Onboarding uses these first before falling back to the algorithmic pool.
    static let onboardingShowcaseDomains: [String: [String]] = [
        "en": [
            // Reference / News — recognizable mastheads
            "reuters.com", "apnews.com", "npr.org", "bbc.com", "bbc.co.uk",
            "theguardian.com", "economist.com", "csmonitor.com",
            // Tech / Science — great images, strong headlines
            "theverge.com", "arstechnica.com", "wired.com", "technologyreview.com",
            "scientificamerican.com", "quantamagazine.org", "nautil.us",
            // Culture / Analysis — longform, distinctive voice
            "theatlantic.com", "newyorker.com", "newyorktimes.com", "nytimes.com",
            "propublica.org", "texasmonthly.com", "theconversation.com",
            // Design / Business — visual content
            "fastcompany.com", "hbr.org", "bloomberg.com",
            // Science / Nature
            "nationalgeographic.com", "smithsonianmag.com", "science.org",
        ],
        "pt": [
            "folha.uol.com.br", "www1.folha.uol.com.br",
            "oglobo.globo.com", "uol.com.br", "nexojornal.com.br",
            "piaui.folha.uol.com.br", "revistapesquisa.fapesp.br",
            "bbc.com/portuguese", "elpais.com/brasil",
            "cartacapital.com.br", "tab.uol.com.br",
        ],
        "es": [
            "elpais.com", "elmundo.es", "elconfidencial.com",
            "bbc.com/mundo", "lanacion.com.ar", "clarin.com",
            "eluniversal.com.mx", "elespanol.com",
        ],
    ]

    /// Check whether a source URL matches any hand-picked onboarding domain.
    /// Uses host extraction + suffix matching to avoid false positives
    /// (e.g. "fakereuters.com" must not match "reuters.com").
    static func isOnboardingShowcase(url: String, language: String) -> Bool {
        guard let domains = onboardingShowcaseDomains[language] else { return false }
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return domains.contains { domain in
            host == domain || host.hasSuffix("." + domain)
        }
    }

    static func makeCandidates(
        items: [FeedItem],
        sources: [FeedSource],
        languages: Set<String>
    ) -> [CuratedCandidate] {
        let normalizedLanguages = Set(languages.compactMap(baseLanguage))
        let sourceMap = Dictionary(
            sources.map { (OPMLParser.normalizeURL($0.url), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenTitles = Set<String>()
        var candidates: [CuratedCandidate] = []
        var sourceItemCounts: [String: Int] = [:]

        for item in items {
            let normalizedURL = OPMLParser.normalizeURL(item.sourceURL)
            let fallbackKind: MediaKind = item.isPodcast
                ? .audio : (item.isYouTube ? .video : (item.isForum ? .forum : .text))
            let source = sourceMap[normalizedURL] ?? FeedSource(
                title: item.sourceTitle,
                url: normalizedURL,
                category: item.category,
                region: item.region,
                mediaKind: fallbackKind,
                language: item.language
            )
            guard source.defaultEnabled,
                  let topic = topic(for: source) else { continue }
            let editorial = editorialAssessment(for: source)
            guard editorial.isEligible,
                  sourceItemCounts[normalizedURL, default: 0] < 2 else { continue }

            // Cheap gates first — reject before expensive NLP
            let cleanTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cleanTitle.count >= 12, cleanTitle.count <= 190 else { continue }

            let upperRatio = cleanTitle.filter(\.isUppercase).count
            let letterCount = cleanTitle.filter(\.isLetter).count
            if letterCount > 0, Double(upperRatio) / Double(letterCount) > 0.85 { continue }
            if cleanTitle.allSatisfy({ $0.isNumber || $0.isWhitespace || $0 == "." || $0 == "," }) { continue }
            if cleanTitle.hasPrefix("http") || cleanTitle.hasPrefix("www.") { continue }

            let foldedTitle = normalizedText(cleanTitle)
            guard !sensitiveOnboardingTerms.contains(where: foldedTitle.contains),
                  !promotionalStoryTerms.contains(where: foldedTitle.contains),
                  seenTitles.insert(foldedTitle).inserted else { continue }

            let substance = (item.excerpt).trimmingCharacters(in: .whitespacesAndNewlines)
            if substance.count < 20 || substance == "No description" { continue }

            guard item.hasPotentialImage else { continue }

            // NLP language detection: expensive, only run for items that
            // already passed all cheaper gates above.
            let declaredLanguage = baseLanguage(item.language ?? source.language)
            let detectedLanguage = detectedContentLanguage(for: item)
            let language = detectedLanguage ?? declaredLanguage
            if !normalizedLanguages.isEmpty {
                guard let language, normalizedLanguages.contains(language) else {
                    continue
                }
            }

            sourceItemCounts[normalizedURL, default: 0] += 1
            candidates.append(CuratedCandidate(
                item: item,
                source: SourceReference(source: source),
                topic: topic,
                featureKeys: featureKeys(for: source, topic: topic),
                quality: editorial.score,
                contentLanguage: language,
                editorial: editorial
            ))
        }

        // Round-robin through the editorial dimensions. This is deterministic:
        // identical content produces identical onboarding candidates.
        let topicOrder = Dictionary(
            uniqueKeysWithValues: CuratedTopic.allCases.enumerated().map { ($1, $0) }
        )
        let styleOrder: [CuratedEditorialStyle: Int] = [
            .reference: 0,
            .specialist: 1,
            .distinctive: 2,
        ]
        // Sort: hand-picked showcase domains first, then quality, then recency.
        // Use sorted languages for determinism + baseLanguage for code normalization.
        let sortedLangs = languages.sorted()
        let languageForShowcase = sortedLangs.first.flatMap { Self.baseLanguage($0) } ?? "en"
        let sorted = candidates.sorted {
            let aShowcase = Self.isOnboardingShowcase(url: $0.source.feedURL, language: languageForShowcase)
            let bShowcase = Self.isOnboardingShowcase(url: $1.source.feedURL, language: languageForShowcase)
            if aShowcase != bShowcase { return aShowcase }
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            if $0.item.publishedAt != $1.item.publishedAt {
                return $0.item.publishedAt > $1.item.publishedAt
            }
            return $0.id < $1.id
        }
        var buckets: [String: [CuratedCandidate]] = [:]
        for candidate in sorted {
            let scope = candidate.source.region.hasPrefix("countries/")
                ? "regional" : "global"
            let key = [
                candidate.language,
                String(styleOrder[candidate.editorial.style] ?? 9),
                scope,
                candidate.source.mediaKind.rawValue,
                String(format: "%02d", topicOrder[candidate.topic] ?? 99),
            ].joined(separator: "|")
            buckets[key, default: []].append(candidate)
        }
        let keys = buckets.keys.sorted()
        var balanced: [CuratedCandidate] = []
        var offsets = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
        while balanced.count < 128 {
            var appended = false
            for key in keys where balanced.count < 128 {
                guard let bucket = buckets[key],
                      let offset = offsets[key],
                      offset < bucket.count else { continue }
                balanced.append(bucket[offset])
                offsets[key] = offset + 1
                appended = true
            }
            if !appended { break }
        }
        return balanced
    }

    /// Selects the next branch of the decision tree. The tree is not stored:
    /// every branch is regenerated from uncertainty, coverage, and available
    /// real content after the previous answer.
    static func nextPair(
        candidates: [CuratedCandidate],
        profile: CuratedProfileDefinition,
        usedItemIDs: Set<String>,
        usedPairIDs: Set<String>
    ) -> CuratedComparisonPair? {
        guard candidates.count >= 2 else { return nil }
        // Never show the same card twice. If we're running low on fresh
        // candidates, the caller must fetch more — we don't fall back to used items.
        let fresh = candidates.filter { !usedItemIDs.contains($0.id) }
        guard fresh.count >= 2 else { return nil }
        let limited = Array(fresh.prefix(80))
        var best: (pair: CuratedComparisonPair, score: Double)?

        for leftIndex in limited.indices {
            for rightIndex in limited.indices where rightIndex > leftIndex {
                let a = limited[leftIndex]
                let b = limited[rightIndex]
                guard a.source.feedURL != b.source.feedURL,
                      a.language == b.language else { continue }

                // The first questions compare subjects while holding editorial
                // role and medium steady. Once there is a topical baseline, the
                // engine can deliberately test recognized vs discovery sources
                // and broad-audience vs specialist depth.
                if profile.responseCount < 4 {
                    guard a.topic != b.topic,
                          a.source.mediaKind == b.source.mediaKind,
                          a.editorial.style == b.editorial.style,
                          abs(a.quality - b.quality) <= 0.15 else { continue }
                }

                let pairID = [a.id, b.id].sorted().joined(separator: "|")
                guard !usedPairIDs.contains(pairID) else { continue }
                let differing = a.featureKeys.symmetricDifference(b.featureKeys)
                    .filter { !$0.hasPrefix("scope:") }
                    .sorted()
                guard !differing.isEmpty else { continue }

                let uncertainty = differing.reduce(0.0) { result, key in
                    result + 1 / (1 + Double(profile.evidenceCount(for: key)))
                }
                let coverage = Double(differing.filter {
                    profile.evidenceCount(for: $0) == 0
                }.count) * 0.85
                let relevance = differing.reduce(0.0) {
                    $0 + min(0.35, abs(profile.weight(for: $1)) * 0.08)
                }
                let editorialKeys = differing.filter {
                    $0.hasPrefix("editorial:")
                }
                let editorialCoverage = editorialKeys.reduce(0.0) { result, key in
                    result + (profile.evidenceCount(for: key) == 0 ? 0.85 : 0.18)
                }
                let cleanEditorialContrast = !editorialKeys.isEmpty
                    && a.topic == b.topic
                    && a.source.mediaKind == b.source.mediaKind
                    ? 1.35 : 0

                let qualityPenalty = abs(a.quality - b.quality) * 4
                let ageDays = abs(a.item.publishedAt.timeIntervalSince(b.item.publishedAt)) / 86_400
                let agePenalty = min(1.2, ageDays / 30)

                // Freshness: reward recent content, capped for clock skew safety
                let now = Date()
                let freshnessBoost: Double = {
                    let aHours = max(0, now.timeIntervalSince(a.item.publishedAt) / 3600)
                    let bHours = max(0, now.timeIntervalSince(b.item.publishedAt) / 3600)
                    return max(0, min(1.8, 1.8 - (aHours + bHours) / 48))
                }()

                // Engagement: reward compelling titles (longer = more informative)
                let titleScore: Double = {
                    let aLen = Double(a.item.title.count)
                    let bLen = Double(b.item.title.count)
                    let aScore = max(0, 1 - abs(aLen - 65) / 65)
                    let bScore = max(0, 1 - abs(bLen - 65) / 65)
                    return (aScore + bScore) * 0.4
                }()

                let confoundPenalty = Double(max(0, differing.count - 4)) * 0.32
                let mediaPenalty = a.source.mediaKind == b.source.mediaKind ? 0 : 0.25

                let score = uncertainty + coverage + relevance
                    + editorialCoverage + cleanEditorialContrast
                    + freshnessBoost + titleScore
                    - qualityPenalty - agePenalty
                    - confoundPenalty - mediaPenalty
                let shouldSwap = (profile.responseCount + leftIndex + rightIndex).isMultiple(of: 2)
                let pair = CuratedComparisonPair(
                    left: shouldSwap ? b : a,
                    right: shouldSwap ? a : b,
                    distinguishingKeys: differing
                )
                if best == nil || score > best!.score {
                    best = (pair, score)
                }
            }
        }
        return best?.pair
    }

    static func applying(
        outcome: CuratedChoiceOutcome,
        pair: CuratedComparisonPair,
        to original: CuratedProfileDefinition
    ) -> CuratedProfileDefinition {
        var profile = original
        let leftOnly = pair.left.featureKeys.subtracting(pair.right.featureKeys)
        let rightOnly = pair.right.featureKeys.subtracting(pair.left.featureKeys)
        let allPresented = pair.left.featureKeys.union(pair.right.featureKeys)
        let affected: Set<String>
        switch outcome {
        case .left, .right:
            // A forced choice only supports attributes that distinguish the
            // stories. Shared traits are intentionally left untouched.
            affected = leftOnly.union(rightOnly)
        case .both, .neither:
            affected = allPresented
        case .skip:
            // Skip records no signal — it's the absence of evidence.
            // The pair is consumed (won't be re-shown) but nothing is learned.
            affected = []
        case .opened:
            affected = []
        }

        func adjust(_ keys: Set<String>, by amount: Double) {
            for key in keys {
                let scaledAmount = key.hasPrefix("scope:") ? amount * 0.55 : amount
                profile.weights[key] = min(
                    3,
                    max(-3, profile.weights[key, default: 0] + scaledAmount)
                )
            }
        }

        switch outcome {
        case .left:
            adjust(leftOnly, by: 0.38)
            adjust(rightOnly, by: -0.17)
        case .right:
            adjust(rightOnly, by: 0.38)
            adjust(leftOnly, by: -0.17)
        case .both:
            adjust(allPresented, by: 0.20)
            profile.discoveryLevel = min(1, profile.discoveryLevel + 0.035)
        case .neither:
            adjust(allPresented, by: -0.15)
            profile.discoveryLevel = max(0, profile.discoveryLevel - 0.02)
        case .opened:
            break
        case .skip:
            break
        }

        for key in affected {
            profile.evidenceCounts[key, default: 0] += 1
        }
        profile.evidence.append(CuratedEvidence(
            leftTitle: pair.left.item.title,
            leftSource: pair.left.item.sourceTitle,
            rightTitle: pair.right.item.title,
            rightSource: pair.right.item.sourceTitle,
            outcome: outcome,
            affectedKeys: Array(affected)
        ))
        profile.evidence = Array(profile.evidence.suffix(80))
        return profile
    }

    /// Small, explicit learning step for opening an article. It is deliberately
    /// weaker than a pairwise answer and never reacts to visibility or scroll.
    static func applyingExplicitOpen(
        item: FeedItem,
        source: FeedSource,
        to original: CuratedProfileDefinition
    ) -> CuratedProfileDefinition {
        guard original.learningEnabled, let topic = topic(for: source) else {
            return original
        }
        var profile = original
        let keys = featureKeys(for: source, topic: topic)
        for key in keys {
            let amount = key.hasPrefix("scope:") ? 0.03 : 0.055
            profile.weights[key] = min(
                3,
                max(-3, profile.weights[key, default: 0] + amount)
            )
            profile.evidenceCounts[key, default: 0] += 1
        }
        profile.evidence.append(CuratedEvidence(
            leftTitle: item.title,
            leftSource: item.sourceTitle,
            rightTitle: "",
            rightSource: "",
            outcome: .opened,
            affectedKeys: Array(keys)
        ))
        profile.evidence = Array(profile.evidence.suffix(80))
        return profile
    }

    static func sourceMultiplier(
        for source: FeedSource,
        profile: CuratedProfileDefinition
    ) -> Double {
        guard let topic = topic(for: source) else { return 1 }
        let keys = featureKeys(for: source, topic: topic)
        var score = 0.0
        for key in keys {
            let confidence = profile.confidence(for: key)
            let scopeScale = key.hasPrefix("scope:") ? 0.5 : 1
            score += profile.weight(for: key)
                * (0.25 + confidence * 0.75)
                * scopeScale
        }

        // Higher discovery keeps neutral and weakly preferred sources closer
        // to the centre instead of locking the user into the strongest branch.
        let exploitation = 1 - profile.discoveryLevel * 0.42
        let learned = exp(score * 0.19 * exploitation)
        let quality = 0.9 + (Double(source.qualityScore ?? 70) / 100) * 0.2
        return min(3, max(0.42, learned * quality))
    }

    static func sourceMultipliers(
        sources: [FeedSource],
        profile: CuratedProfileDefinition
    ) -> [String: Double] {
        var result: [String: Double] = [:]
        result.reserveCapacity(sources.count)
        for source in sources {
            let multiplier = sourceMultiplier(for: source, profile: profile)
            if abs(multiplier - 1) > 0.001 {
                result[source.url] = multiplier
            }
        }
        return result
    }

    static func topTopicWeights(
        in profile: CuratedProfileDefinition,
        limit: Int = 5
    ) -> [(topic: CuratedTopic, weight: Double, confidence: Double)] {
        CuratedTopic.allCases
            .map {
                (
                    topic: $0,
                    weight: profile.weight(for: $0.featureKey),
                    confidence: profile.confidence(for: $0.featureKey)
                )
            }
            .filter { abs($0.weight) > 0.001 || $0.confidence > 0 }
            .sorted {
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                return $0.confidence > $1.confidence
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func normalizedText(_ value: String) -> String {
        value.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    /// The editorial catalogue descriptions are generated in English and the
    /// policy vocabulary is ASCII. Avoid full Unicode folding on this hot path;
    /// story/topic matching still uses `normalizedText`.
    private static func editorialText(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    /// Source metadata remains the fallback, but a confident reading of the
    /// actual story wins. This prevents a mislabelled source from presenting a
    /// user with a comparison in a language they did not select.
    private static func detectedContentLanguage(for item: FeedItem) -> String? {
        let sample = "\(item.title). \(item.excerpt.prefix(420))"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sample.count >= 24 else { return nil }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first else {
            return nil
        }
        let minimumConfidence = sample.count < 80 ? 0.80 : 0.65
        guard best.value >= minimumConfidence else { return nil }
        return baseLanguage(best.key.rawValue)
    }
}

@MainActor
@Observable
final class CuratedOnboardingSession {
    static let minimumAnswers = 5
    // targetAnswers removed — completion is now adaptive via isReady
    static let maximumAnswers = 20

    private struct Snapshot {
        let profile: CuratedProfileDefinition
        let usedItemIDs: Set<String>
        let usedPairIDs: Set<String>
        let pair: CuratedComparisonPair?
    }

    private(set) var profile: CuratedProfileDefinition
    private(set) var candidates: [CuratedCandidate] = []
    private(set) var currentPair: CuratedComparisonPair?
    private(set) var isRefreshingCandidates = false
    private(set) var lastPoolRefreshAt: Date?

    @ObservationIgnored private var usedItemIDs: Set<String> = []
    @ObservationIgnored private var usedPairIDs: Set<String> = []
    @ObservationIgnored private var undoStack: [Snapshot] = []

    init(languages: Set<String>) {
        profile = CuratedProfileDefinition(languages: Array(languages))
    }

    var answerCount: Int { profile.responseCount }
    var canUndo: Bool { !undoStack.isEmpty }
    var canFinish: Bool {
        answerCount >= Self.minimumAnswers
    }

    /// True when the system has enough signal diversity to produce a
    /// meaningful feed. Requires ≥3 distinct topics with evidence AND
    /// ≥2 editorial styles with evidence — not just a raw answer count.
    var isReady: Bool {
        guard answerCount >= Self.minimumAnswers else { return false }
        let answeredKeys = Set(profile.evidence
            .filter { $0.outcome != .skip && $0.outcome != .opened }
            .flatMap(\.affectedKeys))
        let topicKeys = answeredKeys.filter { $0.hasPrefix("topic:") }
        let editorialKeys = answeredKeys.filter { $0.hasPrefix("editorial:") }
        return topicKeys.count >= 3 && editorialKeys.count >= 2
    }

    /// Backward-compatible alias — existing code that checks targetAnswers
    /// now maps to the adaptive isReady check.
    var reachedTarget: Bool { isReady }
    var isComplete: Bool { answerCount >= Self.maximumAnswers }
    var progress: Double {
        if answerCount < Self.minimumAnswers {
            return Double(answerCount) / Double(Self.minimumAnswers) * 0.5
        }
        if isReady { return 1.0 }
        let remaining = Self.maximumAnswers - Self.minimumAnswers
        let past = answerCount - Self.minimumAnswers
        return 0.5 + 0.5 * Double(past) / Double(remaining)
    }

    func setLanguages(_ languages: Set<String>) {
        profile.languages = Array(languages).sorted()
    }

    func beginCandidateRefresh() {
        isRefreshingCandidates = true
    }

    func updateCandidates(_ incoming: [CuratedCandidate]) {
        isRefreshingCandidates = false
        lastPoolRefreshAt = .now
        let merged = Dictionary(
            (candidates + incoming).map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        // Preserve showcase-first ordering from makeCandidates. Incoming
        // items should already be sorted showcase-first; we only need to
        // maintain that priority when merging with existing candidates.
        let lang = profile.languages.first ?? "en"
        candidates = Array(merged.values).sorted {
            let aShowcase = CuratedPreferenceEngine.isOnboardingShowcase(url: $0.source.feedURL, language: lang)
            let bShowcase = CuratedPreferenceEngine.isOnboardingShowcase(url: $1.source.feedURL, language: lang)
            if aShowcase != bShowcase { return aShowcase }
            if $0.topic != $1.topic { return $0.topic.rawValue < $1.topic.rawValue }
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            return $0.item.publishedAt > $1.item.publishedAt
        }
        if currentPair == nil && !isComplete {
            chooseNextPair()
        }
    }

    func answer(_ outcome: CuratedChoiceOutcome) {
        guard let currentPair else { return }
        undoStack.append(Snapshot(
            profile: profile,
            usedItemIDs: usedItemIDs,
            usedPairIDs: usedPairIDs,
            pair: currentPair
        ))
        usedItemIDs.insert(currentPair.left.id)
        usedItemIDs.insert(currentPair.right.id)
        usedPairIDs.insert(currentPair.id)
        profile = CuratedPreferenceEngine.applying(
            outcome: outcome,
            pair: currentPair,
            to: profile
        )
        if isComplete {
            self.currentPair = nil
        } else {
            chooseNextPair()
        }
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        profile = snapshot.profile
        usedItemIDs = snapshot.usedItemIDs
        usedPairIDs = snapshot.usedPairIDs
        currentPair = snapshot.pair
    }

    func setDiscoveryLevel(_ value: Double) {
        profile.discoveryLevel = min(1, max(0, value))
    }

    func setLearningEnabled(_ enabled: Bool) {
        profile.learningEnabled = enabled
    }

    func setTopicWeight(_ topic: CuratedTopic, _ value: Double) {
        profile.weights[topic.featureKey] = min(3, max(-3, value))
    }

    func setEditorialWeight(_ style: CuratedEditorialStyle, _ value: Double) {
        profile.weights[style.featureKey] = min(3, max(-3, value))
    }

    private func chooseNextPair() {
        currentPair = CuratedPreferenceEngine.nextPair(
            candidates: candidates,
            profile: profile,
            usedItemIDs: usedItemIDs,
            usedPairIDs: usedPairIDs
        )
    }
}
