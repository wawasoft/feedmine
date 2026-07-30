# Feedmine — Plano de unificação da seleção de conteúdo

> **Status:** Revisão 1 — cross-check completo contra o código (2026-07-30).
> Cinco agentes independentes analisaram 13,138 linhas de código em 11 arquivos principais,
> cobrindo FeedStore (7,098 linhas), pipelines de seleção, todas as superfícies,
> ranking/mix, SourceRegistry e normalização de URL.
> Ver [Cross-Check Analysis](UnifiedSelectionArchitecture-CrossCheck.md) para o detalhamento completo.

## 1. Objetivo

Substituir as diversas pipelines atuais de seleção de conteúdo por uma arquitetura única e extensível, na qual:

* toda tela declara **o que deseja mostrar**;
* um único motor resolve **quais sources são elegíveis**;
* um único motor decide **quais itens podem aparecer**;
* ranking, proporções e diversidade são políticas explícitas;
* cache e rede usam o mesmo plano;
* todos os cards passam pela mesma preparação de mídia;
* contadores e estados da interface são produzidos pelo mesmo plano;
* somente a composição ativa pode publicar na tela.

O objetivo não é criar uma função gigantesca chamada `applyEverything()`.

O objetivo é separar responsabilidades e fazer todas as superfícies utilizarem o mesmo contrato:

```text
Intenção
→ Plano resolvido
→ Aquisição
→ Elegibilidade
→ Ranking
→ Mistura
→ Preparação de cards
→ Publicação atômica
→ Estado e métricas da UI
```

---

# 2. Diagnóstico executivo

O `FeedStore` atualmente concentra:

* estado de filtros;
* estado de presets;
* source enablement;
* seleção de sources;
* consultas SQLite;
* busca de rede;
* cobertura de catálogo;
* Smart Feeds;
* collections;
* onboarding;
* bookmarks;
* Last Clicked;
* What's New;
* reservoir;
* preparação de cards;
* estado de loading;
* contadores da interface.

Ele também mantém cinco generations diferentes:

```swift
filterGeneration       // incrementado a cada mudança de filtro
presetGeneration       // incrementado a cada mudança de preset
presentationEpoch      // incrementado a cada mudança de filtro/preset/modo
searchGeneration       // incrementado a cada nova busca ou clear
visibleItemsGeneration // incrementado a cada mudança de visibleItems
```

e diversos conjuntos paralelos como:

```swift
presetSourceFilter
cachedTaxonomyFeedURLs
activeSmartFeedItemIDs
activeSmartFeedSourceURLs
clickedItemIDs
clickedSourceURLs
```

O método `applyFilters` é apresentado como "single source of truth", mas ele é apenas a fonte central para uma parte da filtragem **de itens já carregados**. A escolha das sources, a consulta ao SQLite, o fetch, os contadores, o ranking e a publicação continuam sendo calculados por vários caminhos diferentes.

Portanto, o problema não é somente duplicação de filtros.

Existem duplicações de:

```text
source eligibility
item eligibility
SQL selection
network selection
ranking
mixing
pagination
media preparation
progress counters
empty-state decisions
```

---

## 2.1 Relação com o sistema de catálogo FeedEngine

O código já possui uma arquitetura de catálogo mais limpa em `FeedEngine/` (`Identities.swift`,
`CatalogIdentity.swift`, `SQLiteCatalogStore.swift`, `CatalogModels.swift`), com:

* `SourceKey` — identidade semântica baseada em URL canônico conservador
* `SourceID` — hash UInt32 determinístico derivado de `SourceKey`
* `NodeKey` — identidade semântica de nó de taxonomia
* `CatalogNodeID` — hash UInt32 de nó
* `CatalogIdentity.canonicalURLKey()` — normalização conservadora (apenas lowercase scheme/host)

Este sistema de catálogo **não** é usado pelo `FeedStore` para seleção de conteúdo.
O `FeedStore` opera com `String` cru e `OPMLParser.normalizeURL()` (normalização agressiva).

A nova arquitetura de seleção deve:

1. **Usar `SourceKey` e `SourceID` do FeedEngine** como identidade canônica no runtime de seleção
2. **Manter `LegacySourceURL` como ponte transitório** apenas durante a migração
3. **Criar um adapter** para que `SourceRegistry` e `TaxonomyStore` implementem `SelectionCatalogReading`
4. **Unificar as duas normalizações** — adotar `canonicalURLKey` (conservadora) para identidade
   permanente; `normalizeURL` (agressiva) apenas para lookup legado de aliases no repositório de conteúdo

O `FeedEngine` é a fonte de verdade para identidade de sources. O motor de seleção consulta
o catálogo via `SelectionCatalogReading`, não acessa `SourceRegistry.sources` ou
`TaxonomyStore.flatIndex` diretamente.

---

# 3. Inventário das pipelines atuais

## 3.1 Feed principal no startup

O startup:

1. restaura collection antecipadamente, quando aplicável;

2. carrega OPML;

3. constrói a taxonomia;

4. restaura filtros;

5. restaura preset;

6. decide entre Smart Feed, Last Clicked, collection ou feed normal;

7. carrega o SQLite ou usa outro caminho;

8. inicia tarefas progressivas e de cobertura.

O startup não monta um único "plano da tela". Ele escolhe entre várias implementações.

---

## 3.2 Feed principal vindo do SQLite

`reloadFromSQLite` implementa diretamente regras próprias:

* conteúdo dos últimos 30 dias;
* exclusão de lidos e consumidos;
* região;
* idioma;
* tipo de mídia;
* taxonomia;
* limites diferentes para texto ilustrado, texto sem imagem, vídeo, áudio e fórum;
* heurísticas por URL como `%youtube%` e `%reddit%`;
* variantes de URL com HTTP, HTTPS, `www` e trailing slash.

Depois da consulta SQL, ainda executa:

```text
applyFilters
→ balancedCandidatePool
→ Reservoir
→ CardPreparationCoordinator
```

Isso significa que existem dois intérpretes da mesma intenção:

```text
regras aplicadas no SQL
+
regras aplicadas em memória
```

Eles podem divergir.

---

## 3.3 Fetch normal e fetch de runway

`fetchNextBatch` constrói a lista de sources de duas formas:

```text
Content Type = All
→ registry.enabledSources

Content Type explícito
→ coverageSources sobre o catálogo expandido
```

Depois aplica collection, scheduler, cold-start policy ou filtered-runway policy.

Os itens são persistidos, enviados para What's New, colocados no reservoir e eventualmente publicados.

Logo, o fetch normal não recebe uma lista oficial produzida pela consulta atual. Ele reconstrói a lista de sources.

---

## 3.4 Fetch urgente de taxonomia

`fetchUrgentTaxonomyBatch` recebe o conjunto bruto de URLs da taxonomia e cria sua própria definição de elegibilidade:

* considera todo o catálogo;
* ignora desativações herdadas;
* respeita source desligada individualmente;
* filtra idioma, região e tipo por outro helper;
* produz seus próprios contadores.

Depois faz fetch, persiste, aplica novamente os filtros e força o reservoir.

Esse é o caminho que pode dizer:

```text
79 / 1.427 sources
```

enquanto o cabeçalho diz:

```text
7 sources
```

porque as duas interfaces não receberam o mesmo conjunto.

---

## 3.5 Coverage mining

Coverage mining também constrói seu próprio universo:

```text
taxonomy:
catálogo expandido menos explicitamente desligadas

content type explícito:
catálogo expandido menos explicitamente desligadas

all:
enabledSources
```

Ele usa outro planejamento de fetch, outro target e outra decisão sobre publicar ou apenas persistir.

Coverage mining é útil, mas está misturando duas responsabilidades:

```text
manutenção do catálogo local
e
preenchimento da tela atual
```

Essas responsabilidades precisam ser separadas.

---

## 3.6 Progressive fetch e background refresh

`progressiveFetchSources` começa novamente por `registry.enabledSources`, executa helpers próprios de idioma e tipo, aplica um limite de 200 e usa multiplier mais jitter aleatório.

O background refresh alterna entre:

* coverage de tipos (via `coverageSources` para o tipo rotacionado);
* coverage de taxonomias (via `mineNextTaxonomyCoverage`);
* fallback para batch aleatório de 5 `enabledSources` apenas quando a etapa de coverage não produz nada novo.

O padrão de alternância é baseado em `coverageStep`: passos pares fazem type coverage, passos ímpares fazem taxonomy coverage. O batch aleatório (`sourceSnapshot.shuffled().prefix(5)`) só é usado como último recurso, não como uma fase independente.

