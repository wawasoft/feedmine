import Foundation
import UIKit

/// Disk-level image cache. Runs off the MainActor — all I/O is async.
/// Uses the same FNV-1a cache key scheme as the existing ImageCache.
actor DiskImageCache {
    private let cacheDir: URL
    private let maxBytes: Int = 100 * 1024 * 1024  // 100 MB

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("FeedmineImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func data(for key: String) async -> Data? {
        let url = cacheDir.appendingPathComponent(key)
        return try? Data(contentsOf: url)
    }

    func store(_ data: Data, key: String) async throws {
        let url = cacheDir.appendingPathComponent(key)
        try data.write(to: url, options: .atomic)
    }

    func remove(key: String) async {
        let url = cacheDir.appendingPathComponent(key)
        try? FileManager.default.removeItem(at: url)
    }

    func evictIfNeeded() async {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return }

        var total: Int = 0
        var entries: [(url: URL, date: Date, size: Int)] = []
        for url in contents {
            guard let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = attrs.contentModificationDate,
                  let size = attrs.fileSize else { continue }
            total += size
            entries.append((url, date, size))
        }

        guard total > maxBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries {
            guard total > maxBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    func removeAll() async {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
}
