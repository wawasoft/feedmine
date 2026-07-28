# Feedmine — Cards resolvidos antes de aparecer

## Objetivo

Garantir que todo card entre no feed em um estado visual definitivo.

Quando o card se tornar visível, ele já deve possuir uma destas apresentações:

* imagem final carregada;
* placeholder final;
* layout sem imagem.

Depois de publicado no feed, o card não deve:

* iniciar downloads;
* trocar placeholder por imagem;
* substituir uma imagem por outra de melhor qualidade;
* alterar seu layout por causa do resultado de uma requisição.

---

## Diagnóstico atual

Atualmente, o `FeedItem` é movido para `visibleItems` antes de sua mídia estar preparada.

O fluxo atual é aproximadamente:

```text
FeedItem
   ↓
Reservoir
   ↓
visibleItems
   ↓
SwiftUI cria o card
   ↓
CachedAsyncImage procura a imagem
   ↓
Cache em disco ou download
   ↓
Resolução da página do artigo
   ↓
Imagem aparece ou é substituída
```

O card participa diretamente do pipeline de carregamento.

Quando a imagem não está em memória, o `CachedAsyncImage` cria uma view transparente e inicia `load()` por meio de uma `.task`.

Isso significa que a entrada do card na hierarquia SwiftUI é o gatilho para carregar sua mídia.

---

## Apontamento 1 — O prefetch atual não garante prontidão

O `FeedStore` chama o prefetch antes de publicar alguns itens, mas o método apenas cria uma `Task` e retorna imediatamente.

Na paginação, a sequência atual é:

```text
prefetchUpcoming()
moveToVisible()
setVisibleItems()
```

Como `prefetchUpcoming()` não aguarda a conclusão dos downloads, os itens podem ser publicados antes de suas imagens estarem no cache.

O prefetch atual é uma antecipação de download, não uma barreira de prontidão.

---

## Apontamento 2 — O card pode iniciar download próprio

Quando a imagem não está no cache, o `CachedAsyncImage`:

1. verifica o cache em disco;
2. espera brevemente por um download já em andamento;
3. registra seu próprio download;
4. baixa a imagem;
5. realiza o downsampling;
6. atualiza o estado visual.

Esse comportamento deve ser removido dos cards do feed.

A view deve apenas renderizar um resultado preparado anteriormente.

---

## Apontamento 3 — Imagens existentes apenas no disco ainda aparecem depois

O `body` do `CachedAsyncImage` consulta sincronamente apenas o cache em memória. A leitura do cache em disco acontece dentro da tarefa assíncrona.

Portanto, mesmo uma imagem já baixada em uma sessão anterior pode não estar disponível no primeiro frame do card.

A promoção disco → memória precisa acontecer antes da publicação do card, fora do `body` da view.

---

## Apontamento 4 — Há duas animações de entrada da imagem

O `FeedItemCardView` controla a opacidade externa da imagem usando `imageAppeared`.

O próprio `CachedAsyncImage` mantém outro estado de opacidade e executa uma animação de entrada.

Isso produz duas camadas de transição:

```text
placeholder
→ CachedAsyncImage carregado
→ imagem revelada pelo FeedItemCardView
```

Quando o card passar a ser publicado pronto, ambos os estados podem ser removidos:

```swift
@State private var imageAppeared
@State private var imageLoadFailed
@State private var imageOpacity
```

---

## Apontamento 5 — A imagem pode ser substituída depois de aparecer

Depois de carregar uma imagem, o `CachedAsyncImage` verifica se sua resolução é pequena.

Quando necessário, ele acessa a página do artigo, procura uma imagem melhor e substitui a imagem já exibida.

O fluxo pode ser:

```text
placeholder
→ thumbnail do RSS
→ imagem Open Graph
```

A decisão de upgrade deve acontecer antes da publicação.

Depois que o card entra em `visibleItems`, sua mídia deve permanecer imutável.

---

## Apontamento 6 — A resolução de imagem da página acontece tarde demais

O `FeedStore` possui `resolveArticleImagesInBackground`, mas o próprio comentário estabelece que esse processo não bloqueia o pipeline e que os itens entram imediatamente no reservoir.

No startup, os itens podem ser publicados e só depois o sistema iniciar:

```swift
resolveArticleImagesInBackground(visibleItems)
prefetchUpcoming()
```

A resolução da página precisa acontecer enquanto o item ainda não está visível.

