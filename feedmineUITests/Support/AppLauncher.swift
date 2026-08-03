import Foundation
import XCTest

// MARK: - App Launcher

/// Centralized app launch configuration for UI tests.
/// Uses the typed `TestConfiguration` launch arguments.
enum AppLauncher {
    /// Standard UI test launch with filters reset and onboarding skipped.
    static func launch(
        app: XCUIApplication,
        fixtureProfile: String? = nil,
        fixtureSeed: Int? = nil,
        networkProfile: String? = nil,
        fixedTheme: String? = nil,
        showOnboarding: Bool = false,
        locale: String? = "en"
    ) {
        app.launchArguments = buildArguments(
            fixtureProfile: fixtureProfile,
            fixtureSeed: fixtureSeed,
            networkProfile: networkProfile,
            fixedTheme: fixedTheme,
            showOnboarding: showOnboarding,
            locale: locale
        )
        app.launch()
    }

    /// Performance test launch — always skips onboarding, uses fixed data.
    static func launchPerformance(
        app: XCUIApplication,
        fixtureProfile: String = "heavy",
        fixtureSeed: Int = 42001,
        fixedTheme: String = "afternoon"
    ) {
        app.launchArguments = [
            "-performance-testing",
            "-fixture-profile", fixtureProfile,
            "-fixture-seed", "\(fixtureSeed)",
            "-fixed-theme", fixedTheme,
            "-UITestSkipOnboarding",
            "-UITestResetFilters",
            "-AppleLanguages", "(en)",
        ]
        app.launch()
    }

    /// Launch for accessibility audit — respects locale and Dynamic Type.
    static func launchAccessibility(
        app: XCUIApplication,
        locale: String = "en",
        showOnboarding: Bool = false
    ) {
        let args: [String] = [
            "-ui-testing",
            "-AppleLanguages", "(\(locale))",
            showOnboarding ? "-UITestShowOnboarding" : "-UITestSkipOnboarding",
            "-UITestResetFilters",
        ]
        app.launchArguments = args
        app.launch()
    }

    // MARK: - Helpers

    private static func buildArguments(
        fixtureProfile: String?,
        fixtureSeed: Int?,
        networkProfile: String?,
        fixedTheme: String?,
        showOnboarding: Bool,
        locale: String?
    ) -> [String] {
        var args: [String] = ["-ui-testing", "-UITestResetFilters"]

        if showOnboarding {
            args.append("-UITestShowOnboarding")
        } else {
            args.append("-UITestSkipOnboarding")
        }

        if let profile = fixtureProfile {
            args.append(contentsOf: ["-fixture-profile", profile])
        }
        if let seed = fixtureSeed {
            args.append(contentsOf: ["-fixture-seed", "\(seed)"])
        }
        if let net = networkProfile {
            args.append(contentsOf: ["-network-profile", net])
        }
        if let theme = fixedTheme {
            args.append(contentsOf: ["-fixed-theme", theme])
        }
        if let loc = locale {
            args.append(contentsOf: ["-AppleLanguages", "(\(loc))"])
        }

        return args
    }
}
