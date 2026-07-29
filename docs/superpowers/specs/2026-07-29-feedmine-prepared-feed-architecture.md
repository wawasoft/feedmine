# Feedmine — Plano detalhado de migração para uma arquitetura de feed pré-preparado

## 1. Objetivo da migração

Modificar a arquitetura do Feedmine para que o aplicativo funcione segundo este princípio:

> O backend trabalha antecipadamente e agressivamente para que a interface permaneça silenciosa, estável, suave e previsível.

A interface não deve disputar uma corrida com a rede, o cache, o parser ou o decodificador de imagens.

Quando um card for entregue ao scrolling principal, ele já deve estar em um estado visual terminal:

* imagem definitiva disponível e decodificada;
* placeholder definitivo;
* layout definitivamente sem imagem.

Depois da publicação, o card não poderá:

* iniciar download;
* consultar disco;
* analisar a página do artigo;
* trocar placeholder por imagem;
* substituir uma imagem por outra;
* alterar sua altura por causa de mídia;
* mudar de layout;
* desaparecer porque sua imagem falhou;
* alterar sua posição devido à velocidade do servidor.

O objetivo não é apenas implementar prefetch. É mudar a fronteira de publicação:

```text
ARQUITETURA ATUAL

selecionar item
→ ordenar
→ publicar no scrolling
→ resolver imagem


ARQUITETURA DESEJADA

selecionar item
→ ordenar
→ preparar apresentação
→ tornar o card render-ready
→ publicar no scrolling
```

---

# 2. Contratos arquiteturais não negociáveis

Toda implementação deverá respeitar simultaneamente os contratos abaixo.

## 2.1 A ordem editorial é independente da mídia

A velocidade de uma CDN, de um site ou de uma página Open Graph nunca poderá influenciar:

* a posição do item;
* sua relevância;
* sua permanência no feed;
* a distância entre duas fontes;
* o balanceamento de países;
* o balanceamento de tipos de mídia;
* o interleave;
* o preset;
* a curadoria.

Um item lento não deve ser eliminado ou ultrapassado silenciosamente.

Itens posteriores podem ser preparados em paralelo, mas a promoção respeitará a ordem editorial.

## 2.2 Nenhum estado intermediário cruza a fronteira da UI

Não poderão existir no feed publicado estados equivalentes a:

```text
loading
resolving
downloading
waitingForCache
waitingForArticle
upgrading
retrying
unknown
```

Esses estados poderão existir somente dentro do backend.

A interface receberá apenas resultados terminais.

## 2.3 Timeout encerra a preparação, não transfere trabalho para a view

Quando o orçamento de preparação de um item terminar, o sistema deverá produzir imediatamente uma decisão terminal:

```text
imagem válida
ou
placeholder final
ou
layout text-only
```

O timeout não poderá significar:

```text
publique agora e deixe a view tentar novamente
```

## 2.4 Um card lento não bloqueia todo o backend

O backend deverá continuar preparando os itens posteriores em paralelo.

Entretanto, itens posteriores que terminarem antes deverão permanecer no runway pronto até que todas as posições anteriores também estejam em estado terminal.

A promoção deve ocorrer pelo maior prefixo contíguo pronto.

Exemplo:

```text
Ordem editorial:

1  2  3  4  5  6  7  8

Resultados:

✓  ✓  ... ✓  ✓  ✓  ✓  ✓
       ↑
       item 3 ainda preparando
```

Os itens 4 a 8 podem estar completamente preparados, mas o prefixo publicável ainda é:

```text
1, 2
```

Quando o item 3 encontrar uma imagem ou atingir sua decisão terminal de fallback:

```text
1, 2, 3, 4, 5, 6, 7, 8
```

podem ser promovidos juntos.

Isso preserva a ordem sem serializar todo o trabalho.

## 2.5 A UI nunca inicia trabalho de mídia

No feed principal, são proibidos:

* `.task` para carregar imagem;
* `URLSession` iniciado por view;
* leitura de disco iniciada por view;
* retry em `onAppear`;
* resolução Open Graph iniciada por view;
* upgrade de imagem iniciado por view;
* polling iniciado por view.

## 2.6 O Main Actor só publica estado pequeno e pronto

O Main Actor pode:

* substituir ou acrescentar um lote pequeno de cards preparados;
* atualizar read/bookmark de um card;
* atualizar contadores observáveis;
* responder a ações da interface;
* informar ao backend a posição atual do usuário.

O Main Actor não pode:

* fazer interleave pesado;
* ler arquivos de imagem;
* decodificar imagens;
* analisar HTML;
* fazer fetch;
* esperar rede;
* fazer polling;
* calcular grandes candidate pools;
* preparar dezenas de apresentações;
* manter loops de produção.

## 2.7 "Feed é sagrado" continua sendo a regra superior

A migração não pode provocar:

* reordenação de conteúdo próximo ao usuário;
* remoção da cabeça do feed;
* salto de scroll;
* mudança de IDs publicados;
* limpeza de cards que o usuário já começou a ler;
* nova aplicação de filtros com semântica diferente;
* perda do comportamento de collections, Smart Feeds ou bookmarks.

---

# 3. Diagnóstico da arquitetura atual

## 3.1 O `FeedStore` é o orquestrador real

O `FeedStore` é `@MainActor`, observável e concentra:

* banco de conteúdo;
* registro de fontes;
* scheduler;
* reservoir;
* fetch;
* prefetch;
* filtros;
* taxonomy;
* presets;
* collections;
* Smart Feeds;
* bookmarks;
* busca;
* What's New;
* estado de leitura;
* estado de consumo;
* lifecycle do aplicativo.

Ele também é hoje o proprietário de:

```swift
private(set) var visibleItems: [FeedItem]
```

Isso significa que o objeto publicado na UI é um item de conteúdo, não uma apresentação pronta.

## 3.2 A seleção editorial já é sofisticada e deve ser preservada

`applyFilters` centraliza uma combinação importante de regras:

* enablement de fonte;
* allowlist de collection;
* Smart Feed;
* histórico de cliques;
* itens consumidos;
* região;
* taxonomy;
* idioma;
* tipo;
* mood;
* filtros de conteúdo.

Essa lógica não deverá ser duplicada dentro da preparação visual.

O preparador de cards receberá a ordem já decidida e não terá autoridade para reinterpretar elegibilidade.

## 3.3 O reservoir atual é editorial, mas também possui estado "visível"

O `Reservoir` mantém:

```swift
visibleItems
reservoir
```

e possui limites atuais de:

```text
pageSize:             20
maxBuffer:           300
lowWatermark:         80
progressive target:  240
max reservoir:       500
```

Seu interleave protege diversidade e estabilidade da sequência. Ele não reintercala continuamente o começo do reservoir, justamente para não mover conteúdo que o usuário está prestes a alcançar.

Esse comportamento editorial deve continuar existindo.

O problema é que `moveToVisible` atualmente significa simultaneamente:

```text
saiu do backlog editorial
e
foi publicado para a UI
```

Esses eventos precisam ser separados.

## 3.4 O prefetch atual não é uma garantia de prontidão

O `FeedStore` inicia prefetch em uma `Task` e retorna sem aguardar.

Na paginação atual, a ordem efetiva é:

```text
prefetchUpcoming()
reservoir.moveToVisible()
setVisibleItems()
```

O comentário do próprio código reconhece que as células visíveis ainda iniciam seus próprios carregamentos.

Portanto, o prefetch atual aquece o cache oportunisticamente, mas não funciona como barreira de publicação.

## 3.5 A UI real ainda carrega imagens

O feed principal usa:

```text
FeedScreen
→ FeedItemView
→ FeedItemCardView ou FeedItemRowView
→ CachedAsyncImage
```

O `FeedScreen` publica `FeedItem` em um `LazyVStack` e chama `loadMoreIfNeeded` durante `onAppear`.

