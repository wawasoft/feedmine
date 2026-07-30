import Foundation

// MARK: - Item Rule Set
//
// Declarative rules for item eligibility. One rule set, two interpreters:
//   SQLItemRuleCompiler   — transforms into a GRDB query for cache reads
//   InMemoryItemRuleEvaluator — evaluates items already in memory

/// Snapshot of user-defined content exclusions at plan compilation time.
struct ContentExclusionPolicy: Hashable, Sendable {
    /// Keywords that, if present in title/description, exclude an item.
    let excludedKeywords: Set<String>
    /// Whether content filtering is enabled at all.
    let isEnabled: Bool

    static let disabled = ContentExclusionPolicy(excludedKeywords: [], isEnabled: false)
}

/// Declarative rules for determining whether an item may appear in the feed.
/// This replaces the imperative `applyFilters` method.
struct ItemRuleSet: Hashable, Sendable {
    /// Sources that are eligible for this selection.
    var eligibleSourceIDs: Set<SourceID>

    /// Region filter. Empty = all regions allowed.
    var regions: Set<String>

    /// Language filter. Empty = all languages allowed.
    var languages: Set<String>

    /// Taxonomy-eligible source IDs. Empty = no taxonomy restriction.
    var taxonomySourceIDs: Set<SourceID>

    /// Content type filter. Empty = all types allowed.
    var contentTypes: Set<ContentType>

    /// Mood filter (sentiment/emotional tone).
    var mood: MoodFilter

    /// Active search expression, if any.
    var searchExpression: SearchExpression?

    /// Keywords to exclude from title/description.
    var excludedKeywords: Set<String>

    /// User-defined content filter rules.
    var contentExclusions: ContentExclusionPolicy

    /// History/read-state policy.
    var history: HistoryPolicy

    /// Digest of the rules for cache invalidation.
    /// Changes when any rule changes — used by ItemEvaluationCache
    /// to invalidate stale cached evaluations.
    var ruleDigest: UInt64 {
        var hasher = Hasher()
        hasher.combine(eligibleSourceIDs.hashValue)
        hasher.combine(regions.hashValue)
        hasher.combine(languages.hashValue)
        hasher.combine(taxonomySourceIDs.hashValue)
        hasher.combine(contentTypes.hashValue)
        hasher.combine(mood)
        hasher.combine(searchExpression)
        hasher.combine(excludedKeywords.hashValue)
        hasher.combine(contentExclusions)
        hasher.combine(history)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    /// Empty rule set — matches everything.
    static let none = ItemRuleSet(
        eligibleSourceIDs: [],
        regions: [],
        languages: [],
        taxonomySourceIDs: [],
        contentTypes: [],
        mood: .all,
        searchExpression: nil,
        excludedKeywords: [],
        contentExclusions: .disabled,
        history: .includeAll
    )
}

// MARK: - Item Evaluation Cache

/// Cache key for item rule evaluations. Combines item identity with the
/// rule digest so stale cache entries are never used after rule changes.
struct ItemEvaluationCacheKey: Hashable {
    let itemID: String
    let ruleDigest: UInt64
}

/// Thread-safe cache for item rule evaluations.
/// Avoids re-evaluating regex/string matching on thousands of items
/// when rules haven't changed.
actor ItemEvaluationCache {
    private var moodMatches: [ItemEvaluationCacheKey: Bool] = [:]
    private var contentFilterExclusions: [ItemEvaluationCacheKey: Bool] = [:]

    func moodMatch(_ itemID: String, ruleDigest: UInt64) -> Bool? {
        moodMatches[ItemEvaluationCacheKey(itemID: itemID, ruleDigest: ruleDigest)]
    }

    func setMoodMatch(_ itemID: String, ruleDigest: UInt64, match: Bool) {
        moodMatches[ItemEvaluationCacheKey(itemID: itemID, ruleDigest: ruleDigest)] = match
    }

    func contentFilterExcluded(_ itemID: String, ruleDigest: UInt64) -> Bool? {
        contentFilterExclusions[ItemEvaluationCacheKey(itemID: itemID, ruleDigest: ruleDigest)]
    }

    func setContentFilterExcluded(_ itemID: String, ruleDigest: UInt64, excluded: Bool) {
        contentFilterExclusions[ItemEvaluationCacheKey(itemID: itemID, ruleDigest: ruleDigest)] = excluded
    }

    /// Clear all cached evaluations. Called when memory pressure is high.
    func clearAll() {
        moodMatches.removeAll()
        contentFilterExclusions.removeAll()
    }

    /// Estimated memory footprint in bytes.
    var estimatedSize: Int {
        (moodMatches.count + contentFilterExclusions.count) * 128
    }
}
