import Foundation
import GRDB

/// Persisted image resolution state for a feed item. Separates transient
/// failures (retry-able) from confirmed absence (no image exists).
struct ImageResolutionRecord: Codable, FetchableRecord, PersistableRecord {
    var itemID: String
    var candidateFingerprint: String
    var state: String  // "unknown", "resolved", "no_image_confirmed", "transient_failure", "permanent_failure"
    var cacheKey: String?
    var resolvedURL: String?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteCount: Int?
    var attemptCount: Int
    var lastAttemptAt: Int64?
    var nextRetryAt: Int64?
    var failureClass: String?
    var failureCode: Int?
    var updatedAt: Int64

    enum Columns {
        static let itemID = Column("item_id")
        static let candidateFingerprint = Column("candidate_fingerprint")
        static let state = Column("state")
        static let cacheKey = Column("cache_key")
        static let resolvedURL = Column("resolved_url")
        static let pixelWidth = Column("pixel_width")
        static let pixelHeight = Column("pixel_height")
        static let byteCount = Column("byte_count")
        static let attemptCount = Column("attempt_count")
        static let lastAttemptAt = Column("last_attempt_at")
        static let nextRetryAt = Column("next_retry_at")
        static let failureClass = Column("failure_class")
        static let failureCode = Column("failure_code")
        static let updatedAt = Column("updated_at")
    }
}

// MARK: - Resolution Outcome

/// Terminal outcome of an image resolution attempt. Distinct from
/// ImageResolutionState (in ImageResolutionQueue) which tracks retry
/// queue position (pending/inProgress/failed).
enum ImageResolutionOutcome: String, Sendable {
    case unknown
    case resolved
    case noImageConfirmed = "no_image_confirmed"
    case transientFailure = "transient_failure"
    case permanentFailure = "permanent_failure"
}

// MARK: - Candidate Fingerprint

enum ImageCandidateFingerprint {
    /// Compute a fingerprint from the inputs that determine which image
    /// candidate to try. When any input changes, previous resolutions are
    /// invalidated automatically.
    static func compute(
        feedImageURL: String?,
        articleURL: String?,
        youTubeThumbnailURL: String?,
        policyVersion: Int = 1
    ) -> String {
        let components = [
            feedImageURL ?? "",
            articleURL ?? "",
            youTubeThumbnailURL ?? "",
            String(policyVersion)
        ]
        return components.joined(separator: "|")
    }
}
