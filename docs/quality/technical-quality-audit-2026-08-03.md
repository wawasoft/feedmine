# Auditoria de Qualidade Técnica — Feedmine

**Data:** 2026-08-03
**Escopo:** Análise estática completa do repositório — app Swift, pipeline Python, testes, CI/CD, saúde do repo
**Metodologia:** Exploração da estrutura de arquivos, contagem de LOC, análise de dependências entre módulos, revisão de documentação existente, análise do histórico git recente

---

## Veredito

**O Feedmine tem uma arquitetura sólida e bem pensada, mas acumulou dívida técnica em velocidade preocupante.**

O app está funcional, os conceitos são sofisticados (reservoir com fairness interleave, pipeline de preparação de cards com promotor de prefixo contíguo, catálogo pre-compilado com identidade cross-language), e a cobertura de testes unitários é razoável. No entanto, três tendências são alarmantes:

1. **O arquivo central (`FeedStore`) cresce sem controle** — 7,204 linhas, 16 commits nos últimos 60 dias, apesar de 4 documentos diferentes pedindo sua decomposição
2. **A velocidade de churn é muito alta** — 809 commits desde julho, 48 só em agosto, com código sendo adicionado e removido em ciclos de horas (13K linhas do Selection Engine deletadas em um commit, sem nunca ter compilado)
3. **Os gates de qualidade são insuficientes** — CI roda 1 única classe de teste, Makefile mascara falhas com `|| true`, o pbxproj é frágil e manual

O risco não é o app quebrar amanhã. É a velocidade de desenvolvimento colapsar sob o peso da complexidade acumulada.

---

## 1. Visão Geral

### 1.1 O App

| Dimensão | Métrica |
|---|---:|
| Linguagem | Swift 5 (strict concurrency `complete`) |
| UI framework | SwiftUI + Observation (`@MainActor @Observable`) |
| Persistência | GRDB 7.4.0 (3 bancos SQLite separados) |
| Rede | FeedKit 9.x, Network.framework |
| Target iOS | 18.0+, iPhone only |
| Locais | 40 |
| Dependências SPM | FeedKit, GRDB (manual no pbxproj) |

### 1.2 O Repositório

| Dimensão | Métrica |
|---|---:|
| Arquivos Swift (app) | 120 |
| LOC Swift (app) | 39,485 |
| Arquivos de teste unitário | 30 (11,257 LOC) |
| Arquivos de UI test | 13 |
| Scripts Python | 185 |
| Testes Python | 42 |
| Arquivos rastreados | 2,176 |
| Tamanho do `.git` | 3.0 GB |
| Branches | 54 |
| Commits (desde julho) | 809 |
| Commits (agosto, 3 dias) | 48 |

### 1.3 Arquitetura em Alto Nível

```text
FeedmineApp
  └─ FeedScreen (1,880L)
       └─ FeedLoader (1,511L) — @Observable, orquestrador
            └─ FeedStore (7,204L) — coordenador monolítico
                 ├─ DatabaseQueue (feedmine.sqlite)
                 ├─ SourceRegistry (695L)
                 ├─ AdaptiveScheduler (438L)
                 ├─ Reservoir (612L) — buffer in-memory com fairness
                 ├─ RSSFetcher (1,378L) — actor, FeedKit
                 ├─ ImagePrefetcher + ImageCache (1,004L)
                 ├─ ReadyCardQueue (99L)
                 ├─ CardPreparationCoordinator (467L) — actor
                 ├─ FeedRunwayController — actor
                 ├─ MediaAssetStore
                 ├─ SearchEngine (398L) — FTS5
                 ├─ BookmarkStore
                 ├─ SmartFeedStore
                 ├─ CuratedFeedStore
                 ├─ SourceCollectionStore
                 ├─ UserStateStore (1,096L) — user.sqlite
                 ├─ TaxonomyStore (597L)
                 └─ NetworkMonitor

FeedEngine (não é o caminho principal de runtime):
  ├─ SQLiteCatalogStore (876L) — catalog.sqlite (118MB, read-only)
  ├─ CatalogBrowserViewModel
  ├─ CatalogIdentity — SHA256 → UInt32
  └─ Pagination — keyset

Pipeline Python (scripts/):
  ├─ Descoberta (~30 scripts, múltiplas versões)
  ├─ Curadoria (curate_opml_catalog.py, 1,368L)
  ├─ Fetch & Enriquecimento
  ├─ Identidade cross-language
  └─ Publicação (publish_catalog_update.py, sign_manifest.swift)
```

