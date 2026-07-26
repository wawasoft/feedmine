import XCTest
import GRDB
@testable import feedmine

/// Tests the public API surface of BookmarkStore without requiring
/// a full FeedStore environment. Uses in-memory databases.
@MainActor
final class BookmarkStoreTests: XCTestCase {

    var userDB: DatabaseQueue!
    var contentDB: DatabaseQueue!
    var store: BookmarkStore!

    override func setUp() async throws {
        userDB = try DatabaseQueue(configuration: inMemoryConfig)
        contentDB = try DatabaseQueue(configuration: inMemoryConfig)
        try await migrateSchema()
        store = BookmarkStore(userDB: userDB, contentDB: contentDB)
    }

    override func tearDown() {
        store = nil
        userDB = nil
        contentDB = nil
    }

    private var inMemoryConfig: Configuration {
        var config = Configuration()
        config.prepareDatabase { _ in }
        return config
    }

    private func migrateSchema() async throws {
        try await userDB.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS bookmark_list (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    sort_order INTEGER DEFAULT 0,
                    created_at INTEGER DEFAULT 0,
                    is_default INTEGER DEFAULT 0,
                    search_query TEXT,
                    search_region TEXT,
                    search_category TEXT,
                    search_active INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS bookmark_item (
                    list_id INTEGER NOT NULL,
                    item_id TEXT NOT NULL,
                    added_at INTEGER DEFAULT 0,
                    PRIMARY KEY (list_id, item_id)
                )
                """)
        }
        try await contentDB.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS bookmark_list (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    sort_order INTEGER DEFAULT 0,
                    is_default INTEGER DEFAULT 0
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS bookmark_item (
                    list_id INTEGER NOT NULL,
                    item_id TEXT NOT NULL,
                    added_at INTEGER DEFAULT 0,
                    PRIMARY KEY (list_id, item_id)
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS feed_item (
                    id TEXT PRIMARY KEY,
                    source_title TEXT,
                    source_url TEXT,
                    category TEXT,
                    title TEXT,
                    excerpt TEXT,
                    url TEXT,
                    image_url TEXT,
                    published_at INTEGER,
                    audio_url TEXT,
                    duration REAL,
                    region TEXT,
                    language TEXT,
                    is_read INTEGER DEFAULT 0,
                    opened_at INTEGER,
                    fetched_at INTEGER,
                    section_day_offset INTEGER DEFAULT 0
                )
                """)
        }
    }

    func testCreateAndListBookmarks() async throws {
        let id = try await store.createBookmarkList(name: "Test List")
        XCTAssertGreaterThan(id, 0)

        let lists = try await store.allBookmarkLists()
        XCTAssertTrue(lists.contains { $0.name == "Test List" })
    }

    func testDefaultListIDReturnsOne() {
        let id = store.defaultListID()
        XCTAssertGreaterThan(id, 0)
    }

    func testDeleteNonDefaultList() async throws {
        let lists = try await store.allBookmarkLists()
        guard let nonDefault = lists.first(where: { !$0.isDefault }) else {
            // If no non-default list exists, create one
            let id = try await store.createBookmarkList(name: "Deletable")
            try await store.deleteBookmarkList(id)
            let updated = try await store.allBookmarkLists()
            XCTAssertFalse(updated.contains { $0.id == id })
            return
        }
        try await store.deleteBookmarkList(nonDefault.id)
        let updated = try await store.allBookmarkLists()
        XCTAssertFalse(updated.contains { $0.id == nonDefault.id })
    }
}
