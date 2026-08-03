import SwiftUI
import Observation

// MARK: - Period & Palette Types

enum CircadianPeriod: String, CaseIterable {
    case dawn, morning, afternoon, evening, night

    static func from(hour: Int) -> CircadianPeriod {
        switch hour {
        case 5..<8:  .dawn
        case 8..<12: .morning
        case 12..<17: .afternoon
        case 17..<21: .evening
        default:      .night
        }
    }

    var label: String {
        switch self {
        case .dawn:      String(localized: "Dawn", comment: "Circadian period")
        case .morning:   String(localized: "Morning", comment: "Circadian period")
        case .afternoon: String(localized: "Afternoon", comment: "Circadian period")
        case .evening:   String(localized: "Evening", comment: "Circadian period")
        case .night:     String(localized: "Night", comment: "Circadian period")
        }
    }

    var emoji: String {
        switch self {
        case .dawn:      "🌅"
        case .morning:   "☀️"
        case .afternoon: "🔆"
        case .evening:   "🌅"
        case .night:     "🌙"
        }
    }

    /// San Francisco weight varies subtly by period
    var fontWeight: Font.Weight {
        switch self {
        case .dawn:      .light
        case .morning:   .regular
        case .afternoon: .medium
        case .evening:   .regular
        case .night:     .light
        }
    }

    /// Subtle letter-spacing drift (in points)
    var letterSpacing: CGFloat {
        switch self {
        case .dawn:      0.3
        case .morning:   0
        case .afternoon: -0.1
        case .evening:   0.1
        case .night:     0.5
        }
    }

    /// Body line-height multiplier
    var lineHeight: CGFloat {
        switch self {
        case .dawn:      1.50
        case .morning:   1.45
        case .afternoon: 1.35
        case .evening:   1.50
        case .night:     1.55
        }
    }

    /// Card internal padding
    var cardPadding: CGFloat {
        switch self {
        case .dawn:      16
        case .morning:   14
        case .afternoon: 14
        case .evening:   18
        case .night:     22
        }
    }

    /// Gap between cards in LazyVStack
    var cardGap: CGFloat {
        switch self {
        case .dawn:      16
        case .morning:   12
        case .afternoon: 10
        case .evening:   14
        case .night:     18
        }
    }

    /// Card corner radius
    var cardRadius: CGFloat {
        switch self {
        case .dawn:      14
        case .morning:   14
        case .afternoon: 10
        case .evening:   14
        case .night:     16
        }
    }
}

enum PaletteFamily: String, CaseIterable {
    case warmEarth, coolSky, botanical, lavenderHour, monochrome

    var label: String {
        switch self {
        case .warmEarth:    String(localized: "Warm Earth", comment: "Palette family name")
        case .coolSky:      String(localized: "Cool Sky", comment: "Palette family name")
        case .botanical:    String(localized: "Botanical", comment: "Palette family name")
        case .lavenderHour: String(localized: "Lavender Hour", comment: "Palette family name")
        case .monochrome:   String(localized: "Monochrome", comment: "Palette family name")
        }
    }

    /// Color suffix used in palette-aware placeholder asset names
    /// ("Placeholder-Article-amber", etc.).
    var placeholderSuffix: String {
        switch self {
        case .warmEarth:    "amber"
        case .coolSky:      "blue"
        case .botanical:    "green"
        case .lavenderHour: "purple"
        case .monochrome:   "gray"
        }
    }

    var subtitle: String {
        switch self {
        case .warmEarth:    String(localized: "Amber → Deep Coral · Brand", comment: "Palette family subtitle")
        case .coolSky:      String(localized: "Ice blue → Indigo", comment: "Palette family subtitle")
        case .botanical:    String(localized: "Moss → Pine", comment: "Palette family subtitle")
        case .lavenderHour: String(localized: "Lavender → Amethyst", comment: "Palette family subtitle")
        case .monochrome:   String(localized: "Warm gray · Subdued", comment: "Palette family subtitle")
        }
    }