---

## 2. Avaliação por Dimensão

### 2.1 Arquitetura Geral: **Boa, com erosão visível**

**O que está bom:**
- Separação clara entre Models, Services, Views, FeedEngine
- Concorrência estruturada com `@MainActor` para estado e `actor` para I/O
- Swift 6 strict concurrency ativado (`SWIFT_STRICT_CONCURRENCY: complete`)
- Uso de `@Observable` em vez de `@Published`/`ObservableObject`
- Reservoir pattern com fairness interleave é elegante
- Pipeline de preparação de cards com promotor de prefixo contíguo é sofisticado

**O que está erodindo:**
- `FeedStore` concentra ~30 responsabilidades em um arquivo só (7,204L)
- O FeedEngine foi construído mas não alimenta a tela principal — dois caminhos de dados coexistem
- `SourceScheduler` foi deprecated em favor de `AdaptiveScheduler` mas o código legado não foi removido
- 29 arquivos do Unified Selection Engine (~13K linhas) foram deletados em um commit (`09acf5ea`, 3 ago) sem nunca ter compilado — deixando docs órfãos e pontas soltas
- `ContentView.swift` existe mas não é usado (o app vai direto para `FeedScreen`)

### 2.2 Persistência: **Sofisticada, mas frágil**

Três bancos SQLite independentes:

| Banco | Propósito | Localização | Tamanho |
|---|---|---|---|
| `feedmine.sqlite` | Conteúdo fetched (GRDB + FTS5) | Application Support | Variável |
| `user.sqlite` | Estado que sobrevive a rebuilds (bookmarks, coleções) | Application Support | Pequeno |
| `catalog.sqlite` | Catálogo pre-compilado, read-only | Bundle (tracked) | 118 MB |

**Riscos:**
- Migrações coordenadas entre 3 bancos não são atômicas
- `catalog.sqlite` com 118 MB rastreado no git — cada rebuild gera um diff binário enorme
- O contrato de identidade cross-language (Swift ↔ Python) depende de canonicalização de URL implementada em dois lugares (`OPMLParser.normalizeURL` + scripts Python). Testado via JSON vectors — se um lado mudar sem o outro, 88K sources perdem identidade

### 2.3 Rede: **Sofisticada, precisa de limites defensivos**

- `RSSFetcher` (1,378L) como actor dedicado
- `AsyncLimiter` para controle de concorrência
- `URLResolver` com probe de mídia
- `NetworkMonitor` para detecção de conectividade
- `FeedHTTPSync` para downloads

**Preocupações:**
- O review pré-publicação identificou "consumo de memória controlado por resposta remota"
- `NSAllowsArbitraryLoadsForMedia: true` no Info.plist — necessário para feeds HTTP, mas escrutinado na App Store
- Headers HTTP, timeouts, e política de retry não são configuráveis centralmente — cada componente decide

### 2.4 Concorrência: **Boa direção, migração incompleta**

**O que está correto:**
- `@MainActor` para todo estado observável da UI
- `actor` para I/O (RSSFetcher, CardPreparationCoordinator, FeedRunwayController)
- `AsyncLimiter` para controlar concorrência de rede
- `Task` com cancellation consciente no background refresh

**O que preocupa:**
- O roadmap lista: "Background actors completo — `interleave()` e `persistFetchedItems` ainda no MainActor" (Onda 4.5)
- O review pré-publicação menciona "vazamentos para o MainActor"
- `FeedLoader` faz a ponte entre MainActor e actors — zona de risco para races
- O `CuratedStarterSourceCache` é um actor privado dentro do arquivo `FeedStore.swift` — sinal de que a decomposição está sendo adiada

### 2.5 Performance: **Muito trabalhada, com pontos de dor conhecidos**

- Reservoir com fairness interleave previne dominância de fonte única
- Runway controller com histerese controla pressão em 4 "stocks"
- Card preparation pipeline resolve imagens antes do display
- ImageCache em duas camadas (memória + disco) com MemoryImageCache + DiskImageCache
- Podcast counts cacheados ("not on every access")

