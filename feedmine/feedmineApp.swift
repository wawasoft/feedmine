import SwiftUI

@main
struct FeedmineApp: App {
    @State private var store = try! FeedStore()
    @State private var loader: FeedLoader?
    @State private var localeManager = LocaleManager.shared
    @State private var pendingMonitor: PendingItemsMonitor?
    @Environment(\.scenePhase) private var scenePhase
    @State private var deepLinkArticleID: String?

    var body: some Scene {
        WindowGroup {
            if let loader, let pendingMonitor {
                FeedScreen()
                    .environment(loader)
                    .environment(localeManager)
                    .environment(pendingMonitor)
                    .environment(\.deepLinkArticleID, deepLinkArticleID)
                    .onOpenURL { url in
                        handleDeepLink(url)
                    }
            } else {
                Color.clear
                    .task {
                        loader = FeedLoader(store: store)
                        pendingMonitor = PendingItemsMonitor(store: store)
                    }
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
