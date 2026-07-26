import Foundation
import GRDB

actor DownloadManager {
    static let shared = DownloadManager()

    // MARK: - Configuration
    var mode: DownloadMode {
        get { _mode }
        set { _mode = newValue; UserDefaults.standard.set(newValue.rawValue, forKey: "download_mode") }
    }
    private var _mode: DownloadMode = {
        let raw = UserDefaults.standard.string(forKey: "download_mode") ?? "wifi"
        return DownloadMode(rawValue: raw) ?? .wifi
    }()

    var storageLimit: Int64 {
        get { _storageLimit }
        set { _storageLimit = newValue; UserDefaults.standard.set(Int(newValue), forKey: "download_storage_limit") }
    }
    private var _storageLimit: Int64 = {
        let v = UserDefaults.standard.integer(forKey: "download_storage_limit")
        return v > 0 ? Int64(v) : 2_000_000_000  // 2 GB default
    }()

    var autoDelete: AutoDeletePolicy {
        get { _autoDelete }
        set { _autoDelete = newValue; UserDefaults.standard.set(newValue.rawValue, forKey: "download_auto_delete") }
    }
    private var _autoDelete: AutoDeletePolicy = {
        let raw = UserDefaults.standard.string(forKey: "download_auto_delete") ?? "after_read"
        return AutoDeletePolicy(rawValue: raw) ?? .afterRead
    }()

    // MARK: - Internal state
    /// Download storage directory. Uses Application Support (not Caches)
    /// because iOS may purge Caches at any time, deleting user-downloaded
    /// content. Files are excluded from iCloud backup to avoid wasting quota.
    private let downloadsDirectory: URL = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("DownloadManager: applicationSupportDirectory is unavailable")
        }
        var dir = appSupport.appendingPathComponent("Downloads", isDirectory: true)
        // Exclude from iCloud backup — downloaded content is re-downloadable
        // and shouldn't consume the user's iCloud storage.
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? dir.setResourceValues(resourceValues)
        return dir
    }()

    /// Use default URLSession config — the async `download(from:)` API works
    /// with it, and we wrap downloads in Tasks for cancellation. Background
    /// config requires a delegate which is incompatible with the async API.
    private let session: URLSession

    /// Count of in-flight download phases (audio + page). Used to throttle
    /// concurrency so we don't saturate the device's network.
    private var activeCount = 0
    private let maxConcurrent = 3

    /// Task wrappers for cancellable downloads, keyed by itemID.
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var notificationContinuation: AsyncStream<DownloadNotification>.Continuation?
    let notifications: AsyncStream<DownloadNotification>

    private var isProcessing = false

    /// Running total of bytes stored on disk, maintained incrementally.
    /// Avoids O(n) file-system enumeration and hard-link overcounting.
    private var _storageUsed: Int64 = 0

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 3600  // 1 hour max
        self.session = URLSession(configuration: config)
        var continuation: AsyncStream<DownloadNotification>.Continuation!
        self.notifications = AsyncStream { continuation = $0 }
        self.notificationContinuation = continuation
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        // Seed downloads from DB and migrate from old Caches location
        // so iOS cache purges don't delete user content.
        Task {
            await loadCachesFromDB()
            await migrateFromCachesIfNeeded()
        }
    }

    /// One-time migration: move existing downloads from the old Caches
    /// directory to the new Application Support location.
    private func migrateFromCachesIfNeeded() {
        guard let oldCaches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let oldDir = oldCaches.appendingPathComponent("Downloads", isDirectory: true)
        guard FileManager.default.fileExists(atPath: oldDir.path) else { return }
        // Only migrate if the new directory is empty (fresh install or first
        // launch after the storage location change).
        guard (try? FileManager.default.contentsOfDirectory(atPath: downloadsDirectory.path).isEmpty) ?? true else { return }

        if let contents = try? FileManager.default.contentsOfDirectory(atPath: oldDir.path) {
            for item in contents {
                let src = oldDir.appendingPathComponent(item)
                let dst = downloadsDirectory.appendingPathComponent(item)
                try? FileManager.default.moveItem(at: src, to: dst)
            }
            // Remove old directory if empty after migration
            if (try? FileManager.default.contentsOfDirectory(atPath: oldDir.path).isEmpty) ?? false {
                try? FileManager.default.removeItem(at: oldDir)
            }
        }
    }

    private func loadCachesFromDB() async {
        do {
            let db = await FeedStore.sharedDB()
            let rows = try await db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT item_id, status, audio_bytes, page_bytes
                    FROM download
                    WHERE status IN ('completed', 'failed_page', 'downloading_audio', 'downloading_page')
                """)
            }
            var total: Int64 = 0
            for row in rows {
                let statusStr: String = row["status"]
                let itemID: String = row["item_id"]
                if statusStr == DownloadStatus.completed.rawValue || statusStr == DownloadStatus.failedPage.rawValue {
                    total += Int64((row["audio_bytes"] as Int64?) ?? 0) + Int64((row["page_bytes"] as Int64?) ?? 0)
                    if let status = DownloadStatus(rawValue: statusStr) {
                        statusCache[itemID] = status
                    }
                } else if let status = DownloadStatus(rawValue: statusStr) {
                    statusCache[itemID] = status
                }
            }
            _storageUsed = total
        } catch {
            Log.feed.error("DownloadManager.loadCachesFromDB: \(error.localizedDescription)")
        }
    }

    /// Last error from enqueue(), cleared on success. Read by UI for specific
    /// failure messages instead of the generic "Download failed" fallback.
    private(set) var lastEnqueueError: String?

    // MARK: - Public API

    @discardableResult
    func enqueue(item: FeedItem, contentType: DownloadContentType) async -> Bool {
        lastEnqueueError = nil

        let db: DatabaseQueue
        do {
            db = await FeedStore.sharedDB()
        } catch {
            lastEnqueueError = "Database not available: \(error.localizedDescription)"
            return false
        }

        let audioURL = item.audioPlaybackURL?.absoluteString
        let now = Int(Date().timeIntervalSince1970)
        let record = DownloadRecord(
            id: nil,
            itemID: item.id,
            sourceURL: item.sourceURL,
            contentType: contentType.rawValue,
            audioURL: audioURL,
            pageURL: item.url,
            bundlePath: nil,
            audioPath: nil,
            pagePath: nil,
            audioBytes: 0,
            audioDownloaded: 0,
            pageBytes: 0,
            pageDownloaded: 0,
            status: DownloadStatus.queued.rawValue,
            createdAt: now,
            completedAt: nil
        )
        do {
            // If a record already exists for this item, delete it first
            // (re-download). item_id has a UNIQUE constraint.
            try await db.write { db in
                try db.execute(sql: "DELETE FROM download WHERE item_id = ?",
                               arguments: [item.id])
                try record.insert(db)
            }
        } catch let error as DatabaseError {
            lastEnqueueError = "DB error: \(error.localizedDescription)"
            Log.feed.error("DownloadManager.enqueue: \(error)")
            return false
        } catch {
            lastEnqueueError = "Unexpected: \(error.localizedDescription)"
            Log.feed.error("DownloadManager.enqueue: \(error)")
            return false
        }
        statusCache[item.id] = .queued
        notify(.init(event: .queued, itemID: item.id,
                     sourceTitle: item.sourceTitle, itemTitle: item.title, count: nil))
        await processNext()
        return true
    }

    func cancel(itemID: String) async {
        // Cancel any in-flight task
        activeTasks[itemID]?.cancel()
        activeTasks[itemID] = nil

        var bytesToSubtract: Int64 = 0
        do {
            let db = await FeedStore.sharedDB()
            // Read record before deleting so we can subtract from running total
            let record = try await db.read { db in
                try DownloadRecord
                    .filter(DownloadRecord.Columns.itemID == itemID)
                    .fetchOne(db)
            }
            if let record {
                bytesToSubtract = Int64(record.audioBytes + record.pageBytes)
            }
            _ = try await db.write { db in
                try DownloadRecord
                    .filter(DownloadRecord.Columns.itemID == itemID)
                    .deleteAll(db)
            }
        } catch {
            Log.feed.error("DownloadManager.cancel DB error: \(error.localizedDescription)")
            // Still clean up bundle even if DB delete failed — don't leave orphans.
        }
        // Always subtract from running total, even on DB error, to prevent
        // permanent overcounting from orphaned rows.
        _storageUsed -= bytesToSubtract
        if _storageUsed < 0 { _storageUsed = 0 }
        // Clean up partial/full bundle
        let bundle = downloadsDirectory.appendingPathComponent(itemID)
        try? FileManager.default.removeItem(at: bundle)
        statusCache[itemID] = nil
        progressCache[itemID] = nil
    }

    func delete(itemID: String) async {
        await cancel(itemID: itemID)
    }

    /// In-memory cache of download statuses. Seeded from the DB on first access
    /// and updated by processNext / enqueue / cancel.
    private var statusCache: [String: DownloadStatus] = [:]
    private var progressCache: [String: Double] = [:]

    func status(for itemID: String) -> DownloadStatus {
        if let cached = statusCache[itemID] { return cached }
        // Return best-effort default without spawning a Task — the cache is
        // seeded from the DB on first access (loadCachesFromDB), and callers
        // that need the authoritative value should await status(for:) directly.
        return .queued
    }

    private func loadStatusFromDB(itemID: String) async {
        if statusCache[itemID] != nil { return }
        do {
            let db = await FeedStore.sharedDB()
            if let raw = try await db.read({ db in
                try String.fetchOne(db, sql: "SELECT status FROM download WHERE item_id = ?", arguments: [itemID])
            }), let status = DownloadStatus(rawValue: raw) {
                statusCache[itemID] = status
            }
        } catch {}
    }

    func progress(for itemID: String) -> Double {
        progressCache[itemID] ?? 0.0
    }

    func isDownloaded(itemID: String) -> Bool {
        // Check both the bundle directory AND a key file to avoid false
        // positives when the directory was created but the download failed.
        let pageFile = downloadsDirectory.appendingPathComponent("\(itemID)/page.html")
        let audioFile = downloadsDirectory.appendingPathComponent("\(itemID)/audio.mp3")
        return FileManager.default.fileExists(atPath: pageFile.path)
            || FileManager.default.fileExists(atPath: audioFile.path)
    }

    func localPagePath(for itemID: String) -> URL? {
        let path = downloadsDirectory.appendingPathComponent("\(itemID)/page.html")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    func localAudioPath(for itemID: String) -> URL? {
        let path = downloadsDirectory.appendingPathComponent("\(itemID)/audio.mp3")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Non-async variant for @MainActor callers (e.g. AudioPlayerManager.play).
    nonisolated func localAudioPathSync(for itemID: String) -> URL? {
        let path = downloadsDirectory.appendingPathComponent("\(itemID)/audio.mp3")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Expose the downloads directory path so FeedStore can use it without
    /// duplicating path construction.
    nonisolated static func bundlePath(for itemID: String) -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("DownloadManager.bundlePath: applicationSupportDirectory unavailable")
        }
        return appSupport
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(itemID)
    }

    func evaluateRules(for items: [FeedItem]) async {
        let db = await FeedStore.sharedDB()
        let rules: [DownloadRuleRecord]
        do {
            rules = try await db.read { db in
                try DownloadRuleRecord
                    .filter(DownloadRuleRecord.Columns.enabled == true)
                    .fetchAll(db)
            }
        } catch { return }
        guard !rules.isEmpty else { return }

        // Check connectivity — must distinguish WiFi from cellular for WiFi-only mode.
        let snap = NetworkMonitor.shared.snapshot()
        if mode == .wifi {
            if !snap.isConnected { return }            // No connection at all
            if !snap.isExpensive { /* WiFi — proceed */ }
            else { return }                             // Cellular — skip
        }

        // Batch-fetch all queued/completed item IDs to avoid N+1 queries.
        let allCandidateIDs = items.map(\.id)
        var queuedOrCompleted: Set<String> = []
        if !allCandidateIDs.isEmpty {
            do {
                let ids = try await db.read { db in
                    try String.fetchAll(db, sql: """
                        SELECT item_id FROM download
                        WHERE item_id IN (\(allCandidateIDs.map { _ in "?" }.joined(separator: ",")))
                        AND status IN ('queued', 'downloading_audio', 'downloading_page', 'completed')
                    """, arguments: StatementArguments(allCandidateIDs))
                }
                queuedOrCompleted = Set(ids)
            } catch {
                // On DB error, assume nothing is queued so we don't silently
                // block all auto-downloads on transient errors.
            }
        }

        var toEnqueue: [FeedItem] = []
        for rule in rules {
            let matching = items.filter { item in
                if rule.targetType == "source" {
                    return item.sourceURL == rule.targetID
                }
                return false
            }
            let sorted = matching.sorted { $0.publishedAt > $1.publishedAt }
            let count = rule.maxItems > 0 ? min(rule.maxItems, sorted.count) : sorted.count
            let candidates = Array(sorted.prefix(count))
            for item in candidates {
                let alreadyDownloaded = isDownloaded(itemID: item.id)
                let alreadyQueued = queuedOrCompleted.contains(item.id)
                if !alreadyDownloaded && !alreadyQueued {
                    toEnqueue.append(item)
                }
            }
        }

        if !toEnqueue.isEmpty {
            notify(.init(event: .autoDownloadStarted, itemID: nil,
                         sourceTitle: nil, itemTitle: nil, count: toEnqueue.count))
            var enqueued = 0
            for item in toEnqueue {
                let type: DownloadContentType = item.isPodcast ? .podcast : .article
                if await enqueue(item: item, contentType: type) {
                    enqueued += 1
                }
            }
            if enqueued > 0 {
                notify(.init(event: .batchCompleted, itemID: nil,
                             sourceTitle: nil, itemTitle: nil, count: enqueued))
            }
        }
    }

    /// Running-total storage used, maintained incrementally. O(1), no hard-link
    /// overcounting, always consistent with DB records.
    func storageUsed() -> Int64 {
        _storageUsed
    }

    func enforceStorageLimit() async {
        let used = _storageUsed
        guard used > storageLimit else { return }
        do {
            let db = await FeedStore.sharedDB()
            // Evict completed AND failed_page records (both occupy disk space).
            let oldest = try await db.read { db in
                try DownloadRecord
                    .filter(Column("status") == DownloadStatus.completed.rawValue
                            || Column("status") == DownloadStatus.failedPage.rawValue)
                    .order(Column("completed_at").asc)
                    .limit(50)
                    .fetchAll(db)
            }
            var freed: Int64 = 0
            for record in oldest {
                guard _storageUsed - freed > storageLimit * 8 / 10 else { break }
                let recordSize = Int64(record.audioBytes + record.pageBytes)
                await cancel(itemID: record.itemID)
                freed += recordSize
            }
            if freed > 0 {
                notify(.init(event: .storageFull, itemID: nil,
                             sourceTitle: nil, itemTitle: nil, count: nil))
            }
        } catch {
            Log.feed.error("DownloadManager.enforceStorageLimit: \(error.localizedDescription)")
        }
    }

    func freeDiskSpace() -> Int64 {
        guard let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            Log.feed.error("DownloadManager.freeDiskSpace: no Documents directory — returning Int64.max as fallback")
            return Int64.max
        }
        if let values = try? docURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = values.volumeAvailableCapacityForImportantUsage, free > 0 {
            return Int64(free)
        }
        if let values = try? docURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let free = values.volumeAvailableCapacity, free > 0 {
            return Int64(free)
        }
        Log.feed.error("DownloadManager.freeDiskSpace: volume capacity unavailable — returning Int64.max as fallback")
        return Int64.max
    }

    /// Single threshold for critically-low storage. Avoids #if DEBUG divergence
    /// so tests and production behave identically.  50 MB minimum for safe
    /// download operations (temp files, decompression, sanitization overhead).
    private static let criticallyLowThreshold: Int64 = 50_000_000

    /// Testable entry point — allows injecting free space and usage.
    func checkStorageGate(for byteCount: Int64,
                          freeSpace: Int64? = nil,
                          used: Int64? = nil,
                          limit: Int64? = nil) -> StorageGate {
        let actualFree = freeSpace ?? freeDiskSpace()
        if actualFree < Self.criticallyLowThreshold {
            return .criticallyLow(available: actualFree)
        }
        let actualUsed = used ?? _storageUsed
        let actualLimit = limit ?? storageLimit
        if actualUsed + byteCount > actualLimit {
            return .wouldExceedUserLimit(used: actualUsed, limit: actualLimit)
        }
        // Verify we have enough free space with a 2x safety margin for
        // temp files, image downloads, and content sanitization.
        let neededWithMargin = byteCount * 2
        if neededWithMargin > actualFree {
            return .insufficientFree(needed: byteCount, available: actualFree)
        }
        return .allowed
    }

    /// Emergency eviction on launch if critically low on space.
    func emergencyEvictIfNeeded() async {
        let free = freeDiskSpace()
        guard free < 200_000_000 && free != Int64.max else { return }
        do {
            let db = await FeedStore.sharedDB()
            let all = try await db.read { db in
                try DownloadRecord
                    .filter(Column("status") == DownloadStatus.completed.rawValue
                            || Column("status") == DownloadStatus.failedPage.rawValue)
                    .order(Column("completed_at").asc)
                    .fetchAll(db)
            }
            // Cache free space to avoid repeated syscalls inside the loop.
            var cachedFree = free
            for record in all {
                guard cachedFree < 500_000_000 else { break }
                await cancel(itemID: record.itemID)
                cachedFree += Int64(record.audioBytes + record.pageBytes)
            }
            if !all.isEmpty {
                notify(.init(event: .storageFull, itemID: nil,
                             sourceTitle: nil, itemTitle: nil, count: nil))
            }
        } catch {
            Log.feed.error("DownloadManager.emergencyEvictIfNeeded: \(error.localizedDescription)")
        }
    }

    // MARK: - Queue processing

    /// Entry point for the download queue. Serialized by the actor, processes
    /// items one at a time via a while loop (no unbounded recursion).
    private func processNext() async {
        // Prevent re-entrant calls from spawning duplicate processing loops.
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        while true {
            // Respect concurrent download cap.
            guard activeCount < maxConcurrent else { break }

            let db = await FeedStore.sharedDB()
            let next: DownloadRecord?
            do {
                next = try await db.read { db in
                    try DownloadRecord
                        .filter(DownloadRecord.Columns.status == DownloadStatus.queued.rawValue)
                        .order(DownloadRecord.Columns.createdAt.asc)
                        .limit(1)
                        .fetchOne(db)
                }
            } catch {
                Log.feed.error("DownloadManager.processNext DB read: \(error.localizedDescription)")
                break
            }
            guard let nextRecord = next else { break }

            // Fetch item metadata for notifications.
            let itemMeta = try? await db.read { db in
                try Row.fetchOne(db, sql: """
                    SELECT source_title, title FROM feed_item WHERE id = ?
                """, arguments: [nextRecord.itemID])
            }
            let sourceTitle = itemMeta?["source_title"] as? String
            let itemTitle = itemMeta?["title"] as? String

            activeCount += 1
            let itemID = nextRecord.itemID

            // Wrap the entire download in a cancellable Task.
            let downloadTask = Task { [weak self] in
                guard let self else { return }
                await self.processOne(record: nextRecord,
                                      sourceTitle: sourceTitle,
                                      itemTitle: itemTitle)
            }
            activeTasks[itemID] = downloadTask
            await downloadTask.value
            activeTasks[itemID] = nil
            activeCount -= 1
        }
    }

    /// Process a single download record through audio + page phases.
    /// Runs inside a cancellable Task so cancel(itemID:) can stop it.
    /// Takes record by value (not inout) to avoid @Sendable capture issues
    /// with GRDB's db.write closures.
    private func processOne(record: DownloadRecord,
                            sourceTitle: String?,
                            itemTitle: String?) async {
        let db = await FeedStore.sharedDB()

        do {
            var rec = record

            // Phase A: Audio (podcast only)
            if rec.contentType == DownloadContentType.podcast.rawValue,
               let audioStr = rec.audioURL,
               let audioURL = URL(string: audioStr) {

                statusCache[rec.itemID] = .downloadingAudio
                rec.status = DownloadStatus.downloadingAudio.rawValue
                let r1 = rec
                try? await db.write { db in try r1.update(db) }

                let bundle = downloadsDirectory.appendingPathComponent(rec.itemID)
                try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

                do {
                    let (tempURL, _) = try await session.download(from: audioURL)
                    try Task.checkCancellation()
                    let destURL = bundle.appendingPathComponent("audio.mp3")
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.moveItem(at: tempURL, to: destURL)

                    let fileSize = (try? destURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    rec.audioBytes = fileSize
                    rec.audioDownloaded = fileSize
                    rec.audioPath = "audio.mp3"
                    rec.bundlePath = bundle.path
                    rec.status = DownloadStatus.downloadingPage.rawValue
                    progressCache[rec.itemID] = 0.85
                } catch is CancellationError {
                    return
                } catch {
                    statusCache[rec.itemID] = .failedAudio
                    rec.status = DownloadStatus.failedAudio.rawValue
                    rec.completedAt = Int(Date().timeIntervalSince1970)
                    let rFail = rec
                    try? await db.write { db in try rFail.update(db) }
                    notify(.init(event: .failed, itemID: rec.itemID,
                                 sourceTitle: sourceTitle, itemTitle: itemTitle, count: nil))
                    // Clean up partial bundle so isDownloaded doesn't return a false positive.
                    try? FileManager.default.removeItem(at: bundle)
                    return
                }
                let r2 = rec
                try? await db.write { db in try r2.update(db) }
            }

            // Phase B: Set downloadingPage status for articles.
            if rec.contentType == DownloadContentType.article.rawValue {
                statusCache[rec.itemID] = .downloadingPage
                rec.status = DownloadStatus.downloadingPage.rawValue
                let r3 = rec
                try? await db.write { db in try r3.update(db) }
            }

            // Validate page URL.
            guard let pageURL = URL(string: rec.pageURL) else {
                statusCache[rec.itemID] = .failedPage
                rec.status = DownloadStatus.failedPage.rawValue
                rec.completedAt = Int(Date().timeIntervalSince1970)
                let r4 = rec
                try? await db.write { db in try r4.update(db) }
                notify(.init(event: .failed, itemID: rec.itemID,
                             sourceTitle: sourceTitle, itemTitle: itemTitle, count: nil))
                return
            }

            let bundle = downloadsDirectory.appendingPathComponent(rec.itemID)
            try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

            do {
                let sanitized = try await ContentSanitizer.fetchAndSanitize(url: pageURL)
                try Task.checkCancellation()

                // Download images concurrently using TaskGroup.
                await withTaskGroup(of: Void.self) { group in
                    for imageURL in sanitized.imageURLs {
                        group.addTask {
                            if await ImageCache.shared.diskImage(for: imageURL) != nil { return }
                            if let (data, _) = try? await URLSession.shared.data(from: imageURL) {
                                _ = await ImageCache.shared.setImage(data: data, for: imageURL)
                            }
                        }
                    }
                }
                try Task.checkCancellation()

                // Pre-compute keys for all image URLs (avoid redundant hashing).
                let imageKeys: [(URL, String)] = await withTaskGroup(of: (URL, String).self) { group in
                    for url in sanitized.imageURLs {
                        group.addTask { await (url, ImageCache.shared.cacheKey(for: url)) }
                    }
                    var results: [(URL, String)] = []
                    for await pair in group { results.append(pair) }
                    return results
                }

                // Rewrite image paths — sort by URL length descending to avoid
                // prefix corruption (e.g. "photo" replacing inside "photo_wide").
                let rewrittenHTML = rewriteImagePaths(sanitized.html, imageKeys: imageKeys)
                let pageFile = bundle.appendingPathComponent("page.html")
                try rewrittenHTML.write(to: pageFile, atomically: true, encoding: .utf8)

                // Copy cached images into bundle so WKWebView resolves them.
                // Use copy (not hard link) for accurate storageUsed accounting.
                let imagesDir = bundle.appendingPathComponent("images", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
                } catch {
                    Log.feed.error("DownloadManager: failed to create images dir: \(error.localizedDescription)")
                }
                for (url, key) in imageKeys {
                    let cacheFile = await ImageCache.shared.cacheFileURL(for: url)
                    let dest = imagesDir.appendingPathComponent(key)
                    if FileManager.default.fileExists(atPath: cacheFile.path),
                       !FileManager.default.fileExists(atPath: dest.path) {
                        do {
                            try FileManager.default.copyItem(at: cacheFile, to: dest)
                        } catch {
                            Log.feed.error("DownloadManager: failed to copy image \(key): \(error.localizedDescription)")
                        }
                    }
                }
                // Check cancellation after suspension point — prevent double-counting
                // if cancel() ran while we were awaiting image copies.
                try Task.checkCancellation()

                let pageSize = (try? pageFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                rec.pagePath = "page.html"
                rec.pageBytes = pageSize
                rec.pageDownloaded = pageSize
                rec.bundlePath = bundle.path
                rec.status = DownloadStatus.completed.rawValue
                rec.completedAt = Int(Date().timeIntervalSince1970)
                statusCache[rec.itemID] = .completed
                progressCache[rec.itemID] = 1.0

                // Update running storage total.
                _storageUsed += Int64(rec.audioBytes + rec.pageBytes)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: bundle)
                return
            } catch {
                rec.status = DownloadStatus.failedPage.rawValue
                rec.completedAt = Int(Date().timeIntervalSince1970)
                statusCache[rec.itemID] = .failedPage
                if rec.audioPath != nil {
                    _storageUsed += Int64(rec.audioBytes)
                }
                // Clean up partial bundle so isDownloaded doesn't return a false positive
                // for articles (no audio, so the directory would be empty).
                if rec.audioPath == nil {
                    try? FileManager.default.removeItem(at: bundle)
                }
            }

            // Persist final state.
            let r5 = rec
            try? await db.write { db in try r5.update(db) }

            // Notify with item titles so toasts actually appear.
            let isCompleted = rec.status == DownloadStatus.completed.rawValue
            notify(.init(event: isCompleted ? .completed : .failed,
                         itemID: rec.itemID,
                         sourceTitle: sourceTitle,
                         itemTitle: itemTitle,
                         count: nil))

            await enforceStorageLimit()
        } catch is CancellationError {
            // Task was cancelled — silent cleanup (cancel() handles it).
        } catch {
            Log.feed.error("DownloadManager.processOne: \(error.localizedDescription)")
        }
    }

    /// Rewrite remote image URLs to relative paths matching the images/
    /// directory. Sorted by URL length descending to prevent shorter URLs
    /// from corrupting longer ones during string replacement.
    private func rewriteImagePaths(_ html: String, imageKeys: [(URL, String)]) -> String {
        var result = html
        // Sort descending by absolute string length so longer URLs are
        // replaced before shorter prefix URLs.
        for (url, key) in imageKeys.sorted(by: { $0.0.absoluteString.count > $1.0.absoluteString.count }) {
            result = result.replacingOccurrences(of: url.absoluteString, with: "images/\(key)")
        }
        return result
    }

    private func notify(_ notification: DownloadNotification) {
        notificationContinuation?.yield(notification)
    }
}