**Pontos de dor:**
- Startup dominado por parse de OPML (1919 arquivos, documentado em memória de investigação)
- `FeedScreen` com ~40 `@State` properties — re-renderização potencialmente excessiva
- `catalog.sqlite` de 118 MB carregado no bundle — impacto no download da App Store e no first launch

---

## 3. Análise Profunda: FeedStore.swift

Com 7,204 linhas, `FeedStore` é o maior arquivo do app por uma margem de 4.7× sobre o segundo colocado (`FeedScreen`, 1,880L). É o centro de gravidade de toda a arquitetura.

### 3.1 O que ele contém

Cerca de 30 seções `// MARK:`:

- Subcomponents (db, registry, scheduler, reservoir, fetcher, prefetcher, cardQueue, etc.)
- Prepared feed pipeline (coordinator, runway, media assets)
- Public state (~25 propriedades observáveis)
- Filter state (bidirecional: UI ↔ Settings)
- Preset state
- Display phase management
- Startup/runway progress
- visibleItems management
- applyFilters (in-memory filtering)
- immediatelyCullVisibleItems
- Search (FTS5)
- Curated feeds
- Smart feeds
- Bookmarks
- Collections
- Migration
- Maintenance
- Podcast counts
- Background refresh coordination

### 3.2 Por que isso é um problema

1. **Toda mudança toca o FeedStore.** Com 16 commits nos últimos 60 dias, é o arquivo mais modificado do app. Cada alteração arrisca colateral em funcionalidades não relacionadas.

2. **Testar é quase impossível.** O inicializador cria dependências reais (DatabaseQueue, RSSFetcher, ImagePrefetcher, etc.). Testes de integração do FeedStore não existem (roadmap 5.6).

3. **O estado público é enorme.** 25+ propriedades `private(set) var` expostas à UI. É difícil saber quais realmente precisam ser `@Observable` e quais são derivadas.

4. **O plano de decomposição existe mas não é executado.** Quatro documentos diferentes pedem a decomposição: `FeedEngineMigration.md`, `UnifiedSelectionArchitecture.md`, `loop-focus-areas.md`, `roadmap.md`. O arquivo só cresceu desde então.

5. **Há lógicas específicas de superfície dentro dele.** Search, bookmarks, curated feeds, smart feeds, collections — cada uma deveria ser um adapter separado (como o Unified Selection previa), mas estão todas implementadas inline.

### 3.3 Caminho de decomposição sugerido

```text
FeedStore (7,204L)
  ├─ Extrair → FeedDisplayState (visibleItems, visibleCards, displayPhase, generation)
  ├─ Extrair → FilterEngine (bidirectional filter state, applyFilters, culling)
  ├─ Extrair → FeedRunwayOrchestrator (startup progress, runway control, pipeline task)
  ├─ Extrair → SearchAdapter (FTS5 queries, search generation)
  ├─ Extrair → BookmarkAdapter (bookmark CRUD, bookmark visibility)
  ├─ Extrair → CollectionAdapter (collection CRUD, collection visibility)
  ├─ Extrair → SmartFeedAdapter (smart feed matching)
  └─ Manter → FeedStore (coordenação, DI, database ownership)
```

---

## 4. Camada de Views

### 4.1 Dimensões

| View | Linhas | Preocupação |
|---|---|---|
| `FeedScreen.swift` | 1,880 | View principal — ~40 `@State`, sheet chain, navigation path |
| `CuratedOnboardingView.swift` | 949 | Onboarding complexo com preferências |
| `CollectionManagementView.swift` | 706 | Gestão de coleções |
| `FeedItemCardView.swift` | 509 | Card de feed com imagem |
| `AddFeedView.swift` | 455 | Importação de feeds |
| `SettingsSheetView.swift` | 435 | Configurações |

### 4.2 Problemas identificados

- **`FeedScreen` é grande demais** para uma view SwiftUI. Lógica de negócio (contador de sources, progresso de startup, fases de display) está misturada com layout.
- **Sheet chain:** `FeedScreen` apresenta múltiplos sheets sequenciais — o estado de qual sheet está aberto é frágil
- **Re-renderização:** Com ~40 `@State` properties e vários `@Environment` objects, qualquer mudança de estado pode disparar re-renderização da árvore inteira
- **Bugs de UI confirmados:** Três bugs identificados no review de filtros/shake — troca de filtro mostra card solitário, shake mostra "No articles" falso, Source View publica itens sem pipeline de imagem