Tanto o layout de cards quanto o layout de lista ainda utilizam `CachedAsyncImage`.

Logo, remover `CachedAsyncImage` apenas de `FeedItemCardView` seria insuficiente. O modo list também precisa ser migrado.

## 3.6 A paginação ainda é reativa ao usuário

Quando o usuário chega a cinco itens do final:

```swift
loadMoreIfNeeded
→ applyUpdate(.append)
→ moveToVisible
```

Se o reservoir estiver abaixo de 80 itens, a própria ação de scroll aciona `fetchNextBatch`.

O comportamento desejado é diferente:

```text
scroll
→ consome estoque pronto
→ informa a taxa de consumo
```

O scroll não deve ser o mecanismo principal que inicia fetch e preparação.

## 3.7 Existe uma implementação parcial desconectada

O repositório já contém:

* `FeedCardPresentation`;
* `CardPreparationPipeline`;
* `ReadyCardQueue`;
* `ImageLoader`;
* `PreparedCardImage`.

Entretanto, essa arquitetura ainda não está conectada ao fluxo principal.

Além disso, a implementação atual desses componentes não deve ser integrada sem correções.

### Problemas do `ReadyCardQueue`

O objeto é `@MainActor`, mantém arrays e faz polling a cada 100 ms.

O timeout apenas encerra a espera; ele não transforma os cards ainda pendentes em resultados terminais.

Também não há:

* generation de filtro;
* generation de preset;
* identidade do contexto;
* cursor editorial;
* prioridade por distância;
* high/low watermarks;
* backpressure;
* cancelamento por contexto;
* garantia de que a contagem aguardada pertence ao lote correto.

Esse objeto deverá ser substituído por um coordenador de runway, não apenas conectado.

### Problemas do `FeedCardPresentation`

A estrutura atual armazena diretamente:

```swift
case image(UIImage)
```

e duplica `isRead` e `isBookmarked` como snapshots imutáveis.

Isso cria dois problemas:

1. Um runway profundo com centenas de `UIImage` pode consumir memória excessiva.
2. Alterar bookmark ou read state passa a exigir reconstrução da apresentação ou divergência entre estados.

A mídia imutável deve ser separada do estado interativo mutável.

### Problemas do `CardPreparationPipeline`

A implementação atual:

* prepara lotes de até oito imagens;
* retorna tudo somente ao final;
* armazena `UIImage` no resultado;
* considera quase qualquer página HTTP como potencialmente ilustrada;
* converte toda falha em `.placeholder`;
* converte `.placeholder` em `.textOnly`.

Ela ainda não possui:

* prioridades;
* deadlines individuais;
* prefixo contíguo;
* persistência do estado da resolução;
* distinção entre falha transitória e ausência confirmada;
* estágio "resolvido no disco" separado de "decodificado e pronto".

## 3.8 Há inconsistência entre código e testes

Os testes de `ReadyCardQueue` instanciam `FeedItemCardView` com um parâmetro `presentation`, mas a implementação atual da view ainda não possui essa API e continua usando `CachedAsyncImage`.

Portanto, a primeira etapa deverá obrigatoriamente estabelecer um baseline compilável. Não se deve construir uma migração ampla sobre uma árvore já parcialmente integrada.

## 3.9 O script de invariantes não é suficiente

O script atual:

* usa caminho absoluto de uma máquina específica;
* faz apenas verificações por `grep`;
* pode validar arquivos desconectados;
* não prova que o feed real usa a nova arquitetura.

Ele deverá permanecer, no máximo, como verificação auxiliar.

A garantia real virá de testes de integração e instrumentação de rede.

---

# 4. Arquitetura de destino

A arquitetura final deverá possuir cinco camadas explicitamente separadas.

```text
┌─────────────────────────────────────────────┐
│ 1. CONTENT LAKE — SQLite                    │
│ conteúdo persistido, amplo e diversificado  │
└──────────────────────┬──────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│ 2. EDITORIAL BACKLOG                        │
│ elegibilidade + filtros + interleave        │
│ ordem estável de FeedItem                   │
└──────────────────────┬──────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│ 3. RESOLVED RUNWAY                          │
│ mídia resolvida e armazenada no disco       │
│ sem necessidade futura de rede              │
└──────────────────────┬──────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│ 4. RENDER-READY RUNWAY                      │
│ imagem decodificada ou fallback terminal    │
│ pronto para promoção imediata               │
└──────────────────────┬──────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────┐
│ 5. PUBLISHED FEED                           │
│ cards entregues ao SwiftUI scrolling        │
│ zero trabalho de mídia                      │
└─────────────────────────────────────────────┘
```

## 4.1 Content Lake

O SQLite continuará sendo a reserva ampla e durável.

Ele deverá conter conteúdo suficiente para:

* reconstruir o feed sem rede;
* trocar filtros rapidamente;
* abrir collections;
* abrir Smart Feeds;
* mudar idioma;
* mudar tipo de conteúdo;
* recompor o runway após memory warning.

O banco já lê candidate pools grandes, chegando a milhares de registros e balanceando um pool de 500 itens.

Essa base deve ser aproveitada, não substituída.

## 4.2 Editorial Backlog

O editorial backlog conterá `FeedItem` leves e já ordenados.

Ele será o único lugar que conhece:

* interleave;
* source spacing;
* provider spacing;
* country spacing;
* freshness;
* read/consumed exclusion;
* preset multipliers.

A camada de mídia não poderá reordenar esse backlog.

## 4.3 Resolved Runway

Esse runway conterá cards cuja decisão de mídia está completa, mas cuja imagem não precisa permanecer decodificada.

Exemplos:

```text
imagem resolvida, downsampled e gravada no cache
placeholder definitivo
text-only definitivo
```

Uma imagem neste estágio poderá ser representada por:

```swift
struct ResolvedImageAsset: Sendable, Equatable {
    let cacheKey: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let source: ImageResolutionSource
}
```

Não armazenar `UIImage` neste runway profundo.

## 4.4 Render-Ready Runway

Antes de um card poder entrar no feed publicado, a imagem correspondente deverá estar decodificada.

Exemplo:

```swift
enum RenderReadyMedia: @unchecked Sendable {
    case image(RenderImage)
    case placeholder(PlaceholderKind)
    case none
}

struct RenderImage: @unchecked Sendable {
    let cacheKey: String
    let image: UIImage
}
```

Esse runway será menor porque imagens decodificadas são caras.

## 4.5 Published Feed

A UI deverá observar:

```swift
private(set) var visibleCards: [PreparedFeedCard]
```

e não uma lista de `FeedItem` sem preparação.

Exemplo:

```swift
struct PreparedFeedCard: Identifiable, @unchecked Sendable {
    var id: String { item.id }

    var item: FeedItem
    let media: RenderReadyMedia
    let layout: PreparedCardLayout
    let presentationEpoch: UInt64
}
```

`item.isRead` e `item.isBookmarked` poderão continuar sendo atualizados sem alterar `media`.

---

# 5. Contexto e invalidação

## 5.1 Criar uma identidade única de contexto

Cada composição do feed deverá possuir um contexto.

```swift
struct FeedPresentationContext: Hashable, Sendable {
    let epoch: UInt64
    let mode: FeedPresentationMode
    let filterGeneration: Int64
    let presetGeneration: Int64
}

enum FeedPresentationMode: Hashable, Sendable {
    case main
    case collection(Int64)
    case smartFeed(Int64)
    case bookmarks(Int64?)
    case lastClicked
    case whatsNew
}
```

`epoch` deve aumentar sempre que a sequência publicada precisar ser reconstruída.

Exemplos:

* troca de preset;
* troca de collection;
* troca de Smart Feed;
* troca de bookmark box;
* mudança confirmada de filtros;
* shake refresh;
* reset da fonte de verdade editorial.

## 5.2 Toda tarefa de preparação captura o contexto

Cada operação assíncrona deverá carregar:

