# Review de fluidez do feed — 1.0 (5)

## Base e limites

Review do código local comparado ao snapshot de archive `53ec34f6294a3e8dc498ae4caf51234cb7c5dd65`, registrado no checklist da publicação. O diff de `feedmine`, `feedmine.xcodeproj`, `feedmineTests` e `feedmineUITests` contra esse snapshot está vazio. O HEAD da branch, isoladamente, não representa o binário: o archive incluiu alterações ainda não commitadas.

Escopo: primeira tela, retorno com conteúdo salvo, MainActor, filtragem, publicação e estabilidade visual. Não houve alteração no código do app, novo build ou upload neste review. As conclusões abaixo vêm de rastreamento de execução e estado no código. Tempos e a contribuição de cada ponto para os travamentos no aparelho ainda precisam de profiling. Não é possível atribuir encerramentos do processo a uma causa sem crash logs/diagnósticos. Vários problemas antecedem o último hardening; este review não atribui todos ao build 5.

P1 = corrigir antes do próximo candidato de fluidez. P2 = corrigir no mesmo ciclo quando indicado, com menor urgência.

## Achados

### 1. P1 — Imagem atrasada muda a geometria de um card já publicado

**Evidência:** `FeedStore.swift:1051–1070`, `CardPreparationCoordinator.swift:553–619`, `FeedItemCardView.swift:95–117`.

A preparação publica um card sem imagem como texto. Se o retry obtém a imagem, o callback procura esse ID entre os cards publicados e substitui a apresentação por `.image`/`.hero`. No componente visual, isso insere uma área 16:9 que não existia no artigo de texto. Manter o mesmo ID não mantém a altura. O comentário “no layout shift” contradiz o comportamento.

**Efeito:** conteúdo se desloca enquanto o usuário lê ou tenta tocar. É uma violação direta do contrato do feed, independentemente de desempenho da CPU.

**Correção:** congelar layout e mídia da apresentação publicada. Guardar o resultado tardio no cache para a próxima composição; permitir upgrades apenas em candidatos ainda não publicados. A publicação precisa ter uma fronteira explícita e não aceitar callbacks sem contexto.

**Teste:** publicar artigo sem imagem, fixar uma âncora abaixo dele, completar download atrasado; IDs, ordem, alturas e offset devem continuar iguais. Na próxima composição, a imagem pode aparecer.

### 2. P1 — O caminho “off-main” percorre todo o catálogo no MainActor em cada chamada

**Evidência:** `FeedStore.swift:618–643`, chamado por `applyFiltersAsync` em `:679–685` e por append durante scroll em `:2296`.

Antes do `Task.detached`, `buildFilterInput` percorre `registry.sources`, consulta habilitação e normaliza as URLs desabilitadas. Esse método pertence ao `FeedStore` no MainActor. Portanto, até um append pequeno paga um trabalho proporcional ao catálogo inteiro. O catálogo deste build tem aproximadamente 77 mil entradas antes da deduplicação.

**Correção:** construir um snapshot imutável dos índices de habilitação quando `sourceRevision` ou `enablementRevision` mudar. O filtro captura esse snapshot por referência/valor com copy-on-write; não o recompõe a cada página. Respeitar também overrides e escopo das coleções.

**Teste:** com catálogo completo, executar múltiplos appends sem mudar fontes; deve haver uma construção do índice, não uma por append. Medir responsividade no MainActor durante scroll, além do tempo total do filtro.

### 3. P1 — A primeira página salva fica atrás da inicialização integral do catálogo

**Evidência:** `FeedStore.swift:1624–1784`, particularmente OPML `:1684`, taxonomia `:1698` e restore `:1784`; `FeedScreen.swift:101–103`.

O startup começa em preparação e só busca a página persistida após OPML, taxonomia, restauração de filtros/preset, estado de leitura e bookmarks. A saída antecipada existe para algumas coleções, não para o feed comum. Assim, ter conteúdo no banco/cache não remove a tela de espera.

**Correção:** separar a primeira publicação local da manutenção do catálogo. Restaurar um snapshot de apresentação válido para a composição atual antes da hidratação integral. Se faltar snapshot, consultar uma janela local pequena com índices e contexto persistidos. Só exigir a reconstrução necessária quando não for possível validar o contexto; não mostrar conteúdo de filtros diferentes para ganhar velocidade.

