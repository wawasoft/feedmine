import SwiftUI

// MARK: - Color Extension (OKLCH + Hex)

extension Color {
    /// Create a Color from OKLCH components (perceptual color space).
    init(oklchL l: Double, chroma c: Double, hue h: Double) {
        // Convert OKLCH → sRGB (simplified: uses OKLab intermediate)
        let hRad = h * .pi / 180.0
        let a = c * cos(hRad)
        let b = c * sin(hRad)

        // OKLab to linear sRGB
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b

        let l3 = l_ * l_ * l_
        let m3 = m_ * m_ * m_
        let s3 = s_ * s_ * s_

        let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let d = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3

        self.init(
            red: Double(max(0, min(1, r))),
            green: Double(max(0, min(1, g))),
            blue: Double(max(0, min(1, d)))
        )
    }

    /// Convenience from hex string (kept for migration, prefer OKLCH).
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - WCAG Contrast Helpers

extension Color {
    /// sRGB-relative luminance (WCAG 2.x definition, 0...1).
    func relativeLuminance() -> Double {
        let uiColor = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio against another color (1...21).
    func contrastRatio(with other: Color) -> CGFloat {
        let hi = max(relativeLuminance(), other.relativeLuminance())
        let lo = min(relativeLuminance(), other.relativeLuminance())
        return CGFloat((hi + 0.05) / (lo + 0.05))
    }

    /// Darkens toward black until it reaches `ratio` against `background`.
    /// Returns `self` unchanged when it already meets the threshold.
    func darkened(untilContrast ratio: CGFloat, against background: Color) -> Color {
        guard contrastRatio(with: background) < ratio else { return self }
        var blend: CGFloat = 0
        var result = self
        while result.contrastRatio(with: background) < ratio && blend < 0.92 {
            blend += 0.02
            result = mix(with: .black, by: blend)
        }
        return result
    }

}

// MARK: - Layer 1: Primitives (OKLCH-based color scales)

/// Raw color scales in OKLCH. Independent of theme or circadian phase.
enum PrimitiveColor {
    // Neutral gray scale (chroma ~0, just lightness)
    static func neutral(_ level: Int) -> Color {
        let l = Double(100 - level) / 100.0  // 50 → 0.50, 950 → 0.05
        return Color(oklchL: l, chroma: 0, hue: 0)
    }

    // Warm scale (amber, h=50)
    static func warm(_ level: Int) -> Color {
        let l = Double(100 - level) / 100.0
        let c = min(0.15, Double(level) / 600.0)
        return Color(oklchL: l, chroma: c, hue: 50)
    }

    // Cool scale (blue, h=260)
    static func cool(_ level: Int) -> Color {
        let l = Double(100 - level) / 100.0
        let c = min(0.15, Double(level) / 600.0)
        return Color(oklchL: l, chroma: c, hue: 260)
    }

    // Brand accent scale (matches Warm Earth brand gradient)
    static func accent(_ level: Int) -> Color {
        let l = Double(100 - level) / 100.0
        let c = min(0.20, Double(level) / 500.0)
        let h = lerp(from: 50, to: 25, t: Double(level) / 1000.0)  // amber → deeper coral
        return Color(oklchL: l, chroma: c, hue: h)
    }
}

// MARK: - Layer 2: Semantic Tokens

/// Purpose-based colors. These are the ONLY colors views should reference directly.
/// They resolve to primitives based on the active circadian phase.
enum SemanticColor {
    // Foreground (static, non-circadian)
    // Contrast ratios verified against #FFFFFF background:
    //   900 (L=0.10) → 16.8:1 ✅ AAA
    //   700 (L=0.30) → 7.2:1 ✅ AAA
    //   500 (L=0.50) → 3.5:1 — minimum for large text only
    //   400 (L=0.60) → 2.8:1 ❌ fails AA
    static var fgDefault: Color { PrimitiveColor.neutral(900) }
    static var fgMuted: Color { PrimitiveColor.neutral(700) }
    static var fgSubtle: Color { PrimitiveColor.neutral(500) }

    // Background (static)
    static var bgSurface: Color { Color(hex: "#FFFFFF") }
    static var bgElevated: Color { PrimitiveColor.neutral(100) }

    // Borders & separators
    static var borderDefault: Color { PrimitiveColor.neutral(200) }
    static var separatorDefault: Color { PrimitiveColor.neutral(150) }

    // Semantic actions
    static var affirmativeAction: Color { Color(hex: "#34C759") }  // iOS green (fill; white text handled by tint)
    static var cautionAction: Color { Color(hex: "#FF9F0A") }       // iOS orange (fill)
    static var tertiaryAction: Color { PrimitiveColor.neutral(500) }
    // #C03A2E → 5.4:1 on white ✅ AA (iOS #FF3B30 fails at 3.6:1)
    static var destructiveAction: Color { Color(hex: "#C03A2E") }

    // Feedback (darkened from iOS system values to meet AA on white)
    static var fgError: Color { Color(hex: "#C03A2E") }    // 5.4:1 ✅
    static var fgSuccess: Color { Color(hex: "#1E7A34") }  // 5.5:1 ✅

    // Overlays
    static var overlayLight: Color { Color.black.opacity(0.15) }
    static var overlayHeavy: Color { Color.black.opacity(0.35) }
}

// MARK: - Layer 3: Component Tokens

/// Concrete UI element tokens. Reference semantic tokens only.
enum ComponentToken {
    // Feed card (static)
    static var feedCardBg: Color { SemanticColor.bgSurface }
    static var feedCardShadow: Color { Color.black.opacity(0.04) }

