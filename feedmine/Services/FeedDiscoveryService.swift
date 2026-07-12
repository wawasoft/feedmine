import Foundation

/// Discovers RSS/Atom feed URLs from websites.
/// Stub — full implementation in Task 3.
struct FeedDiscoveryService: Sendable {

    /// Detect whether a URL is already a direct feed URL.
    static func isDirectFeedURL(_ url: URL) -> Bool {
        let path = url.pathExtension.lowercased()
        if ["xml", "rss", "atom"].contains(path) { return true }
        let absolute = url.absoluteString.lowercased()
        if absolute.contains("youtube.com/feeds") { return true }
        if absolute.hasSuffix("/feed") || absolute.hasSuffix("/rss") { return true }
        if absolute.contains("anchor.fm") || absolute.contains("spreaker.com") { return true }
        return false
    }

    /// Stub — returns empty. Full implementation in Task 3.
    static func discover(url: URL) async throws -> [PendingItem.DiscoveredFeed] {
        []
    }
}
