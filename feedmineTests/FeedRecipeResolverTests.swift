import XCTest
@testable import feedmine

final class FeedRecipeResolverTests: XCTestCase {
    func testRecipeWeightsBecomeProfileBaseline() {
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        recipe.topicPreferences = ["topic:technology-science": .more]

        let evidence = CuratedProfileDefinition(languages: ["en"])
        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        XCTAssertEqual(
            effective.weight(for: "topic:technology-science"),
            1.5,
            "Recipe 'more' should set weight to +1.5"
        )
    }

    func testEvidenceLayersOnTopOfRecipe() {
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        recipe.topicPreferences = ["topic:technology-science": .more]

        var evidence = CuratedProfileDefinition(languages: ["en"])
        evidence.weights["topic:technology-science"] = 0.5
        evidence.evidenceCounts["topic:technology-science"] = 2

        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        // Recipe baseline +1.5 + evidence +0.5 = +2.0, clamped to 3.0
        XCTAssertEqual(effective.weight(for: "topic:technology-science"), 2.0)
    }

    func testWeightClampedToRange() {
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        recipe.topicPreferences = ["topic:technology-science": .more]

        var evidence = CuratedProfileDefinition(languages: ["en"])
        evidence.weights["topic:technology-science"] = 2.0

        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        // +1.5 + 2.0 = 3.5, clamped to 3.0
        XCTAssertEqual(effective.weight(for: "topic:technology-science"), 3.0)
    }

    func testDiscoveryLevelFromRecipeWhenNoEvidence() {
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        recipe.discoveryLevel = 0.8

        let evidence = CuratedProfileDefinition(languages: ["en"])
        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        XCTAssertEqual(effective.discoveryLevel, 0.8)
    }

    func testLearningEnabledFromRecipe() {
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        recipe.adjustFromOpens = false

        let evidence = CuratedProfileDefinition(languages: ["en"])
        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        XCTAssertFalse(effective.learningEnabled)
    }

    func testMissingRecipeProducesEvidenceOnlyProfile() {
        let evidence = CuratedProfileDefinition(
            languages: ["en"],
            weights: ["topic:technology-science": 1.0],
            discoveryLevel: 0.6,
            learningEnabled: true
        )

        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: nil,
            evidence: evidence
        )

        XCTAssertEqual(effective.weight(for: "topic:technology-science"), 1.0)
        XCTAssertEqual(effective.discoveryLevel, 0.6)
        XCTAssertTrue(effective.learningEnabled)
    }

    func testEditorialPreferencesMapToFeatureKeys() {
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        recipe.editorialPreferences = [
            "editorial:reference": .more,
            "editorial:distinctive": .less,
        ]

        let evidence = CuratedProfileDefinition(languages: ["en"])
        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        XCTAssertEqual(effective.weight(for: "editorial:reference"), 1.5)
        XCTAssertEqual(effective.weight(for: "editorial:distinctive"), -1.5)
        XCTAssertEqual(effective.weight(for: "editorial:specialist"), 0)
    }
}