Essas operações podem alimentar o banco, mas não deveriam decidir diretamente o estado ou a composição da tela atual.

---

## 3.7 Editorial presets

Os presets editoriais não são filtros exclusivos. Eles geram multiplicadores de source.

O preset `Tech & Science`, por exemplo, aumenta pesos de tags e categorias, mas mantém um floor de `1.0`. Portanto, sources não relacionadas continuam elegíveis.

`PresetScorer` transforma esses perfis em um dicionário:

```swift
[String: Double]
```

que é usado pelo scheduler e pelo reservoir.

Isso é uma política de **ranking**, não uma política de elegibilidade.

---

## 3.8 Collections

A collection usada como preset:

* constrói uma allowlist;
* lê conteúdo retido por URLs exatas;
* aplica os filtros globais;
* envia para o reservoir;
* publica pela pipeline principal.

Porém, a tela independente `SourceCollectionFeedView` usa outro caminho:

```text
fetch de todos os membros
→ SQLite
→ [FeedItem]
→ UI
```

sem o prepared-card pipeline.

O método de backend correspondente também retorna itens crus.

Assim, "abrir collection como preset" e "abrir collection pela tela de administração" não são a mesma pipeline.

---

## 3.9 Source view

A inspeção de uma source:

```text
lê todo o histórico do SQLite
→ publica imediatamente com buildPresentations manual
→ faz o fetch
→ publica novamente com buildPresentations manual
```

O backend (`sourceContentFromCache` e `loadSourceContent`) não aplica a preparação de cards do `CardPreparationCoordinator`. Em vez disso, o `SourceFeedView` chama `buildPresentations(for:)` que usa `ImageLoader.resolveImage()` diretamente para criar `FeedCardPresentation` — um caminho de preparação **diferente**, não a ausência total de preparação.

Isso explica inconsistências visuais: o SourceFeedView resolve imagens de forma síncrona e imediata, sem o pipeline de deadline, contiguous-prefix promotion, memory pressure demotion e placeholder fallback que o feed principal usa.

---

## 3.10 Bookmarks e Last Clicked

Bookmark mode cancela algumas tarefas e chama diretamente:

```swift
setVisibleItems(items)
```

Last Clicked consulta diretamente o SQLite, chama `applyFilters` e também publica diretamente.

São snapshots fixos, mas ainda precisam passar pelo mesmo contrato de preparação e estado de tela.

---

## 3.11 Search

A busca possui:

* `searchGeneration`;

* sua própria lista de sources elegíveis;

* seu próprio source-result filter;

* sua própria consulta local;

* seu próprio sweep remoto;

* seus próprios contadores.

`sourcesEligibleForActiveSearch` recria quase toda a lógica de source scope para collection, taxonomy, content type, Smart Feed, Last Clicked, região e idioma.

---

## 3.12 Smart Feeds

A definição de Smart Feed armazena:

* query;
* região;
* taxonomia;
* idiomas;
* tipo;
* mood;
* collection;
* palavras excluídas.

Mas sua execução possui implementações próprias para:

* montar a allowlist;

* encontrar sources por texto;

* encontrar itens por FTS;

* validar itens;

* criar o source pool;

* escolher 75% de sources aprendidas e 25% de descoberta;

* carregar cache diretamente na tela.

O cache do Smart Feed é publicado com `setVisibleItems`, sem a mesma preparação do feed principal.

---

## 3.13 Onboarding e Curated Feed

A suspeita sobre o onboarding está correta.

Hoje existem pelo menos três caminhos:

### Candidatos do onboarding

O onboarding:

* lê até 1.200 itens recentes;
* pode escolher e buscar um conjunto especial de showcase sources;
* aplica um quality gate próprio;
* filtra o pool principalmente por idioma;
* inicia prefetch de imagem separado;
* retorna itens crus para as comparações.

### Preview

O preview usa os itens visíveis atuais e calcula novamente os multipliers do perfil, sem executar a composição completa do futuro feed.

### Feed curado definitivo

Ao salvar, o onboarding cria um `CuratedFeed` e ativa um preset curado.

O preset curado:

* altera o filtro global de idiomas;
* cria multipliers a partir do perfil;
* passa esses multipliers para scheduler e reservoir.

Portanto:

```text
comparações
preview
feed final
```

não usam exatamente a mesma seleção.

---

# 4. O que as "proporções" do onboarding realmente são hoje

O perfil curado armazena:

* weights de features;
* evidence counts;
* discovery level;
* learning enabled;
* idiomas.

O `CuratedPreferenceEngine` transforma esses weights em um multiplier por source, limitado aproximadamente entre `0.42` e `3.0`.

O reservoir usa esses multipliers para criar mais ou menos slots para cada source e depois aplica diversidade por provider, país, categoria, mídia e freshness.

Logo, as "proporções" atuais são **emergentes**.

Não existe uma regra explícita como:

```text
30% Technology & Science
20% Culture
20% News
15% vídeo
15% descoberta
```

Existe:

```text
weights
→ multiplier de source
→ quantidade de slots
→ interleave
```

A proporção final varia conforme:

* número de sources disponíveis;
* número de itens por source;
* idioma;
* freshness;
* catálogo habilitado;
* conteúdo já consumido;
* aleatoriedade do interleave.

Isso torna difícil:

* prever o resultado;
* testar o resultado;
* explicar o resultado;
* preservar o mesmo resultado entre preview e feed final.

A arquitetura nova deve manter suporte a scoring, mas adicionar uma política explícita de mistura.

---

# 5. Um mesmo nome está sendo usado para três conceitos diferentes

"Technology and Science" pode significar hoje:

## Taxonomia

Uma restrição forte:

```text
somente sources que pertencem aos nós selecionados
```

`applyFilters` verifica a presença da URL no conjunto da taxonomia.

## Editorial preset

Uma preferência suave:

```text
todas as sources continuam elegíveis
sources de tecnologia e ciência ganham boost
```

## Curated profile

Um peso aprendido:

```text
topic:technology-science = determinado valor
```

O tópico faz parte do vetor aberto do perfil.

A nova arquitetura precisa representar explicitamente o papel de cada seleção:

```swift
hardConstraints
rankingPreferences
mixTargets
```

Não se deve inferir o papel pelo nome do tópico.

---

# 6. Arquitetura proposta

```text
┌──────────────────────────────┐
│ UI / ação do usuário         │
│ filtro, preset, source, etc. │
└──────────────┬───────────────┘
               ↓
┌──────────────────────────────┐
│ Selection Surface Adapter    │
│ cria SelectionRequest        │
└──────────────┬───────────────┘
               ↓
┌──────────────────────────────┐
│ SelectionCompiler            │
│ resolve catálogo + usuário   │
└──────────────┬───────────────┘
               ↓
┌──────────────────────────────┐
│ ResolvedSelectionPlan        │
│ sources, regras, ranking,    │
│ mix, aquisição, apresentação │
└──────────────┬───────────────┘
               ↓
┌──────────────────────────────┐
│ SelectionSession             │
│ máquina de estado            │
└──────┬────────┬────────┬─────┘
       ↓        ↓        ↓
    Cache     Network   History
       └────────┬────────┘
                ↓
┌──────────────────────────────┐
│ Item eligibility             │
│ RankingEngine                │
│ MixAllocator                 │
└──────────────┬───────────────┘
               ↓
┌──────────────────────────────┐
│ CardPreparationService       │
└──────────────┬───────────────┘
               ↓
┌──────────────────────────────┐
│ FeedSnapshot atômico         │
│ cards + métricas + estado    │
└──────────────┬───────────────┘
               ↓
              UI
```

---

# 7. Modelo central

## 7.1 Identidade canônica de source

### Decisão arquitetural

A nova arquitetura **não** deve criar um novo tipo de identidade de source. Deve usar
os tipos já existentes no `FeedEngine`:

| Tipo | Definição | Uso |
|---|---|---|
| `SourceKey` | `String` com canonicalização conservadora | Identidade semântica estável |
| `SourceID` | `UInt32` derivado de `SourceKey` via SHA-256 | Identidade numérica compacta |

Para as partes legadas que ainda operam com URLs normalizadas, existe **temporariamente**:

```swift
/// Ponte transitório entre URLs normalizadas e identidades do catálogo.
/// Só deve existir durante a migração. Não é uma identidade permanente.
struct LegacySourceURL: Hashable, Sendable {
    let normalizedValue: String

    init(_ rawURL: String) {
        normalizedValue = OPMLParser.normalizeURL(rawURL)
    }

    /// Resolve para a identidade canônica do catálogo.
    func resolve(in catalog: some SelectionCatalogReading) async throws -> SourceID? {
        try await catalog.sourceID(for: normalizedValue)
    }
}
```