---

## 5. FeedEngine (Catálogo)

O FeedEngine é uma segunda stack de dados, construída para substituir o pipeline legado, mas ainda não é o caminho principal de runtime.

### 5.1 Estado atual

| Componente | Status |
|---|---|
| `SQLiteCatalogStore` | Funcional — compila catálogo de OPMLs |
| `CatalogIdentity` | Contrato cross-language estável, testado via JSON vectors |
| `CatalogBrowserViewModel` | Funcional — browse paginado |
| `Pagination` | Keyset pagination implementado |
| `CatalogExploreView` | View de debug, não é a experiência principal |
| `CatalogUpdateService` | Atualização assinada (Ed25519), versionada |

### 5.2 Riscos

- **Caminho duplo:** Dados fluem pelo pipeline legado (OPML → FeedStore → SQLite → Reservoir → UI) e pelo FeedEngine (OPML → catalog.sqlite → SQLiteCatalogStore → CatalogExploreView). Manter os dois em sincronia é custoso.
- **catalog.sqlite no repo:** 118 MB rastreado. Cada rebuild gera diff binário enorme. Git LFS deveria ser considerado.
- **Concorrência de acesso:** catalog.sqlite é aberto read-only pelo app, mas o build_catalog.py pode estar rodando simultaneamente em desenvolvimento

---

## 6. Pipeline Python

### 6.1 Estrutura

| Categoria | Scripts | Destaques |
|---|---|---|
| Descoberta | ~30 | 7 versões de `discover_artist_blogs` (v2, v3, v4, broad, batch, fast, zero) |
| Curadoria | ~15 | `curate_opml_catalog.py` (1,368L), `curate_feeds.py` (811L) |
| Fetch | ~10 | `fetch_all_feeds.py` (936L) + `fetch_all_feeds_v2.py` (1,350L) |
| Enriquecimento | ~10 | DeepSeek, detecção de idioma, extração de email |
| Merge/Integração | ~15 | `merge_curated_to_production.py`, `merge_writer_feeds.py`, etc. |
| Scrapers | ~10 | youtubers.me, YouTube, Wikipedia, museus, universidades |
| Testes | 42 | `test_curate_opml_catalog.py` é o maior (16K) |
| Identidade | ~5 | `catalog_identity.py`, `migrate_catalog_identity.py` |

### 6.2 Problemas

1. **Múltiplas versões do mesmo script:**
   - `discover_artist_blogs.py` + `_v2.py` + `_v3.py` + `_v4.py` + `_broad.py` + `_batch.py` + `_fast.py` + `_zero.py` = 8 arquivos
   - `fetch_all_feeds.py` + `fetch_all_feeds_v2.py` = 2 versões coexistindo
   - **Causa provável:** Refatorações incompletas. A versão nova foi escrita mas a antiga nunca foi removida.

2. **Monólitos Python:**
   - `curate_opml_catalog.py` (1,368L) — orquestrador central da curadoria
   - `reconcile_feed_corpus.py` (700L+) — lógica de reconciliação complexa
   - `promote_watch_history_channels.py` (700L+) — integração YouTube

3. **Testes inconsistentes:**
   - 42 arquivos de teste para 185 scripts (23% de cobertura de arquivo)
   - Alguns scripts grandes sem teste correspondente
   - Editorial CI roda pytest mas engole erros no audit step (`|| true`)

4. **Dados editoriais rastreados:**
   - `editorial/feed-curation/` contém CSVs de 7-9 MB com decisões de placement
   - `source-disposition-ledger.csv.gz` (9.2 MB), `source-placement-decisions.csv.gz` (7.1 MB)
   - Dados que mudam frequentemente não deveriam ser rastreados em git

---

## 7. Infraestrutura de Testes

### 7.1 Cobertura atual

| Camada | Arquivos | LOC | Cobertura |
|---|---|---|---|
| Unit tests (Swift) | 30 | 11,257 | Boa para componentes isolados |
| UI tests | 13 | — | 3 cenários principais |
| Test plans | 5 `.xctestplan` | — | Smoke, Release, Perf, Accessibility, Usability |
| Python tests | 42 | — | 23% dos scripts cobertos |

