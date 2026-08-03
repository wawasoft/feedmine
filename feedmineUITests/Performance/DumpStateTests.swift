import XCTest
@MainActor
final class DumpStateTests: XCTestCase {
    func testDumpAt60s() {
        let app = XCUIApplication()
        app.launch()
        Thread.sleep(forTimeInterval: 60)
        let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
        let loading = texts.filter { $0.contains("Loading") || $0.contains("/100") || $0.contains("%") }
        print("=== 60s: collViews=\(app.collectionViews.count) cells=\(app.collectionViews.firstMatch.cells.count) loading=\(loading) ===")
    }

    func testDumpAt120s() {
        let app = XCUIApplication()
        app.launch()
        Thread.sleep(forTimeInterval: 120)
        let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
        let loading = texts.filter { $0.contains("Loading") || $0.contains("/100") || $0.contains("%") }
        print("=== 120s: collViews=\(app.collectionViews.count) cells=\(app.collectionViews.firstMatch.cells.count) loading=\(loading) ===")
        // Check for content
        let hasContent = app.collectionViews.firstMatch.cells.count > 0 || app.collectionViews.firstMatch.otherElements.count > 0
        print("=== 120s: hasContent=\(hasContent) buttons=\(app.buttons.count) ===")
    }

    func testDumpAt90s() {
        let app = XCUIApplication()
        app.launch()
        Thread.sleep(forTimeInterval: 90)
        let texts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
        let loading = texts.filter { $0.contains("Loading") || $0.contains("/100") || $0.contains("%") }
        let hasContent = app.collectionViews.firstMatch.cells.count > 0
        print("=== 90s: collViews=\(app.collectionViews.count) cells=\(app.collectionViews.firstMatch.cells.count) hasContent=\(hasContent) loading=\(loading) ===")
    }
}
