import Foundation

// MARK: - Mix Allocator
//
// Answers: "Even if the highest scores are all from one category,
//           what composition do we want?"
//
// Applies diversity constraints (provider, region, media type) and
// quota targets. Quotas are preferential — if the catalog doesn't
// supply enough, remaining slots are filled with best available content.

// MARK: - Allocation Result

/// Result of mix allocation with per-slot trace for debugging.
struct MixAllocationResult: Sendable {
    /// Ordered item IDs after mix allocation.
    let orderedItemIDs: [String]

    /// How many items were allocated to each quota.
    let quotaFills: [String: Int]

    /// Total items allocated.
    let totalAllocated: Int

    /// Whether all quotas were met.
    let allQuotasMet: Bool
}

// MARK: - Provider, Region, Media tracking

private struct DiversityTracker {
    var providerHistory: [String: Int] = [:]  // last position each provider appeared
    var regionHistory: [String: Int] = [:]
    var mediaHistory: [ContentType: Int] = [:]
    var sourceCounts: [String: Int] = [:]  // items per source
}

// MARK: - Mix Allocator

/// Allocates scored candidates into an ordered output respecting
/// diversity constraints and quota targets.
///
/// Pure function — no state, no side effects.
struct MixAllocator: Sendable {

    /// Produce an ordered list of item IDs from scored candidates.
    func allocate(
        candidates: [(item: FeedItem, score: CandidateScore)],
        plan: CompiledMixPlan,
        targetCount: Int = 60
    ) -> MixAllocationResult {
        guard !candidates.isEmpty else {
            return MixAllocationResult(orderedItemIDs: [], quotaFills: [:], totalAllocated: 0, allQuotasMet: true)
        }

        // Sort by score descending
        let sorted = candidates.sorted { $0.score.total > $1.score.total }

        var tracker = DiversityTracker()
        var output: [String] = []
        var position = 0
        var quotaFills: [String: Int] = [:]

        // Separate discovery candidates (lower scored, from different regions/providers)
        let discoveryCount = Int(Double(targetCount) * plan.discoveryShare)
        var discoveryCandidates: [FeedItem] = []

        // First pass: fill with diversity constraints
        var usedIDs = Set<String>()

        for candidate in sorted {
            guard output.count < targetCount else { break }
            let item = candidate.item

            // Skip duplicates
            guard !usedIDs.contains(item.id) else { continue }
            guard usedIDs.count < targetCount else { break }

            // Provider cooldown
            let provider = item.sourceTitle
            if let lastPos = tracker.providerHistory[provider],
               position - lastPos < plan.providerCooldown {
                // Hold for discovery pool
                if discoveryCandidates.count < discoveryCount * 2 {
                    discoveryCandidates.append(item)
                }
                continue
            }

            // Region cooldown
            let region = item.region
            if let lastPos = tracker.regionHistory[region],
               position - lastPos < plan.regionCooldown {
                if discoveryCandidates.count < discoveryCount * 2 {
                    discoveryCandidates.append(item)
                }
                continue
            }

            // Media cooldown
            let mediaType = item.isYouTube ? ContentType.video
                : item.isPodcast ? ContentType.audio : ContentType.text
            if let lastPos = tracker.mediaHistory[mediaType],
               position - lastPos < plan.mediaCooldown {
                if discoveryCandidates.count < discoveryCount * 2 {
                    discoveryCandidates.append(item)
                }
                continue
            }

            // Source item limit
            let sourceURL = item.sourceURL
            let sourceCount = tracker.sourceCounts[sourceURL] ?? 0
            if sourceCount >= plan.maxItemsPerSource {
                continue
            }

            // Allocate this item
            output.append(item.id)
            usedIDs.insert(item.id)
            tracker.providerHistory[provider] = position
            tracker.regionHistory[region] = position
            tracker.mediaHistory[mediaType] = position
            tracker.sourceCounts[sourceURL] = sourceCount + 1
            position += 1

            // Track quota fills
            for quota in plan.quotas {
                let key = quotaKey(quota)
                if matchesQuota(item, quota) {
                    quotaFills[key] = (quotaFills[key] ?? 0) + 1
                }
            }
        }

        // Second pass: interleave discovery candidates (relaxed cooldowns)
        var discoveryInserted = 0
        for discItem in discoveryCandidates {
            guard discoveryInserted < discoveryCount else { break }
            guard !usedIDs.contains(discItem.id) else { continue }
            guard output.count < targetCount else { break }

            // Insert at staggered positions
            let insertPos = min(output.count, output.count - (discoveryInserted * 2))
            if insertPos < output.count {
                output.insert(discItem.id, at: insertPos)
            } else {
                output.append(discItem.id)
            }
            usedIDs.insert(discItem.id)
            discoveryInserted += 1
        }

        // Check quota satisfaction
        var allMet = true
        for quota in plan.quotas {
            let key = quotaKey(quota)
            let filled = quotaFills[key] ?? 0
            let targetRange = quotaTarget(quota, total: output.count)
            if !targetRange.contains(Double(filled)) {
                allMet = false
            }
        }

        return MixAllocationResult(
            orderedItemIDs: output,
            quotaFills: quotaFills,
            totalAllocated: output.count,
            allQuotasMet: allMet
        )
    }

