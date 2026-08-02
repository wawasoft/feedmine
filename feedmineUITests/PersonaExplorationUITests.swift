import Foundation
import XCTest

/// Captures screenshots of every major screen/state in Feedmine for persona agents to analyze.
/// This test does NOT assert — it navigates broadly and saves evidence.
@MainActor
final class PersonaExplorationUITests: XCTestCase {

    let app = XCUIApplication()
    var screenshotDir: String = "/tmp/feedmine-persona-screenshots"

    override func setUp() {
        continueAfterFailure = true
        // Ensure clean state — no onboarding, fresh filters
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-UITestResetFilters", "-UITestSkipOnboarding",
        ]
        app.launch()
        try? FileManager.default.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true, attributes: nil)
    }

    // MARK: - Main Screenshot Harness

    func testCaptureAllScreens() {
        waitForAppReady()

        // 1. Main Feed (default view)
        capture("01-main-feed")

        // 2. Scroll feed to see more cards
        app.swipeUp()
        sleep(1)
        app.swipeUp()
        sleep(1)
        capture("02-main-feed-scrolled")

        // 3. Tap first article to open reader
        let firstCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
            .firstMatch
        if firstCard.waitForExistence(timeout: 10) {
            firstCard.tap()
            sleep(3)
            capture("03-article-reader")
            // Swipe article content
            app.swipeUp()
            sleep(1)
            capture("04-article-scrolled")
            // Go back
            app.buttons.firstMatch.tap()
            sleep(2)
        }

        // 4. Filter Sheet
        let filterButton = app.buttons["filter-button"]
        if filterButton.exists {
            filterButton.tap()
            sleep(2)
            capture("05-filter-sheet")
            app.swipeUp()
            sleep(1)
            capture("06-filter-sheet-scrolled")
            app.buttons["filter-done"].tap()
            sleep(1)
        }

        // 5. Search
        let searchButton = app.buttons["search-button"]
        if searchButton.exists {
            searchButton.tap()
            sleep(2)
            capture("07-search-screen")
            let field = app.textFields["unified-search-field"]
            if field.waitForExistence(timeout: 5) {
                field.tap()
                field.typeText("science")
                sleep(2)
                capture("08-search-results")
            }
            // Dismiss search
            app.buttons.firstMatch.tap()
            sleep(1)
        }

        // 6. More menu
        let moreMenu = app.buttons["more-menu"]
        if moreMenu.exists {
            moreMenu.tap()
            sleep(2)
            capture("09-more-menu")
            app.swipeUp()
            sleep(1)
            capture("10-more-menu-scrolled")
            // Dismiss
            let doneBtn = app.buttons["done-button"]
            if doneBtn.exists { doneBtn.tap() }
            else { moreMenu.tap() }
            sleep(1)
        }

        // 7. Settings
        if moreMenu.exists {
            moreMenu.tap()
            sleep(1)
            let settingsBtn = app.buttons["Settings"]
            if !settingsBtn.exists { app.swipeUp(); sleep(1) }
            if settingsBtn.exists {
                settingsBtn.tap()
                sleep(2)
                capture("11-settings")
                app.swipeUp()
                sleep(1)
                capture("12-settings-scrolled")
                app.buttons.firstMatch.tap()
                sleep(1)
            } else {
                // Dismiss more menu
                app.buttons.firstMatch.tap()
            }
        }

        // 8. Add Feed
        if moreMenu.exists {
            moreMenu.tap()
            sleep(1)
            let addFeedBtn = app.buttons["Add Feed"]
            if !addFeedBtn.exists { app.swipeUp(); sleep(1) }
            if addFeedBtn.exists {
                addFeedBtn.tap()
                sleep(2)
                capture("13-add-feed")
                app.buttons.firstMatch.tap()
                sleep(1)
            } else {
                app.buttons.firstMatch.tap()
            }
        }

        // 9. Browse Topics via filter
        if filterButton.exists {
            filterButton.tap()
            sleep(1)
            let browsePred = NSPredicate(format: "label CONTAINS[c] %@", "Browse Topics")
            for _ in 0..<6 {
                let btn = app.buttons.element(matching: browsePred)
                let text = app.staticTexts.element(matching: browsePred)
                if btn.exists { btn.tap(); break }
                else if text.exists { text.tap(); break }
                app.swipeUp()
                usleep(300_000)
            }
            sleep(2)
            capture("14-browse-topics")
            app.swipeUp()
            sleep(1)
            capture("15-topics-scrolled")
            // Dismiss
            app.buttons.firstMatch.tap()
            sleep(1)
            // Dismiss filter sheet too
            let doneFilter = app.buttons["filter-done"]
            if doneFilter.exists { doneFilter.tap() }
            else { app.buttons.firstMatch.tap() }
            sleep(1)
        }

        // 10. Long press context menu on a card
        let cardForMenu = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
            .firstMatch
        if cardForMenu.waitForExistence(timeout: 5) {
            cardForMenu.press(forDuration: 1.0)
            sleep(1)
            capture("16-context-menu")
            app.tap() // dismiss
            sleep(1)
        }

        print("✅ All exploration screenshots saved to: \(screenshotDir)")
    }

    // MARK: - Helpers

    private func capture(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // Also save directly to disk
        if let png = screenshot.pngRepresentation {
            let path = "\(screenshotDir)/\(name).png"
            try? png.write(to: URL(fileURLWithPath: path))
            print("📸 Captured: \(name)")
        }
    }

    private func waitForAppReady() {
        guard app.buttons["filter-button"].waitForExistence(timeout: 45) else {
            print("⚠️ App filter button not found — continuing anyway")
            return
        }
        sleep(8)
    }
}
