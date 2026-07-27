import Foundation

/// Actor responsible for all HTTP-level feed fetching semantics:
/// conditional GET (ETag/If-None-Match, Last-Modified/If-Modified-Since),
/// 304 Not Modified handling, Cache-Control/Expires extraction,
/// Retry-After parsing, and redirect canonical URL resolution.
actor FeedHTTPSync {
    private let session: URLSession

    /// Shared headers for all feed requests.
    private static let requestHeaders: [String: String] = [
        "User-Agent": "FeedMine/1.0 (https://feedmine.app/bot)",
        "Accept": "application/rss+xml, application/atom+xml, application/feed+json, application/json, application/xml, text/xml;q=0.9"
    ]

    init() {
        let cache = URLCache(memoryCapacity: 4_194_304, diskCapacity: 20_971_520)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = cache
        config.httpAdditionalHeaders = Self.requestHeaders
        self.session = URLSession(configuration: config)
    }

    /// Fetch a feed with conditional GET semantics.
    /// - Parameters:
    ///   - source: The feed source to fetch.
    ///   - validators: Previously-stored HTTP validators for this source.
    /// - Returns: The HTTP result with (possibly empty) data, outcome, and updated validators.
    func fetch(_ source: FeedSource, validators: HTTPValidators) async -> FetchHTTPResult {
        guard !Task.isCancelled else {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(CancellationError()),
                updatedValidators: validators,
                canonicalURL: nil
            )
        }

        guard let url = URL(string: source.url) else {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(URLError(.badURL)),
                updatedValidators: validators,
                canonicalURL: nil
            )
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        // Conditional GET headers
        if let etag = validators.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return FetchHTTPResult(
                    data: nil,
                    outcome: .failed(URLError(.badServerResponse)),
                    updatedValidators: validators,
                    canonicalURL: nil
                )
            }

            var updated = validators
            updated.lastFetchAt = Date()

            switch httpResponse.statusCode {
            case 200:
                updated = extractValidators(from: httpResponse, into: updated)
                let canonicalURL = httpResponse.url?.absoluteString
                return FetchHTTPResult(
                    data: data,
                    outcome: .success(data),
                    updatedValidators: updated,
                    canonicalURL: canonicalURL
                )

            case 304:
                updated = extractValidators(from: httpResponse, into: updated)
                updated.lastOutcome = .notModified
                return FetchHTTPResult(
                    data: nil,
                    outcome: .notModified,
                    updatedValidators: updated,
                    canonicalURL: nil
                )

            case 429, 503:
                let retryAfter = parseRetryAfter(from: httpResponse)
                updated.retryAfter = retryAfter
                updated.lastOutcome = .throttled
                return FetchHTTPResult(
                    data: nil,
                    outcome: .throttled(until: retryAfter),
                    updatedValidators: updated,
                    canonicalURL: nil
                )

            case 301, 302, 307, 308:
                // Followed automatically by URLSession. Record canonical URL.
                let canonicalURL = httpResponse.url?.absoluteString
                // Re-fetch is handled by URLSession's redirect — data is the final response.
                // If we got here, the final response was 200 and data is available.
                updated = extractValidators(from: httpResponse, into: updated)
                updated.canonicalURL = canonicalURL
                return FetchHTTPResult(
                    data: data,
                    outcome: .success(data),
                    updatedValidators: updated,
                    canonicalURL: canonicalURL
                )

            default:
                updated.lastOutcome = .failed
                return FetchHTTPResult(
                    data: nil,
                    outcome: .failed(URLError(.badServerResponse)),
                    updatedValidators: updated,
                    canonicalURL: nil
                )
            }

        } catch is CancellationError {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(CancellationError()),
                updatedValidators: validators,
                canonicalURL: nil
            )
        } catch let error as URLError where error.code == .cancelled {
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(error),
                updatedValidators: validators,
                canonicalURL: nil
            )
        } catch {
            var updated = validators
            updated.lastFetchAt = Date()
            updated.lastOutcome = .failed
            return FetchHTTPResult(
                data: nil,
                outcome: .failed(error),
                updatedValidators: updated,
                canonicalURL: nil
            )
        }
    }

    // MARK: - Private

    /// Extract HTTP validators from a 200/304 response into the mutable validators struct.
    private func extractValidators(from response: HTTPURLResponse, into validators: HTTPValidators) -> HTTPValidators {
        var v = validators

        if let etag = response.value(forHTTPHeaderField: "ETag") {
            v.etag = etag
        }
        if let lastMod = response.value(forHTTPHeaderField: "Last-Modified") {
            v.lastModified = lastMod
        }
        if let cacheControl = response.value(forHTTPHeaderField: "Cache-Control") {
            v.cacheControl = HTTPValidators.ParsedCacheControl.parse(cacheControl)
        }
        if let expiresStr = response.value(forHTTPHeaderField: "Expires") {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            v.expires = formatter.date(from: expiresStr)
        }

        return v
    }

    /// Parse Retry-After header: either seconds or HTTP-date.
    private func parseRetryAfter(from response: HTTPURLResponse) -> Date {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else {
            return Date().addingTimeInterval(60) // default 60s
        }

        // Try seconds first
        if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) {
            return Date().addingTimeInterval(seconds)
        }

        // Try HTTP-date
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let date = formatter.date(from: header) {
            return date
        }

        return Date().addingTimeInterval(60) // unparseable → default 60s
    }
}