```swift
context: FeedPresentationContext
```

Antes de escrever qualquer resultado, deverá verificar:

```swift
guard result.context == activeContext else {
    discard(result)
    return
}
```

O padrão atual de `filterGeneration` e `presetGeneration` já protege várias operações e deve ser preservado. O novo `epoch` unifica a proteção no nível de apresentação.

## 5.3 Mudar filtro cancela apresentação, não necessariamente cache

Ao mudar o filtro:

* cancelar a fila editorial anterior;
* cancelar promoção do contexto anterior;
* descartar seus resultados de apresentação;
* manter downloads compartilhados que ainda possam preencher o cache;
* nunca publicar resultado antigo;
* começar imediatamente pelo SQLite local;
* usar rede apenas para ampliar ou renovar.

---

# 6. Modelos novos

## 6.1 Estado interno de preparação

```swift
enum CardPreparationState: Sendable {
    case queued
    case resolvingDirectImage
    case resolvingArticle
    case writingCache
    case resolved(ResolvedCardAsset)
    case decoding
    case renderReady(PreparedFeedCard)
}
```

Esses estados nunca serão observados diretamente pela view.

## 6.2 Resultado terminal resolvido

```swift
enum ResolvedCardAsset: Sendable, Equatable {
    case image(ResolvedImageAsset)
    case placeholder(PlaceholderKind)
    case none
}
```

## 6.3 Placeholder explícito

Não utilizar `.placeholder` sem informação.

```swift
enum PlaceholderKind: String, Codable, Sendable {
    case article
    case video
    case podcast
    case forum
}
```

## 6.4 Layout final

```swift
enum PreparedCardLayout: Sendable, Equatable {
    case hero
    case thumbnail
    case textOnly
}
```

A política de layout deverá ser determinística.

Proposta inicial:

```text
YouTube:
  imagem encontrada → hero/thumbnail
  imagem não encontrada → placeholder de vídeo, mantendo mídia

Podcast:
  imagem encontrada → hero/thumbnail
  imagem não encontrada → placeholder de podcast, mantendo mídia

Forum:
  imagem encontrada → hero/thumbnail
  candidato existente, mas falha transitória → placeholder de forum
  ausência de imagem confirmada → text-only

Article:
  imagem encontrada → hero/thumbnail
  candidato existente, mas falha transitória → placeholder de article
  ausência de imagem confirmada → text-only
```

Assim, uma rede lenta não elimina o card nem produz espaço vazio acidental.

## 6.5 Separar mídia de estado interativo

Não manter `isRead` e `isBookmarked` como propriedades duplicadas e imutáveis dentro da mídia preparada.

Preferir:

```swift
struct PreparedFeedCard {
    var item: FeedItem
    let media: RenderReadyMedia
    let layout: PreparedCardLayout
    let presentationEpoch: UInt64
}
```

Quando um bookmark mudar:

```swift
visibleCards[index].item.isBookmarked = value
```

A mídia permanece intacta.

---

# 7. Persistência do estado de resolução

## 7.1 Remover o uso de `image_url = ''` como sentença permanente

Hoje uma falha na resolução de artigo pode escrever uma string vazia em `feed_item.image_url`.

Isso mistura situações diferentes:

* artigo realmente sem imagem;
* timeout;
* falta de conexão;
* erro de DNS;
* bloqueio temporário;
* HTTP 429;
* servidor indisponível;
* parser sem suporte;
* candidato inválido.

Uma falha transitória não pode apagar permanentemente a chance de uma fonte interessante receber imagem.

## 7.2 Criar tabela específica

Adicionar migration GRDB:

```sql
CREATE TABLE image_resolution (
    item_id TEXT PRIMARY KEY
        REFERENCES feed_item(id)
        ON DELETE CASCADE,

    candidate_fingerprint TEXT NOT NULL,
    state TEXT NOT NULL,

    cache_key TEXT,
    resolved_url TEXT,

    pixel_width INTEGER,
    pixel_height INTEGER,
    byte_count INTEGER,

    attempt_count INTEGER NOT NULL DEFAULT 0,
    last_attempt_at INTEGER,
    next_retry_at INTEGER,

    failure_class TEXT,
    failure_code INTEGER,

    updated_at INTEGER NOT NULL
);
```

Estados permitidos:

```text
unknown
resolved
no_image_confirmed
transient_failure
permanent_failure
```

## 7.3 Candidate fingerprint

Calcular uma impressão a partir de:

```text
feed image URL
article URL
YouTube thumbnail URL
versão da política de resolução
```

Quando algum desses elementos mudar, a resolução anterior deverá ser invalidada automaticamente.

## 7.4 Política de falha

### Transitória

Classificar como transitória:

* timeout;
* offline;
* DNS;
* 408;
* 425;
* 429;
* 500–599;
* cancelamento por pressão;
* indisponibilidade temporária.

### Permanente ou longa

Classificar como permanente ou longa:

* URL sintaticamente inválida;
* esquema não suportado;
* resposta que definitivamente não é imagem;
* 404/410 repetido para o mesmo fingerprint;
* HTML válido analisado com sucesso e sem candidatos.

Mesmo `no_image_confirmed` deve possuir validade temporal, por exemplo sete dias, porque o publisher pode alterar o artigo.

## 7.5 Migração dos sentinels antigos

Para registros atuais com:

```text
image_url = ''
```

fazer:

```text
image_url = NULL
image_resolution.state = unknown
```

Não presumir que os sentinels antigos representam ausência confirmada.

---

# 8. Media Asset Store

## 8.1 Substituir deduplicação por polling por single-flight real

O sistema atual registra URLs em um `Set`, verifica se estão em andamento e faz polling no cache.

Substituir por:

```swift
actor MediaAssetStore {
    private var inFlight: [
        ImageAssetKey: Task<ResolvedImageAsset?, Never>
    ] = [:]

    func resolve(
        request: ImageResolutionRequest
    ) async -> ResolvedImageAsset? {
        if let task = inFlight[request.key] {
            return await task.value
        }

        let task = Task {
            await performResolution(request)
        }

        inFlight[request.key] = task
        let result = await task.value
        inFlight[request.key] = nil
        return result
    }
}
```

Todos os consumidores aguardam a mesma `Task`.

Não usar:

* polling de 25 ms;
* polling de 100 ms;
* polling de 120 ms;
* "verifique cache e tente registrar novamente".

## 8.2 Separar responsabilidades

`MediaAssetStore` deve coordenar:

* cache lookup;
* single-flight;
* download;
* validação;
* downsample;
* escrita;
* metadata de resolução.

`ArticleImageResolver` deve apenas:

* baixar HTML dentro do limite;
* extrair candidatos;
* classificá-los;
* retornar URLs.

`CardPreparationCoordinator` decide quando usar cada candidato.

## 8.3 Cache fora do Main Actor

O `ImageCache` atual é completamente `@MainActor`, apesar de possuir leitura de disco, cache index e operações de arquivo.

Refatorar para:

```text
DiskImageCache actor
MemoryImageCache
MediaAssetStore actor
```

Proposta:

```swift
actor DiskImageCache {
    func data(for key: String) async -> Data?
    func store(_ data: Data, key: String) async throws
    func evictIfNeeded() async
}

final class MemoryImageCache: @unchecked Sendable {
    private let cache: NSCache<NSString, UIImage>
}
```

`NSCache` pode continuar como cache de memória, mas a view não deverá consultá-lo para descobrir se pode mostrar uma imagem.

O preparador deve obter a imagem antes da publicação.

## 8.4 Proibir `diskImageSync` no body

A leitura síncrona de disco atual pode bloquear a thread chamadora por alguns milissegundos.

Essa API não deverá ser usada em:

* `body`;
* `onAppear`;
* eventos de scroll;
* cálculo de layout.

Ela poderá ser removida depois da migração.

---

# 9. Card Preparation Coordinator

