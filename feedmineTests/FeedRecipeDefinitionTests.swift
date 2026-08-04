import XCTest
@testable import feedmine

final class FeedRecipeDefinitionTests: XCTestCase {
    func testNeutralRecipeHasNoTopicBias() {
        let recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        XCTAssertTrue(recipe.topicPreferences.isEmpty)
        XCTAssertTrue(recipe.editorialPreferences.isEmpty)
        XCTAssertEqual(recipe.discoveryLevel, 0.55)
        XCTAssertFalse(recipe.adjustFromOpens)
    }

    func testNeutralRecipeIncludesDefaultMediaTypes() {
        let recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        XCTAssertEqual(recipe.mediaTypes, [.article, .podcast, .video])
    }

    func testEmptyMediaTypesFallBackToDefaults() {
        let recipe = FeedRecipeDefinition(languages: ["en"], mediaTypes: [])
        XCTAssertEqual(recipe.mediaTypes, [.article, .podcast, .video])
    }

    func testDiscoveryLevelClamped() {
        let low = FeedRecipeDefinition(languages: ["en"], discoveryLevel: -0.5)
        XCTAssertEqual(low.discoveryLevel, 0.0)
        let high = FeedRecipeDefinition(languages: ["en"], discoveryLevel: 1.5)
        XCTAssertEqual(high.discoveryLevel, 1.0)
    }

    func testLanguagesNormalizedToRootCodes() {
        let recipe = FeedRecipeDefinition(languages: ["en-US", "pt-BR", "en-GB"])
        XCTAssertEqual(recipe.languages, ["en", "pt"])
    }

    func testPreferenceLevelCycle() {
        XCTAssertEqual(PreferenceLevel.neutral.next(), .more)
        XCTAssertEqual(PreferenceLevel.more.next(), .less)
        XCTAssertEqual(PreferenceLevel.less.next(), .neutral)
    }

    func testPreferenceLevelProfileWeight() {
        XCTAssertEqual(PreferenceLevel.less.profileWeight, -1.5)
        XCTAssertEqual(PreferenceLevel.neutral.profileWeight, 0)
        XCTAssertEqual(PreferenceLevel.more.profileWeight, 1.5)
    }

    func testRoundTripJSON() throws {
        let recipe = FeedRecipeDefinition(
            languages: ["en", "pt"],
            discoveryLevel: 0.7,
            topicPreferences: ["topic:technology-science": .more],
            editorialPreferences: ["editorial:specialist": .more]
        )
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(FeedRecipeDefinition.self, from: data)
        XCTAssertEqual(decoded.languages, recipe.languages)
        XCTAssertEqual(decoded.discoveryLevel, recipe.discoveryLevel)
        XCTAssertEqual(decoded.topicPreferences, recipe.topicPreferences)
    }
}
