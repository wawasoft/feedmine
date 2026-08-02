# Code Review — Contador de Sources do Topo

## Veredito

O contador atualmente **não representa uma única métrica consistente**.

O mesmo espaço do cabeçalho alterna entre:

```text
startup:
fontes que responderam ao fetch / total de fontes do catálogo

modo normal:
fontes consideradas ativas / total de fontes do catálogo

collection:
membros da collection / total de fontes do catálogo
```

Essas três frações possuem significados diferentes.

O principal defeito é o contador de startup: o numerador é limitado a aproximadamente 100 fontes, enquanto o denominador é o catálogo inteiro, atualmente 43.556. Assim, o aplicativo pode mostrar:

```text
100 / 43556
```

e imediatamente exibir um checkmark verde dizendo que o runway está pronto.

Isso é matematicamente e semanticamente contraditório.

---

## 1. Como o contador funciona hoje

### Durante o startup

O cabeçalho entra no modo de progresso quando:

```swift
loader.isPreparingInitialRunway || showReadyPulse
```

Nesse modo, mostra:

```swift
loader.startupFetchedSourceCount / startupTotal
```

e `startupTotal` é:

```swift
max(
    loader.startupTotalSourceCount,
    loader.sourceCount
)
```

No início do `FeedStore.start()`:

```swift
startupFetchedSourceCount = 0
startupTargetSourceCount = 100
startupTotalSourceCount = activeCatalogSourceCount()
startupRunwayReady = false
```

Depois que os OPMLs terminam de carregar:

```swift
startupTotalSourceCount = registry.sourceCount
```

No catálogo atual, isso significa:

```text
startupTargetSourceCount = 100
startupTotalSourceCount  = 43.556
```

### Como o numerador cresce

`recordStartupFetchProgress` incrementa o contador para URLs distintas que retornem status `.success`.

Depois limita o valor ao target:

```swift
startupFetchedSourceCount =
    min(startupTargetSourceCount,
        startupSuccessfulSourceURLs.count)
```

O runway é declarado pronto quando o numerador alcança o target de 100:

```swift
startupRunwayReady =
    startupFetchedSourceCount >= startupTargetSourceCount
```

Logo, o numerador nunca passará de 100, embora o denominador seja 43.556.

### Depois do startup

O cabeçalho passa a mostrar:

```swift
loader.activeSourceCount / loader.sourceCount
```

`sourceCount` é simplesmente:

```swift
registry.sources.count
```

`activeSourceCount` é:

```swift
store.presetSourceFilter?.count
    ?? activeSources.count
```

Portanto, o denominador é o catálogo carregado, e o numerador tenta representar as fontes ativas na configuração atual.

---

## 2. P0 — O progresso de startup usa denominador errado

O target real do startup não é verificar as 43.556 fontes.

O startup deseja produzir um runway inicial usando, no máximo, 100 fontes distintas:

```swift
startupTargetSourceCount =
    max(1, min(100, targetSourceCount))
```

Consequentemente, o cabeçalho deveria mostrar:

```text
37 / 100 sources checked
```

e não:

```text
37 / 43556
```

Quando chegar a:

```text
100 / 100
```

o checkmark verde fará sentido.

### Situação atual

```text
numerador = progresso da preparação inicial
denominador = tamanho total do catálogo
```

São universos diferentes.

### Correção

Durante o startup:

```swift
private var startupProgressTotal: Int {
    loader.startupTargetSourceCount
}
```

E o texto:

```swift
Text(
    "\(loader.startupFetchedSourceCount)/\(loader.startupTargetSourceCount)"
)
```

O total do catálogo pode ser exibido depois, no estado normal.

---

## 3. P0 — O checkmark não significa necessariamente runway útil

O numerador conta um resultado sempre que:

```swift
result.status == .success
```

Mas o modelo considera HTTP `notModified` como sucesso:

```swift
case .notModified:
    return .success
```

Assim, uma fonte pode aumentar o contador mesmo sem ter fornecido um novo item.