Substituir o `ReadyCardQueue` atual por um actor.

```swift
actor CardPreparationCoordinator {
    func replaceEditorialSequence(
        _ items: [FeedItem],
        context: FeedPresentationContext
    )

    func appendEditorialSequence(
        _ items: [FeedItem],
        context: FeedPresentationContext
    )

    func fillRunway(
        policy: RunwayPolicy,
        context: FeedPresentationContext
    ) async

    func takeRenderReadyPrefix(
        maximumCount: Int,
        context: FeedPresentationContext
    ) -> [PreparedFeedCard]

    func snapshot(
        context: FeedPresentationContext
    ) -> RunwaySnapshot

    func invalidate(
        context: FeedPresentationContext
    )

    func handleMemoryPressure()
}
```

## 9.1 Estrutura interna ordenada

```swift
private var orderedItems: [FeedItem]
private var stateByID: [String: CardPreparationState]
private var resolvedByID: [String: ResolvedCardAsset]
private var renderReadyByID: [String: PreparedFeedCard]

private var nextResolvedIndex: Int
private var nextRenderReadyIndex: Int
private var nextPublishIndex: Int
```

## 9.2 Preparação concorrente, promoção contígua

O coordenador pode iniciar tarefas para:

```text
índices 0...79
```

na ordem de prioridade.

Os resultados podem terminar fora de ordem.

`takeRenderReadyPrefix` deve percorrer a partir de `nextPublishIndex` e parar no primeiro item não terminal.

Nunca montar a resposta ordenando pela data de conclusão.

## 9.3 Deadline individual

Cada item recebe um deadline conforme sua distância.

Proposta inicial, configurável:

```text
initial viewport:
    orçamento total de 6 segundos

near runway:
    orçamento total de 15 segundos

deep runway:
    orçamento total de 30 segundos
```

Esses valores são parâmetros iniciais, não regras eternas. Devem ser ajustados por métricas.

O deadline profundo maior permite que conteúdo interessante de servidores lentos tenha mais oportunidade.

Ao atingir o deadline:

```text
produzir placeholder ou text-only terminal
persistir transient_failure e next_retry_at
não remover o card
não alterar sua posição
```

## 9.4 Retry não pode modificar apresentação publicada

Uma nova tentativa bem-sucedida poderá beneficiar:

* próxima abertura;
* próxima reconstrução por filtro;
* nova sessão;
* card ainda não publicado;
* futuro feed.

Ela não poderá substituir a mídia de um card atualmente publicado.

---

# 10. Runway Controller

Criar um actor responsável por decidir a intensidade do backend.

```swift
actor FeedRunwayController {
    func start(context: FeedPresentationContext)
    func stop(context: FeedPresentationContext)

    func reportViewport(
        currentIndex: Int,
        publishedCount: Int,
        timestamp: ContinuousClock.Instant
    )

    func reportNetworkState(_ state: NetworkState)
    func reportMemoryPressure(_ level: MemoryPressureLevel)
    func reportThermalState(_ state: ProcessInfo.ThermalState)
    func reportLifecycle(_ state: FeedActivityState)

    func evaluate() async
}
```

## 10.1 O controller observa quatro estoques

```text
editorial backlog
resolved-on-disk runway
render-ready runway
published cards à frente do usuário
```

## 10.2 Medir runway em tempo, não apenas contagem

Manter EMAs de:

```text
cards consumidos por segundo
cards preparados por segundo
imagens resolvidas por segundo
taxa de falha
latência p50/p95
```

Calcular:

```swift
estimatedReadySeconds =
    Double(publishedAhead + renderReadyCount)
    / max(scrollCardsPerSecondEMA, minimumConsumptionRate)
```

Também calcular runway potencial incluindo cards já resolvidos no disco.

## 10.3 Estados de pressão

```swift
enum RunwayPressure {
    case critical
    case bootstrap
    case filling
    case cruising
    case maintenance
    case constrained
}
```

### Critical

Condições possíveis:

```text
menos de 20 cards render-ready
ou
menos de 30 segundos estimados
```

Ações:

* prioridade máxima na preparação;
* aumentar concorrência dentro do limite;
* suspender tarefas não essenciais;
* resolver primeiro imagens diretas;
* terminalizar rapidamente itens imediatos;
* puxar conteúdo local antes de rede.

### Bootstrap

A tela inicial ainda não possui uma página terminal completa.

Ações:

* preparar 20 cards;
* priorizar diversidade já obtida;
* só liberar o loading quando a página estiver terminal;
* continuar enchendo o runway após o primeiro frame.

### Filling

A primeira página existe, mas a reserva ainda não é confortável.

Ações:

* preencher render-ready;
* preencher resolved-on-disk;
* ampliar editorial backlog;
* continuar coverage mining.

### Cruising

Runways acima dos targets.

Ações:

* reduzir concorrência;
* reduzir frequência;
* continuar renovação leve;
* priorizar apenas novidade e retries vencidos.

### Maintenance

Todos os buffers acima dos high watermarks.

Ações:

* pausar preparação de novas imagens;
* manter refresh cadenciado;
* fazer manutenção de cache;
* expurgo;
* métricas.

### Constrained

Condições:

* low-power mode;
* thermal serious/critical;
* memory warning;
* conexão cara;
* app inactive/background.

Ações:

* reduzir targets;
* cancelar decode profundo;
* manter persistência;
* preservar cards já publicados;
* liberar imagens decodificadas não publicadas;
* não iniciar resolução Open Graph profunda.

## 10.4 Histerese

Nunca alternar agressivamente entre estados.

Exemplo:

```text
começa a encher quando ready < 80
só considera cheio quando ready > 140
```

Isso evita liga/desliga contínuo.

---

# 11. Targets iniciais dos buffers

Os valores devem ficar em `RunwayPolicy`, não espalhados pelo código.

Proposta inicial:

```swift
struct RunwayPolicy {
    var initialPublishedCount = 20

    var publishedAheadLow = 30
    var publishedAheadTarget = 50

    var renderReadyLow = 60
    var renderReadyTarget = 120
    var renderReadyHigh = 180

    var resolvedLow = 200
    var resolvedTarget = 400
    var resolvedHigh = 600

    var editorialLow = 500
    var editorialTarget = 1_000
    var editorialHigh = 1_500
}
```

Esses números devem ser adaptados pela memória do dispositivo.

## 11.1 Não armazenar 600 `UIImage`

O runway de 400–600 cards será principalmente:

* mídia em disco;
* cache key;
* dimensões;
* layout;
* placeholder terminal.

Somente uma janela menor será decodificada.

## 11.2 Faixas adaptativas sugeridas

### Dispositivo sob pressão

```text
render-ready: 40–70
resolved:    150–250
editorial:   400–700
```

### Estado normal

```text
render-ready: 80–140
resolved:    300–500
editorial:   800–1.200
```

### Dispositivo confortável, carregando e Wi-Fi

```text
render-ready: 120–180
resolved:    500–700
editorial:   1.200–1.800
```

## 11.3 O scroll não começa o trabalho principal

`loadMoreIfNeeded` deverá ser alterado para:

```text
registrar posição
promover um lote já render-ready
solicitar avaliação do controller
```

Ele não deverá chamar diretamente:

* `fetchNextBatch`;
* `ImagePrefetcher`;
* `ImageLoader`;
* `ArticleImageResolver`.

O controller já estará trabalhando continuamente conforme os watermarks.

---

# 12. Publicação no Main Actor

## 12.1 Fonte de verdade da UI

No `FeedStore`:

```swift
private(set) var visibleCards: [PreparedFeedCard] = []
private(set) var visibleCardsGeneration: UInt64 = 0
```

Durante a migração, manter temporariamente:

```swift
var visibleItems: [FeedItem] {
    visibleCards.map(\.item)
}
```

somente para compatibilidade de APIs ainda não migradas.

