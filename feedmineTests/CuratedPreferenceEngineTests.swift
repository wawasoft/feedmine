import XCTest
@testable import feedmine

@MainActor
final class CuratedPreferenceEngineTests: XCTestCase {
    func testProfileStartsWithoutIdentityOrDemographicInference() {
        let profile = CuratedProfileDefinition(languages: ["en", "pt-BR"])

        XCTAssertEqual(profile.languages, ["en", "pt"])
        XCTAssertTrue(profile.weights.isEmpty)
        XCTAssertTrue(profile.evidenceCounts.isEmpty)
        XCTAssertTrue(profile.evidence.isEmpty)
    }

    func testChoosingOneStoryUpdatesOnlyVisibleContentAttributes() throws {
        let left = candidate(
            id: "tech",
            topic: .technologyScience,
            sourceURL: "https://tech.example/feed"
        )
        let right = candidate(
            id: "culture",
            topic: .artsCulture,
            sourceURL: "https://culture.example/feed"
        )
        let pair = CuratedComparisonPair(
            left: left,
            right: right,
            distinguishingKeys: [
                CuratedTopic.technologyScience.featureKey,
                CuratedTopic.artsCulture.featureKey,
            ]
        )

        let updated = CuratedPreferenceEngine.applying(
            outcome: .left,
            pair: pair,
            to: CuratedProfileDefinition(languages: ["en"])
        )

        XCTAssertGreaterThan(
            updated.weight(for: CuratedTopic.technologyScience.featureKey),
            0
        )
        XCTAssertLessThan(
            updated.weight(for: CuratedTopic.artsCulture.featureKey),
            0
        )
        XCTAssertEqual(updated.responseCount, 1)
        XCTAssertEqual(updated.evidence.first?.leftTitle, left.item.title)
        XCTAssertFalse(updated.weights.keys.contains { $0.contains("identity") })
        XCTAssertEqual(updated.weight(for: "media:text"), 0)
        XCTAssertEqual(updated.weight(for: "region:global"), 0)
    }

    func testRegionalPreferenceIsLearnedOnlyWhenItDistinguishesTheStories() {
        let regionalSource = FeedSource(
            title: "Regional Source",
            url: "https://regional.example/feed",
            category: CuratedTopic.newsCurrentAffairs.displayName,
            region: "countries/brazil",
            language: "en",
            qualityScore: 90
        )
        let regional = CuratedCandidate(
            item: feedItem(
                id: "regional",
                topic: .newsCurrentAffairs,
                sourceURL: regionalSource.url
            ),
            source: SourceReference(source: regionalSource),
            topic: .newsCurrentAffairs,
            featureKeys: CuratedPreferenceEngine.featureKeys(
                for: regionalSource,
                topic: .newsCurrentAffairs
            ),
            quality: 0.9,
            contentLanguage: "en"
        )
        let global = candidate(
            id: "global",
            topic: .newsCurrentAffairs,
            sourceURL: "https://global.example/feed"
        )
        let updated = CuratedPreferenceEngine.applying(
            outcome: .left,
            pair: CuratedComparisonPair(
                left: regional,
                right: global,
                distinguishingKeys: ["scope:regional", "scope:global"]
            ),
            to: CuratedProfileDefinition(languages: ["en"])
        )

        XCTAssertGreaterThan(updated.weight(for: "scope:regional"), 0)
        XCTAssertLessThan(updated.weight(for: "scope:global"), 0)
        XCTAssertEqual(
            updated.weight(for: CuratedTopic.newsCurrentAffairs.featureKey),
            0,
            "A shared topic must not be mistaken for the reason behind the choice"
        )
    }

    func testBothChoiceIncreasesDiscoveryAndBothTopics() {
        let pair = CuratedComparisonPair(
            left: candidate(
                id: "sport",
                topic: .sports,
                sourceURL: "https://sport.example/feed"
            ),
            right: candidate(
                id: "food",
                topic: .foodDrink,
                sourceURL: "https://food.example/feed"
            ),
            distinguishingKeys: [
                CuratedTopic.sports.featureKey,
                CuratedTopic.foodDrink.featureKey,
            ]
        )
        let original = CuratedProfileDefinition(
            languages: ["en"],
            discoveryLevel: 0.4
        )

        let updated = CuratedPreferenceEngine.applying(
            outcome: .both,
            pair: pair,
            to: original
        )

        XCTAssertGreaterThan(updated.discoveryLevel, original.discoveryLevel)
        XCTAssertGreaterThan(updated.weight(for: CuratedTopic.sports.featureKey), 0)
        XCTAssertGreaterThan(updated.weight(for: CuratedTopic.foodDrink.featureKey), 0)
    }