`LegacySourceURL` não deve ser chamado de `SourceID`, nem usado como identidade
permanente. Ele existe apenas para adaptar código legado que referencia sources por URL.

### Duas normalizações de URL — decisão

O código atual tem duas funções de normalização divergentes:

| Função | Arquivo | Transformações |
|---|---|---|
| `OPMLParser.normalizeURL()` | `OPMLParser.swift:406` | Força HTTPS, strip `www.`, lowercase host, remove fragment, remove tracking params, remove trailing slash |
| `CatalogIdentity.canonicalURLKey()` | `CatalogIdentity.swift:32` | Apenas lowercase scheme/host, trim whitespace |

A decisão arquitetural é:

**Identidade permanente** — usar canonicalização conservadora (`canonicalURLKey`):
- normalização de case em scheme e host;
- remoção de fragment;
- default ports quando seguro;
- **preservação** de `http` vs `https` (são endpoints potencialmente diferentes);
- **preservação** de paths, trailing slash e query quando puderem alterar o endpoint.

**Lookup legado** — o adapter de compatibilidade pode procurar aliases:
```
http ↔ https
www ↔ sem www
trailing slash ↔ sem trailing slash
```
somente para encontrar dados antigos no SQLite. Esses aliases são responsabilidade
do repositório de conteúdo, não do motor de seleção.

**Fetch** — usar `requestURL`, que pode mudar por redirect ou alias conhecido,
sem alterar a identidade (`SourceID`) da source.

`OPMLParser.normalizeURL()` **não** deve ser usado como identidade permanente.
Sua canonicalização agressiva (forçar HTTPS, strip www) trata como iguais
endpoints que podem ser diferentes.

### Como o motor referencia sources

```swift
// Identidade — tipos do FeedEngine
let sourceID: SourceID           // identidade numérica compacta
let sourceKey: SourceKey         // identidade semântica

// Lookup legado — transitório
let legacyURL: LegacySourceURL?  // apenas durante a migração
```

O `SelectionCompiler` não deve depender diretamente de:
- `SourceRegistry.sources`
- `TaxonomyStore.flatIndex`
- `OPMLParser.normalizeURL`

Em vez disso, depende de uma interface do catálogo:

```swift
protocol SelectionCatalogReading: Sendable {
    func resolveSourceScope(
        _ specification: SourceScopeSpecification
    ) async throws -> ResolvedSourceScope

    func sourceMetadata(
        for ids: some Collection<SourceID>
    ) async throws -> [SourceSelectionMetadata]
}
```

Durante a migração, `SourceRegistry` e `TaxonomyStore` implementam essa interface
via um adapter. Depois da migração, o `FeedEngine` pode se tornar a implementação
canônica.

---

## 7.2 `ContentSelectionRequest`

A request é a descrição imutável da intenção.

```swift
struct ContentSelectionRequest: Sendable, Equatable {
    let id: SelectionID
    let surface: SelectionSurface
    let sourceUniverse: SourceUniversePolicy
    let criteria: ItemCriteria
    let ranking: RankingProfile
    let mix: MixPolicy
    let history: HistoryPolicy
    let acquisition: AcquisitionPolicy
    let presentation: PresentationPolicy
}
```

### Surface

```swift
enum SelectionSurface: Sendable, Equatable {
    case main
    case source(SourceID)
    case collection(Int64)
    case smartFeed(Int64)
    case bookmarks(Int64?)
    case lastClicked
    case search(SearchExpression)
    case onboardingComparison
    case curatedPreview
    case whatsNew
}
```

### Source universe

```swift
enum SourceUniversePolicy: Sendable, Equatable {
    case enabledLibrary
    case expandedCatalogRespectingExplicitOff
    case explicitAllowlist(Set<SourceID>)
    case single(SourceID)
    case fixedSnapshot(Set<SourceID>)
}
```

Significados:

```text
enabledLibrary
sources normalmente habilitadas pelo usuário e pelos defaults

expandedCatalogRespectingExplicitOff
consulta explícita ao catálogo, como taxonomia ou media type;
ignora desativações herdadas, respeita source desligada individualmente

explicitAllowlist
collection

single
View Source

fixedSnapshot
bookmarks, Last Clicked ou outros conjuntos persistidos
```

### Critérios de item

```swift
struct ItemCriteria: Sendable, Equatable {
    var regions: Set<String>
    var taxonomyNodeIDs: Set<String>
    var languages: Set<String>
    var contentTypes: Set<ContentType>
    var mood: MoodFilter
    var searchExpression: SearchExpression?
    var excludedKeywords: Set<String>
    /// User-defined content filters (ContentFilterStore).
    /// These are keyword-based exclusions managed by the user
    /// independently from search/taxonomy/preset.
    var contentFilterKeywords: Set<String>
}
```

> **Nota:** O código atual também implementa dois caches de performance no `applyFilters`:
> `moodMatchCache` (por item ID) e `contentFilterExcludeCache` (por item ID).
> A nova arquitetura deve preservar caching equivalente nos evaluators — esses caches
> são essenciais para evitar reavaliar regex/string matching em milhares de itens.

### Histórico

```swift
struct HistoryPolicy: Sendable, Equatable {
    var includeRead: Bool
    var includeConsumed: Bool
    var includeBookmarked: Bool
    var dateRange: ClosedRange<Date>?
}
```

### Ranking

```swift
struct RankingProfile: Sendable, Equatable {
    var signals: [RankingSignal]
}
```

Exemplos de signals:

```swift
enum RankingSignal: Sendable, Equatable {
    case freshness(weight: Double)
    case sourceQuality(weight: Double)
    case editorialPreset(FeedPreset)
    case curatedProfile(CuratedProfileDefinition)
    case sourceAffinity([SourceID: Double])
    case imageAvailability(weight: Double)
    case mediaPreference(ContentType, weight: Double)
    case topicPreference(CuratedTopic, weight: Double)
    case nature(String, weight: Double)
    case activity(String, weight: Double)
}
```

Adicionar "priorizar conteúdos com imagem" passaria a ser:

```swift
.imageAvailability(weight: 0.6)
```

Não seria necessário criar outro fetch, outro filtro ou outro reservoir.

### Mix

```swift
struct MixPolicy: Sendable, Equatable {
    var quotas: [MixQuota]
    var providerCooldown: Int
    var categoryCooldown: Int
    var regionCooldown: Int
    var mediaCooldown: Int
    var discoveryShare: Double
}
```

Exemplos:

```swift
enum MixQuota: Sendable, Equatable {
    case media(ContentType, target: ClosedRange<Double>)
    case topic(CuratedTopic, target: ClosedRange<Double>)
    case illustrated(target: ClosedRange<Double>)
    case region(String, target: ClosedRange<Double>)
}
```

Quotas devem ser preferenciais, não obrigatoriamente destrutivas. Se o catálogo não fornecer a quantidade necessária, o allocator utiliza o melhor conteúdo restante.

---

# 8. `ResolvedSelectionPlan`

A request ainda é intenção. O compiler transforma a intenção em algo executável:

```swift
struct ResolvedSelectionPlan: Sendable {
    let selectionID: SelectionID

    /// Scope das sources elegíveis. Para conjuntos pequenos, materializa.
    /// Para catálogos grandes, mantém consulta paginada.
    let sourceScope: ResolvedSourceScope
    let sourceMetrics: SourceSelectionMetrics

    let itemRules: ItemRuleSet
    let cacheQuery: CacheQuerySpecification

    let rankingPlan: CompiledRankingPlan
    let mixPlan: CompiledMixPlan

    let acquisitionPlan: ResolvedAcquisitionPlan
    let presentationPlan: ResolvedPresentationPlan
    let completionPolicy: CompletionPolicy
}
```

### SourceScopeHandle

```swift
enum SourceScopeHandle: Sendable {
    case materialized(SourceIDSet)       // conjunto pequeno
    case catalogQuery(CatalogSourceQuery) // catálogo grande — paginado
    case explicitList([SourceID])         // collection, bookmarks
    case single(SourceID)                 // Source View
}
```

Para conjuntos pequenos (até ~500 sources), materializar. Para taxonomias e
catálogos grandes, usar consultas paginadas. O fetch também recebe alvos
sob demanda:

```swift
func nextFetchTargets(
    from scope: SourceScopeHandle,
    policy: AcquisitionPolicy,
    limit: Int
) async throws -> [FetchTarget]
```

O `sourceScope` é calculado uma única vez e deve alimentar:

```text
contador do topo
contador do loading
cache query
scheduler
urgent fetch
progressive fetch
coverage da seleção
remote search
empty state
```

