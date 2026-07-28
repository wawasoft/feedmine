import Foundation
import GRDB

/// Owns `user.sqlite` — user-owned state that survives catalog rebuilds.
///
/// Separates bookmark identity (what is bookmarked) from the content database
/// where `feed_item` rows live. Bookmark queries that need `FeedItem` joins
/// fetch IDs from here and hydrate from `feedmine.sqlite` separately.
///
/// Schema version is tracked via GRDB migrator so the database can evolve
/// independently of `feedmine.sqlite`.
@MainActor
final class UserStateStore {
    let db: DatabaseQueue

    private static var dbURL: URL {
        // User-owned data (bookmarks, smart feeds, collections) belongs in
        // Application Support — it should survive and not be exposed in the
        // Files app or inflated into iCloud backups unnecessarily.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Feedmine", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("user.sqlite")
    }

    /// One-time migration: move user.sqlite from Documents (pre-1.0 layout)
    /// to Application Support/Feedmine/. Called before the database is opened.
    private static func migrateUserDBFromDocumentsIfNeeded() {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let oldPath = docs.appendingPathComponent("user.sqlite").path

        guard fm.fileExists(atPath: oldPath) else { return }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let newDir = appSupport.appendingPathComponent("Feedmine", isDirectory: true)
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)

        let newPath = newDir.appendingPathComponent("user.sqlite").path
        let suffixes = ["", "-wal", "-shm"]
        var moved: [(String, String)] = []
        do {
            for suffix in suffixes {
                let src = oldPath + suffix
                let dst = newPath + suffix
                guard fm.fileExists(atPath: src) else { continue }
                try fm.moveItem(atPath: src, toPath: dst)
                moved.append((src, dst))
            }
            Log.db.info("Migrated user.sqlite from Documents to Application Support/Feedmine/")
        } catch {
            for (src, dst) in moved {
                try? fm.moveItem(atPath: dst, toPath: src)
            }
            Log.db.error("User DB migration to Application Support failed, keeping old location: \(error)")
        }
    }

    // MARK: - Init

    init(inMemory: Bool = false) throws {
        if inMemory {
            db = try DatabaseQueue(configuration: UserStateStore.dbConfig)
        } else {
            Self.migrateUserDBFromDocumentsIfNeeded()
            db = try DatabaseQueue(path: Self.dbURL.path, configuration: UserStateStore.dbConfig)
        }
        try UserStateStore.migrate(db)
    }

    // MARK: - Config

    private static var dbConfig: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return config
    }

    // MARK: - Schema

    private static func migrate(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_bookmarks") { db in
            try db.create(table: "bookmark_list") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("is_default", .integer).notNull().defaults(to: 0)
                t.column("search_query", .text)
                t.column("search_region", .text)
                t.column("search_category", .text)
                t.column("search_active", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "bookmark_item") { t in
                t.column("list_id", .integer).notNull()
                    .references("bookmark_list", onDelete: .cascade)
                t.column("item_id", .text).notNull()
                t.column("added_at", .integer).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.primaryKey(["list_id", "item_id"])
            }

            try db.create(index: "idx_user_bookmark_item_list",
                          on: "bookmark_item", columns: ["list_id", "sort_order"])
            try db.create(index: "idx_user_bookmark_item_item",
                          on: "bookmark_item", columns: ["item_id"])

            // Default "Favorites" list
            try db.execute(sql: """
                INSERT INTO bookmark_list (name, sort_order, created_at, is_default)
                VALUES ('Favorites', 0, \(Int(Date().timeIntervalSince1970)), 1)
            """)
        }

        migrator.registerMigration("v2_source_collections") { db in
            try db.create(table: "source_collection") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
            }

            try db.create(table: "source_collection_member") { t in
                t.column("collection_id", .integer).notNull()
                    .references("source_collection", onDelete: .cascade)
                t.column("source_url", .text).notNull()
                t.column("title_snapshot", .text).notNull()
                t.column("media_kind", .text).notNull().defaults(to: MediaKind.text.rawValue)
                t.column("added_at", .integer).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.primaryKey(["collection_id", "source_url"])
            }
            try db.create(index: "idx_source_collection_order",
                          on: "source_collection", columns: ["sort_order", "created_at"])
            try db.create(index: "idx_source_collection_member_order",
                          on: "source_collection_member", columns: ["collection_id", "sort_order"])
            try db.create(index: "idx_source_collection_member_source",
                          on: "source_collection_member", columns: ["source_url"])
        }

        migrator.registerMigration("v3_user_metadata") { db in
            try db.create(table: "user_metadata") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("v4_smart_feeds") { db in
            try db.create(table: "smart_feed") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("definition_json", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }
            try db.create(
                index: "idx_smart_feed_order",
                on: "smart_feed",
                columns: ["sort_order", "created_at"]
            )
        }

        migrator.registerMigration("v5_smart_feed_refresh_state") { db in
            try db.alter(table: "smart_feed") { table in
                table.add(column: "last_refresh_attempt_at", .integer)
                table.add(column: "last_refresh_success_at", .integer)
                table.add(column: "refresh_failure_count", .integer)
                    .notNull()
                    .defaults(to: 0)
            }
            try db.create(
                index: "idx_smart_feed_refresh_due",
                on: "smart_feed",
                columns: ["last_refresh_attempt_at", "refresh_failure_count"]
            )
        }

        migrator.registerMigration("v6_curated_feeds") { db in
            try db.create(table: "curated_feed") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("definition_json", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .integer).notNull()
                t.column("updated_at", .integer).notNull()
            }
            try db.create(
                index: "idx_curated_feed_order",
                on: "curated_feed",
                columns: ["sort_order", "created_at"]
            )
        }

        try migrator.migrate(db)
    }

    // MARK: - Legacy Migration

    private static let legacyMigrationMarker = "legacy_bookmark_migration_v1_completed"

    /// Copy bookmark data from `feedmine.sqlite` into `user.sqlite`.
    /// Idempotent — checks marker first, validates counts after.
    /// Synchronous because all operations are local SQL (fast — typically
    /// hundreds of rows at most). Called during init so migration completes
    /// before the UI loads favorites.
    func migrateFromLegacy(legacyDB: DatabaseQueue) throws {
        // Guard: already completed
        let alreadyDone = try db.read { db in
            try String.fetchOne(db, sql: """
                SELECT value FROM user_metadata WHERE key = ?
                """, arguments: [Self.legacyMigrationMarker])
        } == "1"
        guard !alreadyDone else { return }

        let (lists, items) = try legacyDB.read { legacy in
            (try BookmarkListRecord.fetchAll(legacy),
             try BookmarkItemRecord.fetchAll(legacy))
        }

        guard !lists.isEmpty || !items.isEmpty else {
            // Nothing to migrate — still record marker so we don't re-check
            try db.write { user in
                try user.execute(sql: """
                    INSERT INTO user_metadata (key, value) VALUES (?, '1')
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """, arguments: [Self.legacyMigrationMarker])
            }
            return
        }

        try db.write { user in
            for list in lists {
                try user.execute(sql: """
                    INSERT OR IGNORE INTO bookmark_list
                        (id, name, sort_order, created_at, is_default,
                         search_query, search_region, search_category, search_active)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    list.id, list.name, list.sortOrder, list.createdAt,
                    list.isDefault, list.searchQuery, list.searchRegion,
                    list.searchCategory, list.searchActive,
                ])
            }
            for item in items {
                // Skip items where list_id doesn't exist (orphaned reference)
                let listExists = try Int.fetchOne(user,
                    sql: "SELECT 1 FROM bookmark_list WHERE id = ? LIMIT 1",
                    arguments: [item.listId]) != nil
                guard listExists else { continue }
                try user.execute(sql: """
                    INSERT OR IGNORE INTO bookmark_item
                        (list_id, item_id, added_at, sort_order)
                    VALUES (?, ?, ?, ?)
                """, arguments: [item.listId, item.itemId, item.addedAt, item.sortOrder])
            }

            // Validate: migrated item count should be reasonable
            let migratedLists = try Int.fetchOne(user,
                sql: "SELECT COUNT(*) FROM bookmark_list") ?? 0
            let migratedItems = try Int.fetchOne(user,
                sql: "SELECT COUNT(*) FROM bookmark_item") ?? 0
            Log.db.info("""
                Legacy migration complete: \(lists.count) lists → \(migratedLists), \
                \(items.count) items → \(migratedItems)
                """)

            // Record marker so future launches skip the check
            try user.execute(sql: """
                INSERT INTO user_metadata (key, value) VALUES (?, '1')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [Self.legacyMigrationMarker])
        }
    }

    /// True if the legacy DB has data that hasn't been migrated yet.
    /// Checks the explicit marker first (idempotent), then falls back to
    /// inspecting actual bookmark content — not just list count.
    func needsLegacyMigration(legacyDB: DatabaseQueue) throws -> Bool {
        // Check marker first — one-and-done
        let alreadyCompleted = try db.read { db in
            try String.fetchOne(db, sql: """
                SELECT value FROM user_metadata WHERE key = ?
                """, arguments: [Self.legacyMigrationMarker])
        } == "1"
        if alreadyCompleted { return false }

        // Check for actual bookmark data in the legacy DB.
        // We inspect bookmark_item rows, not just bookmark_list count,
        // because the single-default-list case is the most common one.
        let hasLists = try legacyDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark_list")
        } ?? 0 > 0
        let hasItems = try legacyDB.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark_item")
        } ?? 0 > 0

        return hasLists || hasItems
    }

    // MARK: - Convenience

    /// All bookmarked item IDs. Used by FeedStore to stamp `isBookmarked` on
    /// visible items so bookmark indicators render correctly.
    func allBookmarkedItemIDs() -> Set<String> {
        (try? db.read { db in
            try Set(String.fetchAll(db, sql: "SELECT DISTINCT item_id FROM bookmark_item"))
        }) ?? []
    }
}

