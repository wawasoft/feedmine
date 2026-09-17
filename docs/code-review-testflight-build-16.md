# FeedMine — Code Review das regressões do feed / TestFlight build 16

## Conclusão

A regressão observada no TestFlight é consistente com o código atual.

O problema principal não é que o FeedMine esteja “baixando devagar”. O problema é que **aquisição, seleção editorial, preparação visual, publicação e manutenção do runway não têm hoje uma fronteira suficientemente rígida entre si**.

O produto tem boa parte das peças necessárias — reservoir, interleave, prepared pipeline, MediaAssetStore, CardPreparationCoordinator, RunwayController, cache persistente — mas essas peças foram evoluindo incrementalmente e agora existem comportamentos contraditórios entre elas.

O resultado é exatamente o relatado:

- o app consegue publicar algo antes de estar realmente pronto;
- cards publicados ainda podem mudar posteriormente;
- imagens resolvidas em background provocam novas mutações de estado;
- essas mutações podem invalidar estruturas do feed enquanto o usuário está rolando;
- a regra de diversidade existe no reservoir, mas não é uma invariável da sequência publicada;
- `quality_score` existe, mas não é a prioridade-base de todos os caminhos;
- o warm start guarda conteúdo, mas **não guarda de fato um feed visual pronto**.

A recomendação é **não continuar corrigindo esses sintomas individualmente**. Antes do próximo TestFlight, eu faria uma refatoração concentrada na pipeline de apresentação.

---

# P0 — Warm start está restaurando itens, não um feed pronto

Este é provavelmente o motivo mais direto daquele conteúdo feio que aparece imediatamente ao abrir o aplicativo.

`FeedDisplayState` possui explicitamente um cache para “instant warm-start restore”. Porém o objeto persistido é:

`CachedPage { items, visibleItemsGeneration }`

Ou seja: **os `FeedCardPresentation` não são persistidos**. O próprio código documenta que, quando `visibleCards` não está disponível, a interface volta para `CachedAsyncImage`.

No startup, o `FeedStore` encontra esse snapshot e faz:

`display.setVisibleItems(...)`

Ele não restaura os cards preparados.

Portanto o comportamento relatado tem explicação direta:

**abertura → restaura rapidamente FeedItem antigo → cards não preparados / imagens ainda não resolvidas → pipeline real começa a trabalhar → apresentação vai ficando completa depois.**

Isso não corresponde ao objetivo do produto.

### Correção

O warm-start não deve persistir uma lista de `FeedItem`.

Deve persistir um **Prepared Feed Snapshot** contendo pelo menos:

- item;
- posição editorial;
- tipo/layout final do card;
- media decision final;
- `imageCacheKey`, quando houver;
- provider identity;
- quality score;
- contexto/filtro ao qual aquele runway pertence;
- estado seen/unseen;
- timestamp de preparação.

Ao reabrir:

**SQLite/cache → selecionar cards preparados e unseen → validar assets locais → publicar atomicamente.**

A rede não deve participar do caminho crítico do warm start.

Se houver 40 cards antigos, totalmente preparados e ainda unseen, eles são mais valiosos para a experiência inicial do que 5 cards recém-baixados incompletos.

---

# P0 — O cold start deliberadamente publica um runway incompleto

Há uma intenção correta no código: construir um cold-start diverso a partir de até 100 fontes distintas.

Existem inclusive constantes para isso e uma função `coldStartRunwayIsUseful()` que exige quantidade e diversidade de fontes.

Mas em seguida existe um fallback que quebra essa regra.

O startup define:

- first-paint deadline: **12 segundos**;
- runway deadline: **30 segundos**.

Depois de 12 segundos, se ainda houver conteúdo pendente, o código explicitamente faz:

> publish whatever we have

e persiste apenas:

`coldStartPendingItems.prefix(20)`

Depois abandona o loop inicial e deixa o progressive fetch preencher o restante em background.

Isso é muito próximo do comportamento observado: aparece pouca coisa, sem runway real, e alguns segundos depois o feed começa a ganhar corpo.

### Correção

Para banco vazio, **não deve existir esse fallback visual**.

O estado correto é:

`Loading → Prepared runway complete → Feed`

e não:

`Loading → partial feed → better feed → final feed`

Se demora 15 segundos, a loading screen pode ficar 15 segundos. É preferível a mostrar um produto quebrado durante esses 15 segundos.

O gate inicial deve considerar simultaneamente:

**content ready + editorial ready + presentation ready + media decision terminal + minimum runway ready.**

Não simplesmente “há alguma coisa para mostrar”.

---

# P0 — O pipeline permite explicitamente que cards mudem depois de publicados

Este é o maior conflito conceitual que encontrei.

O `FeedStore` possui comentário dizendo:

> “The UI must never see a card without its resolved media, then see an image appear later — that violates the ‘feed is sacred’ contract.”

Mas o `CardPreparationCoordinator` implementa exatamente esse comportamento.

Quando uma imagem perde o deadline, o card é declarado render-ready como **text-only**. Depois inicia um deferred retry. Se a imagem chegar posteriormente, o card publicado é convertido de text-only para hero.

O código é explícito:

> “card is already published as text-only”

e depois:

> “upgrade to `.image` + `.hero` in-place”

Se o card já saiu do coordinator e está na tela, existe inclusive callback específico para modificar o card publicado.

Isso explica muito bem o relato:

**primeiro cards sem imagem → depois cards bonitos/coloridos → feed mudando enquanto está sendo usado.**

### Correção

Depois que um card entrou no runway publicado, sua apresentação deve ser **imutável durante aquela sessão**.

A imagem não chegou a tempo?

Há duas opções válidas:

1. ele não entra ainda no runway; ou
2. a decisão editorial definitiva é text-only.

O que não deveria existir no main feed é:

`text-only publicado → alguns segundos depois hero`.

Se a imagem for resolvida posteriormente, ela fica preparada para a próxima composição/reabertura. Não modifica o card que o usuário já recebeu.

---

# P0 — Existe uma causa muito plausível para o scroll travando

O upgrade tardio explicado acima não é apenas cosmético.

Quando uma imagem finalmente chega, o callback volta para o `MainActor`, procura o card visível e executa `replaceVisibleCard`.

`replaceVisibleCard` incrementa `visibleCardsGeneration`.

O problema seguinte está no `FeedLoader`.

`visibleCardsGeneration` participa da chave dos caches de:

- `filteredItems`;
- `dateSections`;
- estruturas derivadas dos cards.

Assim, uma atualização puramente visual pode invalidar novamente a estrutura derivada do feed.

Com várias imagens chegando em paralelo, o padrão pode ser:

`imagem chega → MainActor → card muda → generation muda → recomposição → outra imagem chega → generation muda → recomposição...`

justamente enquanto o usuário está rolando.

Isso é uma explicação estrutural muito melhor para a regressão do scrolling do que simplesmente “SwiftUI está lento”.

### Correção

Duas alterações:

**1. eliminar upgrades visuais depois da publicação**, resolvendo grande parte do problema na origem;

**2. separar completamente geração estrutural de geração visual.**

Uma alteração de mídia nunca deveria invalidar:

- filtering;
- grouping;
- ordering;
- date sections;
- editorial sequence.

Idealmente, durante scroll normal, o array publicado fica praticamente congelado.

O usuário move o viewport. O backend prepara o futuro. O backend **não reconstrói o presente**.

---

# P0 — A regra de diversidade está no lugar errado

O `Reservoir` possui hoje uma quantidade considerável de lógica boa:

- interleave por source;
- spreading;
- country spreading;
- freshness;
- `frontLoadUniqueProviders`;
- janela recente de providers;
- penalidade muito alta para provider repetido.

O código inclusive diz que o início do feed é a promessa de breadth do produto.

E há lógica que analisa providers recentemente utilizados para evitar repetição.

O problema é arquitetural:

**essa é uma característica do Reservoir, não uma invariável do feed publicado.**

O `CardPreparationCoordinator` recebe uma sequência editorial pronta e preserva sua ordem. Ele não verifica novamente provider diversity.

Entre o Reservoir e a publicação existem filtros, reloads, appends, compositions, balanceamento e mudanças de contexto.

Portanto basta uma dessas etapas fornecer uma sequência ruim para chegar ao usuário:

`Gato Galáctico`
`Gato Galáctico`
`Gato Galáctico`
`Gato Galáctico`
...

### Correção

Criar **um único `EditorialSequencer`** responsável pela ordem final.

Tudo fornece candidatos a ele.

Ele devolve uma sequência editorial imutável, aplicando nessa ordem:

eligibility → active filter → consumed/unseen → quality → diversity constraints → freshness → media/category/region balance.

O `CardPreparationCoordinator` apenas prepara essa sequência.

O `FeedDisplayState` apenas publica essa sequência.

Nenhuma dessas duas etapas deveria possuir política editorial.

E deve existir uma assertion/test no limite final da pipeline.

Se existem providers alternativos suficientes, uma sequência com cinco itens consecutivos do mesmo provider simplesmente não pode sair do sequencer.

---

# P1 — O ranking de qualidade não é hoje uma prioridade global

O catálogo possui `quality_score`, e há consultas específicas que ordenam por ele.

Mas a principal abstração usada pelo pipeline é `presetMultipliers`.

E para:

- `.everything`;
- `.lastClicked`;
- `.smartFeed`;

`PresetScorer` retorna um dictionary vazio, fazendo todas as fontes caírem no multiplier default `1.0`.