---

# 9. Um rule set, dois intérpretes

Não é suficiente mover `applyFilters` para outro arquivo.

As regras devem ser declarativas:

```swift
struct ItemRuleSet: Sendable, Equatable {
    let eligibleSourceIDs: Set<SourceID>
    let regions: Set<String>
    let languages: Set<String>
    let taxonomySourceIDs: Set<SourceID>
    let contentTypes: Set<ContentType>
    let mood: MoodFilter
    let searchExpression: SearchExpression?
    let excludedKeywords: Set<String>
    /// Snapshot imutável das regras de ContentFilterStore no momento da compilação.
    let contentExclusions: ContentExclusionPolicy
    let history: HistoryPolicy
}
```

### Cache de avaliação

`moodMatchCache` e `contentFilterExcludeCache` são essenciais para performance
mas não pertencem ao modelo declarativo. São infraestrutura do evaluator:

```swift
struct ItemEvaluationCacheKey: Hashable {
    let itemID: String
    let ruleDigest: UInt64
}

actor ItemEvaluationCache {
    func moodMatch(_ itemID: String, ruleDigest: UInt64) -> Bool?
    func setMoodMatch(_ itemID: String, ruleDigest: UInt64, match: Bool)
    func contentFilterExcluded(_ itemID: String, ruleDigest: UInt64) -> Bool?
    func setContentFilterExcluded(_ itemID: String, ruleDigest: UInt64, excluded: Bool)
}
```

Quando mood ou content filters mudam, o `ruleDigest` muda e os valores antigos
deixam de ser usados — sem precisar limpar manualmente múltiplos dicionários.

Depois devem existir dois intérpretes:

```swift
SQLItemRuleCompiler
InMemoryItemRuleEvaluator
```

O primeiro transforma o rule set em uma consulta GRDB.

O segundo avalia:

* itens recém-baixados;
* itens do reservoir;
* resultados de busca;
* itens de What's New;
* conteúdo de uma source;
* conteúdo de uma collection.

A regra não é duplicada. Somente os intérpretes mudam.

Testes de paridade precisam garantir:

```text
o mesmo fixture
→ SQL e in-memory retornam os mesmos IDs
```

---

# 10. Source eligibility centralizada

Criar:

```swift
struct SourceScopeResolver {
    func resolve(
        policy: SourceUniversePolicy,
        criteria: SourceCriteria,
        registry: SourceRegistrySnapshot,
        taxonomy: TaxonomySnapshot,
        userState: SourceEnablementSnapshot
    ) -> ResolvedSourceScope
}
```

O resolver deve ser o único componente autorizado a decidir:

* default-enabled;
* explicit off;
* enabled override;
* desativação de país;
* desativação de região;
* desativação de categoria;
* expansão temporária do catálogo;
* allowlist de collection;
* source única;
* idioma;
* tipo de mídia;
* taxonomia.

A política atual do `SourceRegistry` distingue explicit off, override, defaults e parents.

O resolver não deve alterar essa lógica de persistência. Ele deve apenas tornar explícita a política usada por cada request.

---

# 11. Ranking e mistura são responsabilidades diferentes

## Ranking

Responde:

> Entre dois candidatos elegíveis, qual deveria aparecer primeiro?

Cada item deve receber um breakdown:

```swift
struct CandidateScore {
    let total: Double
    let components: [ScoreComponent]
}
```

Exemplo:

```text
Freshness             +0.82
Curated topic         +0.60
Source quality        +0.35
Illustrated content   +0.25
Already surfaced      -0.70
Total                  1.32
```

Isso facilita debugging e pode alimentar o "open hood" do Feedmine.

## Mix

Responde:

> Mesmo que os maiores scores sejam todos de uma categoria, qual composição queremos?

O `MixAllocator` aplica:

* diversidade de provider;
* diversidade geográfica;
* diversidade de mídia;
* target de assuntos;
* target de imagem;
* discovery share;
* limites por source.

O reservoir atual já tenta diversidade e weighting, mas tudo está embutido em um interleave específico.

Inicialmente, o novo allocator pode encapsular esse comportamento como:

```swift
LegacyReservoirMixPolicy
```

A substituição pode ser gradual.

---

# 12. Aquisição não é seleção

A lista de sources elegíveis pode ter 1.427 entries, mas a operação atual pode decidir verificar somente 120.

Esses números precisam ser distintos:

```text
eligibleSourceCount   = 1.427
scheduledSourceCount  = 120
checkedSourceCount    = 79
respondingSourceCount = 64
contributingCount     = 18
```

A UI nunca deve mostrar:

```text
79 / 1.427
```

se a operação só agendou 120.

Deve mostrar:

```text
79 / 120 checked
1.427 sources match this selection
18 sources contributed content
```

Criar:

```swift
struct SourceSelectionMetrics: Sendable, Equatable {
    let catalogTotal: Int
    let enabledLibraryTotal: Int
    let eligibleTotal: Int
    let scheduledTotal: Int
    let checked: Int
    let responding: Int
    let contributing: Int
    let representedInCache: Int
    let representedOnScreen: Int
}
```

Cabeçalho, loading e empty state devem receber exatamente essa estrutura.

---

# 13. Separar seleção da manutenção do catálogo

Devem existir duas operações diferentes.

## `SelectionAcquisition`

Busca conteúdo para uma request ativa.

Somente essa operação pode contribuir para a composição atual.

## `CatalogMaintenance`

Faz:

* coverage de taxonomias;
* atualização de sources ainda não representadas;
* manutenção de Smart Feeds em background;
* health checks;
* atualização lenta do banco.

Pode persistir conteúdo, mas não pode chamar:

```text
setVisibleItems
reservoir.append
publish
```

O conteúdo novo fica disponível para a próxima avaliação da request ativa.

Isso remove uma parte significativa dos caminhos de rato atuais.

---

# 14. Máquina de estado por sessão

Não deve existir apenas um `loadingState` global.

Criar uma `SelectionSession` por superfície.

**A primeira versão deve ser `@MainActor`, não um actor separado.**
A sessão é responsável por estado observável e publicação. Os trabalhos pesados
ficam em componentes `Sendable` ou actors próprios (`SelectionCompiler`,
`ContentRepository`, `NetworkAcquisition`, `CardPreparationCoordinator`).
Tentar migrar todo o grafo de `FeedStore` para `Sendable` na primeira fase
aumentaria muito o risco.

```swift
@MainActor
final class SelectionSession {
    let id: SelectionID
    let request: ContentSelectionRequest

    func start()
    func refresh()
    func loadMore()
    func cancel()
}
```

### CompletionPolicy

O startup atual não decide "pronto" apenas por `minimumCount`. Ele também
considera breadth e utilidade (`coldStartRunwayIsUseful`). A política deve
ser explícita:

```swift
struct CompletionPolicy: Sendable, Equatable {
    let minimumCardCount: Int
    let preferredCardCount: Int
    let minimumDistinctSources: Int
    let minimumDistinctProviders: Int
    let maximumWait: Duration
    let allowPartialAfterDeadline: Bool
}
```

| Superfície | minimumCardCount | minimumDistinctSources | minimumDistinctProviders | maximumWait |
|---|---|---|---|---|
| Main feed (cold start) | 20 | 10 | 8 | 4s |
| Main feed (warm) | 20 | 5 | 3 | 2s |
| Source View | 1 | 1 | 1 | 5s |
| Bookmarks | todos locais | N/A | N/A | sem network |

Estados:

```swift
enum SelectionState: Sendable {
    case idle
    case preparing(SelectionProgress)
    case ready(FeedSnapshot)
    case refreshing(previous: FeedSnapshot?, progress: SelectionProgress)
    case loadingMore(current: FeedSnapshot, progress: SelectionProgress)
    case empty(SelectionEmptyReason, SelectionMetrics)
    case failed(previous: FeedSnapshot?, SelectionFailure)
    case cancelled
}
```

## Regras

### Troca de filtro

```text
nova session
→ tela preparing
→ conteúdo antigo não é publicado como resultado parcial
→ primeira página completa é preparada
→ snapshot novo substitui o anterior atomicamente
```

### Shake

```text
snapshot atual é preservado internamente
→ tela mostra refreshing
→ nova composição é produzida
→ sucesso: troca atômica
→ falha: snapshot anterior é restaurado
→ vazio real: empty
```

### Empty

Só pode acontecer quando:

```text
source scope foi resolvido
+
cache foi consultado
+
aquisição planejada terminou ou foi considerada suficiente
+
nenhum item passou pelas regras
```

`items.isEmpty` não é uma prova de empty.