### 7.2 O que está bem coberto

- `ReservoirTests` — fairness interleave, buffer ceilings
- `AdaptiveSchedulerTests` — scheduling adaptativo
- `CatalogIdentityContractTests` — único teste que roda em CI, cross-language
- `SQLiteCatalogStoreTests` — compilação e queries do catálogo
- `FeedEngineBoundaryTests` — limites de paginação

### 7.3 O que NÃO está coberto

| Área | Status | Referência |
|---|---|---|
| FeedStore integration | Não iniciado | Roadmap 5.6 |
| Filter system (combinations, debounce, races) | Não iniciado | Roadmap 1.5 |
| ImportPipeline | Não iniciado | Roadmap 3.3 |
| CardPreparationCoordinator | Não iniciado | Pipeline novo |
| FeedRunwayController | Não iniciado | Pipeline novo |
| Background refresh | Não iniciado | — |
| CatalogUpdateService | Não iniciado | — |

### 7.4 Qualidade dos testes existentes

- Page-object pattern nos UI tests (`ScreenObjects.swift`, `AppLauncher.swift`)
- Fixtures organizadas: `GoldenFeeds/`, `DatabaseSnapshots/`, `CatalogManifests/`
- Test plans separados por preocupação (Smoke, Release, Performance, Accessibility, Usability)
- **Problema:** PerformanceBaselines/, FixtureGenerator/, Tests/ são diretórios vazios — deveriam ser removidos ou populados

---

## 8. Build, CI e Release

### 8.1 Estado atual

| Componente | Situação |
|---|---|
| iOS CI | Roda **apenas** `CatalogIdentityContractTests` |
| Editorial CI | Ubuntu, `compileall` + `pytest scripts/`, audit com `\|\| true` |
| Makefile | Build/install/launch em device real, archive com tags |
| pbxproj | **Manual** — 193 file refs, GRDB linkado à mão, não pode ser regenerado |
| project.yml | Marcado "REFERENCE ONLY" — não usar com xcodegen |
| SwiftLint | Não configurado (roadmap 5.2) |
| Crash reporting | Não configurado (roadmap 5.3) |
| Analytics | Não configurado (roadmap 5.4) |

### 8.2 Problemas críticos

1. **CI não pega regressões.** 1 classe de teste em 30. Bugs introduzidos em FeedStore, FeedLoader, RSSFetcher ou qualquer view NUNCA serão pegos pelo CI atual.

2. **Makefile mascara falhas.** `pipefail` ausente + `|| true` nos targets de teste = build pode falhar e o comando reportar sucesso. Isso já foi documentado no review pré-publicação (P0-01) e aparentemente corrigido nos commits recentes, mas merece verificação.

3. **pbxproj é frágil.** Qualquer novo arquivo Swift requer edição manual de 200+ linhas no diff do pbxproj. Isso é propenso a erros e torna conflitos de merge frequentes.

4. **Sem automação de release.** Sem Fastlane, sem signing automation além de `-allowProvisioningUpdates`. O processo de archive é manual e depende do Makefile.

### 8.3 Corrigido recentemente?

Os commits de 3 de agosto (`fix: persistence, producers, publishing, and CI gates`) sugerem que vários problemas de CI/build foram endereçados. O report "all 13/13 gates verified" indica um ciclo de verificação. Mas sem rodar o CI real, não é possível confirmar.

---

## 9. Saúde do Repositório

### 9.1 Sinais de alerta

| Problema | Evidência |
|---|---|
| **Git inchado** | `.git` com 3.0 GB — binários grandes no histórico |
| **Binários rastreados** | `catalog.sqlite` 118MB, `youtube_channels_kaggle.csv` 92MB, JSON reports 36MB |
| **Branches zumbis** | 54 branches, incluindo 10+ `worktree-agent-*` branches de sessões passadas |
| **Worktree ativo** | `onboarding-redesign` — 14/19 itens fixados, 5 pendentes, não mergeado |
| **Diretórios vazios** | `Tests/`, `FixtureGenerator/`, `PerformanceBaselines/` — existem mas estão vazios |
| **Docs desatualizados** | README diz 34,243 sources; catálogo atual tem 88,084. `FeedmineCompletionPlan.md` snapshot de 17 de julho |
| **Arquivos de processo no repo** | `.loop_progress.json` (90KB), `.superpowers/sdd/`, `.pytest_cache/` |
| **Mistura de idiomas** | Documentação em PT e EN sem critério claro |