Depois, remover essa compatibilidade.

## 12.2 Single writer

Criar:

```swift
private func setVisibleCards(
    _ cards: [PreparedFeedCard],
    context: FeedPresentationContext
)
```

O método deve:

1. verificar contexto;
2. atualizar read/bookmark dos itens;
3. validar terminalidade;
4. validar unicidade de IDs;
5. publicar;
6. incrementar generation;
7. registrar métrica.

Assertion de debug:

```swift
precondition(cards.allSatisfy(\.isRenderReady))
```

## 12.3 Append

```swift
private func appendVisibleCards(
    _ cards: [PreparedFeedCard],
    context: FeedPresentationContext
)
```

Antes de acrescentar:

```text
nenhum ID duplicado
mesmo contexto
todos terminalmente preparados
ordem correspondente ao prefixo editorial
```

## 12.4 O que permanece no Main Actor

* array pequeno de cards;
* counters;
* estados de loading;
* estado de seleção;
* callbacks da UI;
* aplicação de deltas.

Todo o resto deve estar em actors ou tarefas detached apropriadas.

---

# 13. Integração com o reservoir

## 13.1 Fase inicial de baixo risco

Na primeira integração, preservar o algoritmo do `Reservoir`.

Adicionar APIs:

```swift
func peekUpcoming(_ count: Int) -> [FeedItem]
func consumeUpcoming(ids: [String])
func replaceEditorialItems(_ items: [FeedItem]) async
```

O fluxo será:

```text
Reservoir mantém ordem editorial
→ coordinator faz peek
→ prepara
→ FeedStore promove cards prontos
→ somente depois consume os IDs do reservoir
```

Não chamar `moveToVisible` antes da preparação.

## 13.2 Estado final recomendado

Depois da migração estabilizar:

```text
Reservoir deixa de possuir visibleItems
```

Ele passa a ser exclusivamente:

```text
EditorialReservoir
```

O `FeedStore` passa a ser o único proprietário do feed publicado.

Essa separação elimina a duplicação atual entre:

* `reservoir.visibleItems`;
* `FeedStore.visibleItems`.

## 13.3 Preservar interleave

Não modificar nesta migração:

* pesos;
* freshness spreading;
* provider keys;
* country spreading;
* front-load de providers;
* cooldown;
* stale tiers;
* regras de read state.

O único objetivo dessa integração é mudar o momento da promoção.

---

# 14. Primeiro carregamento

## 14.1 Warm start

Fluxo:

```text
SQLite
→ applyFilters
→ balancedCandidatePool
→ Reservoir interleave
→ preparar primeiras 20 apresentações
→ publicar
→ continuar preenchendo runways
```

O warm start não deve esperar rede.

Imagens já existentes no disco devem ser:

```text
lidas e decodificadas no preparador
antes da publicação
```

## 14.2 Cold start

O critério atual de runway considera diversidade de fontes, o que deve ser mantido. O cold start já procura uma base ampla de fontes antes da publicação.

Modificar a sequência final:

```text
buscar fontes
→ persistir
→ filtrar
→ intercalar
→ preparar primeira página
→ publicar primeira página
→ continuar buscando e preparando
```

Não fazer:

```text
persistir
→ mover direto para visibleItems
→ iniciar prefetch
```

## 14.3 Loading state

A tela poderá sair de `.initial` quando:

```swift
visibleCards.count >= minimumInitialReadyCards
```

ou quando todos os candidatos disponíveis forem terminalizados e houver menos de 20.

Nunca sair apenas porque existem `FeedItem` no reservoir.

## 14.4 Conteúdo antes de mídia

A prioridade no cold start deve ser:

1. recuperar conteúdo e diversidade;
2. produzir 20 apresentações terminais;
3. publicar;
4. continuar rapidamente até o runway target;
5. reduzir ritmo somente quando os buffers estiverem cheios.

---

# 15. Paginação e scrolling

## 15.1 Novo comportamento de `loadMoreIfNeeded`

```swift
func loadMoreIfNeeded(currentCard: PreparedFeedCard) async {
    reportViewportPosition(currentCard.id)

    let cards = await runwayCoordinator.takeRenderReadyPrefix(
        maximumCount: Reservoir.pageSize,
        context: activeContext
    )

    appendVisibleCards(cards, context: activeContext)

    await runwayController.evaluate()
}
```

O caminho acima não pode fazer rede.

## 15.2 Promoção antecipada

Não esperar chegar a cinco cards do final para verificar se existe runway.

O controller deverá manter:

```text
published cards à frente do usuário
+
render-ready queue
```

constantemente acima dos targets.

## 15.3 Scroll extremamente rápido

O comportamento esperado:

```text
usuário acelera
→ publishedAhead diminui
→ cards render-ready são promovidos
→ controller sobe pressão
→ resolved cards são decodificados
→ novas mídias são resolvidas mais ao fundo
```

A rede é a última camada a ser alcançada, não a primeira.

---

# 16. Filtros

## 16.1 Troca de filtro

Fluxo:

```text
incrementar filterGeneration
incrementar presentation epoch
cancelar promoção antiga
cortar imediatamente cards incompatíveis
consultar SQLite
aplicar filtros existentes
intercalar
preparar primeira página
publicar
continuar enchendo
iniciar urgent fetch apenas para complementar
```

## 16.2 Não deixar tela vazia desnecessariamente

Ao mudar filtro, existem duas situações.

### Cards atuais incompatíveis

Removê-los imediatamente, como já ocorre.

Mostrar loading enquanto a nova primeira página está sendo preparada.

### Parte dos cards atuais ainda compatível

Eles podem permanecer, desde que pertençam ao novo contexto e sua ordem continue válida.

A implementação inicial mais segura pode reconstruir completamente a sequência após mudança confirmada de filtro.

## 16.3 Aproveitar o banco diversificado

O backend deverá manter cobertura ampla no SQLite mesmo quando o filtro atual é estreito.

O coverage mining atual já trabalha para representar até 100 providers úteis em diferentes segmentos.

Preservar essa capacidade e ligá-la ao controller:

```text
runway atual cheio
+
coverage de outro tipo insuficiente
→ mineração de baixa prioridade
```

Isso torna futuras mudanças de filtro mais rápidas.

---

# 17. Fluxos especiais

Todos os caminhos abaixo devem atravessar a mesma fronteira de apresentação.

## 17.1 Collections

Hoje collections:

```text
carregam itens
→ reservoir.seed
→ replace visibleItems
```

A ordem e a allowlist devem ser mantidas, mas a publicação deverá virar:

```text
carregar membros
→ aplicar filtros
→ reservoir.seed
→ criar novo context .collection(id)
→ preparar
→ publicar cards terminais
```

O código atual usa uma allowlist exclusiva e valida preset generation; essas garantias devem permanecer.

## 17.2 Smart Feeds

Hoje `loadSmartFeedFeed` limpa o reservoir e chama diretamente:

```swift
setVisibleItems(items)
```

Modificar para:

```text
obter cached items na ordem atual
→ context .smartFeed(id)
→ preparar
→ publicar
```

Não passar Smart Feed pelo reservoir global se isso alterar sua ordem específica.

## 17.3 Last clicked

Hoje o resultado é publicado diretamente após consulta ordenada por `clicked_at`.

Preservar exatamente essa ordem.

Usar:

```text
context .lastClicked
→ prepare fixed sequence
→ publish
```

## 17.4 Bookmark boxes

Hoje `loadBookmarkFeed` pausa processos e chama diretamente `setVisibleItems`.

Modificar para:

```text
pausar processos
→ context .bookmarks(listID)
→ preparar snapshot fixo
→ publicar
```

Bookmark mode continua sem background global alterando a tela.

## 17.5 What's New

O carousel é visualmente importante e recebe até dez itens.

Criar contexto pequeno independente:

```text
context .whatsNew
→ preparar todos os candidatos
→ promover lote terminal
```

