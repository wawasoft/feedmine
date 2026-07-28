import SwiftUI

/// First-run gate for the transparent Curated Feed onboarding.
///
/// FeedScreen continues loading the ordinary feed behind this full-screen
/// surface, so the comparisons can use real stories as they arrive.
struct OnboardingTipsView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        if !hasSeenOnboarding {
            CuratedOnboardingView(
                isFirstRun: true,
                onCancel: complete,
                onSaved: { feed in
                    NotificationCenter.default.post(
                        name: .onboardingDidSaveCuratedFeed,
                        object: nil,
                        userInfo: ["feedName": feed.name]
                    )
                    complete()
                }
            )
            .transition(.opacity)
            .zIndex(100)
        }
    }

    private func complete() {
        withAnimation(.easeInOut(duration: 0.4)) {
            hasSeenOnboarding = true
        }
    }
}

extension Notification.Name {
    static let onboardingDidSaveCuratedFeed = Notification.Name("onboardingDidSaveCuratedFeed")
}
