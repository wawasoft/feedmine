import Foundation

// MARK: - Selection Compiler
//
// Transforms a ContentSelectionRequest (intent) into a ResolvedSelectionPlan (executable).
// This is a pure function: same request + same catalog state = same plan.

/// Compiles selection requests into executable plans.
struct SelectionCompiler: Sendable {

    let catalog: any SelectionCatalogReading
    let scopeResolver: SourceScopeResolver
    let sqlCompiler: SQLItemRuleCompiler
    let taxonomy: TaxonomySnapshot
    let userState: SourceEnablementSnapshot

    /// Compile a request into an executable plan.
    func compile(
        _ request: ContentSelectionRequest
    ) async throws -> ResolvedSelectionPlan {
        // 1. Resolve source scope
        let sourceCriteria = SourceCriteria(
            taxonomyNodeIDs: request.criteria.taxonomyNodeIDs,
            contentTypes: request.criteria.contentTypes,
            languages: request.criteria.languages,
            regions: request.criteria.regions
        )

        let resolvedScope = try await scopeResolver.resolve(
            policy: request.sourceUniverse,
            criteria: sourceCriteria,
            catalog: catalog,
            taxonomy: taxonomy,
            userState: userState
        )

        // 2. Extract eligible source IDs for the item rule set
        let eligibleIDs = extractEligibleIDs(from: resolvedScope.handle)

        // 3. Build the item rule set
        let itemRules = ItemRuleSet(
            eligibleSourceIDs: eligibleIDs,
            regions: request.criteria.regions,
            languages: request.criteria.languages,
            taxonomySourceIDs: taxonomyNodeSourceIDs(
                request.criteria.taxonomyNodeIDs
            ),
            contentTypes: request.criteria.contentTypes,
            mood: request.criteria.mood,
            searchExpression: request.criteria.searchExpression,
            excludedKeywords: request.criteria.excludedKeywords,
            contentExclusions: ContentExclusionPolicy(
                excludedKeywords: request.criteria.contentFilterKeywords,
                isEnabled: !request.criteria.contentFilterKeywords.isEmpty
            ),
            history: request.history
        )

        // 4. Compile cache query
        let (cacheSQL, cacheArgs) = sqlCompiler.compile(
            itemRules,
            limit: request.presentation.initialPageSize,
            offset: 0
        )
        let cacheQuery = CacheQuerySpecification(
            sqlRuleFragment: cacheSQL,
            sqlBindings: [:],  // StatementArguments will be applied at query time
            limit: request.presentation.initialPageSize,
            offset: 0,
            orderBy: .fetchedAtDescending
        )

        // 5. Compile ranking plan
        let rankingPlan = compileRanking(request.ranking, eligibleIDs: eligibleIDs)

        // 6. Compile mix plan
        let mixPlan = compileMix(request.mix)

        // 7. Compile acquisition plan
        let acquisitionPlan = compileAcquisition(
            request.acquisition,
            sourceScope: resolvedScope.handle
        )

        // 8. Compile presentation plan
        let presentationPlan = compilePresentation(request.presentation)

        // 9. Source metrics
        let sourceMetrics = SourceSelectionMetrics(
            catalogTotal: resolvedScope.totalCount,
            enabledLibraryTotal: userState.defaultEnabled.count,
            eligibleTotal: resolvedScope.totalCount,
            scheduledTotal: 0,
            checked: 0,
            responding: 0,
            contributing: 0,
            representedInCache: 0,
            representedOnScreen: 0
        )

        return ResolvedSelectionPlan(
            selectionID: request.id,
            sourceScope: resolvedScope,
            sourceMetrics: sourceMetrics,
            itemRules: itemRules,
            cacheQuery: cacheQuery,
            rankingPlan: rankingPlan,
            mixPlan: mixPlan,
            acquisitionPlan: acquisitionPlan,
            presentationPlan: presentationPlan,
            completionPolicy: request.completion
        )
    }

    // MARK: - Helpers

    private func extractEligibleIDs(from handle: SourceScopeHandle) -> Set<SourceID> {
        switch handle {
        case .materialized(let ids): return ids
        case .explicitList(let ids): return Set(ids)
        case .single(let id): return [id]
        case .catalogQuery: return []  // Lazy — resolved during acquisition
        }
    }

    private func taxonomyNodeSourceIDs(_ nodeIDs: Set<String>) -> Set<SourceID> {
        guard !nodeIDs.isEmpty else { return [] }
        return nodeIDs.reduce(into: Set<SourceID>()) { acc, nodeID in
            if let ids = taxonomy.nodeSourceMap[nodeID] {
                acc.formUnion(ids)
            }
        }
    }

    private func compileRanking(
        _ profile: RankingProfile,
        eligibleIDs: Set<SourceID>
    ) -> CompiledRankingPlan {
        let operations: [RankingOperation] = profile.signals.compactMap { signal in
            switch signal {
            case .freshness(let weight):
                return .freshness(weight: weight)
            case .sourceQuality(let weight):
                return .sourceQuality(weight: weight)
            case .editorialPreset:
                // Include as preset multiplier — RankingEngine applies the
                // actual multipliers from PresetScorer at execution time
                return .presetMultiplier([:])
            case .curatedProfile:
                // Include as curated multiplier — RankingEngine applies the
                // actual multipliers from CuratedPreferenceEngine at execution time
                return .curatedProfileMultiplier([:])
            case .sourceAffinity(let affinities):
                return .presetMultiplier(affinities)
            case .imageAvailability(let weight):
                return .imageAvailability(weight: weight)
            case .mediaPreference(let type, let weight):
                return .mediaPreference(type, weight: weight)
            case .topicPreference(let topic, let weight):
                // Topic preference forwarded to curated profile adapter
                return .curatedProfileMultiplier([:])
            case .nature(let name, let weight):
                // Editorial nature signal — treated as source quality boost
                return .sourceQuality(weight: weight * 0.5)
            case .activity(let name, let weight):
                // Editorial activity signal — treated as freshness boost
                return .freshness(weight: weight * 0.5)
            }
        }
        return CompiledRankingPlan(operations: operations)
    }

    private func compileMix(_ policy: MixPolicy) -> CompiledMixPlan {
        CompiledMixPlan(
            quotas: policy.quotas,
            providerCooldown: policy.providerCooldown,
            categoryCooldown: policy.categoryCooldown,
            regionCooldown: policy.regionCooldown,
            mediaCooldown: policy.mediaCooldown,
            discoveryShare: policy.discoveryShare,
            maxItemsPerSource: 5
        )
    }

    private func compileAcquisition(
        _ policy: AcquisitionPolicy,
        sourceScope: SourceScopeHandle
    ) -> ResolvedAcquisitionPlan {
        switch policy {
        case .cacheThenNetwork, .cacheThenSweep:
            return ResolvedAcquisitionPlan(
                sourceScope: sourceScope,
                batchSize: 20,
                maxConcurrency: 8,
                useAdaptiveScheduling: true
            )
        case .cacheOnly:
            return .forCacheOnly()
        case .refreshExactSources:
            return ResolvedAcquisitionPlan(
                sourceScope: sourceScope,
                batchSize: 1,
                maxConcurrency: 1,
                useAdaptiveScheduling: false
            )
        }
    }

    private func compilePresentation(
        _ policy: PresentationPolicy
    ) -> ResolvedPresentationPlan {
        ResolvedPresentationPlan(
            initialPageSize: policy.initialPageSize,
            loadMorePageSize: policy.loadMorePageSize,
            requireTerminalPresentation: policy.requireTerminalPresentation,
            deadlineHierarchy: .standard
        )
    }
}
