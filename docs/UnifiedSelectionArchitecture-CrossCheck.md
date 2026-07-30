# Cross-Check Analysis: UnifiedSelectionArchitecture.md vs Actual Code

## Methodology

Five independent agents performed deep exploration of the Feedmine codebase, analyzing:
1. FeedStore (7,098 lines) — complete class map, all properties, methods, and state
2. All 8 selection/fetch pipelines — exact implementations at line level
3. All 8 surface/feature implementations — Search, Smart Feeds, Onboarding, Collections, Source View, Bookmarks, Last Clicked, What's New
4. Reservoir (613 lines), AdaptiveScheduler (438 lines), CardPreparationCoordinator (467 lines), PresetScorer (89 lines)
5. SourceRegistry (695 lines), OPMLParser, TaxonomyStore (597 lines), URL normalization divergence

---

## Summary of Findings

### CONFIRMED: Document accurately diagnoses these problems

| Claim | Verdict | Evidence |
|---|---|---|
| FeedStore is 7000+ lines and concentrates too many concerns | **CONFIRMED** | FeedStore.swift is 7,098 lines with 28 subcomponents, all pipelines, all state |
| Three generations exist (filterGeneration, presetGeneration, presentationEpoch) | **CONFIRMED** | Lines 42, 169, 176 + searchGeneration (line 625) + visibleItemsGeneration (line 74) = actually FIVE generations |
| Parallel state sets exist | **CONFIRMED** | 16 distinct Sets tracking different aspects of state (clickedItemIDs, activeSmartFeedItemIDs, readItemIDs, consumedItemIDs, surfacedItemIDs, etc.) |
| applyFilters is in-memory only, not the single source of truth | **CONFIRMED** | Line 499: `func applyFilters(_ items: [FeedItem]) -> [FeedItem]` — operates only on in-memory arrays |
| reloadFromSQLite has its own parallel SQL-level rules | **CONFIRMED** | Lines 4706-4872: 30-day cutoff, content type heuristics (%youtube%, %reddit%), URL variant generation (HTTP/HTTPS/www/trailing slash), per-type read limits |
| fetchUrgentTaxonomyBatch creates its own eligibility | **CONFIRMED** | Lines 3927-3961: uses lookupSnapshot (ALL sources), filters explicit off only, creates own counters |
| coverageSources has three different universes | **CONFIRMED** | Lines 4110-4154: taxonomy→expanded catalog, type→expanded catalog, .all→enabledSources |
| SourcesEligibleForActiveSearch recreates source scope logic | **CONFIRMED** | Lines 2764-2823: full recreation for collection, taxonomy, content type, smart feed, last clicked, region, language |
| PresetScorer has floor of 1.0 (permissive, not exclusive) | **CONFIRMED** | FeedPreset.swift line 399-430: `max(mult, floorMultiplier)` where floor is always 1.0 |
| CuratedPreferenceEngine multiplier range is 0.42 to 3.0 | **CONFIRMED** | Line 840: `return min(3, max(0.42, learned * quality))` |
| Smart Feed uses 75/25 learned/discovery split | **CONFIRMED** | Lines 5854-5863: `let learnedBudget = max(1, limit * 3 / 4)` |
| Bookmark mode calls setVisibleItems directly | **CONFIRMED** | Line 193: `setVisibleItems(items)` after canceling all background tasks |
| Last Clicked does direct SQLite + applyFilters + setVisibleItems | **CONFIRMED** | Lines 3287-3302: SELECT with clicked_at IS NOT NULL, applyFilters, setVisibleItems |
| Source View publishes without card preparation | **CONFIRMED** | CollectionManagementView.swift lines 493-515: uses ImageLoader.resolveImage() manually, not CardPreparationCoordinator |
| Collection View uses separate path from collection-as-preset | **CONFIRMED** | SourceCollectionFeedView line 688: loads raw items, renders with FeedItemView instead of FeedItemCardView |
| "Technology and Science" means three different things | **CONFIRMED** | Taxonomy (hard constraint, line 537), editorial preset (ranking boost, FeedPreset.swift line 447), curated profile (learned weight, CuratedFeed.swift line 22) |

### CORRECTIONS NEEDED: Inaccuracies in the document

1. **SourceID already exists** (Section 7.1)
   - The codebase has `SourceID` in `FeedEngine/Identities.swift` as a `UInt32` hash derived from `SourceKey`
   - The document proposes a completely different `SourceID` wrapping a canonical URL `String`
   - This is a **naming conflict** — the document must either rename its type (e.g., `CanonicalSourceURL`) or address coexistence

2. **Two URL normalizations exist, not one** (Section 7.1)
   - `OPMLParser.normalizeURL()` — aggressive: HTTPS, strip www, remove tracking params, remove trailing slash, lowercase host
   - `CatalogIdentity.canonicalURLKey()` — conservative: only lowercase scheme/host, trim whitespace
   - The document only describes the aggressive normalization. The divergence between these two is a source of identity bugs that the new architecture should address.

