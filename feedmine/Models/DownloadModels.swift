// feedmine/Models/DownloadModels.swift
import Foundation
import GRDB

// MARK: - Enums

enum DownloadStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case queued
    case downloadingAudio = "downloading_audio"
    case downloadingPage = "downloading_page"
    case completed
    case failedAudio = "failed_audio"
    case failedPage = "failed_page"
}

enum DownloadMode: String, Codable, Sendable {
    case wifi
    case cellular
}

enum AutoDeletePolicy: String, Codable, Sendable {
    case afterRead = "after_read"
    case after7Days = "after_7_days"
    case manual
}

enum DownloadContentType: String, Codable, Sendable {
    case podcast
    case article
}

enum StorageGate: Equatable, Sendable {
    case allowed
    case insufficientFree(needed: Int64, available: Int64)
    case wouldExceedUserLimit(used: Int64, limit: Int64)
    case criticallyLow(available: Int64)
}

// MARK: - Notification Payload

struct DownloadNotification: Sendable {
    let event: DownloadNotificationEvent
    let itemID: String?
    let sourceTitle: String?
    let itemTitle: String?
    let count: Int?

    enum DownloadNotificationEvent: String, Sendable {
        case queued
        case completed
        case failed
        case batchCompleted
        case autoDownloadStarted
        case storageFull
        case airplaneModeNoDownloads
    }
}

// MARK: - GRDB Records

struct DownloadRuleRecord: Codable, PersistableRecord, FetchableRecord, Sendable {
    var id: Int64?
    var targetType: String       // "source" or "collection"
    var targetID: String         // source URL or collection ID as string
    var maxItems: Int = 3
    var mode: String = "wifi"    // "wifi" or "cellular"
    var enabled: Bool = true

    static let databaseTableName = "download_rule"

    enum Columns: String, ColumnExpression {
        case id, targetType = "target_type", targetID = "target_id"
        case maxItems = "max_items", mode, enabled
    }

    enum CodingKeys: String, CodingKey {
        case id
        case targetType = "target_type"
        case targetID = "target_id"
        case maxItems = "max_items"
        case mode, enabled
    }
}

struct DownloadRecord: Codable, PersistableRecord, FetchableRecord, Sendable {
    var id: Int64?
    var itemID: String
    var sourceURL: String
    var contentType: String = "podcast"  // "podcast" or "article"
    var audioURL: String?
    var pageURL: String
    var bundlePath: String?
    var audioPath: String?
    var pagePath: String?
    var audioBytes: Int = 0
    var audioDownloaded: Int = 0
    var pageBytes: Int = 0
    var pageDownloaded: Int = 0
    var status: String = "queued"        // maps to DownloadStatus rawValue
    var createdAt: Int
    var completedAt: Int?

    static let databaseTableName = "download"

    enum Columns: String, ColumnExpression {
        case id, itemID = "item_id", sourceURL = "source_url"
        case contentType = "content_type", audioURL = "audio_url"
        case pageURL = "page_url", bundlePath = "bundle_path"
        case audioPath = "audio_path", pagePath = "page_path"
        case audioBytes = "audio_bytes", audioDownloaded = "audio_downloaded"
        case pageBytes = "page_bytes", pageDownloaded = "page_downloaded"
        case status, createdAt = "created_at", completedAt = "completed_at"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case itemID = "item_id"
        case sourceURL = "source_url"
        case contentType = "content_type"
        case audioURL = "audio_url"
        case pageURL = "page_url"
        case bundlePath = "bundle_path"
        case audioPath = "audio_path"
        case pagePath = "page_path"
        case audioBytes = "audio_bytes"
        case audioDownloaded = "audio_downloaded"
        case pageBytes = "page_bytes"
        case pageDownloaded = "page_downloaded"
        case status
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }
}