**Teste:** relançar com página/banco preenchidos, rede bloqueada e hidratação do catálogo deliberadamente suspensa. O feed correto deve aparecer antes de liberar catálogo ou rede. Cobrir também cache JSON ausente com SQLite válido.

### 4. P1 — O cache de taxonomia e os índices do catálogo ainda são processados na UI

**Evidência:** `TaxonomyStore.swift:589–638`, `SourceRegistry.swift:43–62`, `:114`, `:632–675`, `:684–710`.

O cache hit de taxonomia calcula fingerprint com normalização, ordenação e SHA-256, lê arquivo, decodifica JSON e reconstrói índices e uniões no MainActor. Após o parse assíncrono de OPML, a atribuição a `sources` também reconstrói índices de identidade/idioma/categoria, seguida dos modelos de filtros e países no ator principal. `async` no método externo não desloca essas operações.

**Correção:** produzir snapshots completos de catálogo e taxonomia em executor de trabalho, incluindo índices derivados; publicar uma atribuição curta no MainActor, validada por revisão. Adiar modelos de exploração que não participam da primeira página.

**Teste:** medir separadamente cache hit e cache miss com o catálogo real. Ambos devem permitir taps e scroll; uma leitura de cache não pode bloquear a UI enquanto reconstrói dezenas de milhares de entradas.

### 5. P1 — Cards locais prontos continuam ocultos enquanto a rede termina

**Evidência:** `FeedStore.swift:2648–2649`, `:2260–2283`, `FeedDisplayState.swift:185–194`, `FeedScreen.swift:101–103`.

Uma troca de filtro marca `.refreshing` + `.preparing`. A publicação de cards se recusa a sair de `.preparing` enquanto estiver `.refreshing`. O flush pode então aguardar `fetchNextBatch()` para completar quantidade/diversidade, e só depois marcar `.ready`. Existem cards utilizáveis, mas a tela mostra somente o loading. `setFilter` também limpa os itens antes da substituição estar pronta.

**Correção:** separar “tem uma apresentação válida” de “está buscando mais conteúdo”. Publicar o conjunto local válido e marcar ready imediatamente; repor o restante ao fundo. Uma seleção nova deve ser preparada e substituída atomicamente. Enquanto o usuário edita um rascunho, preservar a composição aplicada; nunca apresentar conteúdo da seleção anterior como se já pertencesse à nova.

**Teste:** cinco artigos locais que atendem ao novo filtro, servidor sem resposta; os cinco precisam aparecer e aceitar interação sem aguardar uma página de vinte ou diversidade adicional.

### 6. P1 — Trabalho de um filtro antigo pode receber o contexto do filtro novo

**Evidência:** `FeedStore.swift:5327–5367`, `Reservoir.swift:51–66`, `FeedStore.swift:2296–2304`, `:2334`, `:2164–2172`, `:2280–2283`.

Há geração e epoch, mas nem todas as fronteiras de suspensão os preservam:

- Reload valida a geração antes de `await reservoir.seed`. O seed espera um trabalho detached e depois escreve seus arrays sem validar geração/cancelamento.
- Ao voltar, reload relê `display.activePresentationContext`, dando aos itens antigos a identidade da composição atual.
- Append/refresh aguardam filtragem e depois publicam sem nova checagem; `setVisibleItems` captura o contexto atual.
- A promoção verifica epoch antes de aguardar `commitPublished`, sem repetir a validação antes de alterar a UI.
- O final do flush pode escrever idle/ready após espera de rede sem validar novamente a operação.

**Correção:** conservar o mecanismo existente, mas transportar um único contexto imutável pela operação inteira. Separar cálculo do reservoir de seu commit. Validar contexto e cancelamento depois das suspensões e imediatamente antes de cada mutação compartilhada. A publicação recebe o contexto original; não busca o atual para legitimar resultados antigos.

**Teste:** suspender o trabalho A, aplicar e concluir B, retomar A. A não pode mudar reservoir, cards, ordem, estado de loading nem contexto de B. Repetir para seed, append, commit do coordenador e retorno de rede.

