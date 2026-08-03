import XCTest
@testable import feedmine

/// Verifies that the Phase 1 testability infrastructure compiles and
/// functions correctly: TestConfiguration parsing, signpost intervals,
/// ScreenID accessibility identifier conventions, and deterministic fixtures.
@MainActor
final class TestInfrastructureValidationTests: XCTestCase {

    // MARK: - TestConfiguration

    func testProductionConfigurationHasAllDefaultsDisabled() {
        let config = TestConfiguration.production
        XCTAssertFalse(config.isUITesting)
        XCTAssertFalse(config.isPerformanceTesting)
        XCTAssertNil(config.fixtureProfile)
        XCTAssertNil(config.fixtureSeed)
        XCTAssertFalse(config.resetTestState)
        XCTAssertFalse(config.skipOnboarding)
        XCTAssertFalse(config.showOnboarding)
    }

    func testParseUITestingArguments() {
        let config = TestConfiguration.parse(args: [
            "-ui-testing",
            "-fixture-profile", "typical",
            "-fixture-seed", "42",
            "-UITestSkipOnboarding",
            "-UITestResetFilters",
            "-AppleLanguages", "(pt-BR)",
        ])

        XCTAssertTrue(config.isUITesting)
        XCTAssertEqual(config.fixtureProfile, "typical")
        XCTAssertEqual(config.fixtureSeed, 42)
        XCTAssertTrue(config.skipOnboarding)
        XCTAssertTrue(config.resetFilters)
        XCTAssertEqual(config.appleLanguages, "pt-BR")
    }

    func testParsePerformanceTestingArguments() {
        let config = TestConfiguration.parse(args: [
            "-performance-testing",
            "-fixture-profile", "heavy",
            "-fixture-seed", "42001",
            "-fixed-theme", "afternoon",
        ])

        XCTAssertTrue(config.isPerformanceTesting)
        XCTAssertEqual(config.fixtureProfile, "heavy")
        XCTAssertEqual(config.fixtureSeed, 42001)
        XCTAssertEqual(config.fixedTheme, "afternoon")
    }

    func testParseNetworkProfiles() {
        for profile in ["offline", "fast", "slow", "timeout", "partial-failure"] {
            let config = TestConfiguration.parse(args: [
                "-network-profile", profile,
            ])
            XCTAssertEqual(config.networkProfile, profile)
        }
    }

    func testParseFixedDate() {
        let config = TestConfiguration.parse(args: [
            "-fixed-date", "2026-08-01T12:00:00Z",
        ])
        XCTAssertNotNil(config.fixedDate)
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: config.fixedDate!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 12)
    }

    func testParseUITestingLegacyArgsBackwardCompatible() {
        // Legacy arguments from existing tests must still work
        let config = TestConfiguration.parse(args: [
            "-UITestResetFilters",
            "-UITestSkipOnboarding",
            "-AppleLanguages", "(en)",
        ])
        XCTAssertTrue(config.isUITesting)
        XCTAssertTrue(config.skipOnboarding)
        XCTAssertTrue(config.resetFilters)
    }

    // MARK: - Signposts

    func testAllSignpostIntervalsHaveValidNames() {
        for interval in FeedMineSignposts.Interval.allCases {
            let name = interval.name
            XCTAssertFalse(name.description.isEmpty, "Interval \(interval) has empty name")
        }
    }

    func testSignpostBeginEndBalanced() {
        let state = FeedMineSignposts.begin(.catalogSearch)
        FeedMineSignposts.end(.catalogSearch, state: state)
        // No crash = signpost API is sound
    }

    func testSignpostMeasureBlock() {
        let result = FeedMineSignposts.measure(.feedParse) { 42 }
        XCTAssertEqual(result, 42)
    }

    func testSignpostMeasureAsyncBlock() async {
        let result = await FeedMineSignposts.measure(.timelineQuery) { @Sendable in
            try? await Task.sleep(nanoseconds: 1_000)
            return "done"
        }
        XCTAssertEqual(result, "done")
    }

    // NOTE: ScreenID identifier convention tests live in the UITest target
    // (feedmineUITests) since ScreenID is defined in the UI test support module.
    // The ScreenID values are validated there via ScreenObjectsTests.

    // MARK: - Deterministic fixtures

    func testMakeFixtureItemsDeterministic() {
        let a = makeFixtureItems(count: 100, seed: 42)
        let b = makeFixtureItems(count: 100, seed: 42)
        XCTAssertEqual(a.count, 100)
        XCTAssertEqual(b.count, 100)
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        XCTAssertEqual(a.map(\.title), b.map(\.title))
    }

    func testMakeFixtureItemsDifferentSeedsDiverge() {
        let a = makeFixtureItems(count: 50, seed: 42)
        let b = makeFixtureItems(count: 50, seed: 99)
        XCTAssertNotEqual(a.map(\.id), b.map(\.id))
    }

    // MARK: - PRNG determinism

    func testXoshiroDeterminism() {
        var rng1 = Xoshiro256Plus(seed: 12345)
        var rng2 = Xoshiro256Plus(seed: 12345)
        for _ in 0..<100 {
            XCTAssertEqual(rng1.next(), rng2.next(), "Same seed → same sequence")
        }
    }
}