    func testExplicitOpenLearnsWeaklyButDoesNotCountAsOnboardingAnswer() {
        let source = source(
            topic: .technologyScience,
            url: "https://science.example/feed"
        )
        let item = feedItem(
            id: "opened",
            topic: .technologyScience,
            sourceURL: source.url
        )

        let updated = CuratedPreferenceEngine.applyingExplicitOpen(
            item: item,
            source: source,
            to: CuratedProfileDefinition(languages: ["en"])
        )

        XCTAssertEqual(updated.responseCount, 0)
        XCTAssertEqual(updated.evidence.last?.outcome, .opened)
        XCTAssertGreaterThan(
            updated.weight(for: CuratedTopic.technologyScience.featureKey),
            0
        )
    }

    func testDisabledLearningIgnoresExplicitOpen() {
        let source = source(
            topic: .sports,
            url: "https://sports.example/feed"
        )
        let profile = CuratedProfileDefinition(
            languages: ["en"],
            learningEnabled: false
        )

        let updated = CuratedPreferenceEngine.applyingExplicitOpen(
            item: feedItem(id: "ignored", topic: .sports, sourceURL: source.url),
            source: source,
            to: profile
        )

        XCTAssertEqual(updated, profile)
    }

    func testAdaptivePairIsLanguageMatchedAndTopicDistinctAtStart() throws {
        let candidates = [
            candidate(id: "one", topic: .technologyScience, sourceURL: "https://1.example/feed"),
            candidate(id: "two", topic: .artsCulture, sourceURL: "https://2.example/feed"),
            candidate(id: "three", topic: .sports, sourceURL: "https://3.example/feed"),
            candidate(id: "four", topic: .foodDrink, sourceURL: "https://4.example/feed"),
        ]

        let pair = try XCTUnwrap(CuratedPreferenceEngine.nextPair(
            candidates: candidates,
            profile: CuratedProfileDefinition(languages: ["en"]),
            usedItemIDs: [],
            usedPairIDs: []
        ))

        XCTAssertEqual(pair.left.language, pair.right.language)
        XCTAssertNotEqual(pair.left.topic, pair.right.topic)
    }

    func testEditorialPreferenceIsLearnedAsContentAttribute() {
        let reference = candidate(
            id: "reference",
            topic: .technologyScience,
            sourceURL: "https://reference.example/feed",
            editorial: CuratedEditorialAssessment(
                style: .reference,
                isRecognized: true,
                isSpecialist: false,
                score: 0.95,
                reason: "Reference",
                isEligible: true
            )
        )
        let specialist = candidate(
            id: "specialist",
            topic: .technologyScience,
            sourceURL: "https://specialist.example/feed",
            editorial: CuratedEditorialAssessment(
                style: .specialist,
                isRecognized: false,
                isSpecialist: true,
                score: 0.94,
                reason: "Specialist",
                isEligible: true
            )
        )
        let updated = CuratedPreferenceEngine.applying(
            outcome: .left,
            pair: CuratedComparisonPair(
                left: reference,
                right: specialist,
                distinguishingKeys: [
                    CuratedEditorialStyle.reference.featureKey,
                    CuratedEditorialStyle.specialist.featureKey,
                ]
            ),
            to: CuratedProfileDefinition(languages: ["en"])
        )

        XCTAssertGreaterThan(
            updated.weight(for: CuratedEditorialStyle.reference.featureKey),
            0
        )
        XCTAssertLessThan(
            updated.weight(for: CuratedEditorialStyle.specialist.featureKey),
            0
        )
        XCTAssertEqual(
            updated.weight(for: CuratedTopic.technologyScience.featureKey),
            0
        )
    }

    func testTechnicalActivityScoreCannotAdmitPromotionalSource() {
        let source = FeedSource(
            title: "Fast Product Updates",
            url: "https://vendor.example/feed",
            category: CuratedTopic.technologyScience.displayName,
            region: "global",
            language: "en",
            sourceDescription: "A prolific distributor publishing product promotion and sales offers.",
            tags: ["technology", "product promotion"],
            nature: "current-sensitive",
            activity: "prolific",
            qualityScore: 100
        )

        let candidates = CuratedPreferenceEngine.makeCandidates(
            items: [feedItem(
                id: "commercial",
                topic: .technologyScience,
                sourceURL: source.url
            )],
            sources: [source],
            languages: ["en"]
        )

        XCTAssertTrue(candidates.isEmpty)
        XCTAssertFalse(
            CuratedPreferenceEngine.editorialAssessment(for: source).isEligible
        )
    }

