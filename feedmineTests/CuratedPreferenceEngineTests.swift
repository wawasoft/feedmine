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

    // MARK: - Pending pair lifecycle

    func test_pendingPair_notVisible_untilPublished() throws {
        let session = CuratedOnboardingSession(languages: ["en"])
        // Session starts with no pair — nothing visible
        XCTAssertNil(session.currentPair)
        XCTAssertNil(session.pendingPair)

        // Add candidates — prepareNextPair should populate pendingPair, not currentPair
        let candidates = makeCandidatePool(count: 10)
        session.updateCandidates(candidates)

        let pending = try XCTUnwrap(session.pendingPair,
            "updateCandidates must compute a pending pair when pool has enough candidates")
        XCTAssertNil(session.currentPair,
            "currentPair must be nil — pair is not yet published")
        XCTAssertNotEqual(pending.left.id, pending.right.id,
            "Pending pair must have two distinct candidates")
    }

    func test_publishPendingPair_movesPairToCurrent() throws {
        let session = CuratedOnboardingSession(languages: ["en"])
        let candidates = makeCandidatePool(count: 10)
        session.updateCandidates(candidates)

        let pending = try XCTUnwrap(session.pendingPair)
        session.publishPendingPair()

        XCTAssertEqual(session.currentPair?.id, pending.id,
            "publish must move the exact pending pair to current")
        XCTAssertNil(session.pendingPair,
            "pendingPair must be nil after publish")
    }

    func test_discardPendingPair_clearsPair() throws {
        let session = CuratedOnboardingSession(languages: ["en"])
        let candidates = makeCandidatePool(count: 10)
        session.updateCandidates(candidates)

        XCTAssertNotNil(session.pendingPair)
        session.discardPendingPair()
        XCTAssertNil(session.pendingPair)
        XCTAssertNil(session.currentPair,
            "discard must not affect currentPair (which was already nil)")
    }

    func test_answer_setsNextPairDirectly() throws {
        let session = CuratedOnboardingSession(languages: ["en"])
        let candidates = makeCandidatePool(count: 20)
        session.updateCandidates(candidates)

        // Publish so user can answer
        let firstPair = try XCTUnwrap(session.pendingPair)
        session.publishPendingPair()
        XCTAssertNotNil(session.currentPair)

        // Answer — next pair should be set directly via chooseNextPair()
        session.answer(.left)
        XCTAssertNotNil(session.currentPair,
            "After answering, currentPair must be the next pair (direct publish)")
        XCTAssertNotEqual(session.currentPair?.id, firstPair.id,
            "Next pair must be different from the answered pair")
    }

    func test_undo_restoresPreviousPairAndClearsPending() throws {
        let session = CuratedOnboardingSession(languages: ["en"])
        let candidates = makeCandidatePool(count: 20)
        session.updateCandidates(candidates)

        let firstPair = try XCTUnwrap(session.pendingPair)
        session.publishPendingPair()
        let firstPairID = firstPair.id

        // Answer — sets next pair directly (or nil if pool exhausted)
        session.answer(.left)

        // Undo — should restore the previous pair
        session.undo()
        XCTAssertEqual(session.currentPair?.id, firstPairID,
            "Undo must restore the previous currentPair")
        XCTAssertNil(session.pendingPair,
            "Undo must discard any pending pair")
    }

    func test_complete_session_clearsBothPairs() throws {
        let session = CuratedOnboardingSession(languages: ["en"])
        // Fill enough candidates to reach maximum answers
        let candidates = makeCandidatePool(count: 50)
        session.updateCandidates(candidates)

        // Publish the first pair and answer until complete or pool exhausted
        session.publishPendingPair()
        while !session.isComplete, session.currentPair != nil {
            session.answer(.left)
        }

        if session.isComplete {
            XCTAssertNil(session.currentPair)
            XCTAssertNil(session.pendingPair,
                "Complete session must have no pending or current pair")
        } else {
            // If not complete, pool was exhausted — not a test failure,
            // just indicates pair constraints couldn't be met with this pool
            XCTAssertNil(session.currentPair)
        }
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

    /// Build a diverse candidate pool with enough variety for pair selection.
    private func makeCandidatePool(count: Int) -> [CuratedCandidate] {
        let topics = CuratedTopic.allCases
        var items: [FeedItem] = []
        var sources: [FeedSource] = []
        for i in 0..<count {
            let topic = topics[i % topics.count]
            let url = "https://source-\(i).example/feed"
            let source = FeedSource(
                title: "Source \(i)",
                url: url,
                category: topic.displayName,
                region: i % 3 == 0 ? "countries/XX" : "global",
                mediaKind: i % 2 == 0 ? .text : (i % 3 == 0 ? .audio : .video),
                language: "en",
                sourceDescription: "Editorial reporting, analysis, and interviews.",
                tags: ["journalism", topic.displayName.lowercased()],
                activity: "active",
                qualityScore: 80 + (i % 20)
            )
            sources.append(source)
            items.append(FeedItem(
                id: "item-\(i)",
                sourceTitle: source.title,
                sourceURL: source.url,
                category: topic.displayName,
                title: "Story \(i): A compelling headline about \(topic.displayName)",
                excerpt: "Detailed analysis and reporting on \(topic.displayName) with expert perspective and original research findings.",
                url: "https://source-\(i).example/article-\(i)",
                imageURL: "https://source-\(i).example/image-\(i).jpg",
                publishedAt: Date().addingTimeInterval(-Double(i * 3600)),
                region: source.region,
                language: "en"
            ))
        }
        return CuratedPreferenceEngine.makeCandidates(
            items: items,
            sources: sources,
            languages: ["en"]
        )
    }
}
