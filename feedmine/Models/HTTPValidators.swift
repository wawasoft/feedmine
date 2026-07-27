import Foundation

// MARK: - HTTP Validators

/// Per-source HTTP validators persisted in source_health.
/// Populated by FeedHTTPSync (headers) and RSSFetcher (feed-level elements).
struct HTTPValidators: Codable, Sendable, Equatable {
    var etag: String?
    var lastModified: String?
    var cacheControl: ParsedCacheControl?
    var expires: Date?
    var canonicalURL: String?
    var lastFetchAt: Date?
    var lastOutcome: FetchOutcomeKind?
    var retryAfter: Date?
    var ttl: Int?                        // RSS <ttl> in minutes
    var skipHours: [Int]?               // hours of day (0-23) when fetching should be avoided
    var skipDays: [String]?             // day names when fetching should be avoided
    var lastBuildDate: Date?
    var capabilities: SourceCapabilities?
    var publicationInterval: TimeInterval?
    var publicationIntervalConfidence: Double?

    init(
        etag: String? = nil,
        lastModified: String? = nil,
        cacheControl: ParsedCacheControl? = nil,
        expires: Date? = nil,
        canonicalURL: String? = nil,
        lastFetchAt: Date? = nil,
        lastOutcome: FetchOutcomeKind? = nil,
        retryAfter: Date? = nil,
        ttl: Int? = nil,
        skipHours: [Int]? = nil,
        skipDays: [String]? = nil,
        lastBuildDate: Date? = nil,
        capabilities: SourceCapabilities? = nil,
        publicationInterval: TimeInterval? = nil,
        publicationIntervalConfidence: Double? = nil
    ) {
        self.etag = etag
        self.lastModified = lastModified
        self.cacheControl = cacheControl
        self.expires = expires
        self.canonicalURL = canonicalURL
        self.lastFetchAt = lastFetchAt
        self.lastOutcome = lastOutcome
        self.retryAfter = retryAfter
        self.ttl = ttl
        self.skipHours = skipHours
        self.skipDays = skipDays
        self.lastBuildDate = lastBuildDate
        self.capabilities = capabilities
        self.publicationInterval = publicationInterval
        self.publicationIntervalConfidence = publicationIntervalConfidence
    }

    struct ParsedCacheControl: Codable, Sendable, Equatable {
        var maxAge: TimeInterval?
        var noCache: Bool
        var noStore: Bool
        var mustRevalidate: Bool

        init(maxAge: TimeInterval? = nil, noCache: Bool = false,
             noStore: Bool = false, mustRevalidate: Bool = false) {
            self.maxAge = maxAge
            self.noCache = noCache
            self.noStore = noStore
            self.mustRevalidate = mustRevalidate
        }

        /// Parse a Cache-Control header value into its directives.
        static func parse(_ header: String) -> ParsedCacheControl {
            var result = ParsedCacheControl()
            let directives = header.lowercased().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for directive in directives {
                if directive == "no-cache" { result.noCache = true }
                else if directive == "no-store" { result.noStore = true }
                else if directive == "must-revalidate" { result.mustRevalidate = true }
                else if directive.hasPrefix("max-age=") {
                    result.maxAge = TimeInterval(directive.dropFirst(8))
                }
            }
            return result
        }
    }

    enum FetchOutcomeKind: String, Codable, Sendable {
        case notModified
        case modifiedWithNewItems
        case modifiedWithoutNewItems
        case failed
        case throttled
    }
}

// MARK: - Cadence Estimator

/// Learns publication frequency per source using exponential moving average.
struct CadenceEstimator: Codable, Sendable {
    var publicationInterval: TimeInterval = 3600  // default 1 hour
    var confidence: Double = 0.0                   // 0 = no data, 1 = highly predictable
    var lastPublication: Date = .distantPast

    /// Record that the feed produced new items — update EMA.
    mutating func recordPublication(_ date: Date) {
        let interval = date.timeIntervalSince(lastPublication)
        if lastPublication > .distantPast, interval > 0 {
            publicationInterval = publicationInterval * 0.7 + interval * 0.3
        }
        lastPublication = date
        confidence = min(1.0, confidence + 0.1)
    }

    /// Record that we checked and found nothing new — slight confidence decay.
    mutating func recordNoChange() {
        confidence = max(0.1, confidence - 0.02)
    }

    /// Recommended minimum interval before next fetch (80% of learned interval).
    var minInterval: TimeInterval {
        max(300, min(publicationInterval * 0.8, 2_592_000))  // 5 min → 30 days
    }
}

// MARK: - Source Capabilities

/// Feed-level features discovered during parsing.
/// Serialized as JSON in source_health.capabilities.
struct SourceCapabilities: Codable, Sendable, Equatable {
    var websub: WebSubEndpoints?
    var cloud: RSSCloudEndpoints?
    var hasPagination: Bool

    struct WebSubEndpoints: Codable, Sendable, Equatable {
        let hub: String
        let selfURL: String?
    }

    struct RSSCloudEndpoints: Codable, Sendable, Equatable {
        let domain: String
        let port: Int
        let path: String
        let registerProcedure: String
        let protocolVersion: String
    }

    var canPush: Bool { websub != nil || cloud != nil }

    init(websub: WebSubEndpoints? = nil, cloud: RSSCloudEndpoints? = nil, hasPagination: Bool = false) {
        self.websub = websub
        self.cloud = cloud
        self.hasPagination = hasPagination
    }
}
