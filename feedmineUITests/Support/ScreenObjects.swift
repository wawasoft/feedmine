import Foundation
import XCTest

// MARK: - Screen element identifiers

/// Accessibility identifiers used across FeedMine UI tests.
/// These are the canonical reference — views must use these exact strings
/// as their `accessibilityIdentifier`.
enum ScreenID {
    // Screens
    static let timeline = "screen.timeline"
    static let catalog = "screen.catalog"
    static let sourceDetail = "screen.sourceDetail"

    // Timeline
    static let timelineList = "timeline.list"
    static func timelineCard(_ fixtureID: String) -> String { "timeline.card.\(fixtureID)" }

    // Card actions
    static func cardOpen(_ fixtureID: String) -> String { "card.open.\(fixtureID)" }
    static func cardSave(_ fixtureID: String) -> String { "card.save.\(fixtureID)" }
    static func cardPlay(_ fixtureID: String) -> String { "card.play.\(fixtureID)" }

    // Source
    static func sourceFollow(_ fixtureID: String) -> String { "source.follow.\(fixtureID)" }
    static func sourceUnfollow(_ fixtureID: String) -> String { "source.unfollow.\(fixtureID)" }

    // Search
    static let searchField = "search.field"
    static let searchResults = "search.results"

    // Player
    static let playerMini = "player.mini"
    static let playerPlayPause = "player.playPause"

    // States
    static let stateLoading = "state.loading"
    static let stateEmpty = "state.empty"
    static let stateOffline = "state.offline"
    static let stateError = "state.error"

    // Onboarding
    static let welcomeStart = "welcome-start"
    static func intentChip(_ intent: String) -> String { "intent-\(intent)" }
    static let intentContinue = "intent-continue"
    static func topicChip(_ topic: String) -> String { "topic-\(topic)" }
    static let topicsContinue = "topics-continue"
    static let languageContinue = "language-continue"
    static let duelTopCard = "duel-top-card"
    static let duelFinish = "duel-finish"
    static let revealSave = "reveal-save"

    // Filter
    static let filterButton = "filter-button"
    static let filterSheet = "filter.sheet"

    // Settings
    static let settingsButton = "settings.button"
    static let settingsSheet = "settings.sheet"
}

// MARK: - UI Wait Helpers

enum UIWaits {
    /// Default timeout for UI element appearance.
    static let defaultTimeout: TimeInterval = 10.0

    /// Extended timeout for operations involving network or large data.
    static let extendedTimeout: TimeInterval = 30.0

    /// Launch/onboarding timeout — can be slow on first run.
    static let launchTimeout: TimeInterval = 60.0

    /// Wait for an element to exist, failing with a descriptive message.
    @discardableResult
    static func waitFor(
        _ element: XCUIElement,
        timeout: TimeInterval = defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let exists = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(
            exists,
            "Expected '\(element.identifier)' (\(element.elementType)) to exist within \(timeout)s",
            file: file, line: line
        )
        return element
    }

    /// Wait for an element to become hittable.
    @discardableResult
    static func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertTrue(
            result == .completed,
            "Expected '\(element.identifier)' to be hittable within \(timeout)s",
            file: file, line: line
        )
        return element
    }

    /// Wait for an element to disappear.
    static func waitForDisappearance(
        _ element: XCUIElement,
        timeout: TimeInterval = defaultTimeout,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertTrue(
            result == .completed,
            "Expected '\(element.identifier)' to disappear within \(timeout)s",
            file: file, line: line
        )
    }

    /// Check if element exists without failing.
    static func exists(
        _ element: XCUIElement,
        timeout: TimeInterval = defaultTimeout
    ) -> Bool {
        element.waitForExistence(timeout: timeout)
    }
}

// MARK: - Failure Attachments

enum FailureAttachments {
    /// Attach diagnostic information when a UI test fails.
    static func attachDiagnostics(
        app: XCUIApplication,
        name: String = "failure-diagnostics"
    ) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = "\(name)-screenshot"
        XCTContext.runActivity(named: "Attach failure diagnostics") { activity in
            activity.add(attachment)
        }
    }
}