O critério real de runway útil é diferente:

```swift
items.count >= target
&&
Set(items.map(\.sourceURL)).count >= target
```

Hoje existem, portanto, duas noções de "pronto":

```text
contador:
100 respostas bem-sucedidas

pipeline de conteúdo:
100 fontes que realmente forneceram itens
```

Essas condições podem divergir.

### Correção

Separar explicitamente:

```swift
startupCheckedSourceCount
startupContributingSourceCount
startupTargetContributingSourceCount
initialContentReady
```

O checkmark deve reagir a:

```swift
initialContentReady
```

e não apenas ao número de respostas HTTP bem-sucedidas.

O texto pode continuar mostrando fontes verificadas, mas não deve afirmar que o runway está pronto por causa desse contador.

---

## 4. P1 — O contador normal não usa a mesma elegibilidade do feed

`FeedLoader.activeSources` começa com:

```swift
let base = store.registry.enabledSources
```

e depois aplica região, idioma, tipo e taxonomia.

Porém, o feed real possui uma regra diferente.

Quando existe um content type explícito ou uma seleção de taxonomy, `FeedStore.isSourceEligible` ignora desativações herdadas de categoria e região e respeita somente o opt-out explícito daquela fonte:

```swift
let isExplicitCatalogueQuery =
    activeContentType != .all
    || taxonomySelectionMatches

if isExplicitCatalogueQuery {
    return !registry.isSourceExplicitlyDisabled(sourceURL)
}
```

Enquanto isso, `registry.enabledSources` exclui:

- fontes `defaultEnabled == false`;
- regiões desabilitadas;
- países desabilitados;
- categorias desabilitadas.

### Exemplo

O usuário escolhe:

```text
Content type: Podcasts
```

O feed permite consultar fontes de podcasts mesmo que o país ou a categoria delas esteja desativado por herança, desde que a fonte não tenha sido individualmente desligada.

Mas o contador começa por `registry.enabledSources`, que já removeu essas fontes.

Resultado:

```text
feed consulta e exibe a fonte
contador não inclui a fonte
```

### Correção

Não duplicar a regra de elegibilidade no `FeedLoader`.

Criar uma única API no `FeedStore`:

```swift
func sourceIsEligibleForCurrentContext(
    _ source: FeedSource
) -> Bool
```

E fazer com que:

- fetch;
- filtros;
- coverage mining;
- source counter;

usem exatamente o mesmo predicado.

---

## 5. P1 — O contador muda de significado conforme o modo

`activeSourceCount` só conhece:

```swift
presetSourceFilter
ou
activeSources
```

Ele não considera explicitamente:

- bookmark mode;
- Last Clicked;
- Smart Feed;
- busca;
- o snapshot realmente mostrado na tela.

### Bookmark mode

Enquanto o usuário visualiza uma caixa com artigos salvos de três fontes, o cabeçalho pode continuar mostrando:

```text
12.000 / 43.556 sources
```

Isso descreve o catálogo habilitado, não a tela atual.

### Smart Feed

Um Smart Feed pode conter conteúdo de 18 fontes, mas o contador continua baseado em todas as fontes habilitadas pela configuração global.

### Last Clicked

O mesmo ocorre ao visualizar o histórico de itens clicados.

### Collection

Para uma collection, `activeSourceCount` retorna:

```swift
presetSourceFilter.count
```

Mas o denominador continua sendo todo o catálogo.

Isso produz:

```text
12 / 43556 sources
```

Embora as 12 fontes da collection possam incluir fontes pessoais que nem fazem parte das 43.556 fontes catalogadas.

A fração mistura novamente universos distintos.

### Correção sugerida

Definir a semântica por modo:

```text
Main/editorial:
12.482 enabled · 43.556 catalog

Filtro:
842 sources match

Collection:
12 sources

Smart Feed:
18 sources in this feed

Bookmarks:
3 sources in this box

Last Clicked:
27 sources in history

Search:
46 source matches
```

