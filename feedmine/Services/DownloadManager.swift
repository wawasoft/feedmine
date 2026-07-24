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
    private let cachesDirectory: URL = {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }()
    private let session: URLSession
    private var activeDownloads: [String: URLSessionDownloadTask] = [:]
    private var activePageTasks: [String: Task<Void, Error>] = [:]
    private var progressHandlers: [String: (Double) -> Void] = [:]

    // Notification publisher
    private var notificationContinuation: AsyncStream<DownloadNotification>.Continuation?
    let notifications: AsyncStream<DownloadNotification>

    init() {
        let config = URLSessionConfiguration.background(withIdentifier: "com.feedmine.downloads")
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 3600  // 1 hour max
        self.session = URLSession(configuration: config)
        var continuation: AsyncStream<DownloadNotification>.Continuation!
        self.notifications = AsyncStream { continuation = $0 }
        self.notificationContinuation = continuation
        try? FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    func enqueue(item: FeedItem, contentType: DownloadContentType) async {
        guard checkStorageGate(for: 50_000_000) == .allowed else {
            notify(.init(event: .failed, itemID: item.id, sourceTitle: item.sourceTitle, itemTitle: item.title, count: nil))
            return
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
            let db = await FeedStore.sharedDB()
            try await db.write { db in try record.insert(db) }
        } catch {
            Log.feed.error("DownloadManager.enqueue: \(error.localizedDescription)")
            return
        }
        notify(.init(event: .queued, itemID: item.id, sourceTitle: item.sourceTitle, itemTitle: item.title, count: nil))
        await processNext()
    }

    func cancel(itemID: String) async {
        activeDownloads[itemID]?.cancel()
        activeDownloads[itemID] = nil
        activePageTasks[itemID]?.cancel()
        activePageTasks[itemID] = nil
        do {
            let db = await FeedStore.sharedDB()
            _ = try await db.write { db in
                try DownloadRecord
                    .filter(Column("item_id") == itemID)
                    .deleteAll(db)
            }
        } catch {}
        // Clean up partial bundle
        let bundle = cachesDirectory.appendingPathComponent(itemID)
        try? FileManager.default.removeItem(at: bundle)
    }

    func delete(itemID: String) async {
        await cancel(itemID: itemID)
    }

    func status(for itemID: String) -> DownloadStatus {
        // This is a synchronous lookup — caller should use cached value or await
        return .queued  // Simplified; real impl reads from in-memory cache
    }

    func progress(for itemID: String) -> Double {
        return 0.0  // Simplified; real impl tracks via progressHandlers
    }

    func isDownloaded(itemID: String) -> Bool {
        let bundle = cachesDirectory.appendingPathComponent(itemID)
        return FileManager.default.fileExists(atPath: bundle.path)
    }

    func localPagePath(for itemID: String) -> URL? {
        let path = cachesDirectory.appendingPathComponent("\(itemID)/page.html")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    func localAudioPath(for itemID: String) -> URL? {
        let path = cachesDirectory.appendingPathComponent("\(itemID)/audio.mp3")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    func evaluateRules(for items: [FeedItem]) async {
        // Stub — full implementation in Phase 2
    }

    func storageUsed() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: cachesDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    func enforceStorageLimit() async {
        let used = storageUsed()
        guard used > storageLimit else { return }
        do {
            let db = await FeedStore.sharedDB()
            let oldest = try await db.read { db in
                try DownloadRecord
                    .filter(Column("status") == DownloadStatus.completed.rawValue)
                    .order(Column("completed_at").asc)
                    .fetchAll(db)
            }
            var freed: Int64 = 0
            for record in oldest {
                guard used - freed > storageLimit * 8 / 10 else { break }  // evict to 80%
                await delete(itemID: record.itemID)
                freed += Int64(record.audioBytes + record.pageBytes)
            }
            if freed > 0 {
                notify(.init(event: .storageFull, itemID: nil, sourceTitle: nil, itemTitle: nil, count: nil))
            }
        } catch {}
    }

    func freeDiskSpace() -> Int64 {
        let values = try? cachesDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    func checkStorageGate(for byteCount: Int64) -> StorageGate {
        let available = freeDiskSpace()
        let used = storageUsed()
        let limit = storageLimit
        if available < 200_000_000 { return .criticallyLow(available: available) }
        if used + byteCount > limit { return .wouldExceedUserLimit(used: used, limit: limit) }
        let neededWithMargin = byteCount + 500_000_000
        if neededWithMargin > available { return .insufficientFree(needed: byteCount, available: available) }
        return .allowed
    }

    /// Emergency eviction on launch if critically low on space.
    func emergencyEvictIfNeeded() async {
        guard freeDiskSpace() < 200_000_000 else { return }
        do {
            let db = await FeedStore.sharedDB()
            let all = try await db.read { db in
                try DownloadRecord
                    .filter(Column("status") == DownloadStatus.completed.rawValue)
                    .order(Column("completed_at").asc)
                    .fetchAll(db)
            }
            for record in all {
                guard freeDiskSpace() < 500_000_000 else { break }
                await delete(itemID: record.itemID)
            }
            if !all.isEmpty {
                notify(.init(event: .storageFull, itemID: nil, sourceTitle: nil, itemTitle: nil, count: nil))
            }
        } catch {}
    }

    // MARK: - Queue processing

    private func processNext() async {
        guard activeDownloads.count + activePageTasks.count < 3 else { return }

        do {
            let db = await FeedStore.sharedDB()
            let next = try await db.read { db in
                try DownloadRecord
                    .filter(DownloadRecord.Columns.status == DownloadStatus.queued.rawValue)
                    .order(DownloadRecord.Columns.createdAt.asc)
                    .limit(1)
                    .fetchOne(db)
            }
            guard var record = next else { return }

            // Phase A: Audio (podcast only)
            if record.contentType == DownloadContentType.podcast.rawValue,
               let audioStr = record.audioURL,
               let audioURL = URL(string: audioStr) {

                record.status = DownloadStatus.downloadingAudio.rawValue
                let r1 = record
                try await db.write { db in try r1.update(db) }

                let bundle = cachesDirectory.appendingPathComponent(record.itemID)
                try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

                let (tempURL, _) = try await session.download(from: audioURL)
                let destURL = bundle.appendingPathComponent("audio.mp3")
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.moveItem(at: tempURL, to: destURL)

                let fileSize = (try? destURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                record.audioBytes = fileSize
                record.audioDownloaded = fileSize
                record.audioPath = "audio.mp3"
                record.bundlePath = bundle.path
                record.status = DownloadStatus.downloadingPage.rawValue
                let r2 = record
                try await db.write { db in try r2.update(db) }
            }

            // Phase B: Page (both podcast and article)
            if record.contentType == DownloadContentType.article.rawValue {
                record.status = DownloadStatus.downloadingPage.rawValue
                let r3 = record
                try await db.write { db in try r3.update(db) }
            }

            guard let pageURL = URL(string: record.pageURL) else {
                record.status = DownloadStatus.failedPage.rawValue
                let r4 = record
                try await db.write { db in try r4.update(db) }
                return
            }

            let bundle = cachesDirectory.appendingPathComponent(record.itemID)
            try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

            do {
                let sanitized = try await ContentSanitizer.fetchAndSanitize(url: pageURL)
                // Download images
                for imageURL in sanitized.imageURLs {
                    if let _ = await ImageCache.shared.diskImage(for: imageURL) {
                        // Already cached — rewrite will use ImageCache
                        continue
                    }
                    // Download and cache the image
                    if let (data, _) = try? await URLSession.shared.data(from: imageURL) {
                        await ImageCache.shared.setImage(data: data, for: imageURL)
                    }
                }
                // Write sanitized HTML with rewritten image paths
                let rewrittenHTML = await rewriteImagePaths(
                    sanitized.html,
                    imageURLs: sanitized.imageURLs
                )
                let pageFile = bundle.appendingPathComponent("page.html")
                try rewrittenHTML.write(to: pageFile, atomically: true, encoding: .utf8)
                record.pagePath = "page.html"
                record.pageBytes = (try? pageFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                record.pageDownloaded = record.pageBytes
                record.bundlePath = bundle.path
                record.status = DownloadStatus.completed.rawValue
                record.completedAt = Int(Date().timeIntervalSince1970)
            } catch {
                // Page failed — if podcast, audio still works
                if record.audioPath != nil {
                    record.status = DownloadStatus.failedPage.rawValue
                    record.completedAt = Int(Date().timeIntervalSince1970)
                } else {
                    record.status = DownloadStatus.failedPage.rawValue
                }
            }
            let r5 = record
            try await db.write { db in try r5.update(db) }

            // Notify
            notify(.init(event: record.status == DownloadStatus.completed.rawValue ? .completed : .failed,
                         itemID: record.itemID, sourceTitle: nil, itemTitle: nil, count: nil))

            await enforceStorageLimit()
            await processNext()  // Continue processing queue
        } catch {
            Log.feed.error("DownloadManager.processNext: \(error.localizedDescription)")
        }
    }

    private func rewriteImagePaths(_ html: String, imageURLs: [URL]) async -> String {
        var result = html
        for url in imageURLs {
            let cache = await ImageCache.shared
            let key = cache.cacheKey(for: url)
            let localPath = "images/\(key).jpg"
            result = result.replacingOccurrences(of: url.absoluteString, with: localPath)
        }
        return result
    }

    private func notify(_ notification: DownloadNotification) {
        notificationContinuation?.yield(notification)
    }
}