---

# 15. Snapshot atômico

```swift
struct FeedSnapshot: Sendable {
    let selectionID: SelectionID
    let cards: [PreparedFeedCard]
    let metrics: SelectionMetrics
    let hasMore: Bool
    let createdAt: Date
}
```

Cada `PreparedFeedCard` deve conter:

```text
FeedItem
+
FeedCardPresentation terminal
```

Terminal significa:

* imagem pronta;
* placeholder definitivo;
* card text-only definitivo.

Nunca se publica um item enquanto ainda se decide se ele possui imagem.

A UI deve renderizar somente `FeedSnapshot.cards`.

Ela não deve juntar:

```text
loader.items
com
loader.cards
```

por ID depois da publicação.

### Protocolo de preparação de cards

O `CardPreparationCoordinator` atual deve ser preservado atrás de um contrato:

```swift
protocol SelectionCardPreparing: Sendable {
    func prepareInitialSnapshot(
        items: [FeedItem],
        policy: PresentationPolicy,
        context: SelectionContext
    ) async -> PreparedSnapshotResult

    func prepareAdditionalCards(
        items: [FeedItem],
        policy: PresentationPolicy,
        context: SelectionContext
    ) async -> [PreparedFeedCard]

    func cancel(context: SelectionContext) async
}
```

O adapter deve: instalar sequência, aguardar prefixo contíguo, validar contexto,
retornar cards preparados, e **nunca** publicar diretamente na UI.

---

# 16. Sessões independentes por superfície

Uma source view não deve substituir o coordinator do feed principal.

O motor deve criar sessões isoladas:

```text
Main feed session
Source sheet session
Collection sheet session
Search session
Onboarding session
```

Todas usam os mesmos engines, mas mantêm estado independente.

Também pode existir uma sessão headless:

```text
Smart Feed background session
Catalog maintenance session
```

A sessão headless persiste resultados, mas não prepara `UIImage` nem publica na interface.

---

# 17. Como cada recurso será representado

## Feed principal sem filtros

```swift
sourceUniverse = .enabledLibrary
criteria = .none
ranking = current editorial or curated profile
mix = default feed mix
```

## Taxonomia explícita

```swift
sourceUniverse = .expandedCatalogRespectingExplicitOff
criteria.taxonomyNodeIDs = selectedNodes
```

A taxonomia é hard constraint.

## Content type explícito

```swift
sourceUniverse = .expandedCatalogRespectingExplicitOff
criteria.contentTypes = [.video]
```

## Editorial preset

```swift
sourceUniverse = .enabledLibrary
ranking.signals += [.editorialPreset(.techAndScience)]
```

Nenhuma exclusão é adicionada.

## Curated Feed

```swift
sourceUniverse = .enabledLibrary
criteria.languages = profile.languages
ranking.signals += [.curatedProfile(profile)]
mix = CuratedMixCompiler.compile(profile)
```

O perfil não deve alterar `activeLanguages` globalmente.

## Collection

```swift
sourceUniverse = .explicitAllowlist(memberIDs)
criteria = filtros escolhidos pelo usuário
```

Preset e tela independente produzem a mesma request.

## Source view

```swift
sourceUniverse = .single(sourceID)
history.includeRead = true
history.includeConsumed = true
acquisition = .refreshExactSources
presentation.initialPageSize = 20
```

## Bookmarks

```swift
surface = .bookmarks(listID)
sourceUniverse = .fixedSnapshot(sourceIDs)
history = include bookmarked IDs
acquisition = .cacheOnly
```

## Last Clicked

```swift
surface = .lastClicked
acquisition = .cacheOnly
ordering = clickedAt descending
```

## Search

```swift
surface = .search(expression)
sourceUniverse = scope resolvido pelos filtros atuais
criteria.searchExpression = expression
acquisition = cache followed by optional exhaustive sweep
```

## Composite Saved Searches

```swift
surface = .compositeSavedSearches(Set<PersistentSearchID>)
// ou como composição: SearchComposition.anyOf([expr1, expr2])
```

A implementação FTS pode continuar otimizada, mas eligibility e filtros
devem vir do mesmo `ItemRuleSet` das outras superfícies.

## Smart Feed

A definição persistida deve ser convertida em uma `ContentSelectionRequest`.

Não deve possuir um segundo matcher independente.

O cache do Smart Feed é o resultado materializado da mesma request.

## What's New

```swift
baseRequest = activeRequest
criteria.fetchedAfter = baseline
history.excludeSurfaced = true
ranking = freshness + active ranking
mix = compact carousel mix
presentation.pageSize = 10
```

## Onboarding comparison

```swift
surface = .onboardingComparison
sourceUniverse = .enabledLibrary
criteria.languages = selectedLanguages
sourcePolicy = .onboardingShowcaseQuality
ranking = editorial quality + uncertainty
mix = comparison diversity
presentation.pageSize = candidate pool size
```

O pair selector continua existindo, mas recebe candidatos preparados pelo motor.

Ele não busca sources nem prepara imagens diretamente.

## Curated preview

O preview executa a mesma request do feed final:

```text
mesmo source scope
mesmo ranking
mesmo mix
limit = 3
cache-only
```

A única diferença é o limite.

---

# 18. Refatoração do onboarding

`CuratedPreferenceEngine` deve ser dividido conceitualmente.

## Deve permanecer nele

* feature extraction;
* pair selection;
* atualização dos weights;
* evidence;
* confidence;
* discovery level.

## Deve sair dele

* seleção de source universe;
* fetch de showcase sources;
* preparação de imagens;
* composição final;
* preview sobre `visibleItems`;
* publicação.

Criar adapters:

```swift
CuratedProfileRankingAdapter
CuratedProfileMixAdapter
OnboardingShowcasePolicy
```

A sequência será:

```text
SelectionEngine prepara pool
→ CuratedPreferenceEngine escolhe o par
→ usuário responde
→ profile é atualizado
→ request de preview é recompilada
→ preview e feed final usam o mesmo motor
```

---

# 19. Semântica de "Clear All Filters"

Não recomendo que "Clear All Filters" habilite automaticamente todo o catálogo.

O `SourceRegistry` inclui na noção de "não habilitada":

* source explicitamente desligada;
* source `defaultEnabled == false`;
* source dentro de região desligada;
* source dentro de país desligado;
* source dentro de categoria desligada.

Portanto, "34 mil sources disabled" não significa necessariamente que o usuário desligou 34 mil sources manualmente.

## Ações recomendadas

### `Reset Feed Filters`

Remove:

* preset editorial/curado;
* taxonomia;
* idioma;
* região;
* tipo;
* mood;
* busca.

Resultado:

```text
All enabled sources
```

Preserva a biblioteca de sources do usuário.

### `Restore Recommended Sources`

Chama a operação equivalente a resetar overrides e toggles para os defaults do catálogo.

O registry já possui `resetAllToggles()`.

### `Explore Entire Catalog`

Modo temporário e explícito:

```swift
sourceUniverse = .expandedCatalogRespectingExplicitOff
```

Não altera permanentemente os toggles.

### `Enable Entire Catalog`

Ação avançada separada, com confirmação. Não precisa estar no fluxo normal.

---

# 20. Refatoração de `Clear All Filters`

Hoje o `FeedLoader` chama duas operações:

```text
setPreset(.everything)
clearAllFilters()
```

O `clearAllFilters` do store possui seu próprio reload e apenas incrementa `filterGeneration`; ele não reconstrói o presentation context como `setFilter` faz.

Substituir por uma única operação:

```swift
func resetFeedFilters() {
    selectionController.submit(
        MainFeedRequestFactory.makeResetRequest(
            preservingSourceLibrary: true
        )
    )
}
```

Não devem existir duas transições concorrentes.

---

## 20.1 Elementos existentes que a nova arquitetura deve estender

O código atual já possui estruturas que são proto-implementações dos conceitos propostos.
A nova arquitetura deve evoluí-las, não substituí-las:

### `FeedPresentationContext` e `FeedPresentationMode`

`Models/FeedPresentationContext.swift` já define:

```swift
struct FeedPresentationContext {
    let epoch: UInt64
    let mode: FeedPresentationMode
    let filterGeneration: Int64
    let presetGeneration: Int64
}

enum FeedPresentationMode {
    case main
    case collection(Int64)
    case smartFeed(Int64)
    case bookmarks(Int64?)
    case lastClicked
    case whatsNew
}
```

Isso é essencialmente o que o documento propõe como `SelectionSurface`. A migração deve:

1. Estender `FeedPresentationMode` com os casos faltantes (source, search, onboarding, curatedPreview)
2. Substituir `FeedPresentationContext` por `ResolvedSelectionPlan`
3. Remover as generations paralelas (`filterGeneration`, `presetGeneration`, `presentationEpoch`)
   em favor de um único `SelectionID`

### `FeedUIUpdate`

`FeedStore.applyUpdate()` já usa um enum com casos `.flush`, `.append`, `.replace`, `.refresh`, `.trim`.
Isso é uma implementação nascente do snapshot atômico proposto. A migração deve:

1. Adicionar o caso `.snapshot(FeedSnapshot)` que publica cards + métricas atomicamente
2. Fazer `.flush`, `.refresh` e `.replace` passarem pelo `SelectionSession`
3. Remover `.trim` (substituído pelo gerenciamento interno do `MixAllocator`)

### `FeedDisplayPhase`

`FeedLoader.FeedDisplayPhase` já tem `.preparing`, `.ready`, `.empty`, `.failed`.
Isso mapeia diretamente para `SelectionState`. A migração deve:

1. Adicionar `.refreshing` e `.loadingMore` como estados distintos
2. Associar `SelectionMetrics` a cada estado
3. Remover `FeedLoadingState` (`.idle`, `.initial`, `.refreshing`, `.loadingMore`)
   em favor de `SelectionState`

### `LoadedIDs`

O `FeedStore` mantém um `loadedIDs: Set<String>` (linha 644) que age como um filtro
Bloom-like para evitar re-fetch de itens já carregados. Este conceito deve ser
explicitamente representado na nova arquitetura como parte do `HistoryPolicy`:

```swift
struct HistoryPolicy {
    var excludeAlreadyLoaded: Bool  // o loadedIDs atual
    var excludeRead: Bool
    var excludeConsumed: Bool
    var excludeSurfaced: Bool
    var excludeBookmarked: Bool
    var dateRange: ClosedRange<Date>?
}
```

### `moodMatchCache` e `contentFilterExcludeCache`

Os evaluators (`InMemoryItemRuleEvaluator` e `SQLItemRuleCompiler`) devem implementar
caches equivalentes. O `ItemRuleSet` não precisa expor os caches — eles são detalhes
de implementação dos evaluators — mas os testes de performance devem verificar que
a avaliação de 5.000 itens com mood + content filters ativos não degrada em relação
ao `applyFilters` atual.

---

# 21. Estrutura de arquivos sugerida

```text
feedmine/
  Models/
    Selection/
      SelectionID.swift
      SourceID.swift
      ContentSelectionRequest.swift
      ResolvedSelectionPlan.swift
      ItemRuleSet.swift
      RankingProfile.swift
      MixPolicy.swift
      SelectionMetrics.swift
      FeedSnapshot.swift
      SelectionState.swift

  Services/
    Selection/
      SelectionCompiler.swift
      SourceScopeResolver.swift
      SQLItemRuleCompiler.swift
      InMemoryItemRuleEvaluator.swift
      RankingEngine.swift
      MixAllocator.swift
      AcquisitionPlanner.swift
      SelectionCoordinator.swift
      SelectionSession.swift
      SelectionTrace.swift

      Adapters/
        MainFeedSelectionAdapter.swift
        EditorialPresetSelectionAdapter.swift
        CuratedFeedSelectionAdapter.swift
        OnboardingSelectionAdapter.swift
        SmartFeedSelectionAdapter.swift
        CollectionSelectionAdapter.swift
        SourceSelectionAdapter.swift
        SearchSelectionAdapter.swift
        BookmarkSelectionAdapter.swift
        LastClickedSelectionAdapter.swift
        WhatsNewSelectionAdapter.swift

      Repositories/
        SelectionCacheRepository.swift
        SelectionNetworkRepository.swift

      Presentation/
        SelectionCardPreparationService.swift

  Services/
    Maintenance/
      CatalogCoverageService.swift
      SourceHealthMaintenanceService.swift
      SmartFeedMaintenanceService.swift
```

`FeedStore` deve se tornar uma façade pequena:

```text
recebe intenções
mantém a main SelectionSession
expõe o SelectionState para a UI
encaminha ações do usuário
```

Ele não deve continuar sendo o local onde cada modo implementa seu próprio fetch.

---

# 22. Plano de migração

## Fase 0 — Congelar a expansão da arquitetura atual

Antes de alterar comportamento:

1. adicionar este documento ao repositório;
2. criar feature flags por fase:
   * `unifiedSelectionEngine` — flag mestre (desligada em produção até Fase 3)
   * `unifiedSelectionShadow` — shadow mode (Fase 1)
   * `unifiedSelectionState` — estado e contadores unificados (Fase 2)
   * `unifiedSelectionMainFeed` — feed principal (Fase 3)
   * `unifiedSelectionRankingMix` — ranking e mix (Fase 4)
   * `unifiedSelectionOnboarding` — onboarding (Fase 5)
   * `unifiedSelectionSurfaces` — escopos fixos (Fase 6A)
   * `unifiedSelectionSearchSmart` — search e smart feed (Fase 6B)
   * `unifiedSelectionWhatsNew` — what's new (Fase 6C)
   * `unifiedSelectionLegacyRemoved` — remoção do legado (Fase 7)
3. impedir novas pipelines diretas;
4. adicionar `SelectionTrace`;
5. registrar cada composição atual com:

   * filtros;
   * preset;
   * source set;
   * item IDs;
   * contadores;
   * caminho utilizado;
6. criar fixtures dos bugs encontrados.

### Critério de saída

É possível reproduzir por teste:

* português + Technology and Science;
* shake que termina vazio;
* Clear All Filters;
* source view sem imagens;
* filtro que publica um card solitário;
* onboarding preview diferente do feed final.

---

## Fase 1 — Modelo e engines puros

Implementar sem alterar a UI:

* `SourceID`;
* `ContentSelectionRequest`;
* `ItemRuleSet`;
* `SourceScopeResolver`;
* `InMemoryItemRuleEvaluator`;
* `SQLItemRuleCompiler`;
* `ResolvedSelectionPlan`;
* `SelectionMetrics`.

Executar o novo compiler em **shadow mode**.

Para cada ação atual, comparar:

```text
source set atual
versus
source set resolvido pelo novo engine
```

Diferenças devem ser registradas, não automaticamente escondidas.

### Critério de saída

Para as requests escolhidas como comportamento oficial:

```text
header
cache
fetch
search
```

recebem o mesmo hash de source IDs.

---

## Fase 2 — Estado e contadores unificados

Implementar:

* `SelectionState`;
* `SelectionProgress`;
* `SelectionMetrics`;
* `FeedSnapshot`.

Migrar:

* cabeçalho;
* initial loading;
* filtering;
* refreshing;
* empty state;
* error state.

A UI deixa de calcular totais usando:

```text
TaxonomyStore.feedCount
activeSources.count
emptyStateFetchTotal
sourceCount
```

separadamente.

### Critério de saída

Para qualquer tela:

```text
eligibleTotal
scheduledTotal
checked
contributing
```

têm uma definição única.

A interface não mostra `empty` enquanto a sessão está preparando ou atualizando.

---

## Fase 3 — Feed principal

Migrar para `SelectionSession`:

1. startup normal;
2. filtro de idioma;
3. filtro de taxonomia;
4. content type;
5. região;
6. mood;
7. editorial preset;
8. Clear/Reset Filters;
9. shake;
10. Refresh Now;
11. load more;
12. source toggles.

Nesta fase, `Reservoir`, `AdaptiveScheduler` e `CardPreparationCoordinator` podem continuar existindo atrás de adapters.

O objetivo é trocar a orquestração antes de trocar os algoritmos.

### Critério de saída

Não existem mais:

* publicação imediata de cards sobreviventes;
* flush destrutivo antes do novo snapshot;
* contadores com source universes diferentes;
* geração antiga publicando na composição nova.

---

## Fase 4 — Ranking e Mix

Criar:

* `RankingEngine`;
* `CandidateScoreBreakdown`;
* `MixAllocator`.

Primeiro, preservar o comportamento atual usando:

```swift
LegacyPresetMultiplierSignal
LegacyReservoirMixAdapter
```

Depois migrar:

* editorial presets;
* curated profile;
* provider diversity;
* country diversity;
* media diversity;
* freshness;
* discovery;
* image preference.

### Critério de saída

É possível criar uma política como:

```swift
MixPolicy(
    quotas: [
        .illustrated(target: 0.60...0.80),
        .media(.video, target: 0.10...0.20),
        .media(.audio, target: 0.05...0.15)
    ],
    discoveryShare: 0.20
)
```

sem modificar fetch, SQLite, views ou source eligibility.