    // MARK: - Quota helpers

    private func quotaKey(_ quota: MixQuota) -> String {
        switch quota {
        case .media(let type, _): return "media:\(type.rawValue)"
        case .topic(let topic, _): return "topic:\(topic.rawValue)"
        case .illustrated: return "illustrated"
        case .region(let region, _): return "region:\(region)"
        }
    }

    private func quotaTarget(_ quota: MixQuota, total: Int) -> ClosedRange<Double> {
        switch quota {
        case .media(_, let target): return target
        case .topic(_, let target): return target
        case .illustrated(let target): return target
        case .region(_, let target): return target
        }
    }

    private func matchesQuota(_ item: FeedItem, _ quota: MixQuota) -> Bool {
        switch quota {
        case .media(let type, _):
            switch type {
            case .video: return item.isYouTube
            case .audio: return item.isPodcast
            case .text: return !item.isYouTube && !item.isPodcast
            default: return true
            }
        case .topic(let topic, _):
            // Topic matching requires taxonomy data — handled by curated profile adapter
            return item.excerpt.localizedCaseInsensitiveContains(topic.rawValue)
                || item.title.localizedCaseInsensitiveContains(topic.rawValue)
        case .illustrated:
            return item.imageURL != nil
        case .region(let region, _):
            return item.region == region || item.region.hasPrefix(region + "/")
        }
    }
}

// MARK: - Legacy Reservoir Mix Adapter

/// Wraps the existing Reservoir's behavior behind the MixAllocator interface.
/// This preserves the current diversity/interleave logic while exposing it
/// through the new MixPolicy contract.
///
/// In Phase 4, this adapter routes through the existing Reservoir.
/// In Phase 7, it can be replaced with the native MixAllocator.
struct LegacyReservoirMixAdapter: Sendable {

    /// Adapt a legacy Reservoir-style interleave into a MixAllocationResult.
    /// This is a structural adapter — it doesn't actually call Reservoir,
    /// but structural the output format.
    func adaptFromReservoir(
        itemIDs: [String],
        quotas: [MixQuota],
        totalCount: Int
    ) -> MixAllocationResult {
        var fills: [String: Int] = [:]
        for quota in quotas {
            fills[quotaKey(quota)] = 0
        }

        return MixAllocationResult(
            orderedItemIDs: itemIDs,
            quotaFills: fills,
            totalAllocated: itemIDs.count,
            allQuotasMet: true  // Legacy reservoir doesn't have explicit quotas
        )
    }

    private func quotaKey(_ quota: MixQuota) -> String {
        switch quota {
        case .media(let type, _): return "media:\(type.rawValue)"
        case .topic(let topic, _): return "topic:\(topic.rawValue)"
        case .illustrated: return "illustrated"
        case .region(let region, _): return "region:\(region)"
        }
    }
}