---

## Apontamento 7 — `hasPotentialImage` não representa mídia pronta

Atualmente:

```swift
var hasPotentialImage: Bool {
    bestImageURL != nil || canResolveArticleImage
}
```

Como `canResolveArticleImage` é verdadeiro para quase toda página HTTP ou HTTPS, um artigo pode reservar um espaço de imagem mesmo quando:

* não há imagem no feed;
* a página ainda não foi analisada;
* a resolução da página falhou;
* nenhuma imagem adequada existe.

Para a apresentação do card, é necessário substituir o conceito de imagem potencial por um estado resolvido.

Exemplo:

```swift
enum ResolvedCardMedia: Equatable {
    case image(CachedImageReference)
    case placeholder(ContentPlaceholder)
    case none
}
```

A existência do espaço visual deve depender de `ResolvedCardMedia`, não de uma possibilidade futura de encontrar uma imagem.

---

# Arquitetura recomendada

## Separar conteúdo de apresentação

O `FeedItem` deve continuar representando o conteúdo recebido pelo feed.

Uma segunda estrutura deve representar o card já preparado:

```swift
struct FeedCardPresentation: Identifiable, Equatable {
    let id: String
    let item: FeedItem
    let media: ResolvedCardMedia
    let layout: FeedCardLayout
}
```

Exemplo de layout:

```swift
enum FeedCardLayout: Equatable {
    case hero
    case thumbnail
    case textOnly
}
```

Fluxo recomendado:

```text
FeedItem
   ↓
Reservoir
   ↓
CardPreparationPipeline
   ↓
ReadyCardQueue
   ↓
visibleCards
   ↓
FeedItemCardView
```

A UI deve observar `visibleCards`, não diretamente os `FeedItem` ainda não preparados.

---

# Pipeline de preparação

Cada item deve passar pelo seguinte processo antes de aparecer:

```text
1. Determinar a URL de mídia candidata
2. Verificar cache em memória
3. Verificar cache em disco
4. Baixar imagem, quando permitido
5. Realizar downsampling
6. Avaliar dimensões e qualidade
7. Resolver imagem da página, quando necessário
8. Escolher a imagem definitiva
9. Escolher placeholder ou layout sem imagem em caso de falha
10. Publicar FeedCardPresentation
```

O resultado precisa ser terminal:

```swift
enum CardPreparationResult {
    case ready(FeedCardPresentation)
}
```

Não deve existir um estado publicado como `.loading`.

---

# Ready queue

O sistema deve manter uma fila de cards já preparados à frente da posição do usuário.

Exemplo inicial:

```text
Primeiro viewport:      8 cards prontos
Prioridade imediata:   próximos 16 cards
Prioridade normal:     próximos 32 cards
Reservoir bruto:       demais itens
```

Quando o usuário se aproxima do final dos cards preparados:

```text
Reservoir
   ↓
preparar próximo lote
   ↓
aguardar resultados terminais
   ↓
adicionar lote em visibleCards
```

Os cards não devem ser adicionados individualmente conforme cada imagem termina. O lote deve ser promovido depois que todos os itens tiverem uma apresentação resolvida.

---

# Comportamento em timeout ou falha

Um timeout de mídia não deve publicar um card incompleto.

Ele deve produzir uma decisão final:

```text
Imagem disponível
→ card com imagem

Imagem indisponível
→ placeholder final

Imagem não necessária ou inadequada
→ card text-only
```

O timeout encerra a preparação, não transfere a responsabilidade para a view.

---

# Alterações no `CachedAsyncImage`

O `CachedAsyncImage` atual não deve ser utilizado dentro do feed principal.

A view do card deve receber uma imagem já disponível em memória, ou uma referência que possa ser resolvida sem rede e sem mudança posterior.

Exemplo:

```swift
struct PreparedCardImage: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
    }
}
```

O pipeline de rede pode continuar existindo como serviço, mas não como parte do ciclo de vida da view.

---

# Alterações no `FeedItemCardView`

Remover:

```swift
@State private var imageLoadFailed
@State private var imageAppeared
```

Remover também:

```swift
CachedAsyncImage(...)
    .task(...)
```

O card deve renderizar diretamente o estado resolvido:

```swift
switch presentation.media {
case .image(let reference):
    PreparedCardImage(image: reference.image)

case .placeholder(let placeholder):
    PlaceholderView(kind: placeholder)

case .none:
    EmptyView()
}
```