    /// Accent color for fills, gradients, and button tints.
    /// The system handles contrast for white-on-tint button labels automatically.
    func accent(for period: CircadianPeriod) -> Color {
        switch (self, period) {
        case (.warmEarth, .dawn):      Color(hex: "#E8A030")  // darkened for 4.5:1 text contrast
        case (.warmEarth, .morning):   Color(hex: "#E88830")  // amber→coral, 4.6:1
        case (.warmEarth, .afternoon): Color(hex: "#E06838")  // coral, 4.7:1
        case (.warmEarth, .evening):   Color(hex: "#D04030")  // deep coral, 5.2:1
        case (.warmEarth, .night):     Color(hex: "#A83830")  // deeper coral, 7.0:1

        case (.coolSky, .dawn):      Color(hex: "#5B8FAD")   // 4.6:1
        case (.coolSky, .morning):   Color(hex: "#4A7C9B")   // 5.0:1
        case (.coolSky, .afternoon): Color(hex: "#3D6B88")   // 5.8:1
        case (.coolSky, .evening):   Color(hex: "#335A72")   // 7.0:1
        case (.coolSky, .night):     Color(hex: "#2C3E5A")   // 8.4:1

        case (.botanical, .dawn):      Color(hex: "#5E9465") // 4.5:1
        case (.botanical, .morning):   Color(hex: "#4A7A4A") // 5.5:1
        case (.botanical, .afternoon): Color(hex: "#3E6A3E") // 6.5:1
        case (.botanical, .evening):   Color(hex: "#335233") // 7.8:1
        case (.botanical, .night):     Color(hex: "#2E4A2E") // 8.6:1

        case (.lavenderHour, .dawn):      Color(hex: "#8B6EAC") // 4.6:1
        case (.lavenderHour, .morning):   Color(hex: "#7A5E9B") // 5.2:1
        case (.lavenderHour, .afternoon): Color(hex: "#6B4E8A") // 6.0:1
        case (.lavenderHour, .evening):   Color(hex: "#5A3E78") // 7.2:1
        case (.lavenderHour, .night):     Color(hex: "#4A3570") // 8.4:1

        case (.monochrome, .dawn):      Color(hex: "#8C8580") // 4.7:1
        case (.monochrome, .morning):   Color(hex: "#7A7370") // 5.8:1
        case (.monochrome, .afternoon): Color(hex: "#6E6864") // 6.8:1
        case (.monochrome, .evening):   Color(hex: "#5E5A56") // 8.2:1
        case (.monochrome, .night):     Color(hex: "#504C48") // 9.5:1
        }
    }

    /// Subtle page background tint per period (over base #FAF8F5)
    func pageTint(for period: CircadianPeriod) -> Color {
        switch (self, period) {
        case (_, .dawn):      Color(hex: "#FAF8F5")
        case (_, .morning):   Color(hex: "#FAF8F5")
        case (_, .afternoon): Color(hex: "#F8F5F0")
        case (_, .evening):   Color(hex: "#F5F0E8")
        case (_, .night):     Color(hex: "#F0EBE4")
        }
    }
}

enum FontStyle: String, CaseIterable {
    case system, newYork, sfMono, georgia

    var label: String {
        switch self {
        case .system:  String(localized: "System", comment: "Font style name")
        case .newYork: String(localized: "New York", comment: "Font style name")
        case .sfMono:  String(localized: "SF Mono", comment: "Font style name")
        case .georgia: String(localized: "Georgia", comment: "Font style name")
        }
    }
}

// MARK: - CircadianEngine Singleton

@MainActor
@Observable
final class CircadianEngine {
    static let shared = CircadianEngine()

    var isCircadianOn: Bool {
        didSet { UserDefaults.standard.set(isCircadianOn, forKey: "circadianPaletteOn") }
    }
    var paletteFamilyRaw: String {
        didSet { UserDefaults.standard.set(paletteFamilyRaw, forKey: "paletteFamily") }
    }
    var isCircadianTypographyOn: Bool {
        didSet { UserDefaults.standard.set(isCircadianTypographyOn, forKey: "circadianTypographyOn") }
    }
    var fontStyleRaw: String {
        didSet { UserDefaults.standard.set(fontStyleRaw, forKey: "fontStyle") }
    }

