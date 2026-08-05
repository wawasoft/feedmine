import Foundation

enum FeedRecipeResolver {
    /// Combine an explicit recipe with learned evidence into the effective
    /// profile used for feed ranking.
    ///
    /// Recipe weights are the baseline. Evidence weights are additive on top,
    /// bounded to [-3, +3]. Recipe discovery and learning settings take
    /// precedence over evidence defaults.
    static func effectiveProfile(
        recipe: FeedRecipeDefinition?,
        evidence: CuratedProfileDefinition
    ) -> CuratedProfileDefinition {
        guard let recipe else {
            return evidence
        }

        var weights: [String: Double] = [:]

        // Start with recipe baselines
        for (topicKey, level) in recipe.topicPreferences {
            weights[topicKey] = level.profileWeight
        }
        for (editorialKey, level) in recipe.editorialPreferences {
            weights[editorialKey] = level.profileWeight
        }

        // Media types map to the engine's `media:*` feature keys (MediaKind
        // vocabulary: text/audio/video). A type the user excluded gets weight
        // -3 — strongly downweighted in ranking and dropped from previews.
        // The default (all three present) adds no weights at all.
        let allMediaTypes: Set<MediaType> = [.article, .podcast, .video]
        if recipe.mediaTypes != allMediaTypes {
            for type in allMediaTypes where !recipe.mediaTypes.contains(type) {
                weights[Self.mediaFeatureKey(for: type)] = -3
            }
        }

        // Layer evidence on top (additive)
        for (key, evidenceWeight) in evidence.weights {
            let baseline = weights[key, default: 0]
            weights[key] = min(3, max(-3, baseline + evidenceWeight))
        }

        // Transfer evidence counts from learned evidence (not from recipe)
        let evidenceCounts = evidence.evidenceCounts

        return CuratedProfileDefinition(
            languages: recipe.languages,
            weights: weights,
            evidenceCounts: evidenceCounts,
            discoveryLevel: recipe.discoveryLevel,
            learningEnabled: recipe.adjustFromOpens,
            evidence: evidence.evidence,
            modelVersion: CuratedProfileDefinition.currentModelVersion
        )
    }

    /// The engine feature key for a media type. `MediaType` uses content names
    /// (article/podcast/video) while the engine's feature vocabulary uses
    /// `MediaKind` names (text/audio/video), so the mapping is explicit.
    private static func mediaFeatureKey(for type: MediaType) -> String {
        switch type {
        case .article: return "media:text"
        case .podcast: return "media:audio"
        case .video: return "media:video"
        }
    }
}