Ao mesmo tempo, várias rotinas dizem estar priorizando “high-quality sources” simplesmente ordenando por `presetMultipliers`.

Para `Everything`, isso não produz ranking de qualidade.

Portanto sua regra desejada ainda não está implementada de forma coerente:

> quando não existe outra prioridade mais forte, baixar/preparar os melhores antes dos piores.

### Correção

O quality score deve ser **baseline**, não preset.

Algo conceitualmente assim:

`priority = eligibility × filter relevance × preset relevance + quality + health/freshness adjustments`

Não literalmente essa equação, mas essa separação.

Um preset pode alterar prioridades.

Ele não deveria ser a única origem da prioridade.

Assim:

1. runway da filtragem ativa;
2. reserve da filtragem ativa;
3. high-probability adjacent content;
4. highest-quality general sources;
5. restante do catálogo.

---

# P1 — O cache específico de filtros não é estável entre launches

Existe tentativa de armazenar uma página por `filterSignature`.

Porém o nome do arquivo é gerado com:

`filterSignature.hashValue`

`hashValue` do Swift não é um identificador persistente entre processos.

Portanto uma assinatura salva numa execução não é uma chave confiável para ser reencontrada na próxima abertura do aplicativo.

Isso compromete justamente o cenário desejado de:

**“eu tinha uma filtragem ativa, fechei o app, abri novamente e quero conteúdo pronto imediatamente.”**

### Correção

Usar hash determinístico, por exemplo SHA-256 ou o mesmo FNV-1a já usado em outras partes do projeto.

---

# P1 — Ainda existem duas arquiteturas de feed convivendo

O projeto ainda mantém:

- `ReadyCardQueue`;
- legacy preparation;
- Reservoir publishing;
- prepared pipeline;
- `CardPreparationCoordinator`;
- feature flag `preparedFeedPipelineEnabled`;
- diversos guards `if usePreparedPipeline`.

O histórico mostra que isso já causou bugs reais.

Em julho houve correção para:

- startup drenando todo o reservoir porque `visibleItems` permanecia zero no pipeline async;
- legacy `cardQueue` sobrescrevendo `visibleCards`;
- feed sendo truncado para 20 cards;
- startup não iniciando corretamente o runway;
- cache keys causando misses.

Em agosto houve outra correção porque o legacy pipeline deixava `visibleItems` vazio mesmo quando o reservoir já tinha itens visíveis.

Isso é forte evidência de que os dois modelos estão interferindo na capacidade de raciocinar sobre o estado.

### Correção

Para 1.0 eu eliminaria a dualidade da execução de produção.

**Uma pipeline.**

Os testes não deveriam precisar de uma arquitetura legacy diferente só porque o prepared pipeline é assíncrono. Para testes, usar dependencies/fakes determinísticos dentro da mesma pipeline.

---

# P1 — A refatoração do FeedStore começou, mas não terminou

Já houve reconhecimento explícito desse problema.

O commit que criou `FeedDisplayState` foi chamado de “Phase 1” da decomposição do `FeedStore`, e o próprio commit registrava que **210 referências ainda precisavam ser migradas**.

Depois disso, o grande snapshot de 15 de setembro voltou a mexer profundamente nessa área: somente `FeedStore.swift` recebeu **563 adições e 160 remoções** dentro de um commit WIP que acumulou 3.398 linhas de mudança no repositório.

Então a percepção de “remendos em cima de remendos” tem fundamento técnico.

Não significa que as correções anteriores foram ruins. Muitas delas corrigem bugs reais.

O problema é que elas continuam sendo colocadas dentro de um orchestration graph excessivamente acoplado.

---

# Arquitetura que eu implementaria

Eu reduziria o fluxo a cinco componentes com responsabilidades rígidas:

**ContentRepository**  
SQLite + raw fetched content + seen state + source metadata + quality.

**EditorialSequencer**  
Recebe candidatos e produz ordem final. É o único responsável por quality/diversity/freshness/filter policy.

**CardPreparer**  
Transforma item editorial em card terminal. Faz download, resolve imagem, decide hero/text-only e persiste o resultado preparado.

**PreparedRunwayRepository**  
Mantém cards já prontos, inclusive entre launches e por context buckets relevantes.

**FeedSessionController**  
Somente decide quando revelar uma sequência e quando pedir mais runway.

O UI nunca conversa com fetcher, resolver, reservoir ou retry.

Ele recebe:

`[PublishedCard]`

e esses `PublishedCard` são imutáveis durante a sessão.

---

# Fluxo correto — banco vazio

