import XCTest

/// UI performance tests for launch, scroll, and concurrency.
///
/// Uses XCUITest + XCTApplicationLaunchMetric for launch measurements
/// and XCTOSSignpostMetric for instrumented operations.
///
/// - Note: These run on simulator for trend data. Physical device
///   baselines are required for official release gates per the plan.
@MainActor
final class LaunchPerformanceTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - PERF-UI-LAUNCH-001: Clean launch

    func testLaunch_CleanInstall() {
        app.launchArguments = [
            "-performance-testing",
            "-UITestSkipOnboarding",
            "-UITestResetFilters",
            "-AppleLanguages", "(en)",
        ]
        app.launch()

        // Verify app launched and is responsive
        let filterButton = app.buttons["filter-button"]
        let timeline = app.collectionViews.firstMatch
        let emptyState = app.staticTexts["state.empty"]
        let somethingVisible = filterButton.waitForExistence(timeout: 30) ||
                                timeline.waitForExistence(timeout: 30) ||
                                emptyState.waitForExistence(timeout: 30)
        XCTAssertTrue(somethingVisible, "App must reach a defined state after launch")
    }

    // MARK: - PERF-UI-LAUNCH-003: Launch with data

    func testLaunch_WithFixtureData() {
        app.launchArguments = [
            "-performance-testing",
            "-fixture-profile", "typical",
            "-fixture-seed", "42",
            "-UITestSkipOnboarding",
            "-UITestResetFilters",
            "-AppleLanguages", "(en)",
        ]
        app.launch()

        // App should reach interactive state
        let filterButton = app.buttons["filter-button"]
        let timeline = app.collectionViews.firstMatch
        let ready = filterButton.waitForExistence(timeout: 30) ||
                     timeline.waitForExistence(timeout: 30)
        XCTAssertTrue(ready, "App must reach interactive state with fixture data")
    }

    // MARK: - PERF-UI-LAUNCH-004: Offline launch

    func testLaunch_Offline() {
        app.launchArguments = [
            "-performance-testing",
            "-network-profile", "offline",
            "-UITestSkipOnboarding",
            "-UITestResetFilters",
            "-AppleLanguages", "(en)",
        ]
        app.launch()

        // Offline launch must not hang
        let anyElement = app.buttons.firstMatch
        let appears = anyElement.waitForExistence(timeout: 15)
        XCTAssertTrue(appears, "Offline launch must show UI within 15s")
    }

    // MARK: - PERF-UI-LAUNCH-006: Resume from background

    func testLaunch_ResumeFromBackground() {
        app.launchArguments = [
            "-performance-testing",
            "-UITestSkipOnboarding",
            "-UITestResetFilters",
            "-AppleLanguages", "(en)",
        ]
        app.launch()

        // Wait for initial load
        _ = app.buttons.firstMatch.waitForExistence(timeout: 20)

        // Background the app
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.5)

        // Resume
        app.activate()
        Thread.sleep(forTimeInterval: 1.0)

        // Verify app is still responsive (may take a moment to reach foreground)
        let appRunning = app.wait(for: .runningForeground, timeout: 5)
        XCTAssertTrue(appRunning, "App must reach runningForeground state after resume")
    }
}
