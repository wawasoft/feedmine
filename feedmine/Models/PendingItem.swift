import Foundation

/// A single pending item in the Share Extension → main app queue.
/// Serialized to JSON in the App Group container.
struct PendingItem: Codable, Identifiable, Sendable {
    let id: String          // UUID string
    let type: ItemType
    let sourceURL: String
    let foundFeeds: [DiscoveredFeed]
    let fileName: String?   // only for opml_import
    let feedCount: Int?     // only for opml_import
    let receivedAt: Int     // epoch seconds

    struct DiscoveredFeed: Codable, Sendable {
        let title: String
        let url: String
    }

    enum ItemType: String, Codable, Sendable {
        case feedDirect = "feed_direct"
        case feedDiscovery = "feed_discovery"
        case opmlImport = "opml_import"
    }
}