---

## Fase 5 — Onboarding e Curated Feeds

Migrar:

1. showcase pool;
2. preparação dos comparison cards;
3. preview;
4. feed final;
5. learning after article open;
6. inspector.

Não permitir que onboarding altere os filtros globais do feed principal.

### Critério de saída

Dado o mesmo perfil e o mesmo catálogo:

```text
preview
e
primeiros cards do feed final
```

usam a mesma função de score e a mesma política de mix.

---

## Fase 6A — Escopos fixos

Migrar:

* Source View;
* Collection View;
* Collection preset;
* Bookmarks;
* Last Clicked.

Cada tela cria sua própria `SelectionSession`.

### Critério de saída

Todos os cards dessas telas possuem presentation terminal antes da publicação.

---

## Fase 6B — Search e Smart Feed

Migrar Smart Feed para armazenar uma request serializável.

Remover matchers paralelos e utilizar:

```text
SourceScopeResolver
ItemRuleEvaluator
RankingEngine
AcquisitionPlanner
```

A busca ao vivo também recebe um plan resolvido.

### Critério de saída

Uma Smart Feed salva e a busca ativa da qual ela foi criada retornam os mesmos resultados para o mesmo snapshot do banco.

---

## Fase 6C — What's New

What's New passa a ser uma projeção da request ativa.

O serviço continua mantendo baseline e surfaced IDs, mas não reconstrói filtros.

### Critério de saída

Nenhum item pode aparecer em What's New se não for elegível pela request ativa.

---

## Fase 7 — Remoção do legado

Remover ou tornar wrappers privados:

```text
applyFilters global e stateful
coverageSources
coverageSourceMatches
sourceMatches(...)
sourcesEligibleForActiveSearch
sourceMatchesActiveSearchFilters
smartFeedMatches
smartFeedMatchingSourceURLs
immediatelyCullVisibleItemsForActiveFilter
emptyStateFetchedCount
emptyStateFetchTotal
filterGeneration
presetGeneration
presentationEpoch
```

Uma única `SelectionID` substitui as generations paralelas.

### Critério de saída

`FeedStore` não contém implementações de seleção específicas de uma surface.

---

# 23. Regras arquiteturais para impedir recaída

Adicionar uma verificação de CI.

## `registry.enabledSources`

Uso permitido apenas em:

```text
SourceRegistry
SourceScopeResolver
CatalogMaintenance
```

## `fetcher.fetch...`

Uso permitido apenas em:

```text
SelectionNetworkRepository
CatalogMaintenance
```

## Escrita de conteúdo visível

Somente:

```text
SelectionCoordinator
FeedStore publication bridge temporário
```

## `setVisibleItems`

Deve desaparecer ao final da migração ou permanecer privado no bridge.

## Views

Views não podem calcular:

* source universe;
* progresso;
* empty;
* ranking;
* presença de imagem.

Devem renderizar `SelectionState`.

## Adapters

Adapters podem apenas criar requests.

Não podem:

* consultar SQLite;
* chamar fetcher;
* filtrar arrays;
* publicar itens;
* preparar imagens.

---

# 24. Estratégia de testes

> **Priorização:** Os testes marcados com 🟢 são obrigatórios para a fase correspondente.
> 🟡 são desejáveis mas podem ser adiados. 🔴 são apenas para fases avançadas.

## 24.1 Source scope 🟢 Fase 1

Fixtures combinando:

* default enabled;
* default dormant;
* explicit off;
* explicit on;
* parent region off;
* category off;
* taxonomy expansion;
* collection;
* source única.

Cada policy deve produzir IDs exatos.

## 24.2 Paridade SQL/in-memory 🟢 Fase 3

Para milhares de combinações:

```text
SQLItemRuleCompiler
e
InMemoryItemRuleEvaluator
```

devem produzir os mesmos IDs.

## 24.3 Contadores 🟢 Fase 4

Para uma request:

```text
header.eligibleTotal
progress.eligibleTotal
plan.eligibleSources.count
```

devem ser iguais.

Se o fetch for amostrado:

```text
progress denominator = scheduledTotal
```

## 24.4 Publicação 🟢 Fase 3

```text
items.count == cards.count
items IDs == card IDs
todas as presentations são terminais
```

## 24.5 Concorrência 🟡 Fase 5

* troca rápida de português para francês;
* troca de taxonomia durante fetch;
* Clear Filters durante loading;
* shake durante filter reload;
* abrir Source View durante refresh do feed principal;
* fechar uma sheet enquanto cards estão sendo preparados.

Somente a session ativa pode publicar.

## 24.6 Empty state 🟢 Fase 4

* cache vazio, rede em andamento: preparing;
* cache vazio, fetch parcial: preparing;
* fetch falhou com snapshot anterior: failed com snapshot preservado;
* operação concluída sem itens: empty;
* zero sources elegíveis: empty com razão específica.

## 24.7 Onboarding 🟢 Fase 5

* candidato, preview e feed final usam o mesmo feature extraction;
* mesmos weights produzem mesmo ranking base;
* mix é determinístico com seed de teste;
* discovery share é respeitado dentro da tolerância;
* alterar preferência por imagem não altera source eligibility.

## 24.8 Bugs relatados 🟢 Fase 0 (fixtures) + 🟢 Fase 3 (correção)

### Português + Technology and Science

```text
topo
loading
fetch
cache
resultado
```

usam a mesma lista de sources.

### Filtro inicialmente sem imagens

Nenhum item é publicado sem presentation terminal.

### Shake

Um feed válido não se torna empty por causa de um refresh parcial.

### Clear All Filters

Uma única request é criada e publicada.

### Source View

Primeira página aparece somente depois de seus cards estarem preparados.

---

# 25. Testes do caminho real de produção

Os testes atuais frequentemente criam:

```swift
FeedStore(inMemory: true)
```

Mas o código desativa o prepared pipeline em in-memory mode.

Criar uma configuração injetável:

```swift
struct FeedStoreConfiguration {
    let persistence: PersistenceMode
    let preparedPipelineEnabled: Bool
    let selectionEngineEnabled: Bool
}
```

Deve ser possível executar:

```text
SQLite temporário
+
prepared pipeline ligado
+
unified selection engine ligado
```

dentro dos testes.

Sem isso, os testes continuam validando um caminho diferente do aplicativo real.

---

# 26. Observabilidade

Cada sessão deve emitir um trace:

```text
Selection ID
Surface
Source universe policy
Catalog total
Enabled total
Eligible total
Scheduled total
Cached contributors
Network contributors
Item candidates
Items after eligibility
Items after ranking
Items after mix
Cards prepared
Published cards
Terminal state
Elapsed time
```

Também registrar um hash ordenado de `eligibleSourceIDs`.

Se topo e fetch apresentarem hashes diferentes, o erro fica imediatamente visível.

---

# 27. Sequência recomendada de PRs

```text
PR 1
Modelos: SourceID, SelectionRequest, ItemRuleSet, RankingProfile,
MixPolicy, SelectionMetrics, FeedSnapshot, SelectionState + testes puros.
Inclui auditoria Sendable em FeedItem, FeedSource, PreparedFeedCard.

PR 2
SourceScopeResolver + shadow comparison (flag: unifiedSelectionShadow).
Unificação ou documentação explícita da divergência normalizeURL vs canonicalURLKey.

PR 3
ItemRuleSet + SQLItemRuleCompiler + InMemoryItemRuleEvaluator + testes de paridade.
Inclui ContentFilterStore no ItemCriteria e caches de mood/content filter nos evaluators.

PR 4
SelectionMetrics + SelectionState + nova UI de loading/empty (flag: unifiedSelectionState).
Migração de header, initial loading, filtering, refreshing, empty state, error state.
A UI deixa de calcular totais diretamente de TaxonomyStore.feedCount, activeSources.count, etc.

PR 5
SelectionSession no feed principal (flag: unifiedSelectionMainFeed).
Adapter para CardPreparationCoordinator, AdaptiveScheduler, Reservoir.

PR 6
Refresh, shake e Reset Feed Filters.
Substitui setPreset(.everything) + clearAllFilters() por operação única.

PR 7
RankingEngine + adapter para PresetScorer (flag: unifiedSelectionRankingMix).
CandidateScore com breakdown de componentes.

PR 8
MixAllocator + adapter para Reservoir (flag: unifiedSelectionRankingMix).

PR 9
Onboarding, preview e Curated Feed (flag: unifiedSelectionOnboarding).
CuratedProfileRankingAdapter, CuratedProfileMixAdapter, OnboardingShowcasePolicy.
Onboarding não altera activeLanguages globalmente.

PR 10
Source, Collection, Bookmarks e Last Clicked (flag: unifiedSelectionSurfaces).
Cada tela com sua própria SelectionSession. Cards com presentation terminal.

PR 11
Search, Smart Feed e What's New (flags: unifiedSelectionSearchSmart,
unifiedSelectionWhatsNew).
Smart Feed armazena request serializável, remove matchers paralelos.

PR 12
Remoção do legado (flag: unifiedSelectionLegacyRemoved).
Enforcement de arquitetura via CI (proibição de acesso direto a registry.enabledSources,
fetcher.fetch, setVisibleItems, CardPreparationCoordinator fora dos adapters aprovados).
```

