# Code review — filtros, shake refresh e página do source

## Veredito

Existem três bugs confirmados:

1. Ao trocar filtro, o aplicativo publica imediatamente qualquer pequeno subconjunto local que ainda combine com o filtro — inclusive um único card.
2. No shake refresh, o feed é apagado antes de a UI entrar em estado de carregamento, fazendo aparecer falsamente "No articles found".
3. A página de um source publica itens crus do SQLite e não passa pelo pipeline de preparação de imagens.

Os três devem ser corrigidos com um único princípio:

```text
Uma nova composição do feed começa como PREPARING.

Nenhum resultado parcial é publicado como READY.

EMPTY só pode ser exibido depois que a operação terminar
e confirmar que realmente não existe conteúdo.
```

---

# 1. Troca de filtro mostra um card sozinho

Ao mudar o idioma, `setFilter` atualiza imediatamente o filtro e chama:

```swift
immediatelyCullVisibleItemsForActiveFilter()
```

Esse método pega os cards que já estão na tela e mantém os que coincidentemente combinam com o novo filtro:

```swift
setVisibleItems(
    visibleItems.filter(filterPredicate)
)
```

Por isso aconteceu exatamente o que você descreveu:

```text
feed em português
→ muda o filtro
→ entre os cards antigos, apenas um passa no novo filtro
→ esse card é publicado sozinho
→ depois o reload do SQLite e da rede completa o feed
```

O código faz isso intencionalmente para evitar mostrar cards incompatíveis, mas o resultado visual é incorreto. Um card sobrevivente não significa que a nova composição esteja pronta.

## Correção

Na mudança de filtro, deve começar uma transação de apresentação:

```swift
feedDisplayPhase = .preparing(
    context: activePresentationContext,
    reason: .filterChange
)
```

O subconjunto local pode ser usado pelo backend como candidato, mas não deve ser exibido como feed pronto.

A UI só deve sair de `.preparing` quando houver:

```text
uma primeira página preparada
ou
todos os resultados disponíveis, se houver menos que uma página
```

Exemplo:

```swift
let minimumReady = min(
    runwayPolicy.initialPublishedCount,
    editorialItemCount
)
```

Depois:

```swift
await coordinator.waitForContiguousPrefix(
    minimumCount: minimumReady,
    context: context
)

publishAtomically(items: items, cards: cards)
feedDisplayPhase = .ready(context)
```

## Hotfix pequeno

Como correção imediata, sem refatorar tudo:

```swift
loadingState = .refreshing
setVisibleItems([])
scheduleFilterReload(...)
```

E fazer a tela mostrar loading quando estiver `.refreshing` e sem conteúdo.

Isso elimina o card solitário, embora a solução correta continue sendo um estado explícito de composição.

---

# 2. Shake mostra falsamente "No articles found"

`shakeToRefresh` cria uma `Task` e chama:

```swift
applyUpdate(.flush(forceFetch: true, skipRead: true))
```

O `.flush` imediatamente executa:

```swift
setVisibleItems([])
reservoir.clear()
```

Mas `shakeToRefresh` não coloca o feed em `.refreshing` antes de limpá-lo.

Além disso, a decisão visual atual só mostra `InitialFeedLoadingView` para:

* `isPreparingInitialRunway`;
* `loadingState == .initial`;
* alguns presets especiais em `.refreshing`.

Um refresh normal em `.refreshing` não está coberto.

Portanto, durante alguns instantes, o estado é:

```text
items = []
loadingState = idle
hasActiveFilters = true
```

A UI conclui:

```text
não há resultados
```

Depois a operação termina e os cards aparecem.

## Correção imediata

No começo de `shakeToRefresh`:

```swift
loadingState = .refreshing
feedDisplayPhase = .preparing(
    context: activePresentationContext,
    reason: .manualRefresh
)
```

Isso precisa acontecer **antes** de:

```swift
setVisibleItems([])
```

E a condição da tela precisa incluir refresh normal:

```swift
if loader.items.isEmpty
    && (
        loader.isPreparingInitialRunway
        || loader.loadingState == .initial
        || loader.loadingState == .refreshing
    ) {
    InitialFeedLoadingView()
}
```

## Regra essencial

`FeedEmptyStateView` só pode ser mostrada quando:

```swift
loadingState == .idle
&&
feedDisplayPhase == .ready
&&
items.isEmpty
```

Hoje a tela considera `items.isEmpty` cedo demais.

---

# 3. "View Source" ignora o pipeline de imagens

Esse problema está exatamente no fluxo que você deduziu.

`SourceFeedView.load()` faz:

```swift
isLoading = true

let cached = await loader.sourceContentFromCache(source)

if !cached.isEmpty {
    items = cached
}

let loaded = await loader.loadSourceContent(source)

result = loaded
items = loaded.items
isLoading = false
```

Ou seja:

```text
abre a página
→ busca diretamente no SQLite
→ publica imediatamente os FeedItem crus
→ depois consulta a fonte
→ publica novamente FeedItem crus
```

Não existe preparação de `FeedCardPresentation`.

## A view também não passa presentation

A página renderiza:

```swift
FeedItemView(
    item: item,
    onOpen: ...
)
```

Ela não fornece:

```swift
presentation: preparedCard
```

`FeedItemView` tenta então procurar o ID dentro de `loader.cards`, que são os presentations do feed principal:

```swift
let pres =
    presentation
    ?? loader.cards.first { $0.id == item.id }
```

Normalmente esses itens do source não estão no runway publicado do feed principal. Portanto:

```text
presentation == nil
```

## A documentação do card está errada

O comentário de `FeedItemCardView` afirma que, quando `presentation` é nil, existe fallback para `CachedAsyncImage`.

Mas a implementação real determina:

```swift
private var hasImage: Bool {
    guard let pres = presentation,
          case .image = pres.media
    else {
        return false
    }

    return true
}
```

Quando não há presentation:

```text
hasImage = false
```

Para um vídeo, isso faz o card ser tratado estruturalmente como conteúdo sem imagem.

Portanto, sua observação está correta:

> Não é uma imagem quebrada. O sistema decidiu que aquele card não tinha imagem.

---

# 4. Como a página do source deve funcionar

Ela precisa usar o mesmo conceito do feed principal, mas em uma sessão independente.

## Fluxo correto

```text
usuário clica em View Source
↓
SourceFeedView entra em PREPARING
↓
buscar conteúdo local + atualizar endpoint
↓
mesclar e deduplicar itens
↓
criar sequência editorial daquele source
↓
resolver imagens
↓
decodificar primeira página
↓
publicar items + presentations atomicamente
↓
mostrar página pronta
↓
continuar preparando o restante à frente
```

## Não reutilizar diretamente o coordinator principal

O source não deve substituir a composição editorial do feed principal.

Criar uma sessão independente:

```swift
actor CardPreparationSession {
    let context: FeedPresentationContext
    let coordinator: CardPreparationCoordinator
}
```

Ou uma API que crie uma sessão isolada:

```swift
func prepareSourceFeed(
    _ source: SourceReference
) async -> PreparedSourceFeed
```

Modelo recomendado:

```swift
struct PreparedSourceFeed {
    let source: SourceReference
    let cards: [PreparedFeedCard]
    let fetchStatus: FeedFetchStatus
    let fetchedItemCount: Int
}
```

A página deve armazenar cards preparados, não dois arrays desconectados:

```swift
@State private var cards: [PreparedFeedCard] = []
```

E renderizar:

```swift
ForEach(cards) { card in
    FeedItemView(
        item: card.item,
        presentation: card.presentation,
        onOpen: { articleItem = card.item }
    )
}
```

---

# 5. Quanto esperar antes de mostrar o source

Não recomendo esperar centenas de posts históricos serem preparados antes de abrir a página.

O comportamento ideal é o mesmo do feed:

```text
preparar completamente a primeira página
→ mostrar
→ manter runway pronto para o scroll
```

Por exemplo:

```swift
let initialCount = min(20, sourceItems.count)
```

Antes de mostrar:

```text
20 cards terminais
ou
todos os cards, se o source tiver menos de 20
```

"Terminal" significa:

* imagem pronta;
* placeholder definitivo;
* text-only definitivo.

Nunca:

```text
item publicado enquanto ainda estamos decidindo se ele tem imagem
```

---

# 6. Estado recomendado para as três telas

A raiz do problema é `FeedLoadingState`, que é genérico demais.

Hoje existem apenas:

```swift
idle
initial
refreshing
loadingMore
```

Isso não informa se o conteúdo atual pertence à composição nova ou antiga.

Criar:

```swift
enum FeedDisplayPhase: Equatable {
    case preparing(
        contextID: UInt64,
        reason: PreparationReason
    )

    case ready(
        contextID: UInt64
    )

    case empty(
        contextID: UInt64
    )

    case failed(
        contextID: UInt64,
        message: String
    )
}

enum PreparationReason {
    case startup
    case filterChange
    case manualRefresh
    case source
    case collection
    case presetChange
}
```

## Regras da UI

```text
PREPARING
→ loading screen

READY + cards
→ feed

EMPTY
→ No articles found

FAILED
→ erro/retry
```

Nunca inferir `EMPTY` apenas porque:

```swift
items.isEmpty
```

---

# 7. Correção mínima para Claude Code

## Filtro

Em `setFilter`:

```swift
feedDisplayPhase = .preparing(
    contextID: presentationEpoch,
    reason: .filterChange
)
loadingState = .refreshing
```

Não publicar `immediatelyCullVisibleItemsForActiveFilter()` como feed final.

Pode:

* limpar a tela;
* ou guardar o resultado internamente como candidatos.

Depois de publicar a primeira página preparada:

```swift
feedDisplayPhase = visibleItems.isEmpty
    ? .empty(contextID: presentationEpoch)
    : .ready(contextID: presentationEpoch)
```

## Shake

Antes de `.flush`:

```swift
loadingState = .refreshing
feedDisplayPhase = .preparing(
    contextID: presentationEpoch,
    reason: .manualRefresh
)
```

Somente depois limpar.

## FeedScreen

Substituir a árvore de condições baseada em `items.isEmpty` por um switch em `feedDisplayPhase`:

```swift
switch loader.feedDisplayPhase {
case .preparing:
    InitialFeedLoadingView()
case .ready where loader.items.isEmpty:
    FeedEmptyStateView(...)
case .ready:
    FeedContentView(...)
case .empty:
    FeedEmptyStateView(...)
case .failed(let message):
    FeedErrorView(message: message, onRetry: ...)
}
```

Isso elimina as três categorias de bug com uma única mudança estrutural.