3. **Five generations, not three** (Section 2)
   - The document mentions three: filterGeneration, presetGeneration, presentationEpoch
   - There are actually five: those three + `searchGeneration` (line 625) + `visibleItemsGeneration` (line 74)
   - The document correctly identifies the core three for feed composition but should acknowledge the others

4. **Source View has partial preparation, not zero** (Section 3.9)
   - The document says "a tela publica itens que não possuem um FeedCardPresentation terminal"
   - The actual code does call `buildPresentations(for:)` which uses `ImageLoader.resolveImage()` and builds `FeedCardPresentation` — it's a *different* preparation path, not *no* preparation
   - The document should say: "Source View uses its own manual image resolution instead of the CardPreparationCoordinator pipeline"

5. **Background refresh alternation is more nuanced** (Section 3.6)
   - The document says background refresh alternates between "coverage de tipos; coverage de taxonomias; batches aleatórios"
   - The actual pattern (lines 4613-4664): coverageStep-based alternation between type coverage and taxonomy coverage, with random batch fallback only when coverage produces nothing new. There's no independent "random batches" phase.

### MISSING: Topics the document should address

1. **FeedEngine catalog system** — The codebase already has a clean catalog architecture (`FeedEngine/`) with `SourceKey`, `SourceID`, `NodeKey`, `CatalogNodeID`, `CatalogIdentity`. This newer, cleaner system exists alongside the legacy FeedStore. The document should discuss how the new selection engine relates to (or replaces) this existing catalog layer.

2. **ContentFilterStore** — A user-facing keyword exclusion system (`ContentFilterStore`) exists and is checked in `applyFilters` (line 505). The document's `ItemCriteria` model doesn't include this dimension.

3. **Mood filtering** — The document mentions mood in `ItemCriteria` but the actual mood implementation uses per-item caching (`moodMatchCache`, line 498) that's not represented in the proposed `ItemRuleSet`.

4. **LoadedIDs dedup set** — FeedStore maintains a `loadedIDs` Set<String> (line 644) that acts as a Bloom filter analog to prevent re-fetch duplication. This is a distinct concept from read/consumed tracking that the proposed architecture should represent.

5. **Composite search feeds** — BookmarkStore has a `compositeSearchFeed()` (line 265) that runs FTS5 across all active persistent searches. This isn't represented in the document's search section.

6. **The `FeedPresentationContext` and `FeedPresentationMode` types** — These already exist as a proto-implementation of what the document proposes as `SelectionSurface`. The document should acknowledge this existing structure and explain how it evolves.

7. **The `FeedUIUpdate` enum** — Already has `.flush`, `.append`, `.replace`, `.refresh`, `.trim` cases. This is a nascent implementation of the document's proposed snapshot-based publication. The migration should build on this.

8. **coldStartRunwayIsUseful logic** — Cold start has complex criteria for when items are "useful enough" to show. The document doesn't address how this maps to its `CompletionPolicy`.

9. **Per-item caches in applyFilters** — `moodMatchCache` and `contentFilterExcludeCache` are performance-critical caches that the new architecture needs to account for.

10. **WhatsNewManager's `matchesActiveFilters` closure** — What's New injects a filter closure `{ !applyFilters([$0]).isEmpty }` to check item eligibility. The new architecture needs to explain how What's New gets its eligibility rules.

### RISKS: Concerns with the proposed architecture

1. **Migration complexity** — 12 PRs across 7 phases is aggressive. The document correctly identifies this risk and mandates feature flags, but the shadow mode comparison approach (Phase 1) will be computationally expensive.

2. **`ResolvedSelectionPlan` as a value type** — If this struct captures Sets of 1,400+ SourceIDs, it could cause memory pressure. The document should address the expected size and whether lazy/cursor-based approaches are needed.

3. **`SelectionSession` as actor** — The proposal says `actor SelectionSession` but the current code is `@MainActor` throughout. The migration from MainActor to a separate actor will require careful Sendable conformance across the entire pipeline.

4. **CardPreparationCoordinator preservation** — The document says to preserve it via adapters (Phase 3), but the coordinator's `contiguousPrefix` promotion model is tightly coupled to the current pipeline. Adapter design needs more detail.

5. **SQL/in-memory parity testing** — The document proposes testing that SQL and in-memory evaluators return the same IDs. This is excellent but extremely ambitious given the URL variant complexity (HTTP/HTTPS, www, trailing slash) and the fact that SQL-level rules differ from in-memory rules by design today.

6. **What's New projection** — The document says What's New should be "a projection of the active request." Currently What's New has its own `matchesActiveFilters` closure injection. The projection model is cleaner but requires careful compatibility.

7. **Feature flag scope** — The document proposes a single `unifiedSelectionEngine` flag, but the 7-phase migration needs per-phase flags to avoid coupling phases together.

### STRUCTURAL OBSERVATIONS