### 9.2 O que fazer

```bash
# Limpeza recomendada (cautelosa, com confirmação):
git remote prune origin                    # Remover refs de branches deletados
git branch -d $(git branch --merged main) # Remover branches merged
# Remover branches worktree-agent-* antigos
# Adicionar catalog.sqlite ao Git LFS
# Adicionar *.csv.gz grande ao Git LFS
# Rodar git gc --aggressive --prune=now
```

---

## 10. Matriz de Risco

| # | Área | Severidade | Probabilidade | Impacto | Risco |
|---|---|---|---|---|---|
| 1 | FeedStore crescendo sem controle | Crítica | **Certa** — Já acontece | Velocidade de dev tende a zero | 🔴🔴🔴 |
| 2 | CI não cobre app principal | Crítica | **Alta** — Regressão já é possível | Bugs em produção sem detecção | 🔴🔴🔴 |
| 3 | Identidade cross-language quebrar | Crítica | **Baixa** — Testado com vectors | 88K sources perdem identidade | 🔴🔴 |
| 4 | Pipeline de cards publicar imagens quebradas | Alta | **Média** — Bugs conhecidos | UX degradada para todos os usuários | 🔴🔴 |
| 5 | pbxproj corrompido por merge | Alta | **Alta** — 54 branches, manual | App não compila | 🔴🔴 |
| 6 | Makefile mascarar falha de build | Alta | **Baixa** — Possivelmente corrigido | Release quebrado na App Store | 🔴🔴 |
| 7 | Catalog.sqlite de 118MB crescer | Média | **Certa** — Catálogo expande | App Store rejeita por tamanho | 🟡🟡 |
| 8 | Dívida técnica dos scripts Python | Média | **Alta** — 8 versões coexistem | Bugs no catálogo para todos os usuários | 🟡🟡 |
| 9 | Docs desatualizados enganarem decisão | Baixa | **Alta** — README e planos antigos | Tempo perdido em premissas erradas | 🟡 |
| 10 | 3 bancos SQLite terem migração dessincronizada | Média | **Baixa** — Schema estável | Perda de dados do usuário | 🟡 |

---

## 11. Recomendações Priorizadas

### 🔴 Bloqueadores — Fazer antes de qualquer feature nova

| # | Ação | Esforço | Impacto |
|---|---|---|---|
| **R1** | Decompor `FeedStore` em 4-5 componentes | 3-5 dias | Velocidade de dev 2×, testabilidade |
| **R2** | Expandir CI para rodar teste completo (Smoke plan) | 1 dia | Regressões pegas automaticamente |
| **R3** | Remover `|| true` e adicionar `pipefail` no Makefile | 30 min | Builds quebrados não passam despercebidos |
| **R4** | Migrar `catalog.sqlite` e CSVs grandes para Git LFS | 2h | Repo respirável, clones rápidos |

### 🟠 Importante — Fazer no próximo mês

| # | Ação | Esforço | Impacto |
|---|---|---|---|
| **R5** | Unificar pipeline de resolução de imagens (Source View usa o mesmo que FeedScreen) | 1-2 dias | Bugs de imagem resolvidos em todas as superfícies |
| **R6** | Remover versões antigas de scripts Python (`discover_artist_blogs_v2/v3/v4`, `fetch_all_feeds.py`) | 1 dia | Pipeline Python auditável |
| **R7** | Extrair lógicas de Search/Bookmarks/Collections do `FeedStore` para adapters | 2-3 dias | FeedStore menor, responsabilidades claras |
| **R8** | Limpar branches zumbis e diretórios vazios | 30 min | Repo navegável |
| **R9** | Atualizar README e docs com métricas atuais | 2h | Novos devs não partem de premissas erradas |

### 🟡 Melhorias contínuas

