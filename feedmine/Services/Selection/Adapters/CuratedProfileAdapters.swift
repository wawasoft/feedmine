import Foundation

// MARK: - Curated Profile Adapters
//
// Bridge CuratedPreferenceEngine into the Selection engine.
// These adapters translate curated profile weights into RankingSignals
// and MixQuotas that the unified engine understands.

// MARK: - Curated Profile Ranking Adapter

/// Adapts a CuratedProfileDefinition into RankingSignals that the
/// unified RankingEngine can apply.
struct CuratedProfileRankingAdapter: Sendable {

    /// Build ranking signals from a curated profile.
    /// Returns topic preferences, source affinities, and other signals
    /// that contribute to the total candidate score.
    func buildSignals(
        profile: CuratedProfileDefinition,
        sources: [FeedSource]
    ) -> [RankingSignal] {
        var signals: [RankingSignal] = []

        // Source multipliers from curated engine
        let multipliers = CuratedPreferenceEngine.sourceMultipliers(
            sources: sources,
            profile: profile
        )
        if !multipliers.isEmpty {
            // Convert string-keyed multipliers to SourceID-keyed
            // (Phase 5 placeholder — Phase 6 resolves SourceIDs via catalog)
            signals.append(.curatedProfile(profile))
        }

        // Topic preferences from profile weights
        for (key, weight) in profile.weights {
            guard key.hasPrefix("topic:") else { continue }
            let topicName = String(key.dropFirst("topic:".count))
            if let topic = CuratedTopic(rawValue: topicName) {
                signals.append(.topicPreference(topic, weight: weight))
            }
        }

        // Image availability preference
        if let imageWeight = profile.weights["imageAvailable"] {
            signals.append(.imageAvailability(weight: imageWeight))
        }

        // Media type preferences
        if let videoWeight = profile.weights["media:video"] {
            signals.append(.mediaPreference(.video, weight: videoWeight))
        }
        if let audioWeight = profile.weights["media:audio"] {
            signals.append(.mediaPreference(.audio, weight: audioWeight))
        }

        return signals
    }
}

// MARK: - Curated Profile Mix Adapter

/// Adapts a CuratedProfileDefinition into MixQuotas for the MixAllocator.
struct CuratedProfileMixAdapter: Sendable {

    /// Build mix quotas from a curated profile.
    /// Topic weights become target ranges for content composition.
    func buildQuotas(profile: CuratedProfileDefinition) -> [MixQuota] {
        var quotas: [MixQuota] = []

        // Sort topics by weight descending, take top topics
        let topicWeights = profile.weights
            .filter { $0.key.hasPrefix("topic:") }
            .sorted { $0.value > $1.value }

        for (key, weight) in topicWeights.prefix(5) {
            guard weight > 0.1 else { continue }
            let topicName = String(key.dropFirst("topic:".count))
            guard let topic = CuratedTopic(rawValue: topicName) else { continue }

            // Map weight to a target range. Weight of 0.5 → 15-25%, 1.0 → 25-40%
            let minShare = max(0.05, weight * 0.3)
            let maxShare = min(0.50, weight * 0.5)
            quotas.append(.topic(topic, target: minShare...maxShare))
        }

        // Illustrated content target from profile
        if let imageWeight = profile.weights["imageAvailable"], imageWeight > 0.3 {
            let target = (imageWeight * 0.5)...(imageWeight * 0.8)
            quotas.append(.illustrated(target: target))
        }

        return quotas
    }
}

// MARK: - Onboarding Showcase Policy

/// Defines the policies for onboarding showcase source selection.
/// Extracted from CuratedPreferenceEngine so the engine doesn't
/// mix selection with preference learning.
struct OnboardingShowcasePolicy: Sendable {

    /// Whether a source qualifies for the onboarding showcase pool.
    /// Replaces the scattered quality gate currently in CuratedPreferenceEngine.
    func isShowcaseEligible(source: FeedSource, language: String) -> Bool {
        let isShowcase = CuratedPreferenceEngine.isOnboardingShowcase(
            url: source.url, language: language
        )
        guard isShowcase else { return false }

        // Quality gate: source must have reasonable metadata
        guard !source.title.isEmpty else { return false }
        guard source.title.count > 3 else { return false }

        return true
    }
}
