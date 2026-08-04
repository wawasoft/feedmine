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
}
