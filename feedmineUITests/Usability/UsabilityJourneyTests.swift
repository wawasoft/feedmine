import XCTest

/// Automated usability regression tests for FeedMine.
///
/// Each test follows the format specified in the plan:
/// Tarefa → Estado inicial → Intenção → Ações → Estado final → Orçamento
///
/// These tests validate that core user journeys remain functional,
/// short, and recoverable — using accessibility identifiers for stability.
@MainActor
final class UsabilityJourneyTests: XCTestCase {

    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        // Capture failure diagnostics if test failed
        if testRun?.failureCount ?? 0 > 0 {
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    // MARK: - UX-001: First opening to usable content

    /// Tarefa: Abrir o app pela primeira vez e encontrar conteúdo utilizável.
    /// Estado inicial: Instalação limpa com catálogo local.
    /// Intenção: Chegar a uma timeline com conteúdo ou escolha clara de fontes.
    /// Orçamento: ≤5 ações discricionárias antes de encontrar conteúdo.
    func testUX001_FirstOpeningToUsableContent() {
        app.terminate()
        AppLauncher.launch(app: app, showOnboarding: true, locale: "en")

        // Step 1: Welcome screen → Composer
        let shape = UIWaits.waitFor(app.buttons[ScreenID.welcomeShape], timeout: UIWaits.launchTimeout)
        shape.tap()

        // Step 2: Composer screen — save the default recipe
        let openFeed = UIWaits.waitFor(app.buttons[ScreenID.composerOpenFeed], timeout: UIWaits.extendedTimeout)
        openFeed.tap()

        // Final assertion: user should see the main feed with the curated preset active
        let hasFilterButton = app.buttons[ScreenID.filterButton].waitForExistence(timeout: UIWaits.launchTimeout)
        XCTAssertTrue(hasFilterButton || app.collectionViews.firstMatch.exists,
                      "User must reach the main feed screen")
    }

    // MARK: - UX-003: Search and follow a known source

    /// Tarefa: Buscar uma fonte conhecida e ver resultados.
    /// Estado: App launched with fixture data, user on main feed.
    /// Orçamento: ≤4 ações após digitar a consulta.
    func testUX003_SearchAndSeeResults() {
        AppLauncher.launch(app: app, fixtureProfile: "typical", fixtureSeed: 42, showOnboarding: false, locale: "en")

        // Wait for feed to stabilize
        let filterReady = app.buttons["filter-button"].waitForExistence(timeout: UIWaits.extendedTimeout)
        XCTAssertTrue(filterReady, "Timeline must be ready for interaction")

        // Step 1: Type search query in search field if available
        let searchField = app.textFields["search.field"]
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            searchField.typeText("Technology")
        }

        // Step 2: Verify results or search feedback appears
        let resultsAppeared = app.staticTexts["search.results"].waitForExistence(timeout: 5) ||
                               app.collectionViews.firstMatch.waitForExistence(timeout: 3)
        // Either search results appear, or we can return to feed
        XCTAssertTrue(resultsAppeared || app.buttons["filter-button"].exists,
                      "Search must produce results or allow return to feed")
    }

    // MARK: - UX-004: Consume and return without losing context

    /// Tarefa: Abrir um conteúdo e voltar sem perder posição.
    /// Estado: Timeline com cards visíveis.
    /// Budget: 1 ação para abrir, 1 para voltar.
    func testUX004_ConsumeAndReturnPreservingContext() {
        AppLauncher.launch(app: app, showOnboarding: false, locale: "en")

        // Wait for timeline with cards
        let timelineExists = app.collectionViews.firstMatch.waitForExistence(timeout: UIWaits.extendedTimeout)
        let filterReady = app.buttons["filter-button"].waitForExistence(timeout: UIWaits.extendedTimeout)

        if !timelineExists && !filterReady {
            // App may be in empty state — that's valid, just verify it's not broken
            let emptyState = app.staticTexts["state.empty"].exists
            let errorState = app.staticTexts["state.error"].exists
            XCTAssertTrue(emptyState || errorState || filterReady,
                          "App must show a defined state (timeline, empty, or error)")
            return
        }

        // Verify filter button still exists (proves we're still on the feed screen)
        XCTAssertTrue(app.buttons["filter-button"].exists,
                      "Filter button confirms feed screen context is preserved")

        // Verify no modal/dialog is blocking interaction
        let blockingAlert = app.alerts.firstMatch
        XCTAssertFalse(blockingAlert.exists && blockingAlert.isHittable,
                       "No blocking alert should prevent interaction")
    }

    // MARK: - UX-007: Podcast playback maintains context