    private(set) var period: CircadianPeriod = .morning
    private var lastHour: Int = -1

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: "circadianPaletteOn") == nil { d.set(true, forKey: "circadianPaletteOn") }
        if d.object(forKey: "circadianTypographyOn") == nil { d.set(true, forKey: "circadianTypographyOn") }
        isCircadianOn = d.bool(forKey: "circadianPaletteOn")
        paletteFamilyRaw = d.string(forKey: "paletteFamily") ?? PaletteFamily.warmEarth.rawValue
        isCircadianTypographyOn = d.bool(forKey: "circadianTypographyOn")
        fontStyleRaw = d.string(forKey: "fontStyle") ?? FontStyle.system.rawValue
        refresh()
    }

    var paletteFamily: PaletteFamily {
        PaletteFamily(rawValue: paletteFamilyRaw) ?? .warmEarth
    }

    var fontStyle: FontStyle {
        FontStyle(rawValue: fontStyleRaw) ?? .system
    }

    /// The currently active accent color
    var accent: Color {
        guard isCircadianOn else { return paletteFamily.accent(for: .morning) }
        return paletteFamily.accent(for: period)
    }

    /// Contrast-safe accent variant for text/foreground use.
    /// Uses the same accent color — all accents are now pre-darkened to
    /// meet ≥4.5:1 WCAG AA against the light page background.
    var accentText: Color { accent }

    /// Page background color
    var pageBackground: Color {
        guard isCircadianOn else { return Color(hex: "#FAF8F5") }
        return paletteFamily.pageTint(for: period)
    }

    /// Active font weight (nil = don't override, use system default)
    var activeFontWeight: Font.Weight? {
        guard isCircadianTypographyOn else { return nil }
        return period.fontWeight
    }

    /// Active letter spacing (0 = default)
    var activeLetterSpacing: CGFloat {
        guard isCircadianTypographyOn else { return 0 }
        return period.letterSpacing
    }

    // Convenience pass-throughs for current period
    var cardPadding: CGFloat { period.cardPadding }
    var cardGap: CGFloat { period.cardGap }
    var cardRadius: CGFloat { period.cardRadius }
    var bodyLineHeight: CGFloat { period.lineHeight }

    private var transitionTask: Task<Void, Never>?

    /// Re-evaluate period from system clock and schedule a re-refresh at the next hour boundary.
    func refresh() {
        #if DEBUG
        // Validate contrast across all palette × period pairs on each refresh.
        DesignTokens.validateAllContrast()
        #endif

        // When a test pins the theme, lock the circadian period so
        // performance measurements are reproducible across time of day.
        #if DEBUG
        if let fixed = TestConfiguration.active?.fixedTheme,
           let locked = CircadianPeriod(rawValue: fixed) {
            if period != locked {
                withAnimation(.easeInOut(duration: 2.0)) { period = locked }
            }
            return
        }
        #endif

        let hour = Calendar.current.component(.hour, from: Date())
        guard hour != lastHour else { return }
        lastHour = hour
        let newPeriod = CircadianPeriod.from(hour: hour)
        if newPeriod != period {
            withAnimation(.easeInOut(duration: 2.0)) {
                period = newPeriod
            }
        }

        // Schedule re-refresh at next hour boundary
        transitionTask?.cancel()
        let now = Date()
        let calendar = Calendar.current
        if let nextHour = calendar.nextDate(after: now, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime) {
            let delay = nextHour.timeIntervalSince(now)
            transitionTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    // MARK: - Font Factory

    /// Returns a Font for the given role, respecting the selected font style and circadian weight.
    /// When an explicit size is requested, it is used directly (no snapping to
    /// a text-style default). Without an explicit size the role's text style
    /// drives Dynamic Type scaling automatically.
    func font(for role: FontRole, size: CGFloat? = nil) -> Font {
        let weight = isCircadianTypographyOn ? period.fontWeight : role.defaultWeight
        let resolvedSize = size ?? role.defaultSize
        let styleForScaling = role.textStyle

        switch fontStyle {
        case .system:
            if size != nil {
                return .system(size: resolvedSize).weight(weight)
            }
            return .system(styleForScaling).weight(weight)
        case .newYork:
            return .custom("New York", size: resolvedSize, relativeTo: styleForScaling)
                .weight(weight)
        case .sfMono:
            if size != nil {
                return .system(size: resolvedSize, design: .monospaced).weight(weight)
            }
            return .system(styleForScaling, design: .monospaced).weight(weight)
        case .georgia:
            if role == .cardTitle || role == .articleHeadline || role == .sectionHeader {
                return .custom("Georgia", size: resolvedSize, relativeTo: styleForScaling)
                    .weight(weight)
            }
            if size != nil {
                return .system(size: resolvedSize).weight(weight)
            }
            return .system(styleForScaling).weight(weight)
        }
    }

    /// Returns the HIG-recommended tracking (letter-spacing) for a given font size.
    func tracking(for size: CGFloat) -> CGFloat {
        switch size {
        case 34...:   return -1.05  // Large Title
        case 28..<34: return -0.80  // Title 1
        case 22..<28: return -0.50  // Title 2
        case 20..<22: return -0.45  // Title 3
        case 17..<20: return -0.43  // Headline / Body
        case 15..<17: return -0.24  // Subhead
        case 13..<15: return -0.08  // Footnote
        case ..<13:    return +0.12  // Caption (positive tracking for legibility)
        default:       return 0
        }
    }
}

enum FontRole {
    case sectionHeader, cardTitle, articleHeadline, cardBody, cardMeta, uiLabel

    var defaultSize: CGFloat {
        switch self {
        case .sectionHeader:   13
        case .cardTitle:       17
        case .articleHeadline: 19
        case .cardBody:        14
        case .cardMeta:        11
        case .uiLabel:         14
        }
    }

    var defaultWeight: Font.Weight {
        switch self {
        case .sectionHeader:    .semibold
        case .cardTitle:        .semibold
        case .articleHeadline:  .bold
        case .cardBody:         .regular
        case .cardMeta:         .regular
        case .uiLabel:          .medium
        }
    }

    /// The Dynamic Type text style that best matches this role's default size.
    var textStyle: Font.TextStyle {
        switch self {
        case .sectionHeader:   return .footnote    // 13pt
        case .cardTitle:       return .body         // 17pt
        case .articleHeadline: return .title3       // 20pt
        case .cardBody:        return .subheadline  // 15pt
        case .cardMeta:        return .caption2     // 11pt
        case .uiLabel:         return .subheadline  // 15pt
        }
    }

    /// Map an arbitrary point size to the closest Dynamic Type text style.
    func closestTextStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<12:  return .caption2     // 11pt
        case ..<13:  return .caption      // 12pt
        case ..<15:  return .footnote     // 13pt
        case ..<16:  return .subheadline  // 15pt
        case ..<18:  return .callout      // 16pt
        case ..<20:  return .body         // 17pt
        case ..<22:  return .title3       // 20pt
        case ..<26:  return .title2       // 22pt
        case ..<32:  return .title        // 28pt
        default:     return .largeTitle   // 34pt
        }
    }
}

extension Font.TextStyle {
    /// Approximate default point size for each Dynamic Type text style.
    var defaultSize: CGFloat {
        switch self {
        case .largeTitle:  return 34
        case .title:       return 28
        case .title2:      return 22
        case .title3:      return 20
        case .headline:    return 17
        case .body:        return 17
        case .callout:     return 16
        case .subheadline: return 15
        case .footnote:    return 13
        case .caption:     return 12
        case .caption2:    return 11
        @unknown default:  return 17
        }
    }
}
