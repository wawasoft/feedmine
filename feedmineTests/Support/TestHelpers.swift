import Foundation
import XCTest
@testable import feedmine

// MARK: - Test fixture profile

/// Standard fixture profiles for performance and functional tests.
enum FixtureProfile: String, Sendable {
    case empty = "empty"
    case typical = "typical"
    case heavy = "heavy"
    case migration = "migration"
    case goldenBadData = "golden-bad-data"
}

/// Network simulation profiles for test reproducibility.
enum NetworkProfile: String, Sendable {
    case fast = "fast"
    case slow = "slow"
    case offline = "offline"
    case timeout = "timeout"
    case partialFailure = "partial-failure"
    case badMedia = "bad-media"
}

// MARK: - Test helpers

extension FeedStore {
    /// Create a FeedStore with in-memory database and a fixed seed for reproducibility.
    /// - Parameters:
    ///   - seed: Deterministic seed for generated data.
    ///   - now: Fixed "current" date for time-dependent logic.
    convenience init(inMemoryWithSeed seed: Int, now: Date = ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!) async throws {
        try self.init(inMemory: true)
    }
}

/// Create a deterministic set of FeedItem fixtures.
func makeFixtureItems(
    count: Int,
    seed: Int = 42,
    startDate: Date = ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!
) -> [FeedItem] {
    var rng = Xoshiro256Plus(seed: UInt64(bitPattern: Int64(seed)))
    var items: [FeedItem] = []
    let sources = (0..<min(count, 20)).map { i in
        (title: "Source \(i)", url: "https://source-\(i).example/feed", category: ["Technology", "News & Current Affairs", "Sports", "Entertainment", "Science", "Business", "Health", "Arts & Culture"][i % 8])
    }

    for i in 0..<count {
        let src = sources[i % sources.count]
        let offset = Double(rng.next() % (7 * 86400)) // up to 7 days ago
        let pubDate = startDate.addingTimeInterval(-offset)
        let item = FeedItem(
            id: "fixture-item-\(seed)-\(i)",
            sourceTitle: src.title,
            sourceURL: src.url,
            category: src.category,
            title: "Story \(i): A compelling headline about \(src.category)",
            excerpt: "Detailed analysis and reporting on \(src.category) with expert perspective and original research findings.",
            url: "https://source-\(i % sources.count).example/article-\(i)",
            imageURL: i % 3 == 0 ? nil : "https://source-\(i % sources.count).example/image-\(i).jpg",
            publishedAt: pubDate,
            audioURL: i % 10 == 0 ? "https://source-\(i % sources.count).example/audio-\(i).mp3" : nil,
            duration: i % 10 == 0 ? Double((rng.next() % 3600) + 60) : nil,
            region: i % 5 == 0 ? "global" : "countries/XX",
            language: ["en", "pt-BR", "ja", "ar", "fr"][i % 5]
        )
        items.append(item)
    }
    return items
}

// MARK: - Simple PRNG for test determinism

/// Minimal xoshiro256+ implementation for test reproducibility.
/// Not cryptographically secure — use only for generating test fixtures.
struct Xoshiro256Plus: RandomNumberGenerator {
    private var state: (UInt64, UInt64, UInt64, UInt64)

    init(seed: UInt64) {
        // SplitMix64 to seed xoshiro256+
        var z = seed &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        z = z ^ (z >> 31)
        state = (z &+ 0x9e3779b97f4a7c15, z, z, z)
        // Mix a few rounds
        for _ in 0..<8 { _ = next() }
    }

    mutating func next() -> UInt64 {
        let result = state.0 &+ state.3
        let t = state.1 << 17
        state.2 ^= state.0
        state.3 ^= state.1
        state.1 ^= state.2
        state.0 ^= state.3
        state.2 ^= t
        state.3 = (state.3 << 45) | (state.3 >> 19)
        return result
    }
}