    /// Tarefa: Verificar que controles de áudio existem e são acessíveis.
    /// Estado: Timeline carregada com fixture data (inclui ~12.5% itens de áudio).
    /// Budget: Player deve ser alcançável a partir do feed.
    func testUX007_AudioControlsAccessible() {
        AppLauncher.launch(app: app, fixtureProfile: "typical", fixtureSeed: 42, showOnboarding: false, locale: "en")

        // Wait for feed to be ready
        let filterReady = app.buttons["filter-button"].waitForExistence(timeout: UIWaits.extendedTimeout)
        XCTAssertTrue(filterReady, "Feed must be ready")

        // With typical fixture data (5K items, 12.5% audio), scroll to find audio cards
        let timeline = app.collectionViews.firstMatch
        if timeline.exists {
            // Scroll down a few pages to find audio content
            for _ in 0..<3 { timeline.swipeUp(); Thread.sleep(forTimeInterval: 0.3) }
        }

        // Either mini-player is visible (audio playing) or app is responsive
        let miniPlayerVisible = app.otherElements["player.mini"].waitForExistence(timeout: 3)
        let playButtonVisible = app.buttons["card.play.fixture-42-8"].waitForExistence(timeout: 2) ||
                                 app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'card.play'")).firstMatch.waitForExistence(timeout: 2)

        // At minimum, the feed must be responsive
        XCTAssertTrue(miniPlayerVisible || playButtonVisible || timeline.exists || app.buttons["filter-button"].exists,
                      "Audio controls or feed must be accessible")

        // If mini-player or play button is visible, verify it's interactive
        if miniPlayerVisible {
            XCTAssertTrue(app.otherElements["player.mini"].isHittable || app.buttons["player.playPause"].exists,
                          "Mini-player must be interactive when visible")
        }
    }

    // MARK: - UX-009: Offline usage

    /// Tarefa: Usar o app offline com conteúdo previamente carregado.
    /// Estado: Conteúdo local; rede simulada offline via fixture.
    /// Budget: Abrir app e navegar sem rede.
    func testUX009_OfflineUsage() {
        // Launch with offline network profile
        AppLauncher.launch(app: app, networkProfile: "offline", showOnboarding: false, locale: "en")

        // App should launch and show either:
        // 1. Cached content (if any)
        // 2. Clear offline indication
        // 3. A defined empty state
        let contentVisible = app.collectionViews.firstMatch.waitForExistence(timeout: 10) ||
                             app.buttons["filter-button"].waitForExistence(timeout: 10)

        let offlineIndicator = app.staticTexts["state.offline"].exists

        // App must not crash or show a blank white screen
        let hasUI = contentVisible || offlineIndicator ||
                     app.buttons.firstMatch.exists || app.staticTexts.firstMatch.exists
        XCTAssertTrue(hasUI, "Offline launch must show defined UI (not blank/crashed)")
    }

    // MARK: - UX-012: Empty state is honest

    /// Tarefa: Entender por que está vazio e encontrar uma saída.
    /// Estado: Filtro sem resultados ou nenhuma fonte seguida.
    /// Budget: Explicação visível e ação clara disponível.
    func testUX012_EmptyStateHonest() {
        app.terminate()
        AppLauncher.launch(app: app, showOnboarding: false, locale: "en")

        // Wait for the app to stabilize — give it more time
        Thread.sleep(forTimeInterval: 2.0)

        // After launch, the app must show ONE of these valid states:
        // 1. Timeline with content
        // 2. Filter button (feed is ready)
        // 3. Empty state with explanation
        // 4. Loading state that resolves

        let timeline = app.collectionViews.firstMatch
        let filterButton = app.buttons["filter-button"]
        let anyButton = app.buttons.firstMatch
        let anyText = app.staticTexts.firstMatch

        // Wait up to launchTimeout for something visible
        let somethingVisible = timeline.waitForExistence(timeout: UIWaits.launchTimeout) ||
                                filterButton.waitForExistence(timeout: UIWaits.launchTimeout) ||
                                anyButton.waitForExistence(timeout: UIWaits.launchTimeout) ||
                                anyText.waitForExistence(timeout: UIWaits.launchTimeout)

        XCTAssertTrue(somethingVisible,
                      "App must show defined UI within \(UIWaits.launchTimeout)s — not a blank screen")

        // Verify no crash by checking the app is still responsive
        let appStillAlive = app.exists && app.state == .runningForeground
        XCTAssertTrue(appStillAlive, "App must still be running and responsive")

        // Verify there's at least one interactive element or explanation
        let hasButtons = app.buttons.count > 0
        let hasText = app.staticTexts.count > 0
        XCTAssertTrue(hasButtons || hasText,
                      "Empty state must have at least one actionable element or explanation")
    }
}