### 7. P1 — Hidratação e persistência ainda fazem trabalho síncrono no MainActor

**Evidência:** `FeedStore.swift:5319–5345`, `:7481–7519`, `:1144–1209`, `:975–1029`; `FeedLoader.swift:651`.

O SELECT é assíncrono, mas a conversão de até cerca de 5.100 registros, limpeza de HTML/regex, normalização de texto, filtragem e balanceamento rodam depois do await no MainActor. `saveSourceHealthBatch` faz `db.write` síncrono, inclusive serialização, e é chamado por ingestão/cobertura. A criação inicial do loader também abre/migra bancos sincronamente antes da primeira UI.

**Correção:** mover hidratação e seleção de candidatos para trabalho fora do MainActor com snapshot imutável. Capturar os dados do scheduler e gravar a saúde das fontes assíncronamente, em lotes ordenados. Separar estado visual leve da abertura/migração dos bancos. Medir cada trecho para priorizar; não declarar que todo travamento vem de um único SELECT.

**Teste:** cache volumoso com títulos/excertos reais e uma gravação de banco deliberadamente lenta. A interação precisa continuar responsiva enquanto o worker calcula ou aguarda armazenamento.

### 8. P2 — O snapshot de primeira página não identifica a composição

**Evidência:** `FeedDisplayState.swift:289–345`; únicos callers de save em `:139`/`:202` e restore em `FeedStore.swift:1784`.

Existe parâmetro `filterSignature`, mas os callers usam o valor vazio. As composições do modo main compartilham um arquivo. O snapshot guarda itens, não a apresentação congelada. Além disso, gravações detached independentes não ordenam commits: uma escrita anterior pode terminar após uma recente. Aplicar filtros na leitura evita várias exclusões incorretas, mas não recupera uma página adequada a outra composição nem uma apresentação visual estável.

**Correção:** chave determinística para preset, filtros, fontes e versão de schema/catálogo pertinente; persistir uma primeira página limitada e sua apresentação. Serializar gravações e rejeitar snapshots obsoletos. Se o ramo de assinaturas for ativado, substituir `hashValue` por digest estável: `hashValue` muda entre processos. Esse último ponto é latente, não a causa atual, pois as assinaturas não são usadas hoje.

**Teste:** alternar A/B e relançar; restaurar a composição correta, preservar geometria e nunca deixar uma gravação velha vencer a nova. Cobrir arquivo inválido e fallback ao banco.

### 9. P2 — “Reset Everything” pode deixar fontes e contadores desatualizados

**Evidência:** `SourceRegistry.swift:422–426` e `:464–466`; chamado por `SettingsSheetView.swift:202`.

`resetAllToggles` limpa os conjuntos, mas chama `ensureActiveCounts`. Se os caches já estão marcados como atuais, esse método retorna sem reconstruir fontes habilitadas, contagens, idiomas ou categorias. O estado persistido e os modelos usados pela UI divergem.

**Correção:** invalidar explicitamente os índices e os grupos pendentes, incrementar a revisão de habilitação e recompor os modelos de forma coerente.

**Teste:** desabilitar fontes, materializar contagens, executar reset e conferir fontes, idiomas, categorias, revisão e resultado do feed na mesma sessão.

### 10. P2 — Os testes de store não exercitam o caminho de publicação usado no aparelho

**Evidência:** `FeedStore.swift:35–40`; `FeedStoreTests.swift:1015–1055`.

`inMemory: true` desliga o prepared pipeline. Boa parte dos testes de store passa pelo caminho legado, enquanto o app usa preparação assíncrona. O teste que promete impedir stale overwrite espera A aparecer antes de aplicar B; não força a sobreposição problemática. Testes isolados do coordenador não substituem a integração store → reservoir → preparação → display.

**Correção:** permitir storage temporário/isolado com a mesma pipeline de produção, além dos testes rápidos existentes. Usar dependências controláveis para suspender trabalho em pontos precisos, sem sleeps como prova de ausência de corrida. Acrescentar testes de geometria/âncora e métricas de MainActor.

**Teste:** a suíte de regressão deve falhar no build 5 para os casos acima e passar após cada correção. Não aumentar os timeouts para mascarar espera indevida.

