import SwiftUI

@main
struct FeedmineApp: App {
    @State private var loader = FeedLoader()
    @State private var localeManager = LocaleManager.shared
    @State private var pendingMonitor: PendingItemsMonitor!
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            FeedScreen()
                .environment(loader)
                .environment(localeManager)
                .environment(pendingMonitor)
                .onAppear {
                    if pendingMonitor == nil {
                        pendingMonitor = PendingItemsMonitor(store: loader.store)
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            pendingMonitor?.scenePhaseDidChange(newPhase)
        }
    }
}
