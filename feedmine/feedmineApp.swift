import SwiftUI

@main
struct FeedmineApp: App {
    @State private var loader = FeedLoader()
    @State private var localeManager = LocaleManager.shared
    @State private var incomingURL: URL?

    var body: some Scene {
        WindowGroup {
            FeedScreen(incomingURL: $incomingURL)
                .environment(loader)
                .environment(localeManager)
                .onOpenURL { url in
                    incomingURL = url
                }
        }
    }
}