Não misturar essas fases num único commit.

---

# 28. Instruções obrigatórias para Claude Code

1. Não corrigir os bugs relatados com condições específicas antes de introduzir os modelos da Fase 1.
   Fixtures sim, correções não.

2. Não criar um novo helper que apenas envolva `applyFilters`.

3. Não mover todo o código atual para uma nova classe gigantesca.

4. Não migrar todas as surfaces simultaneamente. Uma surface por PR a partir da Fase 6.

5. Preservar `AdaptiveScheduler`, `Reservoir` e `CardPreparationCoordinator` inicialmente por adapters.
   O `CardPreparationCoordinator` em particular não deve ser reescrito — seu modelo de
   contiguous-prefix promotion é sofisticado e testado em produção. O adapter deve ser
   um wrapper fino que traduz `ResolvedSelectionPlan` para as chamadas existentes.

6. Toda fase deve:

   * compilar;
   * passar testes;
   * incluir testes novos (prioridade 🟢 da seção 24);
   * deixar o comportamento legado disponível pela feature flag da fase.

7. Antes de migrar uma surface, documentar:

   * request criada;
   * source policy;
   * item criteria;
   * ranking;
   * mix;
   * acquisition;
   * completion policy;
   * presentation policy.

8. Nenhuma surface pode chamar diretamente:

   * `RSSFetcher`;
   * SQLite (exceto via `SQLItemRuleCompiler`);
   * `setVisibleItems`;
   * `CardPreparationCoordinator` (exceto via `SelectionCardPreparationService`).

9. Não remover o legado antes de todas as equivalências estarem cobertas.
   A remoção é a Fase 7, não antes.

10. Divergências encontradas pelo shadow mode precisam ser classificadas como:

    * bug atual (corrigir na fase atual);
    * comportamento que deve ser preservado (adaptar o novo compiler);
    * mudança deliberada de produto (documentar e seguir em frente).

11. Usar `SourceKey` e `SourceID` do FeedEngine como identidade de source no motor de seleção.
    Não usar `String` cru para URLs de source.
    `LegacySourceURL` só deve existir como ponte transitório durante a migração.

12. O `FeedEngine` (catálogo) é a fonte de verdade para identidade de sources.
    O motor de seleção consulta o catálogo via `SelectionCatalogReading`, não acessa
    `SourceRegistry.sources` ou `TaxonomyStore.flatIndex` diretamente.

---

# 29. Análise de riscos

## 29.1 Complexidade da migração

12 PRs em 7 fases é um plano ambicioso. O shadow mode (Fase 1) será computacionalmente caro:
cada ação do usuário dispara tanto o caminho legado quanto o novo compiler. Em dispositivos
mais antigos, isso pode causar frames dropped durante a transição de filtros.

**Mitigação:** Shadow mode habilitado apenas em builds de debug/internal testing.
Feature flag `unifiedSelectionEngine` desligada em produção até a Fase 3.

## 29.2 Tamanho do `ResolvedSelectionPlan`

Se o plano captura `Set<SourceID>` com 1.427+ entradas, cada instância pode ocupar
~50-100KB. Com múltiplas sessions simultâneas (main + source sheet + search), o footprint
de memória pode ser significativo.

**Mitigação:** O plano deve usar referências imutáveis compartilhadas (copy-on-write via
`Set` já é COW). Sessions que compartilham o mesmo source scope podem compartilhar
a mesma instância do plano.

## 29.3 `SelectionSession` como actor vs `@MainActor`

O documento propõe `actor SelectionSession`, mas o código atual é `@MainActor` em toda
a pipeline. A migração para um actor separado exige:

* Conformidade `Sendable` em todos os tipos do plano
* `LookupSnapshot` já é `Sendable` (bom)
* `FeedItem`, `FeedSource`, `PreparedFeedCard` precisam de auditoria de `Sendable`
* `CardPreparationCoordinator` já é um `actor` (bom)

**Mitigação:** Fase 1 implementa os modelos como `Sendable`. Fase 3 mantém a
`SelectionSession` no `@MainActor` inicialmente, migrando para actor separado
apenas na Fase 6 quando as sessions independentes forem implementadas.

## 29.4 Preservação do `CardPreparationCoordinator`

O coordinator usa `contiguousPrefix` promotion — cards são publicados em ordem editorial
contígua, com slow items bloqueando a promoção dos itens seguintes. Este modelo é
sofisticado e testado em produção. O adapter que o encapsula precisa preservar:

* Deadline hierarchy (6s first paint, 15s runway, 30s deep)
* Memory pressure demotion (UIImage → disk-level)
* Wake-on-render-ready (CheckedContinuation)
* Runway stocks (editorial, resolved, render-ready, published-ahead)

**Mitigação:** O adapter deve ser um wrapper fino. O coordinator não deve ser reescrito
na Fase 3 — apenas sua interface de entrada/saída deve ser adaptada para receber
`ResolvedSelectionPlan` em vez de acessar o `FeedStore` diretamente.

## 29.5 Paridade SQL/in-memory

O teste de paridade é conceitualmente correto mas extremamente ambicioso dadas as
diferenças atuais entre as regras SQL e in-memory:

* SQL gera variantes de URL (HTTP/HTTPS, www, trailing slash); in-memory usa `normalizeURL`
* SQL usa `fetched_at > thirtyDayCutoffEpoch`; in-memory não tem essa regra
* SQL separa illustrated text, plain text, video, audio, forum com limites diferentes;
  in-memory aplica `applyFilters` uniformemente

**Mitigação:** A Fase 1 não deve buscar paridade com o comportamento atual bugado.
Deve definir o comportamento **correto** e testar que SQL e in-memory produzem os
mesmos resultados para esse comportamento. As divergências encontradas são bugs
a serem corrigidos, não features a serem preservadas.

## 29.6 Divergência das duas normalizações de URL

Enquanto `OPMLParser.normalizeURL()` e `CatalogIdentity.canonicalURLKey()` divergirem,
existirá uma categoria de bugs onde uma source é reconhecida por um sistema mas não
pelo outro.

**Mitigação:** Adicionar à Fase 1 a tarefa de unificar ou documentar explicitamente
a diferença. Se a unificação for muito arriscada para a Fase 1, criar um teste de
regressão que verifique que toda source no catálogo FeedEngine é alcançável pelo
`SourceID` correspondente.

---

# 30. Definition of Done

A refatoração estará concluída quando:

```text
uma ação do usuário
gera exatamente uma SelectionRequest
```

e:

```text
uma SelectionRequest
gera exatamente um ResolvedSelectionPlan
```

e o mesmo plan determina:

```text
sources elegíveis
consulta de cache
fetch
contadores
item eligibility
ranking
mix
preparação
empty state
```

Além disso:

* nenhum item cru é publicado;
* nenhuma view infere empty a partir de `items.isEmpty`;
* preview e feed curado compartilham o mesmo ranking e mix;
* Source View e Collection View usam o prepared pipeline;
* refresh preserva rollback;
* Clear Filters é atômico;
* contadores distinguem catálogo, biblioteca, elegíveis, agendadas e contribuintes;
* adicionar um novo critério, como preferência por imagens, exige criar uma policy ou signal, não uma nova pipeline.

---

# 31. Resultado arquitetural esperado

Depois da migração, o Feedmine terá quatro conceitos claramente separados:

```text
Eligibility
Pode aparecer?

Ranking
Quão cedo deve aparecer?

Mix
Qual composição queremos?

Acquisition
O que precisa ser buscado agora?
```

A apresentação será uma quinta etapa:

```text
Preparation
O card está pronto para ser exibido?
```

Essa separação permitirá adicionar:

* prioridade para conteúdos com imagem;
* proporções de vídeo, texto e podcast;
* maior diversidade regional;
* mais conteúdo independente;
* mais descoberta;
* filtros temporais;
* novos tipos de mídia;
* perfis editoriais adicionais;

sem recriar SQLite, fetch, contadores, refresh e UI para cada recurso.