| # | Ação | Esforço | Impacto |
|---|---|---|---|
| **R10** | Adicionar SwiftLint e corrigir warnings | 2-3 dias | Consistência de código |
| **R11** | Completar migração do FeedEngine para ser o caminho principal de runtime | 1-2 semanas | Elimina caminho duplo de dados |
| **R12** | Adicionar testes de integração FeedStore + FeedLoader | 2-3 dias | Cobertura do core do app |
| **R13** | Configurar Fastlane para automação de screenshots e release | 1-2 dias | Processo de release profissional |
| **R14** | Adicionar crash reporting (Sentry/Crashlytics) | 1 dia | Visibilidade de crashes em produção |
| **R15** | Unificar idioma da documentação (PT ou EN) | 2-3h | Consistência para contribuidores |

---

## 12. Apêndice: Rankings de Arquivos

### Top 15 Swift — Services

| # | Arquivo | Linhas |
|---|---|---|
| 1 | `FeedStore.swift` | 7,204 |
| 2 | `FeedLoader.swift` | 1,511 |
| 3 | `RSSFetcher.swift` | 1,378 |
| 4 | `CuratedPreferenceEngine.swift` | 1,103 |
| 5 | `UserStateStore.swift` | 1,096 |
| 6 | `ImageCache.swift` | 1,004 |
| 7 | `OPMLParser.swift` | 763 |
| 8 | `SourceRegistry.swift` | 695 |
| 9 | `Reservoir.swift` | 612 |
| 10 | `TaxonomyStore.swift` | 597 |
| 11 | `ExportEngine.swift` | 519 |
| 12 | `CatalogUpdateService.swift` | 494 |
| 13 | `CardPreparationCoordinator.swift` | 467 |
| 14 | `URLResolver.swift` | 454 |
| 15 | `AdaptiveScheduler.swift` | 438 |

### Top 15 Swift — Views

| # | Arquivo | Linhas |
|---|---|---|
| 1 | `FeedScreen.swift` | 1,880 |
| 2 | `CuratedOnboardingView.swift` | 949 |
| 3 | `CollectionManagementView.swift` | 706 |
| 4 | `FeedItemCardView.swift` | 509 |
| 5 | `AddFeedView.swift` | 455 |
| 6 | `SettingsSheetView.swift` | 435 |
| 7 | `CuratedFeedInspectorView.swift` | 412 |
| 8 | `CatalogExploreView.swift` | 365 |
| 9 | `ExportView.swift` | 327 |
| 10 | `SourceManagementView.swift` | 289 |

### Top 10 Python — Scripts

| # | Arquivo | Linhas |
|---|---|---|
| 1 | `curate_opml_catalog.py` | 1,368 |
| 2 | `discover_artist_blogs.py` | 1,100+ |
| 3 | `fetch_all_feeds_v2.py` | 1,350 |
| 4 | `fetch_all_feeds.py` | 936 |
| 5 | `curate_feeds.py` | 811 |
| 6 | `reconcile_feed_corpus.py` | 700+ |
| 7 | `promote_watch_history_channels.py` | 700+ |
| 8 | `discover_writer_blogs.py` | 700+ |
| 9 | `discover_journalist_blogs.py` | 700+ |
| 10 | `build_catalog.py` | 603 |

---

## 13. Notas Metodológicas

Esta auditoria foi conduzida por análise estática do repositório em 2026-08-03. As seguintes limitações se aplicam:

- **Sem compilação:** O projeto não foi compilado. Problemas de build podem existir e não foram detectados.
- **Sem execução de testes:** Nenhum teste Swift ou Python foi executado. A cobertura reportada é baseada na existência de arquivos de teste, não em métricas de cobertura reais.
- **Sem profiling:** Conclusões sobre performance são baseadas em documentação existente e análise de código, não em Instruments ou benchmarks.
- **Sem revisão linha a linha:** Esta é uma auditoria de arquitetura e saúde do repositório. Bugs lógicos específicos não foram procurados.
- **Dados de agosto:** As métricas de agosto cobrem apenas 3 dias (1-3 de agosto de 2026).

Para uma avaliação completa, recomenda-se complementar esta auditoria com:
1. Code review detalhado do `FeedStore.swift` (prioridade máxima)
2. Execução completa dos 5 test plans em device real
3. Profiling de startup com Instruments (Time Profiler + Allocations)
4. Análise de tamanho do bundle com `xcrun assetutil`
