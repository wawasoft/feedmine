import SwiftUI
import BackgroundTasks

@MainActor
final class SmartFeedBackgroundScheduler {
    static let shared = SmartFeedBackgroundScheduler()
    static let taskIdentifier = "com.feedmine.app.smart-feed-refresh"

    private weak var loader: FeedLoader?
    private var isRegistered = false

    private init() {}

    func register() {
        guard !isRegistered else { return }
        isRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                SmartFeedBackgroundScheduler.shared.handle(refreshTask)
            }
        }
        if !isRegistered {
            Log.feed.error("Could not register Smart Feed background refresh")
        }
    }

    func configure(loader: FeedLoader) {
        self.loader = loader
    }

    func schedule() {
        guard isRegistered else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        // This is an earliest date, not a promise. iOS chooses the actual
        // execution time from usage, battery, connectivity, and system load.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.feed.warning(
                "Smart Feed background refresh was not scheduled: \(error.localizedDescription)"
            )
        }
    }

    private func handle(_ systemTask: BGAppRefreshTask) {
        // Re-enqueue first so a process termination during this slice does not
        // break the persistent refresh chain.
        schedule()

        let activeLoader = loader ?? FeedLoader()
        let work = Task { @MainActor in
            await activeLoader.performSmartFeedBackgroundRefresh()
        }
        systemTask.expirationHandler = {
            work.cancel()
        }
        Task {
            let succeeded = await work.value
            systemTask.setTaskCompleted(success: succeeded)
        }
    }
}

@main
struct FeedmineApp: App {
    @State private var loader = FeedLoader()
    @State private var localeManager = LocaleManager.shared
    @State private var circadianEngine = CircadianEngine.shared
    @State private var audioPlayer = AudioPlayerManager.shared
    @State private var contentFilters = ContentFilterStore.shared

    init() {
        if ProcessInfo.processInfo.arguments.contains("-UITestResetFilters") {
            resetFiltersForUITestLaunch()
        }
        if ProcessInfo.processInfo.arguments.contains("-UITestShowOnboarding") {
            UserDefaults.standard.set(false, forKey: Keys.hasSeenOnboarding)
        } else if ProcessInfo.processInfo.arguments.contains("-UITestSkipOnboarding") {
            UserDefaults.standard.set(true, forKey: Keys.hasSeenOnboarding)
        }
        SmartFeedBackgroundScheduler.shared.register()
        FeedMetrics.event("Process.started")
        FeedMetrics.memory("processStarted")
    }

    /// UI cases must not inherit a taxonomy or language intersection from a
    /// previous case. This launch argument is only supplied by the UI target.
    private func resetFiltersForUITestLaunch() {
        Settings.filterRegion = nil
        Settings.filterTaxonomyNodes = []
        Settings.filterContentType = FeedLoader.ContentType.all.rawValue
        Settings.filterLanguages = []
        Settings.filterMood = FeedLoader.MoodFilter.all.rawValue
        Settings.filterSetAt = 0
        Settings.hasInitializedLanguageDefault = true
        TaxonomyStore.shared.clearSelection()
        UserDefaults.standard.synchronize()
    }

    var body: some Scene {
        WindowGroup {
            FeedScreen()
                .environment(loader)
                .environment(localeManager)
                .environment(circadianEngine)
                .environment(audioPlayer)
                .environment(contentFilters)
                .onOpenURL { url in handleIncomingURL(url) }
                .task {
                    SmartFeedBackgroundScheduler.shared.configure(loader: loader)
                }
        }
    }

    /// Handle incoming URLs:
    /// - feedmine://import?url=https://... → import a feed
    /// - file:///.../*.opml → import OPML file
    @MainActor
    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "feedmine" {
            if url.host == "import",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let feedURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
               !feedURL.isEmpty {
                Task {
                    let result = await loader.importFeeds(urls: [feedURL])
                    NotificationCenter.default.post(
                        name: .feedImportCompleted,
                        object: nil,
                        userInfo: ["message": result.importedCount > 0
                            ? "\(result.importedCount) feed\(result.importedCount == 1 ? "" : "s") imported"
                            : "Could not import feed"]
                    )
                }
            } else {
                NotificationCenter.default.post(
                    name: .feedImportCompleted,
                    object: nil,
                    userInfo: ["message": "Invalid import link"]
                )
            }
        } else if url.isFileURL {
            if url.pathExtension.lowercased() == "opml" || url.pathExtension.lowercased() == "xml" {
                Task {
                    guard url.startAccessingSecurityScopedResource() else {
                        NotificationCenter.default.post(name: .feedImportCompleted, object: nil,
                            userInfo: ["message": "Could not access file"])
                        return
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    guard let data = try? Data(contentsOf: url) else {
                        NotificationCenter.default.post(name: .feedImportCompleted, object: nil,
                            userInfo: ["message": "Could not read file"])
                        return
                    }
                    let fileName = url.deletingPathExtension().lastPathComponent
                    let result = await loader.importOPML(data: data, fileName: fileName)
                    NotificationCenter.default.post(
                        name: .feedImportCompleted,
                        object: nil,
                        userInfo: ["message": result.importedCount > 0
                            ? "\(result.importedCount) feed\(result.importedCount == 1 ? "" : "s") imported from \(fileName)"
                            : "Could not import feeds from \(fileName)"]
                    )
                }
            }
        }
    }
}
