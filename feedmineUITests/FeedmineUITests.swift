import Foundation
import XCTest

@MainActor
final class FeedmineUITests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-UITestResetFilters", "-UITestSkipOnboarding",
        ]
        app.launch()
    }

    func testCuratedOnboardingCreatesAnInspectableFeedFromRealStories() {
        app.terminate()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-UITestResetFilters", "-UITestShowOnboarding",
        ]
        app.launch()

        let start = app.buttons["welcome-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 40), "Curated onboarding must appear")
        start.tap()

        // Intent screen — pick "Stay informed"
        let intentChip = app.buttons["intent-stayInformed"]
        XCTAssertTrue(intentChip.waitForExistence(timeout: 30), "Intent screen must appear")
        intentChip.tap()
        let intentContinue = app.buttons["intent-continue"]
        XCTAssertTrue(intentContinue.waitForExistence(timeout: 5))
        intentContinue.tap()

        // Topics screen — pick "Technology & Science"
        let topicChip = app.buttons["topic-technology-science"]
        XCTAssertTrue(topicChip.waitForExistence(timeout: 30), "Topics screen must appear")
        topicChip.tap()
        let topicsContinue = app.buttons["topics-continue"]
        XCTAssertTrue(topicsContinue.waitForExistence(timeout: 5))
        topicsContinue.tap()

        // English is pre-selected by device language; no need to find/tap it
        let continueBtn = app.buttons["language-continue"]
        XCTAssertTrue(continueBtn.waitForExistence(timeout: 30))
        continueBtn.tap()

        let firstStory = app.buttons["duel-top-card"]
        if firstStory.waitForExistence(timeout: 60) {
            for _ in 0..<7 {
                XCTAssertTrue(firstStory.waitForExistence(timeout: 15))
                firstStory.tap()
                // Wait for feedback overlay to dismiss
                _ = app.staticTexts["You chose this"].waitForExistence(timeout: 3)
            }
            let review = app.buttons["duel-finish"]
            XCTAssertTrue(review.waitForExistence(timeout: 10))
            review.tap()
        } else {
            let balanced = app.buttons["Start with a balanced feed"]
            XCTAssertTrue(
                balanced.waitForExistence(timeout: 10),
                "Onboarding must offer a cache-safe fallback when stories are unavailable"
            )
            balanced.tap()
        }

        let save = app.buttons["reveal-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        save.tap()

        let filterButton = app.buttons["filter-button"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(
            Int(filterButton.value as? String ?? "") ?? 0,
            0,
            "Finishing onboarding must persist and activate the Curated Feed"
        )
    }

    // MARK: - Acoustics (4 feeds, topic)

    func testAcousticsFilterShowsAcousticsCards() {
        selectTaxonomyCategory(
            searchTerm: "Acoustics",
            expectedKeywords: ["Acoustics Today", "Audio Engineering", "acoustics.org"],
            forbiddenSources: ["CNN", "BBC News", "Daring Fireball", "MacStories"],
            screenshotName: "acoustics-verified"
        )
    }

    // MARK: - Duplicate-name taxonomy category

    func testMythologyCategoryPrefersEditorialTopicOverCountryDuplicates() {
        selectTaxonomyCategory(
            searchTerm: "Mythology & Folklore",
            expectedKeywords: ["American Folklore Society", "Folklore"],
            forbiddenSources: ["CNN", "BBC News", "Snopes"],
            screenshotName: "mythology-editorial-topic-verified"
        )
    }

    func testFactCheckingCategoryOwnsMisinformationSources() {
        selectTaxonomyCategory(
            searchTerm: "Fact-Checking & Media Literacy",
            expectedKeywords: ["Snopes", "Conspiracy Watch"],
            forbiddenSources: ["Myths Your Teacher Hated", "Freaky Folklore"],
            screenshotName: "fact-checking-editorial-topic-verified"
        )
    }

    // MARK: - Humor topic category

    func testHumorCategoryShowsCards() {
        // Comedy and performance sources share one content-derived category.
        selectTaxonomyCategory(
            searchTerm: "Comedy & Performance",
            expectedKeywords: ["comedy", "funny", "humor"],
            forbiddenSources: ["CNN", "BBC News", "Daring Fireball"],
            screenshotName: "podcast-verified"
        )
    }

    // MARK: - Video/YouTube category

    func testVideoCategoryShowsCards() {
        selectTaxonomyCategory(
            searchTerm: "Cooking & Recipes",
            expectedKeywords: ["Sorted Food", "cooking", "recipe"],
            forbiddenSources: ["CNN", "BBC News", "MacStories"],
            screenshotName: "video-verified"
        )
    }

    // MARK: - Country-based category

    func testCountryCategoryShowsCards() {
        selectTaxonomyCategory(
            searchTerm: "Algeria",
            expectedKeywords: ["Algeria", "algerie", "Echorouk"],
            forbiddenSources: ["This Day in History"],
            screenshotName: "country-verified"
        )
    }

    // MARK: - Many-feeds category

    func testManyFeedsCategoryShowsCards() {
        selectTaxonomyCategory(
            searchTerm: "Visual Arts",
            expectedKeywords: ["photography", "photo", "camera"],
            forbiddenSources: ["CNN", "BBC News"],
            screenshotName: "many-feeds-verified"
        )
    }

    // MARK: - Clear filters restores normal feed

    func testClearFiltersRestoresFullFeed() {
        waitForAppReady()

        // Apply a filter so we can verify it's cleared
        openFilterAndSelectTopic(searchTerm: "Acoustics")
        dismissTopicsAndFilter()
        sleep(5)
        _ = app.cells.firstMatch.waitForExistence(timeout: 20)
        let beforeClear = app.cells.count
        print("Cells with Acoustics filter: \(beforeClear)")

        // Open filter and tap "Clear All Filters"
        let filterButton = app.buttons["filter-button"]
        filterButton.tap()
        sleep(2)
        _ = app.buttons["filter-done"].waitForExistence(timeout: 5)
        let clearBtn = app.buttons["Clear All Filters"]
        XCTAssertTrue(clearBtn.exists, "Clear All Filters button must be visible")
        clearBtn.tap()
        // clearAllFilters() calls dismiss() internally
        sleep(3)

        // After clear, the filter badge on the button should be gone
        // (activeCount == 0 means no badge circle with number)
        // Verify the filter button still exists (sheet dismissed successfully)
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5),
                      "App should return to feed after clearing filters")

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = "clear-filters-verified"
        add(attachment)

        let cards = waitForFeedItemIdentifiers(timeout: 20)
        XCTAssertFalse(cards.isEmpty, "Clearing filters must restore feed cards")
    }

    func testContentTypeFilterTapsRespondImmediately() {
        waitForAppReady()
        let filterButton = app.buttons["filter-button"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5))
        filterButton.tap()
        XCTAssertTrue(app.buttons["filter-done"].waitForExistence(timeout: 3))

        let id = "content-type-videos"
        let button = app.buttons[id]
        for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        XCTAssertTrue(button.waitForExistence(timeout: 2), "Missing \(id) filter")
        if (button.value as? String) == "selected" {
            button.tap()
        }
        let start = CFAbsoluteTimeGetCurrent()
        button.tap()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 1.3, "\(id) filter tap blocked the UI for \(elapsed)s")
        app.buttons["filter-done"].tap()
        XCTAssertTrue(filterButton.waitForExistence(timeout: 3))
    }

    func testUnifiedSearchFindsAndOpensContentAnalyzedSource() {
        let searchButton = app.buttons["search-button"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 45), "Search button must be available")
        searchButton.tap()

        let field = app.textFields["unified-search-field"]
        var didOpenSearch = field.waitForExistence(timeout: 15)
        if !didOpenSearch, searchButton.exists {
            // The first tap can coincide with the initial taxonomy publication
            // on slower simulators. Retry the idempotent presentation action
            // once instead of turning startup load into a false UI failure.
            searchButton.tap()
            didOpenSearch = field.waitForExistence(timeout: 20)
        }
        XCTAssertTrue(didOpenSearch, "Unified search field must open")
        guard didOpenSearch else { return }
        field.tap()
        field.typeText("astronomy")
        field.typeText("\n")

        XCTAssertTrue(app.staticTexts["Sources"].waitForExistence(timeout: 12),
                      "Content-analyzed source tier must be first")
        let astronomySource = app.staticTexts["Astronomy Magazine"].firstMatch
        XCTAssertTrue(astronomySource.waitForExistence(timeout: 8),
                      "Astronomy source should be found from catalog tags/descriptions")
        astronomySource.tap()

        XCTAssertTrue(app.navigationBars["Astronomy Magazine"].waitForExistence(timeout: 8),
                      "Tapping a source should open its complete source feed")
        XCTAssertTrue(app.buttons["Add source to collection"].exists)
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label ==[c] %@", "astronomy")).firstMatch.exists,
            "Source feed should expose its content-derived astronomy tag"
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "currently exposed by the feed")).firstMatch.exists,
            "Source view should explain the honest RSS history boundary"
        )

        // A source result can be put into a reusable many-to-many playlist
        // without enabling or moving its catalog/OPML entry.
        app.buttons["Add source to collection"].tap()
        let collectionName = "Astronomy reading \(Int(Date().timeIntervalSince1970))"
        let collectionField = app.textFields["Collection name"]
        for _ in 0..<8 where !collectionField.exists {
            app.swipeUp()
        }
        XCTAssertTrue(collectionField.waitForExistence(timeout: 5))
        collectionField.tap()
        collectionField.typeText(collectionName)
        app.buttons["Create Collection"].tap()
        XCTAssertTrue(app.staticTexts[collectionName].waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "unified-search-astronomy-source"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testAddFeedListsCollectionsCreatedInSourceCollections() {
        let moreMenu = app.buttons["more-menu"]
        XCTAssertTrue(moreMenu.waitForExistence(timeout: 45), "More menu must be available")
        moreMenu.tap()
        app.buttons["Source Collections"].tap()

        XCTAssertTrue(app.navigationBars["Source Collections"].waitForExistence(timeout: 8))
        app.buttons["Create source collection"].tap()
        let collectionName = "URL imports \(Int(Date().timeIntervalSince1970))"
        let nameField = app.textFields["Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText(collectionName)
        app.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts[collectionName].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        XCTAssertTrue(moreMenu.waitForExistence(timeout: 5))
        moreMenu.tap()
        app.buttons["Add Feed"].tap()

        let picker = app.buttons["add-feed-collection-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        picker.tap()
        let collectionOption = app.buttons[collectionName]
        XCTAssertTrue(
            collectionOption.waitForExistence(timeout: 5),
            "A real source collection must be offered by Add Feed"
        )
        collectionOption.tap()
        XCTAssertTrue(
            (picker.value as? String)?.contains(collectionName) == true
                || picker.label.contains(collectionName),
            "The personal collection must be selected as the URL destination"
        )
    }

    func testRecoveredDormantAstronomySourceIsSearchableButNotAutoEnabled() {
        let searchButton = app.buttons["search-button"]
        XCTAssertTrue(searchButton.waitForExistence(timeout: 45), "Search button must be available")
        searchButton.tap()

        let field = app.textFields["unified-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Unified search field must open")
        guard field.exists else { return }
        field.tap()
        field.typeText("Turk Astronomi")
        field.typeText("\n")

        XCTAssertTrue(app.staticTexts["Sources"].waitForExistence(timeout: 12))
        let recoveredSource = app.staticTexts["Türk Astronomi Derneği (TAD)"].firstMatch
        XCTAssertTrue(
            recoveredSource.waitForExistence(timeout: 8),
            "A recovered source must be discoverable through its analyzed catalog metadata"
        )
        recoveredSource.tap()

        XCTAssertTrue(
            app.navigationBars["Türk Astronomi Derneği (TAD)"].waitForExistence(timeout: 8),
            "The recovered source result must open its exact source view"
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label ==[c] %@", "astronomy")).firstMatch.exists,
            "The source must retain its content-derived astronomy classification"
        )
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Dormant in the automatic feed")
            ).firstMatch.exists,
            "Dormant current-sensitive sources must remain searchable without auto-enabling them"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "recovered-dormant-astronomy-source"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLongPressCardOpensThatExactSource() {
        waitForAppReady()
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), "A feed card is required for source navigation")
        guard card.exists else { return }

        card.press(forDuration: 1.2)
        let viewSource = app.buttons["View Source"]
        XCTAssertTrue(viewSource.waitForExistence(timeout: 5), "Long press must offer direct source navigation")
        viewSource.tap()

        XCTAssertTrue(app.buttons["Add source to collection"].waitForExistence(timeout: 8),
                      "The exact source feed should open from the card menu")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "currently exposed by the feed")).firstMatch.exists,
            "The source screen should be content-first and disclose feed history limits"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "long-press-view-source"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Helpers

    /// Full flow: wait for app, open filter, search topic, select it, verify results.
    private func selectTaxonomyCategory(
        searchTerm: String,
        expectedKeywords: [String],
        forbiddenSources: [String],
        screenshotName: String,
        allowEmptyCards: Bool = false
    ) {
        waitForAppReady()
        openFilterAndSelectTopic(searchTerm: searchTerm)
        dismissTopicsAndFilter()

        // Wait for cards and verify
        print("Waiting for cards after selecting '\(searchTerm)'...")
        let cardIdentifiers = waitForFeedItemIdentifiers(timeout: 30)
        let cardsExist = !cardIdentifiers.isEmpty
        print("Total visible cards: \(cardIdentifiers.count)")

        let allTexts = app.staticTexts

        // Verify expected keywords
        var foundExpected = expectedKeywords.isEmpty
        for kw in expectedKeywords {
            if allTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", kw)).firstMatch.exists {
                foundExpected = true
                break
            }
        }

        // Collect diagnostics
        var labels: [String] = []
        for i in 0..<min(cardIdentifiers.count, 5) {
            labels.append(cardIdentifiers[i])
        }

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = screenshotName
        add(attachment)

        if !allowEmptyCards {
            XCTAssertTrue(cardsExist,
                          "No cards visible for '\(searchTerm)' after 30 seconds. Cards: \(labels)")
            XCTAssertTrue(foundExpected,
                          "No \(searchTerm) card found. Cards: \(labels)")
        }

        // Verify no leakage
        for source in forbiddenSources {
            let match = allTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", source)).firstMatch
            XCTAssertFalse(match.exists,
                          "Non-\(searchTerm) source '\(source)' leaked into filtered feed!")
        }
    }

    /// Waits for app to load, opens filter, searches for and selects a topic.
    private func openFilterAndSelectTopic(searchTerm: String) {
        let filterButton = app.buttons["filter-button"]
        guard filterButton.waitForExistence(timeout: 40) else {
            XCTFail("App failed to load — filter button not found")
            return
        }
        sleep(8)  // Let progressive fetch settle

        // Open filter
        filterButton.tap()
        sleep(2)

        // Ensure sheet is visible
        let doneButton = app.buttons["Done"]
        let filterDone = app.buttons["filter-done"]
        let sheetVisible = doneButton.waitForExistence(timeout: 5) ||
                           filterDone.waitForExistence(timeout: 5)
        if !sheetVisible {
            filterButton.tap()
            sleep(2)
            guard doneButton.waitForExistence(timeout: 5) || filterDone.waitForExistence(timeout: 5) else {
                XCTFail("Filter sheet did not open")
                return
            }
        }

        // Find and tap Browse Topics
        sleep(1)
        let browsePred = NSPredicate(format: "label CONTAINS[c] %@", "Browse Topics")
        var foundBrowse = false
        for _ in 0..<8 {
            let btn = app.buttons.element(matching: browsePred)
            let text = app.staticTexts.element(matching: browsePred)
            if btn.exists { btn.tap(); foundBrowse = true; break }
            else if text.exists { text.tap(); foundBrowse = true; break }
            app.swipeUp()
            usleep(500_000)
        }
        guard foundBrowse else {
            XCTFail("Browse Topics not found")
            return
        }

        sleep(1)

        // Wait for search field and search
        let searchField = app.textFields["search-topics"]
        guard searchField.waitForExistence(timeout: 10) else {
            XCTFail("Topics search field did not appear")
            return
        }
        searchField.tap()
        sleep(1)
        searchField.typeText(searchTerm)
        sleep(2)
        searchField.typeText("\n")
        usleep(300_000)

        // Tap search result
        let resultPred = NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "taxonomy-node-", searchTerm
        )
        let resultBtn = app.buttons.matching(resultPred).firstMatch
        guard resultBtn.waitForExistence(timeout: 5) else {
            XCTFail("'\(searchTerm)' not found in search results")
            return
        }
        let searchShot = XCTAttachment(screenshot: app.screenshot())
        searchShot.name = "topic-search-\(searchTerm)"
        searchShot.lifetime = .deleteOnSuccess
        add(searchShot)
        XCTAssertTrue(resultBtn.isHittable,
                      "Topic result is not hittable: \(resultBtn.identifier), \(resultBtn.label)")
        resultBtn.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        XCTAssertGreaterThan(
            Int(app.buttons["topics-done"].value as? String ?? "") ?? 0,
            0,
            "Topic selection must update immediately after tapping '\(resultBtn.label)' (\(resultBtn.identifier))"
        )
        sleep(1)
    }

    /// Dismisses Topics view and Filter sheet.
    private func dismissTopicsAndFilter() {
        let topicsDone = app.buttons["topics-done"]
        if topicsDone.exists { topicsDone.tap() }
        else {
            let doneBtn = app.buttons["Done"]
            if doneBtn.exists { doneBtn.tap() }
        }
        sleep(1)

        let selectedTopicCount = Int(app.buttons["browse-topics"].value as? String ?? "") ?? 0
        XCTAssertGreaterThan(selectedTopicCount, 0,
                             "Topic selection must remain active after leaving the topic browser")

        let filterDoneBtn = app.buttons["filter-done"]
        if filterDoneBtn.exists { filterDoneBtn.tap() }
        else {
            let doneBtn = app.buttons["Done"]
            if doneBtn.exists { doneBtn.tap() }
        }
        sleep(2)

        let activeFilterCount = Int(app.buttons["filter-button"].value as? String ?? "") ?? 0
        XCTAssertGreaterThan(activeFilterCount, 0,
                             "Topic selection must remain active after dismissing filters")
    }

    /// Wait for app to finish initial loading.
    private func waitForAppReady() {
        guard app.buttons["filter-button"].waitForExistence(timeout: 40) else {
            XCTFail("App failed to load")
            return
        }
        sleep(8)
    }

    private func waitForFeedItemIdentifiers(timeout: TimeInterval) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let identifiers = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "feed-item-"))
                .allElementsBoundByIndex
                .map(\.identifier)
            if !identifiers.isEmpty { return identifiers }
            usleep(100_000)
        } while Date() < deadline
        return []
    }

    /// Captura a tela atual para inspeção do contador de sources no header.
    func testCaptureHeaderScreenshot() {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "header-counter"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    // MARK: - Interactive Persona Script Harness

    /// Reads /tmp/feedmine-script.json, executes each action, saves screenshots.
    /// Actions: tap(id), tapLabel(text), swipeUp, swipeDown, typeText(id,text),
    ///          screenshot(id), wait(seconds), press(id,duration), relaunch
    func testExecuteInteractiveScript() {
        let scriptPath = "/tmp/feedmine-script.json"
        let screenshotDir = "/tmp/feedmine-interactive"

        // Ensure screenshot directory exists
        let fm = FileManager.default
        if !fm.fileExists(atPath: screenshotDir) {
            try? fm.createDirectory(atPath: screenshotDir, withIntermediateDirectories: true)
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: scriptPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actions = json["actions"] as? [[String: Any]] else {
            print("❌ Failed to read script from \(scriptPath)")
            return
        }

        print("📜 Executing \(actions.count) interactive actions...")

        for (index, action) in actions.enumerated() {
            let type = action["type"] as? String ?? ""
            print("  [\(index + 1)/\(actions.count)] \(type): \(action["id"] as? String ?? action["text"] as? String ?? "")")

            switch type {
            case "tap":
                if let targetId = action["id"] as? String {
                    let element = app.buttons[targetId].firstMatch
                    if element.waitForExistence(timeout: 5) {
                        element.tap()
                    } else {
                        // Try as any element type
                        let anyElement = app.descendants(matching: .any)[targetId].firstMatch
                        if anyElement.waitForExistence(timeout: 3) {
                            anyElement.tap()
                        } else {
                            print("    ⚠️ Element '\(targetId)' not found")
                        }
                    }
                }

            case "tapLabel":
                if let label = action["text"] as? String {
                    let predicate = NSPredicate(format: "label CONTAINS[c] %@", label)
                    let element = app.buttons.matching(predicate).firstMatch
                    if !element.exists {
                        // Try static texts
                        let textElement = app.staticTexts.matching(predicate).firstMatch
                        if textElement.waitForExistence(timeout: 3) {
                            textElement.tap()
                        } else {
                            print("    ⚠️ Label '\(label)' not found")
                        }
                    } else if element.waitForExistence(timeout: 3) {
                        element.tap()
                    } else {
                        print("    ⚠️ Label '\(label)' not found")
                    }
                }

            case "tapFirst":
                // Tap the first element matching a prefix
                if let prefix = action["id"] as? String {
                    let predicate = NSPredicate(format: "identifier BEGINSWITH %@", prefix)
                    let element = app.descendants(matching: .any).matching(predicate).firstMatch
                    if element.waitForExistence(timeout: 5) {
                        element.tap()
                    } else {
                        print("    ⚠️ No element with prefix '\(prefix)'")
                    }
                }

            case "typeText":
                if let fieldId = action["id"] as? String,
                   let text = action["text"] as? String {
                    let field = app.textFields[fieldId].firstMatch
                    if field.waitForExistence(timeout: 5) {
                        field.tap()
                        usleep(300_000)
                        field.typeText(text)
                        usleep(200_000)
                    } else {
                        // Try search fields
                        let searchField = app.searchFields[fieldId].firstMatch
                        if searchField.waitForExistence(timeout: 3) {
                            searchField.tap()
                            usleep(300_000)
                            searchField.typeText(text)
                            usleep(200_000)
                        } else {
                            print("    ⚠️ Text field '\(fieldId)' not found")
                        }
                    }
                }

            case "swipeUp":
                app.swipeUp()
                usleep(500_000)

            case "swipeDown":
                app.swipeDown()
                usleep(500_000)

            case "press":
                if let targetId = action["id"] as? String {
                    let duration = action["duration"] as? Double ?? 1.0
                    let element = app.descendants(matching: .any)[targetId].firstMatch
                    if element.waitForExistence(timeout: 5) {
                        element.press(forDuration: duration)
                    }
                }

            case "scrollTo":
                // Scroll until element is visible, then tap
                if let targetId = action["id"] as? String {
                    for _ in 0..<8 {
                        let element = app.buttons[targetId].firstMatch
                        if element.exists && element.isHittable {
                            element.tap()
                            break
                        }
                        app.swipeUp()
                        usleep(300_000)
                    }
                }

            case "wait":
                let seconds = action["seconds"] as? Double ?? 2.0
                usleep(UInt32(seconds * 1_000_000))

            case "relaunch":
                app.terminate()
                usleep(1_000_000)
                app.launchArguments = [
                    "-AppleLanguages", "(en)",
                    "-UITestResetFilters", "-UITestSkipOnboarding",
                ]
                app.launch()
                // Wait for app to settle
                _ = app.buttons["filter-button"].waitForExistence(timeout: 45)
                usleep(3_000_000)

            case "dismiss":
                // Try common dismiss patterns
                if app.buttons["filter-done"].exists { app.buttons["filter-done"].tap() }
                else if app.buttons["Done"].exists { app.buttons["Done"].tap() }
                else if app.buttons["done-button"].exists { app.buttons["done-button"].tap() }
                else { app.buttons.firstMatch.tap() }
                usleep(500_000)

            case "screenshot":
                let shotName = action["id"] as? String ?? "step-\(index)"
                let screenshot = app.screenshot()
                let png = screenshot.pngRepresentation
                let path = "\(screenshotDir)/\(shotName).png"
                try? png.write(to: URL(fileURLWithPath: path))
                print("    📸 Saved: \(shotName).png")

            default:
                print("    ⚠️ Unknown action type: \(type)")
            }
        }

        // Final screenshot always
        let finalShot = app.screenshot()
        let png2 = finalShot.pngRepresentation
        let path2 = "\(screenshotDir)/final.png"
        try? png2.write(to: URL(fileURLWithPath: path2))
        print("    📸 Final screenshot saved")

        print("✅ Script complete — \(actions.count) actions executed")
    }
}