Não mostrar item no carousel antes da mídia terminal.

## 17.6 Search

A busca principal atual usa rows textuais simples e não depende de imagens. Ela pode permanecer fora do runway inicialmente.

Não alterar:

* source results;
* FTS;
* live remote sweep;
* filtros de busca.

Caso uma futura busca use cards ilustrados, ela deverá adotar o mesmo preparador.

## 17.7 Source views e onboarding

`CachedAsyncImage` pode permanecer temporariamente em:

* telas de detalhe;
* onboarding;
* source views;
* componentes que não pertencem ao feed principal.

Isso evita ampliar o escopo da primeira migração.

Entretanto, o uso deve ser explicitamente listado e não pode voltar a ser utilizado no feed principal.

---

# 18. Memória

## 18.1 Evitar interpretar cache como garantia

`NSCache` pode evictar objetos.

Portanto, um card publicado não deve depender exclusivamente de que sua imagem ainda esteja no `NSCache`.

`PreparedFeedCard` deverá manter referência forte ao `UIImage` enquanto estiver publicado.

## 18.2 Janela decodificada

Manter referências fortes para:

```text
cards publicados
+
render-ready runway
```

Não manter referências fortes para todo o resolved runway.

## 18.3 Memory warning

Ordem de liberação:

1. cancelar decode profundo;
2. liberar render-ready cards mais distantes;
3. reduzir targets;
4. limpar imagens decodificadas não publicadas;
5. trimar tail seguro do feed;
6. manter cards na viewport e safety zone;
7. manter arquivos comprimidos no disco;
8. preservar a ordem editorial.

Nunca remover a cabeça do feed por causa de memória.

## 18.4 Custo medido

Registrar custo real de cada imagem:

```swift
width * height * 4
```

Os targets devem obedecer a um orçamento de bytes, não apenas contagem de imagens.

---

# 19. Concorrência

## 19.1 Limites separados

Não compartilhar um único número de concorrência para tudo.

Criar limites distintos:

```text
direct image downloads
article HTML requests
article candidate downloads
disk decodes
card preparations
background retries
feed fetches
```

Proposta inicial:

```text
direct image resolutions:      6–10
article HTML:                  3–4
article candidate download:    3–4
disk decode:                   4–6
deep background retry:         1–2
```

O controller poderá ajustar dentro dessas faixas.

## 19.2 Prioridades

```text
initial page:        userInitiated
published runway:   userInitiated
near runway:        utility elevada
deep runway:        utility
future coverage:    background
retry futuro:       background
```

## 19.3 Não usar polling

Substituir loops que verificam repetidamente:

```text
task terminou?
cache apareceu?
slot liberou?
```

por:

* `Task` compartilhada;
* async semaphore;
* continuation;
* task group;
* actor state.

---

# 20. Alterações por arquivo

## 20.1 Novos arquivos

Criar:

```text
feedmine/Models/FeedPresentationContext.swift
feedmine/Models/PreparedFeedCard.swift
feedmine/Models/ImageResolutionRecord.swift

feedmine/Services/CardPreparationCoordinator.swift
feedmine/Services/FeedRunwayController.swift
feedmine/Services/RunwayPolicy.swift
feedmine/Services/MediaAssetStore.swift
feedmine/Services/DiskImageCache.swift
feedmine/Services/MemoryImageCache.swift
feedmine/Services/AsyncLimiter.swift
feedmine/Services/RunwayMetrics.swift
```

## 20.2 `FeedCardPresentation.swift`

Substituir o modelo atual por:

* `ResolvedCardAsset`;
* `RenderReadyMedia`;
* `PreparedFeedCard`;
* placeholder explícito;
* sem snapshots duplicados de read/bookmark;
* sem `UIImage` no resolved runway.

O nome `FeedCardPresentation` pode ser mantido para compatibilidade, mas `PreparedFeedCard` é semanticamente mais claro.

## 20.3 `ReadyCardQueue.swift`

Não estender a implementação atual.

Substituir por `CardPreparationCoordinator`.

Remover:

* `@MainActor`;
* polling de 100 ms;
* timeout global de três segundos;
* contagem global de presentations;
* `pendingIDs` como representação da ordem.

## 20.4 `CardPreparationPipeline.swift`

Transformar em worker stateless ou incorporar ao coordinator.

Adicionar:

* `context`;
* `index`;
* `urgencyBand`;
* deadline individual;
* resultado resolvido sem `UIImage` profunda;
* classification de falha;
* persistência da resolução;
* cancelamento.

## 20.5 `ImageLoader.swift`

Transformar em parte do `MediaAssetStore`.

Remover duplicação com `CachedAsyncImage`.

Garantir single-flight real.

Não fazer upgrade posterior à publicação.

## 20.6 `ImageCache.swift`

Separar:

* cache de memória;
* cache de disco;
* tracker/single-flight;
* article resolver;
* `CachedAsyncImage`.

Esse arquivo atualmente concentra responsabilidades demais.

## 20.7 `ImagePrefetcher.swift`

Depois da migração:

* não deve ser chamado para itens que já atravessaram a fronteira de apresentação;
* pode ser absorvido pelo `MediaAssetStore`;
* não deve competir com o coordinator;
* não deve possuir lógica paralela de download.

Idealmente, removê-lo após consolidar o single-flight.

## 20.8 `FeedStore.swift`

Adicionar:

```swift
let preparationCoordinator: CardPreparationCoordinator
let runwayController: FeedRunwayController

private(set) var visibleCards: [PreparedFeedCard]
private var presentationEpoch: UInt64
private var activePresentationContext: FeedPresentationContext
```

Modificar todos os writers:

* startup;
* SQLite reload;
* append;
* refresh;
* replace;
* collections;
* Smart Feeds;
* Last clicked;
* bookmarks;
* source toggle;
* category toggle;
* region toggle;
* emergency trim;
* shake refresh.

Remover do caminho de publicação:

* `prefetchUpcoming`;
* `resolveArticleImagesInBackground`;
* prefetch fire-and-forget usado como garantia;
* `moveToVisible` antes de preparação.

Renomear ou remover `presentationItems(from:)`, pois hoje ele apenas aplica filtros e não produz presentations.

## 20.9 `FeedLoader.swift`

Expor:

```swift
var cards: [PreparedFeedCard]
```

Alterar:

* `dateSections`;
* filtered cache;
* generation cache;
* current visible index;
* load more.

Durante transição, APIs que precisam de `FeedItem` usam:

```swift
card.item
```

## 20.10 `FeedScreen.swift`

Alterar:

```swift
ForEach(section.cards) { card in
    FeedItemView(card: card)
}
```

`onAppear` poderá:

* registrar impressão;
* informar posição;
* promover cards já prontos.

Não poderá iniciar resolução.

## 20.11 `FeedItemView.swift`

Receber:

```swift
let card: PreparedFeedCard
```

Usar:

```swift
let item = card.item
```

para ações e playback.

Passar a mídia preparada aos layouts.

## 20.12 `FeedItemCardView.swift`

Remover:

```swift
@State imageLoadFailed
@State imageAppeared
CachedAsyncImage
onResult
fade de chegada da imagem
```

Renderizar:

```swift
switch card.media {
case .image(let renderImage):
    Image(uiImage: renderImage.image)

case .placeholder(let kind):
    PreparedPlaceholderView(kind: kind)

case .none:
    EmptyView()
}
```

## 20.13 `FeedItemRowView.swift`

Fazer a mesma migração.

Esse arquivo não pode ser esquecido, pois o modo list também carrega imagens atualmente.

## 20.14 `WhatsNewManager`

Alterar para trabalhar com:

```text
candidate FeedItems
→ prepared carousel cards
→ published carousel
```

## 20.15 Migrations

Adicionar migration da tabela `image_resolution`.

Adicionar índices:

```sql
CREATE INDEX image_resolution_state_retry
ON image_resolution(state, next_retry_at);
```