1. **The document's diagnostic sections (1-5) are highly accurate.** The code confirms almost every claim about the current architecture's problems.

2. **The proposed architecture (sections 6-17) is sound in concept.** The separation into Eligibility → Ranking → Mix → Acquisition → Preparation is the right decomposition.

3. **The migration plan (sections 22-27) is pragmatic.** Freeze → Model → State → Main Feed → Ranking/Mix → Surfaces → Legacy removal is the correct sequence.

4. **The architectural rules (sections 23, 28) are necessary.** Without CI-enforced boundaries, the new architecture will accumulate the same duplication.

5. **The test strategy (sections 24-25) is comprehensive but needs prioritization.** Not all tests can be written in Phase 1. The document should identify the minimum test set for each phase.

---

## Section-by-Section Accuracy Assessment

| Section | Accuracy | Notes |
|---|---|---|
| 1. Objetivo | ✅ Accurate | No factual claims to verify |
| 2. Diagnóstico executivo | ✅ Accurate | Five generations confirmed (not three). All state sets confirmed. |
| 3.1 Feed principal no startup | ✅ Accurate | Startup flow matches code at `start()` method |
| 3.2 Feed principal vindo do SQLite | ✅ Accurate | URL variants, YouTube/Reddit heuristics, per-type limits all confirmed |
| 3.3 Fetch normal e de runway | ✅ Accurate | Two source pool construction paths confirmed |
| 3.4 Fetch urgente de taxonomia | ✅ Accurate | lookupSnapshot + explicit off only + own counters confirmed |
| 3.5 Coverage mining | ✅ Accurate | Three universe types confirmed |
| 3.6 Progressive fetch | ✅ Accurate | 200 limit, jitter, diversity all confirmed |
| 3.7 Editorial presets | ✅ Accurate | Floor 1.0, multiplicative boosts confirmed |
| 3.8 Collections | ✅ Accurate | Two separate paths confirmed |
| 3.9 Source view | ⚠️ Minor inaccuracy | Has partial preparation via buildPresentations, not zero |
| 3.10 Bookmarks e Last Clicked | ✅ Accurate | Direct setVisibleItems, direct SQL confirmed |
| 3.11 Search | ✅ Accurate | SearchGeneration, parallel source eligibility confirmed |
| 3.12 Smart Feeds | ✅ Accurate | 75/25 split, separate cache path confirmed |
| 3.13 Onboarding e Curated Feed | ✅ Accurate | Three paths (comparison, preview, final) confirmed |
| 4. Proporções do onboarding | ✅ Accurate | 0.42-3.0 range, emergent proportions confirmed |
| 5. Três conceitos | ✅ Accurate | Taxonomy/preset/profile distinction confirmed |
| 6. Arquitetura proposta | ✅ Sound | No factual claims to verify |
| 7. Modelo central | ⚠️ SourceID conflict | Existing SourceID (UInt32) conflicts with proposed SourceID (String) |
| 8. ResolvedSelectionPlan | ✅ Sound | Conceptually correct |
| 9. Rule set + intérpretes | ✅ Sound | SQL/in-memory parity ambitious but correct |
| 10. Source eligibility | ✅ Sound | Matches existing SourceRegistry concepts |
| 11. Ranking e mistura | ✅ Sound | Matches existing PresetScorer + Reservoir concepts |
| 12. Aquisição | ✅ Sound | Metrics concept confirmed by existing emptyStateFetchTotal confusion |
| 13. Separação manutenção | ✅ Sound | Addresses real mixing of concerns |
| 14. Máquina de estado | ✅ Sound | Better than existing single loadingState |
| 15. Snapshot atômico | ✅ Sound | PreparedFeedCard already has this concept |
| 16. Sessões independentes | ✅ Sound | Addresses real coordinator replacement bugs |
| 17. Representação de recursos | ✅ Sound | Each mapping matches existing behavior |
| 18. Refatoração onboarding | ✅ Sound | Clear separation of concerns |
| 19. Clear All Filters | ✅ Sound | Addresses real confusion about disabled vs. not enabled |
| 20. Refatoração Clear Filters | ✅ Sound | Single operation vs. two concurrent transitions |
| 21. Estrutura de arquivos | ✅ Sound | Reasonable organization |
| 22. Plano de migração | ✅ Sound | Phase sequence is correct |
| 23. Regras arquiteturais | ✅ Sound | Necessary for preventing recidivism |
| 24. Estratégia de testes | ✅ Sound | Comprehensive, needs prioritization |
| 25. Testes reais | ✅ Sound | inMemory mode disabling pipeline is a real gap |
| 26. Observabilidade | ✅ Sound | Trace concept is valuable |
| 27. Sequência de PRs | ✅ Sound | Correct granularity |
| 28. Instruções Claude Code | ✅ Sound | Good constraints |
| 29. Definition of Done | ✅ Sound | Clear and testable |
| 30. Resultado esperado | ✅ Sound | Correct decomposition |