### 11. P1 — O fallback de primeira abertura salva artigos, mas não os mostra

**Evidência:** `FeedStore.swift:1944–1969`, `persistFetchedItems` em `:3951–4130`.

Quando o prazo/limite da coleta é atingido com resultados parciais, o código salva os primeiros vinte, descarta o retorno, limpa todos os pendentes e sai do loop. O fallback seguinte também apenas persiste. A persistência não preenche o reservoir nem publica cards; sem outra publicação concorrente, o guard seguinte conclui `.empty`, embora os artigos estejam no banco. O primeiro ramo também abandona pendentes além dos vinte.

**Correção:** persistir a coleta, hidratar/preparar/publicar a parcela disponível sob o contexto capturado e só então concluir ready. Reter ou persistir os demais pendentes. Só concluir vazio depois de verificar que não há conteúdo local elegível.

**Teste:** primeira instalação com poucos provedores respondendo e artigos válidos; forçar cada fallback. Artigos recebidos precisam aparecer, pendentes adicionais não podem sumir e o estado final deve ser ready.

## Ordem da solução

1. **Travar o contrato de publicação:** contexto único, commit validado, apresentação publicada imutável. Corrige os achados 1 e 6 e evita que otimizações tornem as corridas mais frequentes.
2. **Liberar conteúdo local:** separar ready de refresh, trocar composições atomicamente e restaurar snapshot/SQLite antes do catálogo integral. Corrige 3, 5 e 8. Corrigir o fallback 11 na primeira abertura, que continua sendo um estado distinto do retorno com dados.
3. **Retirar trabalho proporcional ao catálogo da UI:** índices de filtros por revisão, snapshots de taxonomia/registro, hidratação de itens e gravação assíncrona. Corrige 2, 4 e 7.
4. **Fechar consistência de filtros:** reset, revisão dos índices, ida e volta entre idiomas/tipos/coleções e resultados vazios legítimos. Corrige 9 sem reescrever a semântica dos filtros.
5. **Validar o caminho real:** testes determinísticos, UI e profiling físico. Corrige 10 e mede os ganhos. Só depois gerar outro candidato.

O MainActor continua responsável pela pequena alteração final de estado observável e pela UI. Catálogo, disco, decodificação de metadados, filtro e ordenação ficam fora dele. Mover tudo para `Task {}` não basta: o task pode herdar o ator, e uma função `nonisolated` síncrona também executa no chamador.

## Critérios de aceitação

- Com conteúdo local válido, nenhuma dependência de rede para a primeira página ou aplicação de filtro.
- Nenhum resultado obsoleto entra em reservoir, preparação ou display após troca de contexto.
- Cards publicados mantêm IDs, ordem e geometria durante leitura, retries e refresh ao fundo. Novidades aguardam ação explícita ou entram somente na extensão permitida do feed.
- Rascunho de filtros não destrói a composição aplicada; a confirmação realiza uma troca coerente.
- Testes com cache JSON presente/ausente, banco preenchido, rede offline/lenta, imagens lentas, poucos resultados, troca rápida de filtros, reset, scroll e retorno do background.
- Usar Instruments Time Profiler/Hangs e pontos de medição de startup, snapshot, query, hidratação, filtro e commit. Registrar p50/p95 em aparelho, não só tempo total da suíte.
- Metas iniciais de validação, a confirmar no aparelho de referência: primeira página local em até 1 s no p95; resposta visual a tap em até 100 ms; nenhuma tarefa de catálogo/disco monopolizando o MainActor por mais de 100 ms. Scroll também exige olhar hitches/frame budget, que é mais rigoroso que esse limite de hang.
- Se houver encerramentos do app, analisar `.ips`, watchdog e jetsam separadamente; nenhum desses diagnósticos foi fornecido neste review.

## Pendências de release mantidas

Não confundir acesso/assinatura/TestFlight funcionando com fluidez validada. A próxima publicação precisa de build novo, snapshot reproduzível do código e evidências dos cenários acima. Preservar os ajustes de segurança e migração existentes; não voltar a uma versão antiga inteira para contornar estes problemas. `release/1.0` permanece fora deste trabalho de revisão.