Não é necessário usar uma fração em todos os contextos.

---

## 6. P1 — Collection pode mostrar `X/0 sources` na abertura

O startup permite que uma collection persistida seja hidratada antes do carregamento completo do catálogo.

Se a hidratação local encontrar itens, o código define:

```swift
isPreparingInitialRunway = false
loadingState = .idle
```

antes de executar:

```swift
await registry.loadFromOPML()
```

Ao mesmo tempo, `rebuildPresetMultipliers` monta `presetSourceFilter` diretamente a partir dos membros da collection:

```swift
let normalizedMembers = Set(members.map { ... })
presetSourceFilter = normalizedMembers.union(registryMatches)
```

Mesmo que o registry ainda esteja vazio.

Nesse intervalo:

```text
activeSourceCount = número de membros da collection
sourceCount       = 0
```

Como `isPreparingInitialRunway` já foi desligado, o cabeçalho normal pode renderizar:

```text
12/0 sources
```

### Correção

Collection não deve usar o denominador global.

Durante collection mode:

```swift
Text("\(collectionMemberCount) sources")
```

Isso também elimina o estado impossível `X/0`.

---

## 7. P1 — O contador pode executar um scan de 43 mil fontes no Main Actor

`activeSources` é uma propriedade computada.

Quando qualquer filtro está ativo, ela executa:

```swift
base.filter { source in
    // região
    // idioma
    // tipo
    // taxonomy
}
```

Com o catálogo atual, isso pode significar filtrar 43.556 objetos sempre que o valor precisar ser recalculado.

Além disso, `registry.enabledSources` pode reconstruir seu cache sincronamente:

```swift
var enabledSources: [FeedSource] {
    if let cached = _enabledSources {
        return cached
    }

    recomputeActiveCounts()
    return _enabledSources ?? []
}
```

`recomputeActiveCounts` percorre todas as fontes no `MainActor`.

### A otimização de debounce pode ser anulada

Quando um toggle muda, o registry invalida o cache e agenda a reconstrução para 120 ms depois.

Mas uma renderização imediata do cabeçalho pode ler `activeSourceCount`, que lê `enabledSources` e força a reconstrução naquele instante.

Assim, o cabeçalho pode anular a intenção do debounce e executar um scan completo durante a interação.

### Correção

O contador não precisa materializar um array de `FeedSource`.

Criar um valor cacheado:

```swift
private(set) var currentEligibleSourceCount: Int
```

Recalcular somente quando mudar uma chave relevante:

```text
sourceRevision
enablementRevision
presetGeneration
filterGeneration
region
languages
content type
taxonomy
modo
```

Também é possível usar:

```swift
struct SourceCountCacheKey: Hashable {
    let sourceRevision: UInt64
    let enablementRevision: UInt64
    let presetGeneration: Int64
    let filterGeneration: Int64
    let mode: FeedPresentationMode
}
```

A view deve ler apenas o inteiro já calculado.

---

## 8. P2 — O texto normal não está preparado para cinco dígitos

O modo startup possui:

```swift
.lineLimit(1)
.minimumScaleFactor(0.8)
```

Mas o estado normal apenas apresenta:

```swift
Text("·\(active)/\(total) sources")
```

sem limitação ou redução.

Com 43.556 fontes, o texto pode ter formato semelhante a:

```text
·12847/43556 sources
```

Isso disputa espaço com:

- busca;
- bookmarks;
- filtros;
- menu.

Em telas pequenas ou com Dynamic Type, pode:

- comprimir os botões;
- truncar o cabeçalho;
- quebrar o layout;
- aumentar a altura inesperadamente.

### Correção

Visual compacto:

```text
12.8K / 43.6K
```

Accessibility com valores completos:

```text
12.847 fontes habilitadas de 43.556 no catálogo
```

Ou usar agrupamento local:

```swift
Text(
    "\(active.formatted()) / \(total.formatted())"
)
```

Adicionar:

```swift
.lineLimit(1)
.minimumScaleFactor(0.7)
.layoutPriority(1)
```

