import XCTest
@testable import feedmine

@MainActor
final class LocaleManagerTests: XCTestCase {

    func testSupportedLanguagesNotEmpty() {
        let languages = LocaleManager.supportedLanguages
        XCTAssertFalse(languages.isEmpty)
    }

    func testDefaultLanguageIsEnglish() {
        let manager = LocaleManager.shared
        XCTAssertTrue(manager.selectedLanguage.code.hasPrefix("en"))
    }

    func testSupportedLanguagesHaveUniqueCodes() {
        let codes = LocaleManager.supportedLanguages.map(\.code)
        XCTAssertEqual(codes.count, Set(codes).count)
    }

    func testEnglishIsInSupportedLanguages() {
        XCTAssertTrue(LocaleManager.supportedLanguages.contains { $0.code == "en" })
    }

    func testSelectLanguageUpdatesSelection() {
        let manager = LocaleManager.shared
        let previous = manager.selectedLanguage
        guard let target = LocaleManager.supportedLanguages.first(where: { $0.code != previous.code }) else {
            return
        }
        manager.selectLanguage(target)
        XCTAssertEqual(manager.selectedLanguage.code, target.code)
        manager.selectLanguage(previous)
    }
}