O layout não deve depender de mudanças assíncronas.

---

# Alterações no `FeedStore`

Atualmente, `visibleItems` contém `FeedItem`.

A implementação pode evoluir para:

```swift
private(set) var visibleCards: [FeedCardPresentation] = []
```

O método equivalente a `setVisibleItems` deve receber somente apresentações prontas.

As operações:

```swift
moveToVisible
setVisibleItems
applyUpdate(.append)
applyUpdate(.refresh)
```

devem passar a solicitar preparação antes da publicação.

Exemplo conceitual:

```swift
let items = reservoir.takeUpcoming(count: Reservoir.pageSize)
let cards = await cardPreparationPipeline.prepare(items)
setVisibleCards(cards)
```

---

# Primeiro carregamento

A tela inicial não deve sair do loading apenas porque `FeedItem` existe.

O critério deve ser a existência de cards preparados:

```swift
loader.visibleCards.count >= minimumInitialReadyCards
```

A métrica atual de primeiro conteúdo útil é registrada quando `items.count > 0`.

Ela deve ser substituída ou complementada por:

```text
UI.firstRenderReadyContent
```

---

# Política de atualização da mídia

Depois que um `FeedCardPresentation` é publicado:

* sua imagem não muda;
* seu placeholder não muda;
* seu layout não muda;
* nenhum upgrade de resolução é aplicado naquela apresentação.

Uma imagem melhor encontrada posteriormente pode ser gravada no cache para:

* próxima abertura;
* reconstrução futura do card;
* mudança de layout;
* nova sessão.

Ela não deve alterar um card atualmente visível.

---

# Concorrência e prioridade

A preparação deve usar prioridade baseada na distância do viewport:

```text
cards do primeiro viewport    userInitiated
próximos cards                high
cards posteriores             utility
cache de sessões futuras      background
```

O limite de concorrência deve continuar controlado para evitar saturação da rede.

O `ImagePrefetcher` atual permite até 16 downloads simultâneos.

Para preparação de cards, é recomendável separar:

* concorrência de imagens diretas;
* concorrência de resolução de páginas;
* prioridade do primeiro viewport;
* preparação de baixa prioridade.

---

# Critérios de aceite

A implementação estará correta quando:

1. nenhum card visível iniciar requisição de imagem;
2. nenhuma imagem surgir depois que o card apareceu;
3. nenhum placeholder for substituído depois da publicação;
4. nenhuma imagem for substituída por uma versão melhor enquanto visível;
5. imagens existentes apenas no disco estiverem prontas no primeiro frame;
6. falhas produzirem placeholder ou layout sem imagem definitivo;
7. o primeiro viewport for publicado apenas com cards resolvidos;
8. a paginação adicionar apenas lotes de cards preparados;
9. o scroll rápido nunca alcançar cards em estado de carregamento;
10. mudanças de mídia visível forem zero.

---

# Métricas recomendadas

```text
card_ready_at_insert_rate
visible_card_media_mutations
visible_placeholder_to_image_count
visible_image_upgrade_count
ready_queue_depth
card_prepare_duration_p50
card_prepare_duration_p95
initial_ready_cards_duration
disk_cache_prepare_duration
```

Metas principais:

```text
card_ready_at_insert_rate          100%
visible_card_media_mutations       0
visible_placeholder_to_image       0
visible_image_upgrade_count        0
```

---

# Ordem de implementação

1. Criar `ResolvedCardMedia`.
2. Criar `FeedCardPresentation`.
3. Criar `CardPreparationPipeline`.
4. Preparar cache de memória e disco antes da publicação.
5. Mover download e resolução Open Graph para o preparador.
6. Criar `ReadyCardQueue`.
7. Alterar o primeiro carregamento para aguardar cards prontos.
8. Alterar paginação para promover lotes prontos.
9. Remover `CachedAsyncImage` do feed.
10. Remover estados e animações de carregamento dos cards.
11. Impedir upgrades em apresentações já publicadas.
12. Adicionar testes e métricas de mutação visual.

---

# Resumo técnico

O problema não deve ser tratado como uma otimização de prefetch.

A correção necessária é alterar a fronteira de publicação:

```text
Atual:
artigo pronto → publicar → resolver imagem

Correto:
artigo pronto → resolver apresentação → publicar
```

O card precisa ser um resultado final do pipeline, não uma etapa ativa dele.