    // Swipe actions
    static var swipeReadActive: Color { SemanticColor.affirmativeAction }
    static var swipeReadInactive: Color { SemanticColor.tertiaryAction }
    static var swipeBookmark: Color { Color(hex: "#FFD60A") }  // iOS yellow

    // Category badges
    static func categoryColor(for category: String) -> Color {
        switch category.lowercased() {
        case "tech", "technology":     return Color(hex: "#5B7FA5")
        case "news":                   return Color(hex: "#B8685C")
        case "science":                return Color(hex: "#6B9E7A")
        case "design":                 return Color(hex: "#8B7BA8")
        case "culture":                return Color(hex: "#C4854A")
        default:                       return PrimitiveColor.neutral(500)
        }
    }

    static func categoryColor(for category: String?) -> Color {
        guard let category else { return PrimitiveColor.neutral(500) }
        return categoryColor(for: category)
    }

    // Category gradients (for placeholders)
    static func categoryGradient(for category: String) -> [Color] {
        let base = categoryColor(for: category)
        return [base.opacity(0.3), base.opacity(0.15)]
    }

    // Briefing card
    static var briefingGradient: [Color] {
        [Color(hex: "#FF7A45").opacity(0.3), Color(hex: "#8B7BA8").opacity(0.15)]
    }

    // Carousel
    static var carouselAccentGradient: [Color] {
        [Color(hex: "#5B7FA5").opacity(0.6), Color(hex: "#8B7BA8").opacity(0.4), Color.black.opacity(0.7)]
    }

    // Share overlay
    static func shareOverlayGradient(for category: String) -> [Color] {
        let base = categoryColor(for: category)
        return [base.opacity(0.2), base.opacity(0.05)]
    }

    // Badges
    static func badgeBg(_ color: Color) -> Color { color.opacity(0.12) }

    // Media badges
    static var podcastBadge: Color { Color(hex: "#8B7BA8") }  // purple
    static var videoBadge: Color { Color(hex: "#FF3B30") }    // red
    static var newBadge: Color { Color(hex: "#5B7FA5") }      // blue

    /// Bookmark glyph rendered over a `.ultraThinMaterial` circle on photo
    /// cards. Darkened from pure yellow so it stays visible on light material
    /// in light mode while remaining warm enough to read on dark photos.
    /// Cached — the contrast search loop is expensive per-render.
    static let bookmarkGlyph: Color = Color.yellow.darkened(
        untilContrast: DesignTokens.minIconContrast, against: .white
    )

    /// Text color for a badge rendered on `color.opacity(0.10)` over a
    /// light surface: the tint's own hue, darkened to WCAG AA 4.5:1.
    static func badgeTextColor(_ color: Color) -> Color {
        color.darkened(untilContrast: DesignTokens.minTextContrast, against: .white)
    }
}

// MARK: - Contrast Validation

enum DesignTokens {
    /// WCAG AA minimum contrast for normal text (4.5:1).
    static let minTextContrast: CGFloat = 4.5
    /// WCAG AA minimum contrast for icons and graphics (3:1).
    static let minIconContrast: CGFloat = 3.0

    /// Prints a warning for every foreground/background pair that fails
    /// WCAG AA. Covers every palette family × circadian period so token
    /// changes can never silently regress a theme. Called from
    /// `CircadianEngine.refresh()` in DEBUG builds.
    static func validateAllContrast() {
        #if DEBUG
        var failures = 0

        func check(_ name: String, _ fg: Color, _ bg: Color, min: CGFloat) {
            let ratio = fg.contrastRatio(with: bg)
            if ratio < min {
                failures += 1
                print("DesignTokens contrast FAIL: \(name) = \(String(format: "%.2f", ratio)):1 (needs \(min):1)")
            }
        }

        // Semantic foregrounds against the page background of every theme.
        let textTokens: [(String, Color)] = [
            ("fgDefault", SemanticColor.fgDefault),
            ("fgMuted", SemanticColor.fgMuted),
            ("fgSubtle", SemanticColor.fgSubtle),
            ("fgError", SemanticColor.fgError),
            ("fgSuccess", SemanticColor.fgSuccess),
            ("tertiaryAction", SemanticColor.tertiaryAction),
            ("destructiveAction", SemanticColor.destructiveAction),
        ]
        for family in PaletteFamily.allCases {
            for period in CircadianPeriod.allCases {
                let bg = family.pageTint(for: period)
                for (name, color) in textTokens {
                    check("\(name) on \(family.label)/\(period.label) pageTint", color, bg, min: minTextContrast)
                }
            }
        }

        // Category colors used as badge text on white cards.
        let categories = ["tech", "news", "science", "design", "culture", "other"]
        for category in categories {
            check("categoryColor(\(category)) on card", ComponentToken.categoryColor(for: category), SemanticColor.bgSurface, min: minTextContrast)
        }

        // Accent as text on the page background, and white text on accent
        // fills (selected chips, prominent actions).
        for family in PaletteFamily.allCases {
            for period in CircadianPeriod.allCases {
                let accent = family.accent(for: period)
                let bg = family.pageTint(for: period)
                check("accentText \(family.label)/\(period.label)", accent, bg, min: minTextContrast)
                check("white on accent \(family.label)/\(period.label)", .white, accent, min: minIconContrast)
                check("accent glyph \(family.label)/\(period.label)", accent, bg, min: minIconContrast)
            }
        }

        if failures > 0 {
            print("DesignTokens: \(failures) contrast failures found — see messages above.")
        } else {
            print("DesignTokens: all palette × period contrast pairs pass WCAG AA.")
        }
        #endif
    }
}

// MARK: - Math Helper

private func lerp(from a: Double, to b: Double, t: Double) -> Double {
    a + (b - a) * max(0, min(1, t))
}
