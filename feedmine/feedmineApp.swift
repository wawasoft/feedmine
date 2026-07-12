import SwiftUI

@main
struct FeedmineApp: App {
    @State private var loader = FeedLoader()
    @State private var localeManager = LocaleManager.shared
    @State private var pendingMonitor: PendingItemsMonitor!
    @Environment(\.scenePhase) private var scenePhase
    @State private var deepLinkArticleID: String?

    var body: some Scene {
        WindowGroup {
            FeedScreen()
                .environment(loader)
                .environment(localeManager)
                .environment(pendingMonitor)
                .environment(\.deepLinkArticleID, deepLinkArticleID)
                .onAppear {
                    if pendingMonitor == nil {
                        pendingMonitor = PendingItemsMonitor(store: loader.store)
                    }
                }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            pendingMonitor?.scenePhaseDidChange(newPhase)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "feedmine" else { return }

        switch url.host {
        case "article":
            let id = url.lastPathComponent
            guard !id.isEmpty, id != "article" else { break }
            deepLinkArticleID = id
        default:
            break
        }
    }
}