// MARK: - Smart feeds

/// User-owned Smart Feed definitions live in `user.sqlite`; their cached item
/// identities live beside `feed_item` in the content database so SQLite can
/// retain and hydrate them efficiently.
@MainActor
final class SmartFeedStore {
    nonisolated static let cacheLimit = 2_000
    nonisolated static let retentionInterval: TimeInterval = 180 * 24 * 60 * 60

    private let userDB: DatabaseQueue
    private let contentDB: DatabaseQueue

    init(userDB: DatabaseQueue, contentDB: DatabaseQueue) {
        self.userDB = userDB
        self.contentDB = contentDB
    }

    func allSmartFeeds() async throws -> [SmartFeed] {
        let counts = try await contentDB.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT smart_feed_id, COUNT(*) AS item_count
                FROM smart_feed_item
                GROUP BY smart_feed_id
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["smart_feed_id"] as Int64, row["item_count"] as Int)
            })
        }
        return try await userDB.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name, definition_json, created_at
                FROM smart_feed
                ORDER BY sort_order, created_at, id
                """).compactMap { row in
                    let id: Int64 = row["id"]
                    let name: String = row["name"]
                    let definitionJSON: String = row["definition_json"]
                    let createdAt: Int = row["created_at"]
                    guard let definition = Self.decodeDefinition(definitionJSON) else {
                        return nil
                    }
                    return SmartFeed(
                        id: id,
                        name: name,
                        definition: definition,
                        createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                        cachedItemCount: counts[id] ?? 0
                    )
                }
        }
    }

    func smartFeed(id: Int64) async throws -> SmartFeed? {
        let count = try await contentDB.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM smart_feed_item WHERE smart_feed_id = ?",
                arguments: [id]
            ) ?? 0
        }
        return try await userDB.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, name, definition_json, created_at
                FROM smart_feed WHERE id = ?
                """, arguments: [id]) else {
                return nil
            }
            let definitionJSON: String = row["definition_json"]
            guard let definition = Self.decodeDefinition(definitionJSON) else {
                return nil
            }
            let createdAt: Int = row["created_at"]
            return SmartFeed(
                id: row["id"],
                name: row["name"],
                definition: definition,
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                cachedItemCount: count
            )
        }
    }

    @discardableResult
    func createSmartFeed(name: String, definition: SmartFeedDefinition) async throws -> Int64 {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw SmartFeedError.emptyName }
        guard definition.searchExpression.canSearch else { throw SmartFeedError.emptyQuery }
        guard definition.includeSources || definition.includeContents else {
            throw SmartFeedError.emptyScope
        }
        let data = try JSONEncoder().encode(definition)
        guard let json = String(data: data, encoding: .utf8) else {
            throw SmartFeedError.invalidDefinition
        }
        return try await userDB.write { db in
            let order = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM smart_feed"
            ) ?? 0
            let now = Int(Date().timeIntervalSince1970)
            try db.execute(sql: """
                INSERT INTO smart_feed
                    (name, definition_json, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [cleanName, json, order, now, now])
            return db.lastInsertedRowID
        }
    }

    func renameSmartFeed(id: Int64, name: String) async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw SmartFeedError.emptyName }
        try await userDB.write { db in
            try db.execute(
                sql: "UPDATE smart_feed SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [cleanName, Int(Date().timeIntervalSince1970), id]
            )
        }
    }

    func deleteSmartFeed(id: Int64) async throws {
        try await userDB.write { db in
            try db.execute(sql: "DELETE FROM smart_feed WHERE id = ?", arguments: [id])
        }
        try await contentDB.write { db in
            try db.execute(
                sql: "DELETE FROM smart_feed_item WHERE smart_feed_id = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM smart_feed_source WHERE smart_feed_id = ?",
                arguments: [id]
            )
        }
    }

    func cache(itemIDs: [String], for smartFeedID: Int64) async throws {
        guard !itemIDs.isEmpty else { return }
        let now = Int(Date().timeIntervalSince1970)
        try await contentDB.write { db in
            let uniqueIDs = Array(Set(itemIDs))
            var sourceURLsByItemID: [String: String] = [:]
            for start in stride(from: 0, to: uniqueIDs.count, by: 400) {
                let chunk = Array(
                    uniqueIDs[start..<min(start + 400, uniqueIDs.count)]
                )
                let placeholders = Array(
                    repeating: "?",
                    count: chunk.count
                ).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, source_url
                    FROM feed_item
                    WHERE id IN (\(placeholders))
                    """, arguments: StatementArguments(chunk))
                for row in rows {
                    sourceURLsByItemID[row["id"]] = OPMLParser.normalizeURL(
                        row["source_url"]
                    )
                }
            }

            for itemID in uniqueIDs {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO smart_feed_item
                        (smart_feed_id, item_id, matched_at)
                    SELECT ?, id, ? FROM feed_item WHERE id = ?
                    """, arguments: [smartFeedID, now, itemID])
                let isNewMatch = db.changesCount > 0
                if !isNewMatch {
                    try db.execute(sql: """
                        UPDATE smart_feed_item
                        SET matched_at = ?
                        WHERE smart_feed_id = ? AND item_id = ?
                        """, arguments: [now, smartFeedID, itemID])
                }
                guard let sourceURL = sourceURLsByItemID[itemID] else { continue }
                if isNewMatch {
                    try db.execute(sql: """
                        INSERT INTO smart_feed_source
                            (smart_feed_id, source_url, hit_count, last_matched_at)
                        VALUES (?, ?, 1, ?)
                        ON CONFLICT(smart_feed_id, source_url) DO UPDATE SET
                            hit_count = smart_feed_source.hit_count + 1,
                            last_matched_at = excluded.last_matched_at
                        """, arguments: [smartFeedID, sourceURL, now])
                } else {
                    // Backfill affinity for caches created by an earlier schema,
                    // but never count the same item twice.
                    try db.execute(sql: """
                        INSERT INTO smart_feed_source
                            (smart_feed_id, source_url, hit_count, last_matched_at)
                        VALUES (?, ?, 1, ?)
                        ON CONFLICT(smart_feed_id, source_url) DO UPDATE SET
                            last_matched_at = excluded.last_matched_at
                        """, arguments: [smartFeedID, sourceURL, now])
                }
            }
            try db.execute(sql: """
                DELETE FROM smart_feed_item
                WHERE smart_feed_id = ?
                  AND item_id NOT IN (
                    SELECT sfi.item_id
                    FROM smart_feed_item sfi
                    JOIN feed_item fi ON fi.id = sfi.item_id
                    WHERE sfi.smart_feed_id = ?
                    ORDER BY fi.published_at DESC, sfi.matched_at DESC
                    LIMIT \(Self.cacheLimit)
                  )
                """, arguments: [smartFeedID, smartFeedID])
        }
    }

    func prioritizedSourceURLs(smartFeedID: Int64) async throws -> [String] {
        try await contentDB.read { db in
            try String.fetchAll(db, sql: """
                SELECT source_url
                FROM smart_feed_source
                WHERE smart_feed_id = ?
                ORDER BY hit_count DESC, last_matched_at DESC, source_url
                """, arguments: [smartFeedID])
        }
    }

    func refreshStates() async throws -> [SmartFeedRefreshState] {
        try await userDB.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, last_refresh_attempt_at, last_refresh_success_at,
                       refresh_failure_count
                FROM smart_feed
                """).map { row in
                    let attemptEpoch: Int? = row["last_refresh_attempt_at"]
                    let successEpoch: Int? = row["last_refresh_success_at"]
                    return SmartFeedRefreshState(
                        id: row["id"],
                        lastAttemptAt: attemptEpoch.map {
                            Date(timeIntervalSince1970: TimeInterval($0))
                        },
                        lastSuccessAt: successEpoch.map {
                            Date(timeIntervalSince1970: TimeInterval($0))
                        },
                        consecutiveFailures: row["refresh_failure_count"]
                    )
                }
        }
    }

    func markRefreshStarted(smartFeedID: Int64, at date: Date = .now) async throws {
        try await userDB.write { db in
            try db.execute(sql: """
                UPDATE smart_feed
                SET last_refresh_attempt_at = ?
                WHERE id = ?
                """, arguments: [
                    Int(date.timeIntervalSince1970),
                    smartFeedID,
                ])
        }
    }

    func markRefreshFinished(
        smartFeedID: Int64,
        succeeded: Bool,
        at date: Date = .now
    ) async throws {
        try await userDB.write { db in
            if succeeded {
                try db.execute(sql: """
                    UPDATE smart_feed
                    SET last_refresh_success_at = ?,
                        refresh_failure_count = 0
                    WHERE id = ?
                    """, arguments: [
                        Int(date.timeIntervalSince1970),
                        smartFeedID,
                    ])
            } else {
                try db.execute(sql: """
                    UPDATE smart_feed
                    SET refresh_failure_count = refresh_failure_count + 1
                    WHERE id = ?
                    """, arguments: [smartFeedID])
            }
        }
    }

    /// Items not yet seen lead the queue. Seen items stay cached and are moved
    /// to the tail on the next Smart Feed load, preserving scroll stability.
    func cachedItems(smartFeedID: Int64) async throws -> [FeedItem] {
        try await contentDB.read { db in
            try FeedItemRecord.fetchAll(db, sql: """
                SELECT fi.*
                FROM smart_feed_item sfi
                JOIN feed_item fi ON fi.id = sfi.item_id
                WHERE sfi.smart_feed_id = ?
                ORDER BY
                    CASE WHEN fi.consumed_at IS NULL THEN 0 ELSE 1 END,
                    CASE WHEN fi.consumed_at IS NULL THEN fi.published_at END DESC,
                    CASE WHEN fi.consumed_at IS NOT NULL THEN fi.consumed_at END DESC,
                    sfi.matched_at DESC,
                    fi.id
                LIMIT \(Self.cacheLimit)
                """, arguments: [smartFeedID]).map { $0.toFeedItem() }
        }
    }

    func cachedItemIDs(smartFeedID: Int64) async throws -> Set<String> {
        try await contentDB.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT item_id FROM smart_feed_item WHERE smart_feed_id = ?",
                arguments: [smartFeedID]
            ))
        }
    }

    nonisolated private static func decodeDefinition(
        _ json: String
    ) -> SmartFeedDefinition? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SmartFeedDefinition.self, from: data)
    }
}