---

## 9. P2 — Texto e acessibilidade usam idiomas diferentes

A interface mostra:

```text
sources
```

mas o accessibility label do startup está hard-coded em português:

```swift
"\(count) de \(total) fontes verificadas"
```

O restante da tela está em inglês.

Isso deve ser movido para localization e usar a língua configurada pelo aplicativo.

---

## 10. Ausência de testes específicos

Não encontrei testes dedicados a:

- `CompactFeedStatus`;
- `activeSourceCount`;
- `startupTotal`;
- transição entre progresso e ready;
- collection antes do registry;
- catálogos com dezenas de milhares de fontes.

A busca pelo componente retorna somente a implementação em `FeedScreen.swift`.

Com a recente expansão do catálogo, testes de layout e semântica desse contador se tornaram necessários.

---

## Arquitetura recomendada

O cabeçalho não deveria montar a métrica combinando várias propriedades independentes.

Criar um único modelo já resolvido no `FeedStore`:

```swift
enum HeaderSourceStatus: Equatable {
    case loadingCatalog
    case preparing(
        checked: Int,
        target: Int
    )
    case main(
        eligible: Int,
        catalogTotal: Int
    )
    case filtered(
        matching: Int
    )
    case collection(
        members: Int
    )
    case smartFeed(
        represented: Int
    )
    case bookmarks(
        represented: Int
    )
    case history(
        represented: Int
    )
}
```

O `CompactFeedStatus` apenas renderizaria:

```swift
switch loader.headerSourceStatus {
case .preparing(let checked, let target):
    Text("\(checked)/\(target)")

case .main(let eligible, let total):
    Text("\(eligible.formatted())/\(total.formatted()) sources")

case .filtered(let matching):
    Text("\(matching.formatted()) sources match")

case .collection(let members):
    Text("\(members.formatted()) sources")

...
}
```

Isso dá uma definição estável para cada estado e impede a view de combinar contadores incompatíveis.

---

## Testes necessários

### Startup normal

```text
catalogTotal = 43.556
startupTarget = 100
checked = 37

resultado:
37/100
```

Não:

```text
37/43556
```

### Startup concluído

```text
checked = 100
target = 100
initialContentReady = true

resultado:
100/100 + checkmark
```

### Respostas sem conteúdo

```text
100 fontes respondem
20 fornecem itens

resultado:
contador de checked pode chegar a 100
checkmark de runway não aparece
```

### Content type explícito

```text
fonte está dentro de país desativado
fonte não foi individualmente desativada
filtro = Podcasts

resultado:
fonte incluída no mesmo critério usado pelo feed
```

### Collection antes do catálogo

```text
collection = 12 membros
registry = vazio

resultado:
12 sources
```

Nunca:

```text
12/0 sources
```

### Bookmark box

```text
20 itens
3 sourceURLs únicas

resultado:
3 sources in this box
```

### Performance

Com 50 mil fontes:

```text
abrir header
alternar filtro
alternar região
```

O body do cabeçalho não deve percorrer as 50 mil fontes.

### Layout

Testar:

- iPhone SE;
- Dynamic Type máximo;
- total de seis dígitos;
- localização com palavras longas;
- modo offline e error banner ativos.

---

## Conclusão

O contador atual mistura três conceitos:

```text
catálogo total
fontes configuradas
fontes verificadas no startup
```

O erro mais evidente está aqui:

```swift
startupFetchedSourceCount
/
max(startupTotalSourceCount, sourceCount)
```

O numerador tem target máximo de 100, enquanto o denominador atual é 43.556.

A correção prioritária é:

```text
startup:
checked / startupTarget

modo normal:
eligible / catalogTotal

modos fixos:
quantidade de fontes daquele contexto
```

Depois disso, a contagem de fontes elegíveis deve ser centralizada no `FeedStore`, usando a mesma regra do pipeline e sem filtrar dezenas de milhares de fontes dentro do body do cabeçalho.