1. Mostrar loading screen.
2. Ler filtro/preset ativo.
3. Buscar primeiro fontes elegíveis para aquele contexto.
4. Aplicar quality priority.
5. Construir candidatos suficientes.
6. `EditorialSequencer` aplica diversidade.
7. Preparar cards e mídia.
8. Persistir prepared runway.
9. Quando existir um primeiro runway utilizável, publicar atomicamente.
10. Continuar preparando reserve do mesmo contexto.
11. Quando essa reserve atingir o target, começar a preparar outros buckets de alta probabilidade/qualidade.

Não existe publicação do `prefix(20)` porque o relógio chegou a 12 segundos.

---

# Fluxo correto — reabertura

1. Consultar prepared runway local.
2. Eliminar seen/invalid.
3. Escolher a melhor sequência já pronta.
4. Publicar imediatamente.
5. Só então refresh/fetch/preparation começam em background.
6. Conteúdo novo entra **no futuro do runway**, sem modificar o que já está publicado.

Esse modelo atende exatamente à prioridade de produto:

**estabilidade > novidade.**

---

# Fluxo correto — mudança de filtro

Primeiro procurar no prepared repository.

Se houver reserve suficiente:

`filter tap → composição local → feed`

sem rede.

Se não houver:

preservar a experiência anterior ou mostrar preparação apropriada até existir um novo primeiro runway coerente.

Não apresentar cinco cards e depois preencher a página enquanto o usuário tenta usá-la.

---

# O que eu não faria

Eu não:

- aumentaria 6 segundos para 10;
- mudaria 12 segundos para 20;
- aumentaria concorrência de imagens;
- adicionaria outro prefetch;
- colocaria mais um `if usePreparedPipeline`;
- aumentaria simplesmente o reservoir;
- tentaria corrigir “Gato Galáctico” apenas alterando uma constante de interleave.

Tudo isso atacaria manifestações da mesma arquitetura.

---

# Critérios de aceite antes do próximo TestFlight

**Cold start**
- banco vazio nunca revela feed parcial;
- primeiro paint possui um conjunto completo de cards preparados;
- todos possuem presentation decision terminal;
- diversidade é validada antes de publish.

**Warm start**
- funciona sem rede;
- nenhum card começa “quebrado” para ganhar imagem depois;
- seen content é removido da seleção inicial;
- existe runway local além da primeira tela.

**Scrolling**
- nenhum fetch ou image completion reorganiza cards já publicados;
- nenhuma image completion invalida filtering/date sections;
- ordem e dimensões dos cards publicados permanecem estáveis.

**Diversity**
- teste automatizado no output final do EditorialSequencer;
- repetição consecutiva do mesmo provider é rejeitada quando há alternativas;
- primeira página mantém a política de breadth já pretendida pelo Reservoir.

**Quality**
- quality baseline é utilizada mesmo em `Everything`;
- depois de completar o reserve do contexto atual, background preparation começa pelos candidatos de maior prioridade.

**Filter switch**
- contextos previamente preparados mudam sem rede;
- snapshot de filtro usa chave persistente determinística.

---

# Observação sobre o build 16

Existe ainda um problema de rastreabilidade.

No GitHub, `release/1.0` está no commit `321e38e…`. Existe depois a branch `fix/release-1.0-final-hardening`, mas o histórico nela ainda contém commit de alinhamento do projeto com **build 3**.

Não encontrei no repositório um commit que me permita afirmar honestamente:

**“TestFlight build 16 = SHA X”.**

Por isso, esta revisão confirma problemas presentes na linhagem de código usada pelo release, mas não atribui cada regressão exclusivamente a um commit específico do build 16.

Isso também deveria ser corrigido: cada upload ao TestFlight precisa carregar SHA/tag inequívoco.

O último hardening de imagens, por exemplo, passou a rejeitar downloads acima de 12 MB e imagens com dimensões consideradas inseguras. É uma correção razoável, mas ela pode aumentar a quantidade de imagens que cai no caminho de fallback text-only; ela pode amplificar o sintoma, mas **não é a causa estrutural**.

---

## Prioridade de execução

**P0.1 — remover publicação/upgrade tardio de cards.**  
**P0.2 — substituir warm-cache de items por prepared snapshot.**  
**P0.3 — criar Bootstrap Gate real para banco vazio.**  
**P0.4 — separar media changes de structural feed invalidation.**  
**P0.5 — tornar diversidade uma regra do output editorial.**

Depois:

**P1.1 — quality baseline global.**  
**P1.2 — prepared reserves por contexto/filtro.**  
**P1.3 — eliminar legacy pipeline da produção.**  
**P1.4 — terminar decomposição do FeedStore.**  
**P1.5 — TestFlight build ↔ Git SHA obrigatório.**

A partir daí eu voltaria a otimizar detalhes.

Hoje, mexer em timeouts, quantidade de fontes ou tamanho do reservoir antes disso tem grande chance de gerar exatamente mais uma rodada de regressões.
