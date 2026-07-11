import Foundation
import GRDB

// MARK: - Domain model

struct LibraryNode: Identifiable, Hashable, Sendable {
    var id: Int64
    var parentId: Int64?
    var name: String
    var sortOrder: Int
    var origin: SourceOrigin
    var enabled: Bool
    var childCount: Int = 0       // populated by query, not stored
    var sourceCount: Int = 0      // populated by query, not stored
}

// MARK: - GRDB Records

struct LibraryNodeRecord: Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var parentId: Int64?
    var name: String
    var sortOrder: Int
    var origin: String
    var enabled: Bool

    static let databaseTableName = "library_node"

    enum CodingKeys: String, CodingKey {
        case id
        case parentId = "parent_id"
        case name
        case sortOrder = "sort_order"
        case origin
        case enabled
    }

    func toNode() -> LibraryNode {
        LibraryNode(
            id: id!,
            parentId: parentId,
            name: name,
            sortOrder: sortOrder,
            origin: SourceOrigin(rawValue: origin) ?? .bundled,
            enabled: enabled
        )
    }
}

struct LibrarySourceRecord: Codable, FetchableRecord, PersistableRecord {
    var nodeId: Int64
    var sourceUrl: String

    static let databaseTableName = "library_source"

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case sourceUrl = "source_url"
    }
}

// MARK: - Derived table for source lookup

/// Joins library_node + library_source for fetching FeedSource metadata
/// without loading all sources into memory.
struct LibraryNodeSource: Codable, FetchableRecord {
    var nodeId: Int64
    var sourceUrl: String
    var nodeEnabled: Bool
    var parentEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case sourceUrl = "source_url"
        case nodeEnabled = "node_enabled"
        case parentEnabled = "parent_enabled"
    }
}

// MARK: - Recursive CTE query

extension LibraryNodeRecord {
    /// Returns all source_urls from enabled nodes in the active tree.
    /// Uses recursive CTE — a disabled parent excludes descendants
    /// regardless of their own enabled flag.
    static func activeSourceURLs(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            WITH RECURSIVE active_tree AS (
                SELECT id FROM library_node
                WHERE enabled = 1 AND parent_id IS NULL
                UNION ALL
                SELECT n.id FROM library_node n
                JOIN active_tree a ON n.parent_id = a.id
                WHERE n.enabled = 1
            )
            SELECT DISTINCT ls.source_url FROM library_source ls
            JOIN active_tree at ON ls.node_id = at.id
        """)
    }

    /// Returns flat list of enabled nodes for tree rendering.
    static func allNodes(_ db: Database) throws -> [LibraryNodeRecord] {
        try LibraryNodeRecord
            .order(Column("sort_order"))
            .fetchAll(db)
    }

    /// Returns child nodes for a given parent, ordered by sort_order.
    static func children(of parentId: Int64?, _ db: Database) throws -> [LibraryNodeRecord] {
        if let pid = parentId {
            return try LibraryNodeRecord
                .filter(Column("parent_id") == pid)
                .order(Column("sort_order"))
                .fetchAll(db)
        } else {
            return try LibraryNodeRecord
                .filter(Column("parent_id") == nil)
                .order(Column("sort_order"))
                .fetchAll(db)
        }
    }
}
