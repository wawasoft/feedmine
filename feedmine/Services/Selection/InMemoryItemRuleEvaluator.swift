import Foundation

// MARK: - In-Memory Item Rule Evaluator
//
// Evaluates ItemRuleSet against FeedItems already in memory.
// Used for: freshly-fetched items, reservoir items, search results,
// What's New items, source content, collection content.
//
// This is the in-memory counterpart of SQLItemRuleCompiler.
// Tests MUST verify that both interpreters produce the same IDs for the same fixtures.

/// Evaluates item rules in-memory. Uses ItemEvaluationCache to avoid
/// re-evaluating expensive checks (mood regex, content filter matching)
/// when rules haven't changed.
struct InMemoryItemRuleEvaluator: Sendable {

    /// Cache for expensive evaluations. Shared across evaluations within
    /// the same selection session.
    let evaluationCache: ItemEvaluationCache

    init(evaluationCache: ItemEvaluationCache = ItemEvaluationCache()) {
        self.evaluationCache = evaluationCache
    }

    /// Filter an array of items, returning only those that pass all rules.
    func evaluate(
        _ items: [FeedItem],
        against rules: ItemRuleSet
    ) async -> [FeedItem] {
        let digest = rules.ruleDigest

        var result: [FeedItem] = []
        for item in items {
            if await passesRules(item, rules: rules, digest: digest) {
                result.append(item)
            }
        }
        return result
    }

    /// Check whether a single item passes all rules.
    func isEligible(
        _ item: FeedItem,
        against rules: ItemRuleSet
    ) async -> Bool {
        await passesRules(item, rules: rules, digest: rules.ruleDigest)
    }

    // MARK: - Rule checks

    private func passesRules(
        _ item: FeedItem,
        rules: ItemRuleSet,
        digest: UInt64
    ) async -> Bool {
        // 1. Region
        if !rules.regions.isEmpty {
            let itemRegion = item.region
            guard rules.regions.contains(itemRegion) || rules.regions.contains(where: { itemRegion.hasPrefix($0 + "/") }) else {
                return false
            }
        }

        // 2. Language
        if !rules.languages.isEmpty {
            guard let itemLang = item.language,
                  rules.languages.contains(itemLang) else {
                return false
            }
        }

        // 3. Content type — inferred from item properties
        if !rules.contentTypes.isEmpty {
            let itemType = contentType(of: item)
            guard rules.contentTypes.contains(itemType) else {
                return false
            }
        }

        // 4. Mood (cached — expensive regex evaluation)
        if rules.mood != .all {
            guard await evaluateMood(item, mood: rules.mood, digest: digest) else {
                return false
            }
        }

        // 5. Search expression
        if let search = rules.searchExpression {
            guard matchesSearch(item, expression: search) else {
                return false
            }
        }

        // 6. Excluded keywords
        if !rules.excludedKeywords.isEmpty {
            guard !containsExcludedKeywords(item, keywords: rules.excludedKeywords) else {
                return false
            }
        }

        // 7. Content filter keywords (cached)
        if rules.contentExclusions.isEnabled,
           !rules.contentExclusions.excludedKeywords.isEmpty {
            guard await !evaluateContentFilterExclusion(
                item,
                keywords: rules.contentExclusions.excludedKeywords,
                digest: digest
            ) else {
                return false
            }
        }

        // 8. History — read/bookmarked (consumed state tracked externally)
        if !rules.history.includeRead && item.isRead {
            return false
        }
        if !rules.history.includeBookmarked && item.isBookmarked {
            return false
        }

        // 9. Date range — use publishedAt
        if let dateRange = rules.history.dateRange {
            guard dateRange.contains(item.publishedAt) else {
                return false
            }
        }

        return true
    }

    // MARK: - Content type inference

    private func contentType(of item: FeedItem) -> ContentType {
        if item.isYouTube { return .video }
        if item.isPodcast { return .audio }
        return .text
    }

    // MARK: - Expensive checks (cached)

    private func evaluateMood(
        _ item: FeedItem,
        mood: MoodFilter,
        digest: UInt64
    ) async -> Bool {
        // Check cache first
        if let cached = await evaluationCache.moodMatch(item.id, ruleDigest: digest) {
            return cached
        }
        // Evaluate and cache
        let result = mood.matches(item.title)
        await evaluationCache.setMoodMatch(item.id, ruleDigest: digest, match: result)
        return result
    }

    private func evaluateContentFilterExclusion(
        _ item: FeedItem,
        keywords: Set<String>,
        digest: UInt64
    ) async -> Bool {
        // Check cache first
        if let cached = await evaluationCache.contentFilterExcluded(item.id, ruleDigest: digest) {
            return cached
        }
        // Evaluate and cache
        let result = ContentFilterMatcher.isExcluded(
            title: item.title, excerpt: item.excerpt, keywords: keywords
        )
        await evaluationCache.setContentFilterExcluded(
            item.id, ruleDigest: digest, excluded: result
        )
        return result
    }

    private func matchesSearch(_ item: FeedItem, expression: SearchExpression) -> Bool {
        let searchText = "\(item.title) \(item.excerpt)".lowercased()
        // Check required terms present and excluded terms absent
        for term in expression.requiredTerms {
            if !searchText.contains(term.lowercased()) { return false }
        }
        for term in expression.excludedTerms {
            if searchText.contains(term.lowercased()) { return false }
        }
        return true
    }

    private func containsExcludedKeywords(_ item: FeedItem, keywords: Set<String>) -> Bool {
        let text = "\(item.title.lowercased()) \(item.excerpt.lowercased())"
        return keywords.contains { keyword in
            text.contains(keyword.lowercased())
        }
    }
}

// MARK: - Content Filter Matcher

enum ContentFilterMatcher {
    /// Check if an item should be excluded based on content filter keywords.
    static func isExcluded(
        title: String,
        excerpt: String,
        keywords: Set<String>
    ) -> Bool {
        guard !keywords.isEmpty else { return false }
        let text = "\(title.lowercased()) \(excerpt.lowercased())"
        return keywords.contains { keyword in
            text.contains(keyword.lowercased())
        }
    }
}
