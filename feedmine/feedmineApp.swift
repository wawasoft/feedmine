import SwiftUI

@main
struct FeedmineApp: App {
    @State private var loader = FeedLoader()
    @State private var localeManager = LocaleManager.shared

    var body: some Scene {
        WindowGroup {
            FeedScreen()
                .environment(loader)
                .environment(localeManager)
                .onOpenURL { url in handleIncomingURL(url) }
        }
    }

    /// Handle incoming URLs:
    /// - feedmine://import?url=https://... → import a feed
    /// - file:///.../*.opml → import OPML file
    private func handleIncomingURL(_ url: URL) {
        if url.scheme == "feedmine" {
            // feedmine://import?url=https://example.com/feed.xml
            if url.host == "import",
               let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let feedURL = components.queryItems?.first(where: { $0.name == "url" })?.value {
                Task { _ = await loader.importFeeds(urls: [feedURL]) }
            }
        } else if url.isFileURL {
            // Opened an OPML file from Files app or AirDrop
            if url.pathExtension.lowercased() == "opml" || url.pathExtension.lowercased() == "xml" {
                Task {
                    guard url.startAccessingSecurityScopedResource() else { return }
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url) {
                        let fileName = url.deletingPathExtension().lastPathComponent
                        _ = await loader.importOPML(data: data, fileName: fileName)
                    }
                }
            }
        }
    }
}