    func testRecognizedReferenceClearsEditorialGate() throws {
        let source = FeedSource(
            title: "Associated Press",
            url: "https://apnews.com/feed",
            category: CuratedTopic.newsCurrentAffairs.displayName,
            region: "global",
            language: "en",
            sourceDescription: "Independent reporting and global news coverage.",
            tags: ["news", "reporting"],
            nature: "current-sensitive",
            activity: "active",
            qualityScore: 84
        )
        let candidates = CuratedPreferenceEngine.makeCandidates(
            items: [feedItem(
                id: "reference-story",
                topic: .newsCurrentAffairs,
                sourceURL: source.url
            )],
            sources: [source],
            languages: ["en"]
        )

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.editorial.style, .reference)
        XCTAssertTrue(candidate.editorial.isEligible)
    }

    func testShowcaseSourceOrderIsDeterministic() {
        let sources = [
            editorialSource("Associated Press", "https://apnews.com/feed", .newsCurrentAffairs, 86),
            editorialSource("Reuters", "https://reuters.com/feed", .businessIndustry, 90),
            editorialSource("University Research Review", "https://example.edu/feed", .educationKnowledge, 88),
            editorialSource("Distinctive Culture Magazine", "https://culture.example/feed", .artsCulture, 92),
        ]

        let first = CuratedPreferenceEngine.showcaseSources(from: sources, limit: 4)
        let second = CuratedPreferenceEngine.showcaseSources(from: sources, limit: 4)

        XCTAssertEqual(first.map(\.url), second.map(\.url))
        XCTAssertEqual(Set(first.map(\.url)).count, first.count)
    }

    func testConfidentContentLanguageOverridesIncorrectSourceMetadata() {
        let source = FeedSource(
            title: "Mislabelled Source",
            url: "https://mislabelled.example/feed",
            category: CuratedTopic.artsCulture.displayName,
            region: "global",
            language: "en",
            sourceDescription: "A culture magazine publishing stories, reviews, and interviews.",
            tags: ["culture", "magazine", "reviews"],
            activity: "prolific",
            qualityScore: 90
        )
        let arabicItem = FeedItem(
            id: "arabic",
            sourceTitle: source.title,
            sourceURL: source.url,
            category: source.category,
            title: "الفنون والثقافة في المدينة تتغير مع جيل جديد من المبدعين",
            excerpt: "يستكشف هذا التقرير المشهد الثقافي المعاصر وأعمال الفنانين الشباب وتأثيرها في المجتمع المحلي.",
            url: "https://mislabelled.example/arabic",
            imageURL: "https://mislabelled.example/image.jpg",
            publishedAt: .now,
            region: "global",
            language: "en"
        )

        let candidates = CuratedPreferenceEngine.makeCandidates(
            items: [arabicItem],
            sources: [source],
            languages: ["en"]
        )

        XCTAssertTrue(
            candidates.isEmpty,
            "A confident content-language mismatch must not enter the selected language pool"
        )
    }

    func testCuratedFeedPersistsRoundTrip() async throws {
        let userState = try UserStateStore(inMemory: true)
        let store = CuratedFeedStore(db: userState.db)
        let definition = CuratedProfileDefinition(
            languages: ["en", "pt"],
            weights: [CuratedTopic.musicAudio.featureKey: 1.25],
            discoveryLevel: 0.68
        )

        let id = try await store.create(name: "Open Mix", definition: definition)
        let saved = try await store.curatedFeed(id: id)

        XCTAssertEqual(saved?.name, "Open Mix")
        XCTAssertEqual(saved?.definition, definition)
    }

    private func candidate(
        id: String,
        topic: CuratedTopic,
        sourceURL: String,
        editorial: CuratedEditorialAssessment? = nil
    ) -> CuratedCandidate {
        let feedSource = source(topic: topic, url: sourceURL)
        var features = CuratedPreferenceEngine.featureKeys(
            for: feedSource,
            topic: topic
        )
        if editorial != nil {
            features = features.filter { !$0.hasPrefix("editorial:") }
        }
        return CuratedCandidate(
            item: feedItem(id: id, topic: topic, sourceURL: sourceURL),
            source: SourceReference(source: feedSource),
            topic: topic,
            featureKeys: features,
            quality: 0.9,
            contentLanguage: "en",
            editorial: editorial
        )
    }

    private func editorialSource(
        _ title: String,
        _ url: String,
        _ topic: CuratedTopic,
        _ quality: Int
    ) -> FeedSource {
        FeedSource(
            title: title,
            url: url,
            category: topic.displayName,
            region: "global",
            language: "en",
            sourceDescription: "Editorial reporting, analysis, research, and interviews.",
            tags: ["journalism", "analysis", "research"],
            nature: "current-sensitive",
            activity: "active",
            qualityScore: quality
        )
    }

    private func source(topic: CuratedTopic, url: String) -> FeedSource {
        FeedSource(
            title: "\(topic.displayName) Source",
            url: url,
            category: topic.displayName,
            region: "global",
            mediaKind: .text,
            language: "en",
            qualityScore: 90
        )
    }

    private func feedItem(
        id: String,
        topic: CuratedTopic,
        sourceURL: String
    ) -> FeedItem {
        FeedItem(
            id: id,
            sourceTitle: "\(topic.displayName) Source",
            sourceURL: sourceURL,
            category: topic.displayName,
            title: "A substantial real story about \(topic.displayName)",
            excerpt: "Enough context for a fair choice.",
            url: "https://example.com/\(id)",
            imageURL: "https://example.com/\(id).jpg",
            publishedAt: .now,
            region: "global",
            language: "en"
        )
    }
}