---

# 21. Ordem de implementação

Cada fase deve terminar compilando e com testes verdes.

Não fazer uma alteração única e gigantesca.

## Fase 0 — Baseline e reconciliação

### Tarefas

1. Fazer checkout do commit de referência.
2. Executar build completo.
3. Executar todos os unit tests.
4. Executar UI tests relevantes.
5. Registrar falhas preexistentes.
6. Reconciliar testes que esperam `presentation` com a view que ainda não possui esse parâmetro.
7. Corrigir o script de invariantes para usar caminho relativo ao repositório.
8. Criar feature flag interna:

```swift
Settings.preparedFeedPipelineEnabled
```

9. Criar launch argument:

```text
-PreparedFeedPipeline
```

10. Não alterar comportamento de produção nesta fase.

### Critério de saída

* baseline compilável;
* testes existentes executáveis;
* falhas conhecidas documentadas;
* feature flag disponível;
* nenhum comportamento editorial alterado.

## Fase 1 — Modelos e observabilidade

### Tarefas

1. Criar `FeedPresentationContext`.
2. Criar `PreparedFeedCard`.
3. Criar estados resolved e render-ready separados.
4. Criar `RunwayPolicy`.
5. Criar métricas.
6. Manter pipeline antigo publicando.
7. Executar nova preparação em shadow mode sobre os primeiros itens.
8. Comparar IDs editoriais antigos e novos.

### Critério de saída

* shadow pipeline não altera UI;
* ordem dos IDs é idêntica;
* preparation latency mensurável;
* memory cost mensurável.

## Fase 2 — Media Asset Store

### Tarefas

1. Criar single-flight por asset key.
2. Separar disk cache.
3. Separar memory cache.
4. Centralizar downloads.
5. Centralizar validação e downsample.
6. Adicionar migration `image_resolution`.
7. classificar falhas;
8. remover sentinel permanente de string vazia;
9. escrever testes com `URLProtocol`.

### Critério de saída

* uma URL gera no máximo um download simultâneo;
* falha transitória não vira ausência permanente;
* cache lookup e decode não acontecem no Main Actor;
* resultado resolved pode ser reconstruído após reiniciar.

## Fase 3 — Card Preparation Coordinator

### Tarefas

1. Criar coordinator actor.
2. Implementar sequência editorial.
3. Implementar `stateByID`.
4. Implementar tarefas concorrentes.
5. Implementar prefixo contíguo.
6. Implementar deadlines individuais.
7. Implementar terminalização.
8. Implementar invalidation por contexto.
9. Implementar resolved runway.
10. Implementar render-ready runway.

### Critério de saída

* itens concluem fora de ordem sem serem publicados fora de ordem;
* um item lento não impede preparação posterior;
* timeout produz fallback terminal;
* nenhum item desaparece;
* context antigo não publica.

## Fase 4 — Warm start e cold start

### Tarefas

1. Integrar `reloadFromSQLite`.
2. Preservar `balancedCandidatePool`.
3. Preservar interleave.
4. Preparar primeira página.
5. publicar `visibleCards`;
6. alterar loading criterion;
7. continuar enchendo runway após primeiro frame;
8. comparar ordem com pipeline antigo.

### Critério de saída

* primeira página contém somente cards terminais;
* warm cache não mostra flashes;
* disk-only images aparecem no primeiro frame;
* primeira página mantém a ordem editorial.

## Fase 5 — Paginação e views

### Tarefas

1. Migrar `FeedScreen`.
2. Migrar `FeedItemView`.
3. Migrar `FeedItemCardView`.
4. Migrar `FeedItemRowView`.
5. Remover `CachedAsyncImage` do feed principal.
6. Alterar `loadMoreIfNeeded`.
7. Promover somente render-ready prefix.
8. manter read/bookmark updates independentes;
9. implementar testes de scroll rápido.

### Critério de saída

* zero download iniciado pelo feed visível;
* zero placeholder-to-image;
* zero image upgrade visível;
* modo card e modo list seguros;
* scroll acrescenta apenas cards terminais.

## Fase 6 — Fluxos especiais

Executar separadamente:

1. collections;
2. Smart Feeds;
3. Last clicked;
4. bookmark boxes;
5. What's New;
6. source toggles;
7. region toggles;
8. category toggles;
9. shake refresh;
10. memory warning.

### Critério de saída

Cada caminho publica apenas `PreparedFeedCard`.

Nenhum caminho poderá chamar diretamente:

```swift
setVisibleItems([FeedItem])
```

## Fase 7 — Runway Controller

### Tarefas

1. implementar watermarks;
2. implementar pressão;
3. registrar scroll EMA;
4. registrar preparation throughput;
5. registrar runway em segundos;
6. integrar lifecycle;
7. integrar network state;
8. integrar low power;
9. integrar thermal state;
10. implementar histerese;
11. substituir fetch reativo por controller;
12. manter coverage mining.

### Critério de saída

* backend acelera com buffers baixos;
* backend desacelera com buffers altos;
* scroll normal não é origem do fetch;
* controller mantém estoque antecipado;
* app não faz trabalho intenso indefinidamente quando cheio.

## Fase 8 — Memória e performance

### Tarefas

1. medir custo de imagens;
2. adaptar targets por bytes;
3. implementar decode window;
4. memory warning policy;
5. Instruments Main Thread;
6. Instruments Allocations;
7. Instruments Network;
8. testar aparelhos com diferentes memórias;
9. testar low power e thermal constraints.

### Critério de saída

* nenhuma operação de mídia bloqueia Main Actor;
* cards publicados não perdem imagem;
* runway profundo não mantém todas as imagens decodificadas;
* memory warning não causa salto ou flash.

## Fase 9 — Remoção do legado

Somente depois de todos os fluxos migrarem:

1. remover feed-path de `CachedAsyncImage`;
2. remover `ReadyCardQueue` antigo;
3. remover `ImageDownloadTracker` com polling;
4. remover `prefetchUpcoming`;
5. remover `resolveArticleImagesInBackground`;
6. remover `image_url=''`;
7. remover compatibilidade `visibleItems`;
8. tornar `visibleCards` a única fonte;
9. ativar feature flag por padrão;
10. manter kill switch por uma versão;
11. atualizar documentação;
12. remover kill switch após estabilização.

---

# 22. Testes obrigatórios

## 22.1 Unit tests — ordem

### Preparação fora de ordem

```text
item 2 termina primeiro
item 3 termina depois
item 1 termina por último
```

Resultado publicável antes do item 1:

```text
nenhum
```

Resultado depois do item 1:

```text
1, 2, 3
```

### Timeout

```text
item 1 nunca responde
item 2 termina
```

Ao expirar item 1:

```text
item 1 = placeholder terminal
item 2 = imagem
prefixo = [1, 2]
```

### Sem penalidade editorial

Verificar que timeout não remove item e não muda índice.

## 22.2 Unit tests — contexto

1. iniciar contexto A;
2. preparar cards;
3. trocar para contexto B;
4. finalizar tarefas de A;
5. verificar que A não publica;
6. verificar que cache compartilhado ainda pode ser aproveitado por B.

## 22.3 Unit tests — single-flight

Executar dez resoluções simultâneas da mesma URL.

Esperado:

```text
1 request HTTP
10 consumidores recebem o mesmo resultado
```

## 22.4 Unit tests — falhas

Cobrir:

* offline;
* timeout;
* DNS;
* 404;
* 410;
* 429;
* 500;
* HTML sem imagem;
* imagem inválida;
* arquivo muito grande;
* cancelamento;
* candidato YouTube fallback;
* artigo com OG válido.

## 22.5 FeedStore integration tests

Verificar:

* cold start;
* warm start;
* append;
* filter generation;
* preset generation;
* collection;
* Smart Feed;
* bookmark feed;
* Last clicked;
* source toggle;
* region toggle;
* shake refresh;
* memory warning.

