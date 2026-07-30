import Foundation

// MARK: - Ranking Engine
//
// Answers: "Between two eligible candidates, which should appear first?"
//
// Pure function — takes items + compiled ranking plan → scored candidates.
// Each candidate gets a breakdown of score components for debugging/transparency.

// MARK: - Score Component

/// One component of a candidate's total score, with its source for transparency.
struct ScoreComponent: Hashable, Sendable {
    let name: String
    let weight: Double
    let rawValue: Double
    let contribution: Double  // weight × rawValue

    static func component(name: String, weight: Double, rawValue: Double) -> ScoreComponent {
        ScoreComponent(
            name: name,
            weight: weight,
            rawValue: rawValue,
            contribution: weight * rawValue
        )
    }
}

// MARK: - Candidate Score

/// Complete score for a candidate item with full component breakdown.
struct CandidateScore: Hashable, Sendable {
    let itemID: String
    let total: Double
    let components: [ScoreComponent]

    /// Items with negative total are penalized below baseline.
    var isPenalized: Bool { total < 0 }

    static func zero(for itemID: String) -> CandidateScore {
        CandidateScore(itemID: itemID, total: 0, components: [])
    }
}

// MARK: - Ranking Engine

/// Scores candidates using a compiled ranking plan.
/// Pure function — no side effects, no state.
struct RankingEngine: Sendable {

    /// Score a batch of items against the compiled plan.
    func score(
        items: [FeedItem],
        plan: CompiledRankingPlan,
        sourceMetadata: [SourceID: SourceSelectionMetadata] = [:],
        presetMultipliers: [SourceID: Double] = [:],
        curatedMultipliers: [SourceID: Double] = [:],
        alreadySurfacedIDs: Set<String> = []
    ) -> [CandidateScore] {
        items.map { item in
            scoreOne(
                item: item,
                plan: plan,
                sourceMetadata: sourceMetadata,
                presetMultipliers: presetMultipliers,
                curatedMultipliers: curatedMultipliers,
                alreadySurfacedIDs: alreadySurfacedIDs
            )
        }
    }

    // MARK: - Single item scoring

    private func scoreOne(
        item: FeedItem,
        plan: CompiledRankingPlan,
        sourceMetadata: [SourceID: SourceSelectionMetadata],
        presetMultipliers: [SourceID: Double],
        curatedMultipliers: [SourceID: Double],
        alreadySurfacedIDs: Set<String>
    ) -> CandidateScore {
        // Identity plan — items pass through with zero score
        if plan.isIdentity {
            return CandidateScore.zero(for: item.id)
        }

        var components: [ScoreComponent] = []
        var total: Double = 0

        for operation in plan.operations {
            switch operation {
            case .freshness(let weight):
                let raw = freshnessScore(item)
                let c = ScoreComponent.component(name: "Freshness", weight: weight, rawValue: raw)
                components.append(c)
                total += c.contribution

            case .sourceQuality(let weight):
                let raw = sourceQualityScore(item)
                let c = ScoreComponent.component(name: "Source Quality", weight: weight, rawValue: raw)
                components.append(c)
                total += c.contribution

            case .presetMultiplier(let multipliers):
                // Apply preset multipliers — these are typically source-level boosts
                // In Phase 4, sourceID lookup needs the catalog adapter
                if let presetMult = presetMultipliers.first(where: { _ in true }) {
                    // Placeholder — full implementation requires SourceID resolution
                }
                let raw = 1.0  // baseline — actual multiplier applied by caller
                let c = ScoreComponent.component(name: "Preset Boost", weight: 1.0, rawValue: raw)
                components.append(c)
                total += c.contribution

            case .curatedProfileMultiplier:
                let raw = 1.0  // baseline — actual multiplier from CuratedPreferenceEngine
                let c = ScoreComponent.component(name: "Curated Profile", weight: 1.0, rawValue: raw)
                components.append(c)
                total += c.contribution

            case .imageAvailability(let weight):
                let raw = item.hasImage ? 1.0 : 0.0
                let c = ScoreComponent.component(name: "Image Available", weight: weight, rawValue: raw)
                components.append(c)
                total += c.contribution

            case .mediaPreference(let preferredType, let weight):
                let raw = mediaTypeScore(item, preferred: preferredType)
                let c = ScoreComponent.component(name: "Media Preference", weight: weight, rawValue: raw)
                components.append(c)
                total += c.contribution
            }
        }

        // Penalize already-surfaced items
        if alreadySurfacedIDs.contains(item.id) {
            let penalty = ScoreComponent.component(name: "Already Surfaced", weight: 1.0, rawValue: -0.70)
            components.append(penalty)
            total += penalty.contribution
        }

        return CandidateScore(itemID: item.id, total: total, components: components)
    }

    // MARK: - Scoring helpers

    /// Score based on item age. 0 = very old, 1 = brand new (within 1 hour).
    private func freshnessScore(_ item: FeedItem) -> Double {
        let age = Date().timeIntervalSince(item.publishedAt)
        let oneHour: TimeInterval = 3600
        let oneDay: TimeInterval = 86400
        let oneWeek: TimeInterval = 604800

        if age < oneHour { return 1.0 }
        if age < oneDay { return 0.8 }
        if age < oneWeek { return 0.5 }
        return 0.1
    }

    /// Score based on whether the source has good metadata signals.
    private func sourceQualityScore(_ item: FeedItem) -> Double {
        var score: Double = 0.5  // baseline

        // Has proper language metadata
        if item.language != nil { score += 0.15 }

        // Has author attribution
        if item.authors?.isEmpty == false { score += 0.15 }

        // Has proper title (not just domain)
        if item.title.count > 20 { score += 0.1 }

        // Has excerpt
        if !item.excerpt.isEmpty { score += 0.1 }

        return min(score, 1.0)
    }

    /// Score based on item's media type vs. preferred type.
    private func mediaTypeScore(_ item: FeedItem, preferred: ContentType) -> Double {
        switch preferred {
        case .video: return item.isYouTube ? 1.0 : 0.0
        case .audio: return item.isPodcast ? 1.0 : 0.0
        case .text:  return (!item.isYouTube && !item.isPodcast) ? 1.0 : 0.3
        default: return 0.5
        }
    }
}

// MARK: - FeedItem Convenience

private extension FeedItem {
    var hasImage: Bool { imageURL != nil || bestImageURL != nil }
}
