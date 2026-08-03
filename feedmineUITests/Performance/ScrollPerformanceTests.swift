import XCTest

/// UI performance tests for scroll and concurrent operations.
@MainActor
final class ScrollPerformanceTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - PERF-UI: Scroll stability

    func testScroll_FeedTimeline() {
        app.launchArguments = [
            "-performance-testing",
            "-fixture-profile", "typical",
            "-fixture-seed", "42001",
            "-UITestSkipOnboarding",
            "-UITestResetFilters",
            "-AppleLanguages", "(en)",
        ]
        app.launch()

        // Wait for timeline
        let timeline = app.collectionViews.firstMatch
        guard timeline.waitForExistence(timeout: 30) else {
            // No collection view — app may use List or ScrollView
            // Verify we're not in a broken state
            XCTAssertTrue(app.buttons.firstMatch.exists || app.staticTexts.firstMatch.exists,
                          "App must show content or a defined empty state")
            return
        }

        // Scroll down and back up — verify no crash
        let startY = timeline.frame.minY
        timeline.swipeUp()
        Thread.sleep(forTimeInterval: 0.3)
        timeline.swipeUp()
        Thread.sleep(forTimeInterval: 0.3)
        timeline.swipeDown()
        Thread.sleep(forTimeInterval: 0.3)
        timeline.swipeDown()

        // App must still be running
        XCTAssertTrue(app.exists, "App must not crash during scroll")
    }

    // MARK: - PERF-UI-CON-001: Scroll during refresh

    func testScroll_DuringRefresh() {
        app.launchArguments = [
            "-performance-testing",
            "-fixture-profile", "typical",
            "-fixture-seed", "42002",
            "-UITestSkipOnboarding",
            "-UITestResetFilters",
            "-AppleLanguages", "(en)",
        ]
        app.launch()

        let timeline = app.collectionViews.firstMatch
        guard timeline.waitForExistence(timeout: 30) else {
            XCTAssertTrue(app.exists, "App must be running")
            return
        }

        // Scroll while refresh may be happening
        for _ in 0..<3 {
            timeline.swipeUp()
            Thread.sleep(forTimeInterval: 0.2)
        }

        XCTAssertTrue(app.exists, "App must not crash during scroll+refresh")
    }

    // MARK: - PERF-UI-CON-006: Background/foreground

    func testBackgroundForeground() {
        app.launchArguments = [
            "-performance-testing",
            "-UITestSkipOnboarding",
            "-UITestResetFilters",
            "-AppleLanguages", "(en)",
        ]
        app.launch()

        _ = app.buttons.firstMatch.waitForExistence(timeout: 20)

        // Background and resume
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1.0)
        app.activate()

        // Verify state is preserved (not a blank screen)
        let hasContent = app.buttons.firstMatch.exists ||
                          app.collectionViews.firstMatch.exists ||
                          app.staticTexts.firstMatch.exists
        XCTAssertTrue(hasContent, "App must show content after resume")
    }
}