Em todos:

```text
visibleCards.allSatisfy(isRenderReady) == true
```

## 22.6 UI tests

Criar `URLProtocol` ou servidor de teste que:

* atrasa imagens;
* falha imagens;
* retorna imagens rapidamente;
* retorna HTML atrasado;
* retorna 429;
* nunca responde dentro do deadline.

Executar scroll rápido.

Verificar:

* nenhuma imagem aparece depois;
* nenhum layout muda;
* nenhum card pisca;
* nenhum espaço colapsa;
* nenhuma chamada de mídia é iniciada após `onAppear`;
* ordem estável;
* scroll offset estável.

## 22.7 Teste de rede pós-publicação

Instrumentar o momento:

```text
cardPublishedAt
```

Toda requisição deve registrar:

```text
requestStartedAt
requestOwner
itemID
context
```

Assertion:

```text
requestOwner == mainFeedView
```

deve ocorrer zero vezes.

Também:

```text
requestStartedAt > cardPublishedAt
```

para a mídia daquele mesmo card deve ocorrer zero vezes.

## 22.8 Performance tests

Medir:

* tempo de preparação p50/p95;
* decode p50/p95;
* Main Actor stall;
* custo da promoção de 20 cards;
* uso de memória;
* throughput de cards;
* runway em segundos;
* taxa de fallback;
* cache hit de memória;
* cache hit de disco;
* download single-flight reuse.

---

# 23. Métricas

Adicionar:

```text
editorial_backlog_depth
resolved_runway_depth
render_ready_runway_depth
published_ahead_depth

estimated_runway_seconds
scroll_cards_per_second_ema
prepare_cards_per_second_ema

card_prepare_duration_p50
card_prepare_duration_p95
initial_ready_page_duration

media_memory_hit
media_disk_hit
media_network_hit
media_article_resolution_hit

media_transient_failure
media_permanent_failure
media_terminal_placeholder

visible_card_media_mutation
visible_placeholder_to_image
visible_image_upgrade
post_publication_media_request

main_actor_publish_duration
main_actor_stall_over_8ms
```

Metas invariantes:

```text
visible_card_media_mutation        = 0
visible_placeholder_to_image       = 0
visible_image_upgrade              = 0
post_publication_media_request     = 0
ready_at_publication               = 100%
editorial_order_violation          = 0
```

---

# 24. Rollout seguro

## 24.1 Shadow mode

Durante desenvolvimento:

```text
pipeline antigo publica
pipeline novo prepara em paralelo
```

Comparar:

* IDs;
* ordem;
* filtros;
* source diversity;
* provider diversity;
* média;
* memória;
* readiness.

A imagem não precisa ser idêntica, mas os IDs e a ordem editorial devem ser.

## 24.2 Feature flag

Estados:

```text
legacy
shadow
prepared
```

## 24.3 Kill switch

Manter um kill switch local durante pelo menos uma versão de teste.

Não misturar os dois pipelines em um mesmo feed publicado.

## 24.4 Commits pequenos

Cada fase deve ser um ou mais commits isolados.

Formato recomendado:

```text
test: establish prepared-feed baseline
feat: add presentation context models
feat: add media asset single-flight
feat: add ordered card preparation coordinator
feat: gate initial feed on render-ready cards
feat: publish ready runway during scroll
feat: migrate special feed modes
feat: add adaptive runway controller
perf: tune decoded image window
chore: remove legacy feed image path
```

---

# 25. Regras de execução para o Claude Code

1. Não alterar algoritmo de interleave nesta migração.
2. Não alterar semântica de filtros.
3. Não alterar allowlist de collections.
4. Não alterar regras de Smart Feed.
5. Não alterar retenção de bookmarks.
6. Não remover itens lentos.
7. Não reordenar por conclusão de imagem.
8. Não publicar estado intermediário.
9. Não usar `CachedAsyncImage` como fallback no feed principal.
10. Não introduzir leitura síncrona de disco na view.
11. Não colocar o coordinator no Main Actor.
12. Não armazenar centenas de `UIImage` no runway profundo.
13. Não usar timeout global de lote.
14. Não usar polling como mecanismo de sincronização.
15. Não converter falha transitória em ausência permanente.
16. Não substituir mídia depois da publicação.
17. Não fazer uma refatoração monolítica.
18. Executar build e testes depois de cada fase.
19. Comparar a ordem editorial com a implementação anterior.
20. Parar a fase se qualquer invariável "Feed é sagrado" falhar.

---

# 26. Definição final de pronto

A migração estará concluída somente quando todas as afirmações abaixo forem verdadeiras.

## Publicação

* O feed principal observa `PreparedFeedCard`.
* Todo card publicado possui mídia terminal.
* O primeiro viewport é totalmente terminal.
* Toda paginação acrescenta apenas cards terminais.

## UI

* `FeedItemCardView` não contém `CachedAsyncImage`.
* `FeedItemRowView` não contém `CachedAsyncImage`.
* Nenhuma view do feed inicia rede.
* Nenhuma view do feed lê disco.
* Nenhuma imagem entra com fade de carregamento.
* Nenhum placeholder é substituído.
* Nenhum card muda de altura devido à mídia.

## Ordem editorial

* A ordem continua sendo determinada pelo reservoir.
* Um item lento permanece em sua posição.
* Preparação posterior pode ocorrer em paralelo.
* Promoção usa prefixo contíguo.
* A velocidade do servidor não muda curadoria.

## Backend

* Há backlog editorial amplo.
* Há resolved runway profundo.
* Há render-ready runway.
* O controller trabalha até os buffers ficarem cheios.
* O controller desacelera quando há sobra.
* O scroll consome estoque e apenas informa pressão.
* Filtros normalmente começam pelo conteúdo local.
* Rede complementa, não define o primeiro frame.

## Concorrência

* Mídia não é preparada no Main Actor.
* Downloads da mesma imagem são single-flight.
* Não existe polling de cache.
* Tarefas antigas não publicam em contexto novo.
* Memory warning reduz runway sem corromper o feed.

## Métricas

```text
ready_at_publication             100%
visible_card_media_mutation      0
post_publication_media_request   0
editorial_order_violation        0
```

---

# 27. Fluxo final esperado

```text
APP ABRE
│
├─ carrega SQLite, filtros, presets e estado
├─ cria contexto de apresentação
├─ monta candidate pool amplo
├─ aplica elegibilidade
├─ executa interleave
├─ cria editorial backlog
│
├─ prepara primeiras 20 posições
│   ├─ cache memória
│   ├─ cache disco
│   ├─ imagem direta
│   ├─ página do artigo
│   ├─ fallback terminal
│   └─ decode
│
├─ publica primeira página totalmente pronta
│
├─ enche render-ready runway
├─ enche resolved runway
├─ enche editorial backlog
│
└─ atinge estado de manutenção


USUÁRIO FAZ SCROLL
│
├─ consome cards publicados
├─ FeedStore promove cards já render-ready
├─ controller observa queda do runway
├─ backend aumenta produção antecipada
└─ usuário não vê nenhuma guerra


CARD LENTO
│
├─ mantém posição editorial
├─ itens posteriores continuam preparando
├─ recebe orçamento conforme distância
├─ encontra imagem
│   ou
├─ chega a fallback terminal
│
└─ prefixo contíguo é liberado


USUÁRIO TROCA FILTRO
│
├─ novo context epoch
├─ tarefas antigas perdem autoridade de publicação
├─ SQLite responde primeiro
├─ nova ordem editorial é criada
├─ primeira página é preparada
├─ cards terminais são publicados
└─ rede amplia o runway em segundo plano
```

A finalidade desta arquitetura é fazer com que a complexidade, a latência, as tentativas, os erros e a concorrência existam somente atrás da interface.

A UI permanece uma igreja.

O backend pode continuar sendo guerra.
