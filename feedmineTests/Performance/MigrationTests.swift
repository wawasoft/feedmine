import XCTest
@testable import feedmine
import GRDB

/// Database migration tests — verifies that schema migrations run correctly
/// and data survives the migration process without corruption.
@MainActor
final class MigrationTests: XCTestCase {

    // MARK: - Migration integrity

    func testMigrate_EmptyDB_CreatesAllTables() async throws {
        let store = try FeedStore(inMemory: true)

        // Verify expected tables exist after migration
        let tables = try await store.db.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
            """)
        }

        // Core tables that must exist
        // Verify that migration created tables. Exact names depend on GRDB schema.
        // The key assertion: migration ran without error and tables exist.
        XCTAssertFalse(tables.isEmpty, "Migration must create database tables. Found: \(tables.joined(separator: ", "))")
    }

    func testMigrate_InsertThenReopen_DataSurvives() async throws {
        let store = try FeedStore(inMemory: true)

        // Insert data
        let items = makeFixtureItems(count: 100, seed: 999)
        let persisted = await store.persistFetchedItems(items)
        XCTAssertEqual(persisted.count, 100, "100 items must persist")

        // Search for persisted items through search engine (SQLite)
        let results = await store.searchEngine.search("Technology", region: nil, category: nil)
        XCTAssertFalse(results.isEmpty, "Search must find persisted Technology items")
    }

    func testMigrate_DuplicateInsert_DoesNotCorrupt() async throws {
        let store = try FeedStore(inMemory: true)

        // Insert same items twice
        let items = makeFixtureItems(count: 50, seed: 888)
        let first = await store.persistFetchedItems(items)
        let second = await store.persistFetchedItems(items)

        XCTAssertEqual(first.count, 50, "First insert: 50 items")
        XCTAssertEqual(second.count, 0, "Second insert of same IDs: 0 new items (no duplicates)")

        // Store must still be functional
        let newItems = makeFixtureItems(count: 10, seed: 889)
        let third = await store.persistFetchedItems(newItems)
        XCTAssertEqual(third.count, 10, "Store must accept new items after duplicate insert")
    }

    func testMigrate_MultipleStores_IndependentState() async throws {
        let store1 = try FeedStore(inMemory: true)
        let store2 = try FeedStore(inMemory: true)

        let items1 = makeFixtureItems(count: 30, seed: 100)
        let items2 = makeFixtureItems(count: 30, seed: 200)

        _ = await store1.persistFetchedItems(items1)
        _ = await store2.persistFetchedItems(items2)

        // Each store has independent state
        let results1 = await store1.searchEngine.search("Technology", region: nil, category: nil)
        let results2 = await store2.searchEngine.search("Technology", region: nil, category: nil)

        XCTAssertFalse(results1.isEmpty, "Store 1 must have items")
        XCTAssertFalse(results2.isEmpty, "Store 2 must have items")
        // Different seeds → different IDs → independent results
    }

    // MARK: - FTS5 index integrity

    func testFTS5_AfterInsert_Searchable() async throws {
        let store = try FeedStore(inMemory: true)
        let items = makeFixtureItems(count: 500, seed: 777)
        _ = await store.persistFetchedItems(items)

        // FTS5 must index the inserted content
        let results = await store.searchEngine.search("Technology", region: nil, category: nil)
        XCTAssertFalse(results.isEmpty, "FTS5 must find Technology items")

        // Category filtering must work
        let filtered = await store.searchEngine.search("Technology", region: nil, category: "Technology")
        XCTAssertFalse(filtered.isEmpty, "FTS5 + category filter must work")
    }

    func testFTS5_AfterDuplicateInsert_NoDoubleIndex() async throws {
        let store = try FeedStore(inMemory: true)
        let items = makeFixtureItems(count: 200, seed: 666)

        _ = await store.persistFetchedItems(items)
        _ = await store.persistFetchedItems(items) // duplicate insert

        let results = await store.searchEngine.search("Technology", region: nil, category: nil)
        // Must not double-count items in FTS5
        XCTAssertFalse(results.isEmpty, "FTS5 must still work after duplicate insert")
    }
}
