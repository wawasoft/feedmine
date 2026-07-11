import Foundation
import GRDB

// MARK: - Domain model

struct Channel: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var sortOrder: Int
}

// MARK: - GRDB Records

struct ChannelRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String
    var sortOrder: Int

    static let databaseTableName = "channel"

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sortOrder = "sort_order"
    }

    func toChannel() -> Channel {
        Channel(id: id!, name: name, sortOrder: sortOrder)
    }
}

struct ChannelNodeRecord: Codable, FetchableRecord, PersistableRecord {
    var channelId: Int64
    var nodeId: Int64

    static let databaseTableName = "channel_node"

    enum CodingKeys: String, CodingKey {
        case channelId = "channel_id"
        case nodeId = "node_id"
    }

    /// Returns all node IDs for a channel
    static func nodeIDs(for channelId: Int64, _ db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT node_id FROM channel_node WHERE channel_id = ?
        """, arguments: [channelId])
    }

    /// Returns source URLs for a channel by joining through library_node + library_source
    static func sourceURLs(for channelId: Int64, _ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT ls.source_url FROM library_source ls
            JOIN channel_node cn ON ls.node_id = cn.node_id
            WHERE cn.channel_id = ?
        """, arguments: [channelId])
    }
}
