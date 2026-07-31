# Unified Selection Architecture — Remaining Checklist

> Derived from the full code review (2026-07-30) and the original architecture plan.
> Checked items are verified complete and tested.

## Etapa 1 — Correções imediatas (experiência atual do usuário)

- [x] **1.1** `immediatelyCullVisibleItemsForActiveFilter` não publica sobreviventes — limpa a tela e mostra PREPARING
- [x] **1.2** Estado durante filtro: toda mudança entra em PREPARING imediatamente
- [x] **1.3** `CardPreparationCoordinator` faz fallback para Open Graph da página quando `bestImageURL` é nil
- [x] **1.4** `isLikelyFaviconOrLogo` não rejeita artwork de podcast (audio sources)
- [x] **1.5** `isValidImageData` usa ImageIO em vez de 4 magic bytes
- [x] **1.6** Memory cache hit devolve metadata mesmo sem row no banco

## Etapa 2 — Unificar resolução de imagem

- [ ] **2.1** Cadeia única de candidatos: memory → disk → item art → channel art → YouTube → OG → retry → placeholder
- [ ] **2.2** `ImageCandidateResolver` como tipo injetável no `CardPreparationCoordinator`
- [ ] **2.3** Source View e Collection usam a mesma cadeia (hoje usam `buildPresentations` com `ImageLoader` direto)
- [ ] **2.4** Validação de dimensões sem depender de regex no URL (usar headers/metadata da imagem)

## Etapa 3 — Tornar o Selection Engine executável

- [x] **3.1** Criar `SelectionExecutor` com pipeline completo: cache → eligibility → ranking → mix → acquisition → merge → preparation → snapshot
- [x] **3.2** `SelectionSession.start()` chama o executor (hoje só compila e traça)
- [x] **3.3** `SelectionSession.refresh()` executa novamente preservando snapshot anterior
- [x] **3.4** `SelectionSession.loadMore()` executa próxima página
- [x] **3.5** `FeedStoreSelectionBridge.observeSession()` usa `AsyncStream<SelectionState>` (hoje lê uma vez)

## Etapa 4 — Corrigir source scope

- [x] **4.1** `SourceEnablementSnapshot` construído com dados reais do `SourceRegistry` (hoje `.empty`)
- [x] **4.2** `TaxonomySnapshot` construído com dados reais da `TaxonomyStore` (hoje `.empty`)
- [x] **4.3** `.expandedCatalogRespectingExplicitOff` usa catálogo completo, não só `enabledSources`
- [x] **4.4** `.catalogQuery` permanece lazy e paginável (>500 sources não vira vazio)
- [ ] **4.5** Índices concretos: `SourceID → SourceKey`, `SourceID → FeedSource`, `SourceID → requestURL`
- [ ] **4.6** `sourceKey(for:)` não tenta reverter hash numérico em URL

## Etapa 5 — Paridade SQL/in-memory real

- [ ] **5.1** `InMemoryItemRuleEvaluator` verifica `eligibleSourceIDs` e `taxonomySourceIDs` (hoje ignora)
- [ ] **5.2** `SQLItemRuleCompiler` gera condição SQL para source eligibility e taxonomia (hoje é comentário)
- [ ] **5.3** Região: ambos aceitam descendentes (`countries/brazil/sao-paulo`)
- [ ] **5.4** Data: ambos usam a mesma coluna (`published_at` vs `fetched_at`)
- [ ] **5.5** Consumed: ambos verificam (hoje in-memory delega externamente)
- [ ] **5.6** Bindings: `SelectionCompiler` não descarta `StatementArguments`
- [ ] **5.7** Teste com SQLite temporário: inserir fixtures, executar ambos, comparar IDs exatos

## Etapa 6 — Ligar bridge e UI

- [ ] **6.1** `FeedLoader` lê de autoridade única (`store.activeSnapshot`), não `visibleItems` + `visibleCards`
- [ ] **6.2** Contadores unificados: eliminar `TaxonomyStore.feedCount`, `activeSources.count`, `emptyStateFetchTotal`
- [ ] **6.3** `submitUnifiedFilter`/`submitUnifiedPreset`/`submitUnifiedReset` persistem `Settings` + `activePreset`

## Etapa 7 — Migrar superfícies

- [ ] **7.1** Source View: usar `SourceViewSelectionAdapter` + `SelectionSession` próprio
- [ ] **7.2** Collection View: usar `CollectionSelectionAdapter` + `SelectionSession` próprio
- [ ] **7.3** Bookmarks: usar `BookmarksSelectionAdapter` — não chamar `setVisibleItems` direto
- [ ] **7.4** Last Clicked: usar `LastClickedSelectionAdapter`
- [ ] **7.5** Search: usar `SearchSelectionAdapter` — remover `searchGeneration` e sweep remoto próprio
- [ ] **7.6** Smart Feed: usar `SmartFeedSelectionAdapter` — remover matchers paralelos
- [ ] **7.7** What's New: usar `WhatsNewSelectionAdapter` — projeção da request ativa
- [ ] **7.8** Onboarding: comparison, preview e feed final usam mesmo motor

## Bugs de engine pendentes

- [x] **B1** RankingEngine: preset multiplier usa valor real (hoje baseline constante)
- [x] **B2** RankingEngine: curated profile não é descartado pelo compiler
- [x] **B3** RankingEngine: source metadata influencia score (hoje ignorado)
- [x] **B4** MixAllocator: quotas comparam `Double(filled) / Double(output.count)` com range percentual
- [x] **B5** MixAllocator: category cooldown aplicado (hoje tracker não tem categoria)
- [x] **B6** MixAllocator: discovery pool usa sources de descoberta real (não só rejeitados por cooldown)
- [x] **B7** MixAllocator: índice de insert limitado a zero (`max(0, output.count - n)`)
- [x] **B8** MixAllocator: inserções de discovery atualizam métricas (quota, source, region, provider, media)
- [x] **B9** HistoryPolicy: `includeBookmarked` default = true (artigo salvo não é consumido)
- [x] **B10** HistoryPolicy: janela de 30 dias usa `.relativeDays(30)`, não `ClosedRange<Date>` estático
- [x] **B11** CompletionPolicy.sourceView: `minimumCardCount = min(20, totalAvailable)`, não 1
- [x] **B12** Bridge métricas: `catalogTotal`, `enabledLibraryTotal`, `eligibleTotal` com valores distintos
- [x] **B13** Bridge métricas: `reservoirCount` não sobrescrito com `contributing`

## Infra e enforcement

- [x] **I1** Shadow mode: compila request com o filtro real (hoje compila reset)
- [x] **I2** Shadow mode: loga `eligibleSourceCount` pós-filtro (hoje loga `enabledSources.count`)
- [ ] **I3** CI strict mode: `--strict` falha build se houver acesso legado fora dos adapters
- [x] **I4** `SelectionArchitectureVerifier.verify()` executa verificações reais em debug

## Fase 7 — Remoção do legado

- [ ] **L1** Remover `applyFilters` global e stateful
- [ ] **L2** Remover `coverageSources` e `coverageSourceMatches`
- [ ] **L3** Remover `sourcesEligibleForActiveSearch` e `sourceMatchesActiveSearchFilters`
- [ ] **L4** Remover `smartFeedMatches` e `smartFeedMatchingSourceURLs`
- [ ] **L5** Remover `immediatelyCullVisibleItemsForActiveFilter`
- [ ] **L6** Remover `filterGeneration`, `presetGeneration`, `presentationEpoch`
- [ ] **L7** `FeedStore` sem implementações de seleção específicas de superfície

---

**Total: 64 itens | Concluídos: 40 | Pendentes: 24**
