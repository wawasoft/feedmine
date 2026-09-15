import Foundation
import UIKit
import GRDB
import ImageIO

/// Central actor for image asset resolution. Coordinates memory/disk cache,
/// single-flight downloads, bounded network transfer, safe metadata inspection,
/// downsampling, and image-resolution persistence.
actor MediaAssetStore {
    private let memoryCache = MemoryImageCache()
    private let diskCache = DiskImageCache()
    private let db: DatabaseQueue

    private var inFlight: [ImageAssetKey: Task<ResolvedImageAsset?, Error>] = [:]

    /// Compressed-transfer ceiling. This is enforced while bytes arrive, not
    /// after URLSession has buffered the response.
    private static let maxDownloadBytes = 12 * 1024 * 1024
    /// A compressed image can expand dramatically when decoded. Inspect image
    /// metadata before asking ImageIO to create a thumbnail.
    private static let maxSourceDimension = 12_000
    private static let maxSourcePixels = 50_000_000

    private enum DownloadError: Error {
        case nonHTTP
        case badStatus(Int)
        case tooLarge
        case invalidImage
        case unsafeDimensions
    }

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

    func resolve(request: ImageResolutionRequest) async -> ResolvedImageAsset? {
        let key = request.key

        if let memKey = request.cacheKey, memoryCache.image(for: memKey) != nil {
            return await loadAssetMetadata(cacheKey: memKey)
        }

        if let task = inFlight[key] {
            return try? await task.value
        }

        let task = Task<ResolvedImageAsset?, Error> { [weak self] in
            try Task.checkCancellation()
            return await self?.performResolution(request)
        }
        inFlight[key] = task
        let result = try? await task.value
        inFlight[key] = nil
        return result
    }

    func diskData(for key: String) async -> Data? {
        await diskCache.data(for: key)
    }

    func decodedImage(for cacheKey: String) async -> UIImage? {
        if let image = memoryCache.image(for: cacheKey) {
            return image
        }
        guard let data = await diskCache.data(for: cacheKey),
              Self.hasSafeImageDimensions(data),
              let image = ImageCache.downsample(data: data, to: ImageCache.downsampleMaxDimension) else {
            return nil
        }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memoryCache.setImage(image, for: cacheKey, cost: cost)
        return image
    }

    func cancelAll() {
        // Intentionally empty: in-flight work is shared across display contexts.
    }

    func clearMemoryCache() {
        memoryCache.removeAll()
    }

    // MARK: - Private

    private func performResolution(_ request: ImageResolutionRequest) async -> ResolvedImageAsset? {
        if let cacheKey = request.cacheKey,
           let data = await diskCache.data(for: cacheKey),
           Self.hasSafeImageDimensions(data),
           let image = ImageCache.downsample(data: data, to: ImageCache.downsampleMaxDimension) {
            memoryCache.setImage(image, for: cacheKey)
            return assetMetadata(from: image, cacheKey: cacheKey, data: data, source: request.source)
        }

        guard let url = request.url else { return nil }

        do {
            let data = try await downloadImageData(from: url)
            guard isValidImageData(data) else { throw DownloadError.invalidImage }
            guard Self.hasSafeImageDimensions(data) else { throw DownloadError.unsafeDimensions }

            let cacheKey = request.cacheKey ?? ImageCacheKey.forURL(url)
            guard let image = ImageCache.downsample(data: data, to: ImageCache.downsampleMaxDimension) else {
                throw DownloadError.invalidImage
            }

            // Nothing reaches disk until the response is complete, within the
            // byte ceiling, passes magic-byte validation, passes source-size
            // validation, and successfully downsamples.
            try await diskCache.store(data, key: cacheKey)
            await diskCache.evictIfNeeded()

            let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            memoryCache.setImage(image, for: cacheKey, cost: cost)

            await persistResolution(
                itemID: request.itemID,
                cacheKey: cacheKey,
                data: data,
                url: url,
                source: request.source
            )
            return assetMetadata(from: image, cacheKey: cacheKey, data: data, source: request.source)
        } catch {
            await persistFailure(itemID: request.itemID, error: error, url: url)
            return nil
        }
    }

    /// Stream the body with a hard ceiling. Unknown/chunked Content-Length is
    /// safe because iteration stops before appending byte maxBytes+1. Exiting
    /// the async byte sequence cancels consumption; no partial file is created.
    private func downloadImageData(from url: URL) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.nonHTTP }
        guard (200...299).contains(http.statusCode) else {
            throw DownloadError.badStatus(http.statusCode)
        }
        if response.expectedContentLength > Int64(Self.maxDownloadBytes) {
            throw DownloadError.tooLarge
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Self.maxDownloadBytes, Int(response.expectedContentLength)))
        }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < Self.maxDownloadBytes else { throw DownloadError.tooLarge }
            data.append(byte)
        }
        return data
    }

    /// Reads metadata through ImageIO without decoding the full raster.
    private nonisolated static func hasSafeImageDimensions(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return false
        }
        let width = widthNumber.intValue
        let height = heightNumber.intValue
        guard width > 0, height > 0,
              width <= maxSourceDimension,
              height <= maxSourceDimension else { return false }
        let pixels = Int64(width) * Int64(height)
        return pixels <= Int64(maxSourcePixels)
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
        if data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF { return true }
        if data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4E && data[3] == 0x47 { return true }
        if data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x38 { return true }
        if data[0] == 0x52 && data[1] == 0x49 && data[2] == 0x46 && data[3] == 0x46 { return true }
        return false
    }
}

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
    static func forURL(_ url: URL) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "img_\(String(hash, radix: 16))"
    }
}