enum SmartFeedError: LocalizedError {
    case emptyName
    case emptyQuery
    case emptyScope
    case invalidDefinition

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Smart Bookmark name cannot be empty."
        case .emptyQuery: return "Smart Bookmark search needs a positive term."
        case .emptyScope: return "Select Sources, Contents, or both."
        case .invalidDefinition: return "The Smart Bookmark filters could not be saved."
        }
    }
}

// MARK: - Curated feeds

@MainActor
final class CuratedFeedStore {
    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    func allCuratedFeeds() async throws -> [CuratedFeed] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, name, definition_json, created_at, updated_at
                FROM curated_feed
                ORDER BY sort_order, created_at, id
                """).compactMap(Self.feed(from:))
        }
    }

    func curatedFeed(id: Int64) async throws -> CuratedFeed? {
        try await db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT id, name, definition_json, created_at, updated_at
                FROM curated_feed
                WHERE id = ?
                """, arguments: [id]).flatMap(Self.feed(from:))
        }
    }

    @discardableResult
    func create(name: String, definition: CuratedProfileDefinition) async throws -> Int64 {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw CuratedFeedError.emptyName }
        guard !definition.languages.isEmpty else { throw CuratedFeedError.emptyLanguages }
        let data = try JSONEncoder().encode(definition)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CuratedFeedError.invalidDefinition
        }
        return try await db.write { db in
            let order = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM curated_feed"
            ) ?? 0
            let now = Int(Date().timeIntervalSince1970)
            try db.execute(sql: """
                INSERT INTO curated_feed
                    (name, definition_json, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [cleanName, json, order, now, now])
            return db.lastInsertedRowID
        }
    }

    func update(
        id: Int64,
        name: String,
        definition: CuratedProfileDefinition
    ) async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw CuratedFeedError.emptyName }
        guard !definition.languages.isEmpty else { throw CuratedFeedError.emptyLanguages }
        let data = try JSONEncoder().encode(definition)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CuratedFeedError.invalidDefinition
        }
        try await db.write { db in
            try db.execute(sql: """
                UPDATE curated_feed
                SET name = ?, definition_json = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [
                    cleanName,
                    json,
                    Int(Date().timeIntervalSince1970),
                    id,
                ])
        }
    }

    func delete(id: Int64) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM curated_feed WHERE id = ?", arguments: [id])
        }
    }

    nonisolated private static func feed(from row: Row) -> CuratedFeed? {
        let json: String = row["definition_json"]
        guard let data = json.data(using: .utf8),
              let definition = try? JSONDecoder().decode(
                CuratedProfileDefinition.self,
                from: data
              ) else { return nil }
        let createdAt: Int = row["created_at"]
        let updatedAt: Int = row["updated_at"]
        return CuratedFeed(
            id: row["id"],
            name: row["name"],
            definition: definition,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
        )
    }
}

