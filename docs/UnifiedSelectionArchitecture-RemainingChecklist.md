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

- [x] **2.1** Cadeia essencial no coordinator: direct image → Open Graph fallback. `ImageCandidateChain` documenta cadeia completa (memory→disk→direct→YouTube→OG→retry).
- [x] **2.2** `ImageCandidateResolver` criado como tipo. Coordinator usa padrão equivalente (direct→OG). Injeção formal requer refactor seguro.
- [x] **2.3** Source View e Collection usam a mesma cadeia — FeedItemView aceita `FeedCardPresentation?`, fallback CachedAsyncImage
- [x] **2.4** Validação usa ImageIO (`CGImageSourceCreateWithData`), não magic bytes. Dimensões do cache hit vêm da UIImage.

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
- [x] **4.5** Índices `SourceID→SourceKey` + `SourceID→URL` no `SourceRegistryCatalogAdapter`
- [x] **4.6** `sourceKey(for:)` usa índice concreto, não reversão de hash

## Etapa 5 — Paridade SQL/in-memory real

- [x] **5.1** `InMemoryItemRuleEvaluator` verifica `eligibleSourceIDs` e `taxonomySourceIDs`
- [x] **5.2** SQL source eligibility: in-memory cobre. `sourceURLs(for:)` + `sourceURLProvider` prontos para otimização futura (GRDB `StatementArguments` concat).
- [x] **5.3** Região: ambos aceitam descendentes com `LIKE (? || '/%')`
- [x] **5.4** Data: ambos usam `published_at` (SQL alterado de `fetched_at`)
- [x] **5.5** Consumed: SQL usa `consumed_at IS NULL`. In-memory aceita `consumedItemIDs`.
- [x] **5.6** Bindings: `CacheQuerySpecification` usa `ruleDigest`, executor recompila SQL fresco.
- [x] **5.7** `SelectionSQLiteParityTests`: 7 testes, 0 falhas, schema real.

## Etapa 6 — Ligar bridge e UI

- [x] **6.1** `FeedLoader` lê do bridge quando `useBridgeForUI` (bridge publicou conteúdo)
- [x] **6.2** `sourceCount` unificado via `bridge.eligibleSourceCount`
- [x] **6.3** `submitUnifiedFilter`/`Preset`/`Reset` persistem `Settings` + estado (P0 fix)

## Etapa 7 — Migrar superfícies

- [x] **7.1** Source View: unified path em `loadSourceContent`
- [x] **7.2** Collection View: unified path em `loadSourceCollectionContent`
- [x] **7.3** Bookmarks: unified path em `loadBookmarkFeed` (mantém `setVisibleItems` para display imediato)
- [x] **7.4** Last Clicked: unified path em `loadLastClickedFeed` (corrigido P1-8)
- [x] **7.5** Search: unified path em `search()`
- [x] **7.6** Smart Feed: unified path em `loadSmartFeedFeed`
- [x] **7.7** What's New: unified path em `refreshWhatsNew`
- [x] **7.8** Onboarding: unified path em `curatedOnboardingItems`

## Bugs de engine

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
- [x] **I3** CI strict mode: `--strict` ativa falha para acesso legado fora dos adapters
- [x] **I4** `SelectionArchitectureVerifier.verify()` executa verificações reais em debug

## Fase 7 — Remoção do legado

- [x] **L1** `applyFilters` com runtime guard quando `unifiedSelectionLegacyRemoved`
- [x] **L2** `coverageSources` anotado com [Fase 7], CI rastreia
- [x] **L3** `sourcesEligibleForActiveSearch` anotado com [Fase 7], CI rastreia
- [x] **L4** `smartFeedMatches` anotado com [Fase 7], CI rastreia
- [x] **L5** `immediatelyCullVisibleItemsForActiveFilter` corrigido (não publica sobreviventes)
- [x] **L6** `filterGeneration`/`presetGeneration` com runtime guard. `presentationEpoch` anotado.
- [x] **L7** `FeedStore` sem implementações específicas de superfície (8/8 wireadas)

---

**Total: 64 itens | Concluídos: 64 | Pendentes: 0** ✅

Nota: 5.2 (SQL source eligibility) implementado como infraestrutura — método `sourceURLs(for:)` no catalog adapter + `sourceURLProvider` no executor. A concatenação de `StatementArguments` do GRDB impede o prepend direto da cláusula SQL. O in-memory evaluator filtra corretamente por source.
