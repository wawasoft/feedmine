import Foundation
import UIKit
import GRDB

/// Central actor for image asset resolution. Coordinates:
/// - Memory cache lookup (MemoryImageCache)
/// - Disk cache lookup (DiskImageCache)
/// - Single-flight deduplication (shared Tasks)
/// - Network download + validation
/// - Downsample + disk write
/// - image_resolution persistence
actor MediaAssetStore {
    private let memoryCache = MemoryImageCache()
    private let diskCache = DiskImageCache()
    private let db: DatabaseQueue

    /// In-flight resolution tasks keyed by ImageAssetKey.
    /// All consumers of the same key await the same Task — no polling.
    /// Uses Error failure type so cancellation propagates to awaiters.
    private var inFlight: [ImageAssetKey: Task<ResolvedImageAsset?, Error>] = [:]

    /// Session for image downloads.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config)
    }()

    init(db: DatabaseQueue) {
        self.db = db
    }

    // MARK: - Public API

    /// Resolve an image asset with single-flight deduplication.
    /// Returns nil if the image cannot be resolved (transient or permanent),
    /// or if the calling Task is cancelled.
    ///
    /// Single-flight uses a throwing Task so cancellation propagates properly:
    /// when the caller's Task is cancelled, `await task.value` throws
    /// CancellationError, which propagates up through the coordinator's
    /// raceWithDeadline, which returns nil → terminal placeholder.
    func resolve(request: ImageResolutionRequest) async -> ResolvedImageAsset? {
        let key = request.key

        // 1. Memory cache hit
        if let memKey = request.cacheKey, memoryCache.image(for: memKey) != nil {
            return await loadAssetMetadata(cacheKey: memKey)
        }

        // 2. Single-flight dedup: if this key is already in-flight, await it
        if let task = inFlight[key] {
            return try? await task.value
        }

        // 3. Create a shared task so concurrent callers await the same download.
        // Uses Task<..., Error> so cancellation propagates to awaiters.
        let task = Task<ResolvedImageAsset?, Error> { [weak self] in
            try Task.checkCancellation()
            return await self?.performResolution(request)
        }
        inFlight[key] = task
        let result = try? await task.value
        inFlight[key] = nil
        return result
    }

    /// Read raw image data from disk cache.
    func diskData(for key: String) async -> Data? {
        await diskCache.data(for: key)
    }

    /// Return a downsampled UIImage for the given cache key. Checks memory
    /// cache first (free), then disk + downsample. Never returns a
    /// full-resolution UIImage — the decode step must not use UIImage(data:)
    /// on raw disk bytes.
    func decodedImage(for cacheKey: String) async -> UIImage? {
        if let image = memoryCache.image(for: cacheKey) {
            return image
        }
        guard let data = await diskCache.data(for: cacheKey) else { return nil }
        guard let image = ImageCache.downsample(data: data, to: ImageCache.downsampleMaxDimension) else {
            return nil
        }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memoryCache.setImage(image, for: cacheKey, cost: cost)
        return image
    }

    /// Context change does NOT cancel or clear in-flight downloads. The
    /// coordinator's context guard prevents stale tasks from publishing.
    /// Keeping the dictionary means new contexts reuse in-progress downloads
    /// (single-flight across contexts), and completed disk writes benefit
    /// all future compositions.
    func cancelAll() {
        // Intentionally empty — in-flight tasks are shared across contexts.
    }

    /// Clear memory cache (memory warning).
    func clearMemoryCache() {
        memoryCache.removeAll()
    }

    // MARK: - Private

    private func performResolution(_ request: ImageResolutionRequest) async -> ResolvedImageAsset? {
        // 1. Check disk cache
        if let cacheKey = request.cacheKey,
           let data = await diskCache.data(for: cacheKey),
           let image = ImageCache.downsample(data: data, to: ImageCache.downsampleMaxDimension) {
            memoryCache.setImage(image, for: cacheKey)
            let asset = assetMetadata(from: image, cacheKey: cacheKey, data: data, source: request.source)
            return asset
        }

        // 2. Download from network
        guard let url = request.url else { return nil }

        do {
            let (data, _) = try await session.data(from: url)
            guard isValidImageData(data) else { return nil }

            let cacheKey = request.cacheKey ?? ImageCacheKey.forURL(url)
            let image = ImageCache.downsample(data: data, to: ImageCache.downsampleMaxDimension)

            // Store to disk
            try? await diskCache.store(data, key: cacheKey)
            await diskCache.evictIfNeeded()

            // Cache in memory
            if let image {
                let cost = Int(image.size.width * image.size.height * 4)
                memoryCache.setImage(image, for: cacheKey, cost: cost)
            }

            // Persist resolution state
            await persistResolution(itemID: request.itemID, cacheKey: cacheKey,
                                    data: data, url: url, source: request.source)

            if let image {
                return assetMetadata(from: image, cacheKey: cacheKey, data: data, source: request.source)
            }
            return nil
        } catch {
            await persistFailure(itemID: request.itemID, error: error, url: url)
            return nil
        }
    }

    private func assetMetadata(
        from image: UIImage, cacheKey: String, data: Data, source: ImageResolutionSource
    ) -> ResolvedImageAsset {
        ResolvedImageAsset(
            cacheKey: cacheKey,
            pixelWidth: Int(image.size.width * image.scale),
            pixelHeight: Int(image.size.height * image.scale),
            byteCount: data.count,
            source: source
        )
    }

    private func loadAssetMetadata(cacheKey: String) async -> ResolvedImageAsset? {
        do {
            return try await db.read { db in
                try ImageResolutionRecord
                    .filter(ImageResolutionRecord.Columns.cacheKey == cacheKey)
                    .filter(ImageResolutionRecord.Columns.state == ImageResolutionOutcome.resolved.rawValue)
                    .fetchOne(db)
                    .map { record in
                        ResolvedImageAsset(
                            cacheKey: record.cacheKey ?? cacheKey,
                            pixelWidth: record.pixelWidth ?? 0,
                            pixelHeight: record.pixelHeight ?? 0,
                            byteCount: record.byteCount ?? 0,
                            source: ImageResolutionSource(rawValue: record.failureClass ?? "") ?? .unknown
                        )
                    }
            }
        } catch {
            return nil
        }
    }

    private func persistResolution(
        itemID: String, cacheKey: String, data: Data, url: URL, source: ImageResolutionSource
    ) async {
        let fingerprint = ImageCandidateFingerprint.compute(
            feedImageURL: url.absoluteString,
            articleURL: nil,
            youTubeThumbnailURL: nil
        )
        let now = Int64(Date().timeIntervalSince1970)
        let record = ImageResolutionRecord(
            itemID: itemID, candidateFingerprint: fingerprint,
            state: ImageResolutionOutcome.resolved.rawValue,
            cacheKey: cacheKey, resolvedURL: url.absoluteString,
            pixelWidth: 0, pixelHeight: 0, byteCount: data.count,
            attemptCount: 1, lastAttemptAt: now, nextRetryAt: nil,
            failureClass: source.rawValue, failureCode: nil,
            updatedAt: now
        )
        do {
            try await db.write { db in
                try record.save(db)
            }
        } catch {
            // Upsert on conflict — record may already exist
            _ = try? await db.write { db in
                try record.upsert(db)
            }
        }
    }

    private func persistFailure(itemID: String, error: Error, url: URL) async {
        let nsError = error as NSError
        let isTransient = nsError.domain == NSURLErrorDomain && [
            NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
            NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost
        ].contains(nsError.code)

        let now = Int64(Date().timeIntervalSince1970)
        let fingerprint = ImageCandidateFingerprint.compute(
            feedImageURL: url.absoluteString,
            articleURL: nil, youTubeThumbnailURL: nil
        )
        let state = isTransient
            ? ImageResolutionOutcome.transientFailure.rawValue
            : ImageResolutionOutcome.permanentFailure.rawValue

        let record = ImageResolutionRecord(
            itemID: itemID, candidateFingerprint: fingerprint,
            state: state, cacheKey: nil, resolvedURL: nil,
            pixelWidth: nil, pixelHeight: nil, byteCount: nil,
            attemptCount: 1, lastAttemptAt: now,
            nextRetryAt: isTransient ? now + 30 : nil,
            failureClass: nsError.domain, failureCode: nsError.code,
            updatedAt: now
        )
        do {
            try await db.write { db in
                try record.save(db)
            }
        } catch {
            _ = try? await db.write { db in
                try record.upsert(db)
            }
        }
    }

    private nonisolated func isValidImageData(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        // JPEG: FF D8 FF
        if data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF { return true }
        // PNG: 89 50 4E 47
        if data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 { return true }
        // GIF: 47 49 46 38
        if data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x38 { return true }
        // WebP/RIFF: 52 49 46 46
        if data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 { return true }
        return false
    }
}

// MARK: - Supporting Types

struct ImageResolutionRequest: Sendable {
    let itemID: String
    let url: URL?
    let cacheKey: String?
    let source: ImageResolutionSource
    var key: ImageAssetKey { ImageAssetKey(url: url, cacheKey: cacheKey) }
}

struct ImageAssetKey: Hashable, Sendable {
    let url: URL?
    let cacheKey: String?
}

enum ImageCacheKey {
    /// FNV-1a 64-bit — deterministic across launches, unlike Hasher.
    /// Same algorithm as `ImageCache.stableHash` so cache keys are
    /// consistent regardless of which pipeline produced the file.
    static func forURL(_ url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "img_\(String(hash, radix: 16))"
    }
}
