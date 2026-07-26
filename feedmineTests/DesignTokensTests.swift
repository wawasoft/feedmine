import XCTest
import SwiftUI
@testable import feedmine

final class DesignTokensTests: XCTestCase {

    func testColorHexWhite() {
        let color = Color(hex: "#FFFFFF")
        // Verify we get a valid Color (no crash)
        XCTAssertNotNil(color)
    }

    func testColorHexBlack() {
        let color = Color(hex: "#000000")
        XCTAssertNotNil(color)
    }

    func testColorHexRed() {
        let color = Color(hex: "#FF0000")
        XCTAssertNotNil(color)
    }

    func testColorHexWithoutHash() {
        let color = Color(hex: "FF8800")
        XCTAssertNotNil(color)
    }

    func testComponentTokenCategoryColor() {
        let color = ComponentToken.categoryColor(for: "Tech")
        // Should produce a valid Color — not crash
        XCTAssertNotNil(color)
    }

    func testGradientsAreNonNil() {
        let g1 = ComponentToken.briefingGradient
        let g2 = ComponentToken.carouselAccentGradient
        XCTAssertFalse(g1.isEmpty)
        XCTAssertFalse(g2.isEmpty)
    }
}
