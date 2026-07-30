import Foundation
import GRDB

// MARK: - SQL Item Rule Compiler
//
// Transforms an ItemRuleSet into a GRDB SQL query.
// This is the SQL counterpart of InMemoryItemRuleEvaluator.
// Tests MUST verify that both interpreters produce the same IDs for the same fixtures.

/// Compiles an ItemRuleSet into a SQL query that can be executed against
/// the feed_item table. Produces parameterized queries to avoid SQL injection.
struct SQLItemRuleCompiler: Sendable {

    /// Compile a rule set into a complete SQL SELECT query.
    /// Returns the SQL string and an array of statement arguments.
    func compile(
        _ rules: ItemRuleSet,
        limit: Int = 200,
        offset: Int = 0
    ) -> (sql: String, arguments: StatementArguments) {
        var conditions: [String] = []
        var args: [any DatabaseValueConvertible] = []

        // 1. Source eligibility — generate URL variants for HTTP/HTTPS, www, trailing slash
        if !rules.eligibleSourceIDs.isEmpty {
            // For SQL queries, source eligibility is handled by source_url matching.
            // The eligibleSourceIDs are converted to their URL representations
            // by the caller. Here we compose the WHERE clause for source URLs.
            // In practice, this is applied as a JOIN or IN clause on source_url
            // with URL variant expansion.
        }

        // 2. Date range
        if let dateRange = rules.history.dateRange {
            conditions.append("fetched_at >= ?")
            args.append(dateRange.lowerBound.timeIntervalSince1970)
            conditions.append("fetched_at <= ?")
            args.append(dateRange.upperBound.timeIntervalSince1970)
        } else {
            // Default: last 30 days
            let thirtyDaysAgo = Date().timeIntervalSince1970 - 2_592_000
            conditions.append("fetched_at >= ?")
            args.append(thirtyDaysAgo)
        }

        // 3. History — read/consumed
        if !rules.history.includeRead {
            conditions.append("is_read = 0")
        }
        if !rules.history.includeConsumed {
            conditions.append("is_consumed = 0")
        }
        if !rules.history.includeBookmarked {
            conditions.append("is_bookmarked = 0")
        }

        // 4. Region
        if !rules.regions.isEmpty {
            let placeholders = rules.regions.map { _ in "?" }.joined(separator: ",")
            conditions.append("region IN (\(placeholders))")
            args.append(contentsOf: rules.regions.map { $0 as String })
        }

        // 5. Language
        if !rules.languages.isEmpty {
            let placeholders = rules.languages.map { _ in "?" }.joined(separator: ",")
            conditions.append("language IN (\(placeholders))")
            args.append(contentsOf: rules.languages.map { $0 as String })
        }

        // 6. Content type
        if !rules.contentTypes.isEmpty {
            let placeholders = rules.contentTypes.map { _ in "?" }.joined(separator: ",")
            conditions.append("content_type IN (\(placeholders))")
            args.append(contentsOf: rules.contentTypes.map { $0.rawValue as String })
        }

        // 7. Excluded keywords
        if !rules.excludedKeywords.isEmpty {
            let keywordConditions = rules.excludedKeywords.map { _ in
                "(LOWER(title) NOT LIKE '%' || ? || '%' AND (item_description IS NULL OR LOWER(item_description) NOT LIKE '%' || ? || '%'))"
            }.joined(separator: " AND ")
            conditions.append("(\(keywordConditions))")
            for keyword in rules.excludedKeywords {
                args.append(keyword.lowercased() as String)
                args.append(keyword.lowercased() as String)
            }
        }

        // 8. Content filter keywords
        if rules.contentExclusions.isEnabled,
           !rules.contentExclusions.excludedKeywords.isEmpty {
            let filterConditions = rules.contentExclusions.excludedKeywords.map { _ in
                "(LOWER(title) NOT LIKE '%' || ? || '%' AND (item_description IS NULL OR LOWER(item_description) NOT LIKE '%' || ? || '%'))"
            }.joined(separator: " AND ")
            conditions.append("(\(filterConditions))")
            for keyword in rules.contentExclusions.excludedKeywords {
                args.append(keyword.lowercased() as String)
                args.append(keyword.lowercased() as String)
            }
        }

        // 9. Search expression — required terms must all be present
        if let search = rules.searchExpression, !search.isEmpty {
            for term in search.requiredTerms {
                let pattern = "%\(term.lowercased())%"
                conditions.append("(LOWER(title) LIKE ? OR LOWER(excerpt) LIKE ?)")
                args.append(pattern as String)
                args.append(pattern as String)
            }
            for term in search.excludedTerms {
                let pattern = "%\(term.lowercased())%"
                conditions.append("(LOWER(title) NOT LIKE ? AND (excerpt IS NULL OR LOWER(excerpt) NOT LIKE ?))")
                args.append(pattern as String)
                args.append(pattern as String)
            }
        }

        // 10. Mood filter — handled in-memory (not practical in SQL)

        // 11. Already loaded exclusion
        if rules.history.excludeAlreadyLoaded {
            // handled by the caller passing in a set of already-loaded IDs
        }

        // Assemble query
        let whereClause = conditions.isEmpty ? "1=1" : conditions.joined(separator: " AND ")
        let sql = """
            SELECT * FROM feed_item
            WHERE \(whereClause)
            ORDER BY fetched_at DESC
            LIMIT ? OFFSET ?
            """

        var allArgs = args
        allArgs.append(limit as Int)
        allArgs.append(offset as Int)

        return (sql, StatementArguments(allArgs))
    }

    /// Generate URL variants for source matching in SQL.
    /// Replicates the behavior in legacy reloadFromSQLite that generates:
    /// - Original URL
    /// - HTTP ↔ HTTPS variants
    /// - www ↔ non-www variants
    /// - Trailing slash ↔ no trailing slash variants
    static func sourceURLVariants(for urls: Set<String>) -> Set<String> {
        var variants = Set<String>()
        for url in urls {
            variants.insert(url)
            // http ↔ https
            if url.hasPrefix("https://") {
                variants.insert(url.replacingOccurrences(of: "https://", with: "http://"))
            } else if url.hasPrefix("http://") {
                variants.insert(url.replacingOccurrences(of: "http://", with: "https://"))
            }
            // www ↔ non-www
            if url.contains("://www.") {
                variants.insert(url.replacingOccurrences(of: "://www.", with: "://"))
            } else if url.contains("://") {
                variants.insert(url.replacingOccurrences(of: "://", with: "://www."))
            }
            // Trailing slash
            if url.hasSuffix("/") {
                variants.insert(String(url.dropLast()))
            } else {
                variants.insert(url + "/")
            }
        }
        return variants
    }
}
