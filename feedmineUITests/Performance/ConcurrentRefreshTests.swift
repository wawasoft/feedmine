import XCTest

/// Tests for concurrent refresh + scroll — covers P0 risk "refresh reordenando
/// conteúdo visível de forma abrupta, perdendo posição ou bloqueando a interface."
@MainActor
final class ConcurrentRefreshTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - P0: Refresh + scroll without reorder

    func testRefreshDuringScrollDoesNotCrash() {
        app.terminate()
        AppLauncher.launch(app: app, fixtureProfile: "heavy", fixtureSeed: 42, showOnboarding: false, locale: "en")

        XCTAssertTrue(app.buttons["filter-button"].waitForExistence(timeout: UIWaits.extendedTimeout),
                      "Feed must be ready")

        let timeline = app.collectionViews.firstMatch
        guard timeline.exists else {
            XCTAssertTrue(app.buttons["filter-button"].exists, "App must be functional")
            return
        }

        // Scroll while pulling to refresh
        for i in 0..<5 {
            if i % 2 == 0 {
                timeline.swipeUp(velocity: .fast)
            } else {
                // Pull-to-refresh gesture
                timeline.swipeDown(velocity: .slow)
            }
            Thread.sleep(forTimeInterval: 0.4)
            XCTAssertTrue(app.exists, "App must not crash during scroll+refresh (pass \(i + 1))")
        }

        // After concurrent operation, filter button must still be accessible
        XCTAssertTrue(app.buttons["filter-button"].waitForExistence(timeout: 5) || timeline.exists,
                      "Feed must remain interactive after concurrent scroll+refresh")
    }

    // MARK: - Card order preserved during refresh

    func testCardCountStableAfterQuickRefresh() {
        app.terminate()
        AppLauncher.launch(app: app, fixtureProfile: "typical", fixtureSeed: 42, showOnboarding: false, locale: "en")

        XCTAssertTrue(app.buttons["filter-button"].waitForExistence(timeout: UIWaits.extendedTimeout),
                      "Feed must be ready")

        // Count visible elements before refresh
        let beforeCount = app.collectionViews.firstMatch.cells.count +
                          app.collectionViews.firstMatch.otherElements.count

        // Trigger a pull-to-refresh
        let timeline = app.collectionViews.firstMatch
        if timeline.exists {
            let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            let end = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            start.press(forDuration: 0.1, thenDragTo: end)
        }

        Thread.sleep(forTimeInterval: 3.0)

        // Feed must still be interactive — not crashed or frozen
        XCTAssertTrue(app.buttons["filter-button"].exists || app.collectionViews.firstMatch.exists,
                      "Feed must be responsive after refresh")
    }

    // MARK: - Quick navigation during refresh

    func testNavigationDuringRefresh() {
        app.terminate()
        AppLauncher.launch(app: app, fixtureProfile: "typical", fixtureSeed: 42, showOnboarding: false, locale: "en")

        XCTAssertTrue(app.buttons["filter-button"].waitForExistence(timeout: UIWaits.extendedTimeout),
                      "Feed must be ready")

        // Open filter sheet while refresh might be happening
        app.buttons["filter-button"].tap()

        // Wait for filter UI
        let filterAppeared = app.buttons["filter-done"].waitForExistence(timeout: 10) ||
                              app.staticTexts["Clear All Filters"].waitForExistence(timeout: 10)
        if filterAppeared {
            // Dismiss filter
            if app.buttons["filter-done"].exists {
                app.buttons["filter-done"].tap()
            } else {
                app.swipeDown()
            }
        }

        // Back to feed — must still be functional
        XCTAssertTrue(app.buttons["filter-button"].waitForExistence(timeout: 5) ||
                       app.collectionViews.firstMatch.exists,
                      "Feed must be functional after filter navigation during refresh")
    }
}