enum CuratedFeedError: LocalizedError {
    case emptyName
    case emptyLanguages
    case invalidDefinition
    case missingFeed

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Curated Feed name cannot be empty."
        case .emptyLanguages: return "Choose at least one reading language."
        case .invalidDefinition: return "The curation profile could not be saved."
        case .missingFeed: return "This Curated Feed no longer exists."
        }
    }
}

// MARK: - Personal source collections

struct SourceCollection: Identifiable, Equatable, Sendable {
    let id: Int64
    let name: String
    let sortOrder: Int
    let createdAt: Date
    let memberCount: Int
}

struct SourceCollectionMember: Identifiable, Equatable, Sendable {
    var id: String { sourceURL }
    let sourceURL: String
    let title: String
    let mediaKind: MediaKind
    let addedAt: Date
    let sortOrder: Int
}

/// Many-to-many personal playlists of sources. Membership never mutates a
/// FeedSource's OPML category/region and deleting a collection never deletes a
/// source from the catalog.
@MainActor
final class SourceCollectionStore {
    private static let importedCategoryMigrationKey = "imported_categories_to_collections_v1"
    private let db: DatabaseQueue

    init(db: DatabaseQueue) {
        self.db = db
    }

    func allCollections() async throws -> [SourceCollection] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id, c.name, c.sort_order, c.created_at,
                       COUNT(m.source_url) AS member_count
                FROM source_collection c
                LEFT JOIN source_collection_member m ON m.collection_id = c.id
                GROUP BY c.id
                ORDER BY c.sort_order, c.created_at, c.id
                """).map { row in
                    SourceCollection(
                        id: row["id"],
                        name: row["name"],
                        sortOrder: row["sort_order"],
                        createdAt: Date(timeIntervalSince1970: TimeInterval(row["created_at"] as Int)),
                        memberCount: row["member_count"]
                    )
                }
        }
    }

    @discardableResult
    func createCollection(name: String) async throws -> Int64 {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw SourceCollectionError.emptyName }
        return try await db.write { db in
            let order = (try Int.fetchOne(db,
                sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM source_collection")) ?? 0
            try db.execute(sql: """
                INSERT INTO source_collection (name, sort_order, created_at)
                VALUES (?, ?, ?)
                """, arguments: [cleanName, order, Int(Date().timeIntervalSince1970)])
            return db.lastInsertedRowID
        }
    }

    func renameCollection(id: Int64, name: String) async throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw SourceCollectionError.emptyName }
        try await db.write { db in
            try db.execute(sql: "UPDATE source_collection SET name = ? WHERE id = ?",
                           arguments: [cleanName, id])
        }
    }

    func deleteCollection(id: Int64) async throws {
        try await db.write { db in
            try db.execute(sql: "DELETE FROM source_collection WHERE id = ?", arguments: [id])
        }
    }

    func reorderCollections(ids: [Int64]) async throws {
        try await db.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE source_collection SET sort_order = ? WHERE id = ?",
                               arguments: [index, id])
            }
        }
    }

    func members(collectionID: Int64) async throws -> [SourceCollectionMember] {
        try await db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT source_url, title_snapshot, media_kind, added_at, sort_order
                FROM source_collection_member
                WHERE collection_id = ?
                ORDER BY sort_order, added_at, source_url
                """, arguments: [collectionID]).map { row in
                    let rawKind: String = row["media_kind"]
                    return SourceCollectionMember(
                        sourceURL: row["source_url"],
                        title: row["title_snapshot"],
                        mediaKind: MediaKind(rawValue: rawKind) ?? .text,
                        addedAt: Date(timeIntervalSince1970: TimeInterval(row["added_at"] as Int)),
                        sortOrder: row["sort_order"]
                    )
                }
        }
    }

    func add(_ source: SourceReference, to collectionID: Int64) async throws {
        try await add([source], to: collectionID)
    }

    func add(_ sources: [SourceReference], to collectionID: Int64) async throws {
        guard !sources.isEmpty else { return }
        try await db.write { db in
            var order = (try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(sort_order), -1) + 1
                FROM source_collection_member WHERE collection_id = ?
                """, arguments: [collectionID])) ?? 0
            for source in sources {
                try db.execute(sql: """
                    INSERT INTO source_collection_member
                        (collection_id, source_url, title_snapshot, media_kind, added_at, sort_order)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(collection_id, source_url) DO UPDATE SET
                        title_snapshot = excluded.title_snapshot,
                        media_kind = excluded.media_kind
                    """, arguments: [
                        collectionID, OPMLParser.normalizeURL(source.feedURL), source.title,
                        source.mediaKind.rawValue, Int(Date().timeIntervalSince1970), order,
                    ])
                if db.changesCount > 0 { order += 1 }
            }
        }
    }

    /// Repairs destinations created by the old Add Feed screen. That screen
    /// stored its picker value in FeedSource.category instead of creating a
    /// personal collection, leaving imported sources filed under invisible
    /// pseudo-collections. Run once after imported_sources.json is restored.
    func migrateImportedCategoriesToCollections(_ importedSources: [FeedSource]) async throws -> Int {
        let migrationKey = Self.importedCategoryMigrationKey
        return try await db.write { db in
            let completed = try String.fetchOne(
                db,
                sql: "SELECT value FROM user_metadata WHERE key = ?",
                arguments: [migrationKey]
            ) == "1"
            guard !completed else { return 0 }

            let grouped = Dictionary(grouping: importedSources) { source in
                let name = source.category.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? "Imported" : name
            }
            var migratedCount = 0

            for name in grouped.keys.sorted() {
                let collectionID: Int64
                if let existingID = try Int64.fetchOne(
                    db,
                    sql: "SELECT id FROM source_collection WHERE name = ? COLLATE NOCASE ORDER BY id LIMIT 1",
                    arguments: [name]
                ) {
                    collectionID = existingID
                } else {
                    let collectionOrder = (try Int.fetchOne(
                        db,
                        sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM source_collection"
                    )) ?? 0
                    try db.execute(sql: """
                        INSERT INTO source_collection (name, sort_order, created_at)
                        VALUES (?, ?, ?)
                        """, arguments: [name, collectionOrder, Int(Date().timeIntervalSince1970)])
                    collectionID = db.lastInsertedRowID
                }

                var memberOrder = (try Int.fetchOne(db, sql: """
                    SELECT COALESCE(MAX(sort_order), -1) + 1
                    FROM source_collection_member WHERE collection_id = ?
                    """, arguments: [collectionID])) ?? 0
                for source in grouped[name] ?? [] {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO source_collection_member
                            (collection_id, source_url, title_snapshot, media_kind, added_at, sort_order)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [
                            collectionID, OPMLParser.normalizeURL(source.url), source.title,
                            source.mediaKind.rawValue, Int(Date().timeIntervalSince1970), memberOrder,
                        ])
                    if db.changesCount > 0 {
                        migratedCount += 1
                        memberOrder += 1
                    }
                }
            }

            try db.execute(sql: """
                INSERT INTO user_metadata (key, value) VALUES (?, '1')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [migrationKey])
            return migratedCount
        }
    }

    func remove(sourceURL: String, from collectionID: Int64) async throws {
        try await db.write { db in
            try db.execute(sql: """
                DELETE FROM source_collection_member
                WHERE collection_id = ? AND source_url = ?
                """, arguments: [collectionID, OPMLParser.normalizeURL(sourceURL)])
        }
    }

    func reorderMembers(collectionID: Int64, sourceURLs: [String]) async throws {
        try await db.write { db in
            for (index, sourceURL) in sourceURLs.enumerated() {
                try db.execute(sql: """
                    UPDATE source_collection_member SET sort_order = ?
                    WHERE collection_id = ? AND source_url = ?
                    """, arguments: [index, collectionID, OPMLParser.normalizeURL(sourceURL)])
            }
        }
    }

    func collectionIDs(containing sourceURL: String) async throws -> Set<Int64> {
        try await db.read { db in
            try Set(Int64.fetchAll(db, sql: """
                SELECT collection_id FROM source_collection_member WHERE source_url = ?
                """, arguments: [OPMLParser.normalizeURL(sourceURL)]))
        }
    }
}

enum SourceCollectionError: LocalizedError {
    case emptyName

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Collection name cannot be empty."
        }
    }
}
