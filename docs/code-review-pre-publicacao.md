# Code review pré-publicação do Feedmine

## Veredito

**Eu não publicaria o estado atual da `main` ainda.**

Não porque o aplicativo esteja mal construído — pelo contrário, a arquitetura já está bem acima do que normalmente se vê numa primeira versão — mas porque encontrei alguns problemas que podem:

- perder ou aparentemente perder dados de usuários;
- restaurar fontes que o usuário removeu;
- fazer feeds do próprio catálogo falharem;
- congelar a interface em importações grandes;
- permitir que builds e testes falhem sem interromper o processo de release;
- provocar consumo de memória controlado por uma resposta remota.

Minha avaliação atual:

| Área | Avaliação |
|---|---:|
| Arquitetura geral | **Boa** |
| Concorrência e organização | **Boa, com alguns vazamentos para o MainActor** |
| Persistência | **Boa estrutura, mas há bugs de migração** |
| Rede | **Sofisticada, mas precisa de limites defensivos** |
| Performance | **Muito trabalhada, ainda com alguns pontos de congelamento** |
| Testes | **Boa quantidade, cobertura desigual** |
| Processo de release | **Insuficiente como gate de produção** |
| Prontidão para publicação | **Ainda não** |

Esta foi uma revisão estática do código atual. Eu não consegui compilar o projeto, executar os testes, rodar Instruments nem testar o binário físico. Portanto, os bugs lógicos abaixo são concretos, mas as conclusões de tempo, memória e fluidez ainda precisam ser validadas no app executando.

---

# Bloqueadores de publicação — P0

## 1. O processo de build e testes pode reportar sucesso quando falhou

Este é o problema mais urgente porque invalida todo o restante do processo de qualidade.

O target `build` executa:

```make
xcodebuild ... 2>&1 | tail -5
```

Sem `pipefail`, o código de saída normalmente será o de `tail`, não necessariamente o de `xcodebuild`. Assim, o compilador pode falhar e o comando ainda terminar como sucesso. fileciteturn28file0L40-L47

Nos targets de testes, o resultado passa por `grep` e termina com `|| true`. Isso garante explicitamente que o comando retorne sucesso mesmo quando os testes ou o próprio build falharem. fileciteturn28file0L59-L107

### Impacto

Você pode:

- gerar um release acreditando que os testes passaram;
- deixar uma regressão entrar no TestFlight;
- automatizar publicação no futuro sobre uma base que nunca bloqueia erro;
- perder tempo procurando um problema no app que já estava explícito no log.

### Correção mínima

No `Makefile`:

```make
SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -ec
```

Remover todos os `|| true` dos comandos usados como gates.

Para manter saída resumida sem esconder falhas:

```make
xcodebuild test ... | tee .build/test.log
```

Ou usar `xcbeautify`, preservando o exit code com `pipefail`.

Também faltam targets claros para:

- build `Release`;
- análise estática;
- archive;
- validação do archive;
- testes obrigatórios antes do archive.

Eu separaria:

```text
make test
make test-ui
make analyze
make build-release
make archive
```

E nenhum deles poderia retornar sucesso após uma falha.

---

## 2. A migração de favoritos pode ignorar o caso mais comum

O `UserStateStore` cria uma lista padrão `Favorites` no banco novo. A função que decide se deve migrar o banco antigo só retorna `true` quando o banco antigo tem **mais de uma lista**:

```swift
return userCount <= 1 && legacyCount > 1
```

fileciteturn46file0L206-L216

Isso ignora o cenário extremamente comum:

- o usuário só utilizava a lista padrão;
- essa lista contém dezenas de favoritos;
- o banco antigo tem exatamente uma lista;
- `legacyCount` é `1`;
- a migração nunca acontece.

A decisão deveria considerar os registros de `bookmark_item`, não apenas quantas listas existem.

Além disso, a migração é disparada num `Task` não aguardado dentro do inicializador. Enquanto ela acontece, o restante do app já pode consultar favoritos e mostrar o estado ainda vazio. fileciteturn45file0L235-L286

### Impacto

Num upgrade entre builds, o usuário pode acreditar que perdeu todos os favoritos.

Mesmo que uma abertura posterior faça alguma sincronização, a primeira experiência já será de perda de dados — um dos piores bugs possíveis para um leitor offline-first.

### Correção

Não inferir migração a partir da quantidade de listas. Use um marcador explícito:

```text
legacy_bookmark_migration_v1_completed
```

A lógica deveria ser:

1. Verificar se o marcador existe.
2. Verificar se o banco legado contém listas **ou itens**.
3. Migrar tudo numa transação.
4. Validar contagens.
5. Somente então registrar o marcador.
6. Aguardar o término antes de carregar o estado de favoritos na interface.

Também é necessário mapear corretamente a lista padrão antiga para a lista padrão nova, em vez de depender de ambas terem ID `1`.

### Testes obrigatórios

- banco antigo com uma lista e zero itens;
- banco antigo com uma lista e 50 itens;
- banco antigo com múltiplas listas;
- IDs diferentes para a lista padrão;
- migração interrompida;
- migração executada duas vezes;
- banco novo já contendo alguns favoritos;
- item favoritado cujo conteúdo já não existe em `feed_item`.

---

## 3. A última fonte importada removida pode reaparecer no próximo launch

A persistência de fontes importadas contém:

```swift
guard !imported.isEmpty else { return }
```

Quando a última fonte importada é removida, a função simplesmente retorna e não atualiza nem apaga `imported_sources.json`. O arquivo antigo continua no disco. Na próxima inicialização, ele é lido e as fontes são restauradas novamente. fileciteturn18file0L58-L92

### Impacto

O usuário remove uma fonte, fecha o app e ela volta.

Isso prejudica diretamente a promessa central de controle pelo usuário.

### Correção imediata

```swift
if imported.isEmpty {
    try? FileManager.default.removeItem(at: importedSourcesURL)
    return
}
```

A correção estrutural seria não usar um JSON paralelo para este estado. Fontes adicionadas pelo usuário são dados de usuário e deveriam viver no `user.sqlite`, com:

- URL normalizada;
- título;
- tipo;
- data de inclusão;
- estado ativo;
- coleção;
- origem da importação;
- ordem editorial do OPML.

Isso também simplificaria transações, deduplicação e migrações.

### Testes obrigatórios

- adicionar uma fonte, remover, reiniciar;
- adicionar três, remover uma, reiniciar;
- remover todas, reiniciar;
- falhar a gravação por falta de espaço;
- arquivo JSON corrompido;
- duas operações de importação concorrentes.

---

## 4. A configuração de ATS não libera os feeds HTTP do catálogo

O `Info.plist` declara `NSAllowsArbitraryLoadsForMedia`, além dos modos de background para áudio e fetch. fileciteturn9file0L98-L107

Esse parâmetro libera exceções de ATS para mídia carregada pelo AVFoundation. Ele **não afeta conexões feitas por `URLSession`**, que é justamente o caminho utilizado para baixar RSS e Atom. A própria documentação da Apple deixa isso explícito. citeturn206214search12

O catálogo contém feeds HTTP. Um exemplo é o feed de futebol da BBC:

```xml
xmlUrl="http://feeds.bbci.co.uk/sport/football/rss.xml"
```

fileciteturn73file0L21-L28

A busca no repositório encontrou ocorrências de `xmlUrl="http://"` em dezenas de arquivos de países e categorias. fileciteturn71file0L1-L2 fileciteturn71file42L85-L86

### Impacto

Parte do catálogo pode falhar silenciosamente no dispositivo, mesmo que esses feeds tenham funcionado em scripts de catalogação executados fora do iOS.

O problema é especialmente traiçoeiro porque:

- o feed está no catálogo;
- pode ter metadata e score altos;
- o scheduler tenta buscá-lo;
- a falha parece ser do publisher;
- na realidade, é a política de rede do app.

### Correção recomendada

O pipeline que compila o catálogo deveria:

1. Preferir automaticamente HTTPS quando o endpoint responde.
2. Resolver redirects e persistir o URL canônico HTTPS.
3. Rejeitar ou marcar como incompatível qualquer fonte HTTP.
4. Produzir um relatório de fontes HTTP antes de gerar o catálogo.
5. Impedir que uma fonte HTTP seja `defaultEnabled=true`.

Eu evitaria `NSAllowsArbitraryLoads=true`. A Apple exige justificativa para exceções amplas e recomenda exceções mais estreitas. citeturn206214search1

Para publishers genuinamente limitados a HTTP, seria melhor decidir editorialmente entre:

- exceção por domínio;
- proxy futuro;
- fonte desabilitada;
- remoção do catálogo.

---

## 5. A sessão rápida do cold start está configurada, mas não é utilizada

O `RSSFetcher` cria:

- uma sessão normal, com timeout de 15–30 segundos;
- uma sessão de startup, com timeout de 5–7 segundos;
- um `FeedHTTPSync` normal;
- um `starterHTTPSync`.

Os comentários afirmam que essa sessão rápida impede um publisher lento de esticar o cold start. fileciteturn24file0L18-L59

Porém:

```swift
private func fetchStarterSource(_ source: FeedSource) async -> FeedFetchResult {
    await fetch(source, validators: HTTPValidators())
}
```

O método chama `fetch`, que usa o `httpSync` normal. Ele não usa `starterHTTPSync`. fileciteturn24file0L61-L70 fileciteturn24file0L136-L139

A busca por `starterHTTPSync` não encontrou outro uso funcional. fileciteturn26file0L1-L2

### Impacto

A configuração que deveria garantir o tempo da primeira tela está morta.

O `fetchStarter` possui um deadline global de aproximadamente 2,25 segundos e cancela as tarefas, o que reduz o impacto. Mas a promessa descrita no código — uma camada HTTP própria com timeout curto — não está sendo cumprida. fileciteturn24file0L208-L302

### Correção

Fazer o transporte ser um parâmetro real:

```swift
private func fetch(
    _ source: FeedSource,
    validators: HTTPValidators,
    httpSync: FeedHTTPSync
) async -> FeedFetchResult
```

E então:

```swift
private func fetchStarterSource(_ source: FeedSource) async -> FeedFetchResult {
    await fetch(
        source,
        validators: HTTPValidators(),
        httpSync: starterHTTPSync
    )
}
```

O `FeedHTTPSync` também deveria receber configuração ou `URLSession` no inicializador, permitindo testes determinísticos.

### Teste necessário

Usar um `URLProtocol` de teste que:

- espera 10 segundos antes de responder;
- confirma que o starter cancela ou retorna dentro do deadline;
- confirma que o fetch normal continua usando o timeout maior.

---

## 6. Respostas de rede podem ser carregadas integralmente sem limite

O novo pipeline HTTP usa:

```swift
let (data, response) = try await session.data(for: request)
```

Isso carrega o corpo completo antes de validar tamanho ou conteúdo. fileciteturn25file0L55-L89

O mesmo padrão aparece em:

- importação de OPML remoto;
- descoberta de feeds em páginas HTML;
- resolução de canais do YouTube;
- probes de feeds;
- lookup de podcasts.

No `URLResolver`, por exemplo, o app baixa a resposta inteira e só depois usa `data.prefix(50000)` ou `data.prefix(100000)`. Limitar o prefixo depois do download não limita a memória consumida durante o download. fileciteturn21file0L126-L173 fileciteturn21file0L221-L252

A detecção de feed também aceita qualquer JSON cujo primeiro caractere útil seja `{`:

```swift
prefix.trimmingCharacters(in: .whitespaces).hasPrefix("{")
```

fileciteturn20file0L60-L70

### Impacto

Uma URL importada, um feed comprometido ou uma resposta acidentalmente enorme pode causar:

- pico de memória;
- encerramento pelo sistema;
- parsing muito demorado;
- cache de conteúdo que nem sequer é feed;
- repetição permanente de erros de parser.

Como o app aceita URLs externas e possui deep link de importação, o input não deve ser tratado como confiável.

### Correção

Usar `session.bytes(for:)` e interromper ao atingir um teto.

Limites iniciais razoáveis, ajustáveis por configuração:

| Recurso | Limite sugerido |
|---|---:|
| HTML para descoberta | 256 KB |
| OPML importado | 10 MB |
| RSS/Atom/JSON Feed | 20 MB |
| Manifesto | 1–5 MB |
| Imagem | 4 MB, já implementado em parte |

Além do tamanho:

- validar `Content-Type`;
- aceitar apenas `http` e `https`;
- exigir host;
- validar a estrutura JSON Feed, não apenas `{`;
- verificar o resultado de `XMLParser.parse()`;
- retornar erro claro para OPML parcialmente malformado;
- limitar quantidade de fontes por importação;
- pedir confirmação antes de importar URLs recebidas por deep link.

---

## 7. O binário validado no TestFlight não está ligado a um commit reproduzível

O documento de submissão informa que o build `1.0 (2)` foi validado e aceito no TestFlight. fileciteturn35file0L31-L38

Porém, o documento não registra:

- commit SHA;
- tag;
- data do archive;
- Xcode utilizado;
- configuração exata;
- resultado dos testes;
- checksum do archive;
- catálogo incluído.

Considerando a quantidade de mudanças recentes no repositório, não há uma prova simples de que o código revisado agora seja exatamente o código do binário validado.

### Correção

Cada release deveria ter algo como:

```text
Version: 1.0
Build: 3
Git SHA: 6175d3e...
Catalog revision: 123
Xcode: 18.x
Archive checksum: ...
Unit tests: passed
UI tests: passed
Device smoke test: passed
```

E o archive deve sair de uma tag imutável:

```text
ios/1.0-build.3
```

Não publique o build já validado apenas porque ele está com status `VALID`. Esse status prova que o pacote foi aceito pelo sistema de upload, não que o comportamento atual foi aprovado pelos seus próprios gates.

---

# Problemas de prioridade alta — P1

## 8. Leitura e escrita síncronas estão ocorrendo no `MainActor`

`FeedLoader` inteiro é `@MainActor`. fileciteturn13file0L23-L25

Apesar disso, ele executa operações como:

- `Data(contentsOf:)`;
- codificação JSON;
- `data.write`;
- leitura de arquivo de fontes importadas;
- restauração de estado.

fileciteturn18file0L58-L92

O handler de arquivo recebido pelo app também lê o OPML dentro de um contexto de MainActor. fileciteturn10file0L145-L165

O importador de coleção repete o mesmo padrão:

```swift
let data = try Data(contentsOf: url)
```

antes de entregar os dados ao pipeline. fileciteturn56file0L216-L253

### Impacto

Com OPML pequeno, provavelmente passa despercebido.

Com milhares de fontes, pode:

- congelar animações;
- impedir toque;
- causar watchdog no pior caso;
- tornar a importação aparentemente travada.

### Correção estrutural

Criar um ator dedicado:

```swift
actor ImportFileStore {
    func read(url: URL, maxBytes: Int) async throws -> Data
    func saveImportedSources(_ sources: [FeedSource]) async throws
}
```

O MainActor deveria apenas receber o resultado final e atualizar a UI.

A inicialização e as migrações do GRDB também merecem medição. O `FeedStore` é criado no MainActor e chama as migrações de banco sincronamente. fileciteturn45file0L235-L259

---

## 9. Os bancos estão na pasta errada

`feedmine.sqlite` é armazenado em `Documents`. fileciteturn44file0L133-L145

`user.sqlite` também está em `Documents`. fileciteturn46file0L18-L31

A Apple explica que:

- arquivos em `Documents` entram em backups;
- podem ser expostos pelo app Files;
- suporte interno deve ficar em `Application Support`;
- conteúdo regenerável e cache deve ficar em `Caches`. citeturn206214search9turn206214search19

### Organização mais adequada

```text
Library/Application Support/Feedmine/user.sqlite
Library/Caches/Feedmine/feedmine.sqlite
Library/Caches/Feedmine/ImageCache/
```

Possivelmente:

```text
Library/Application Support/Feedmine/imported-sources.sqlite
Library/Application Support/Feedmine/ManagedCatalog/
```

O `user.sqlite` contém dados valiosos e deve sobreviver.

O `feedmine.sqlite` contém artigos baixados, estado derivado, índices e cache. Se é regenerável, não deveria inflar backup de iCloud.

### Atenção

Mover os arquivos exige uma migração cuidadosa:

- fechar a `DatabaseQueue`;
- mover `sqlite`, `sqlite-wal` e `sqlite-shm`;
- validar integridade;
- reabrir;
- manter rollback;
- testar upgrade de instalação existente.

---

## 10. O catálogo remoto tem integridade, mas não autenticidade

Esta é uma das áreas mais bem construídas:

- paths são validados;
- há SHA-256;
- tamanho é conferido;
- arquivos são montados em staging;
- o SQLite é recompilado;
- a quantidade de fontes é validada;
- a ativação possui backup e rollback. fileciteturn66file0L258-L355 fileciteturn67file0L31-L55

O problema é que o manifesto e os arquivos vêm do mesmo repositório remoto. Como inferência de segurança, quem conseguir alterar esse repositório pode:

1. alterar os OPMLs;
2. calcular novos hashes;
3. alterar o manifesto;
4. fazer o app aceitar tudo como válido.

O checksum protege contra corrupção durante o transporte. Ele não prova que o catálogo foi autorizado pela Wawasoft.

### Correção recomendada

Assinar o manifesto:

- chave privada mantida fora do repositório;
- assinatura gerada no processo editorial/release;
- chave pública Ed25519 embutida no app;
- app verifica assinatura antes de interpretar o manifesto;
- revisão deve ser monotônica;
- assinatura cobre manifesto, revisão e hashes dos arquivos.

Assim, o GitHub pode continuar sendo o transporte e a comunidade pode continuar contribuindo por PR, mas apenas snapshots aprovados editorialmente serão ativados.

---

## 11. Episódios terminados podem continuar com posição salva

O player salva assim:

```swift
defaults.set(currentTime, forKey: "\(savedPositionKey).\(id)")
```

fileciteturn53file0L204-L216

Ao terminar, remove:

```swift
removeObject(forKey: savedPositionKey)
```

A chave removida não é a chave por episódio utilizada na gravação. fileciteturn53file0L287-L301

### Impacto

Ao reproduzir novamente um episódio concluído, ele pode saltar para perto do fim.

### Correção

Capturar o ID e remover a chave correta:

```swift
if let id = self?.currentItem?.id {
    defaults.removeObject(
        forKey: "\(Self.savedPositionKey).\(id)"
    )
}
```

Também vale decidir uma regra:

- apagar posição quando restarem menos de 30 segundos;
- considerar episódio concluído em 95%;
- permitir "marcar como não reproduzido".

### Outro risco menor

A criação do artwork acontece em `Task.detached`. Se o usuário troca rapidamente de episódio, a tarefa antiga pode atualizar o Now Playing depois do novo item ter iniciado. fileciteturn53file0L185-L201

Antes de escrever no `MPNowPlayingInfoCenter`, compare novamente o ID atual.

---

## 12. O limite de 100 MB do cache de imagens pode não ser real

Na inicialização, o cache aquece somente os 50 arquivos mais recentes. Ele soma apenas o tamanho desses arquivos e atribui esse total a `diskCacheSize`. fileciteturn51file0L195-L227

Depois, a expulsão de arquivos só acontece quando esse contador ultrapassa 100 MB. fileciteturn51file0L229-L253

Se já houver 300 MB no diretório, mas os 50 arquivos aquecidos somarem 20 MB, o app acredita que o cache possui 20 MB.

### Impacto

O cache pode crescer bem além do limite documentado.

### Correção

Na inicialização:

- enumerar todos os arquivos apenas para somar `fileSize`;
- ordenar somente quando a remoção for necessária;
- aquecer os 50 mais recentes separadamente.

Também convém usar `totalFileAllocatedSize`, quando disponível, para aproximar o uso real em disco.

### Ponto positivo

O pipeline de imagens está significativamente melhor protegido que o pipeline de feeds:

- streaming;
- limite de 4 MB;
- downsampling;
- deduplicação;
- limite de concorrência;
- cache em `Caches`. fileciteturn49file0L19-L105

---

## 13. URLs completas são registradas publicamente no log

No erro HTTP de imagem:

```swift
logger.warning("HTTP \(status): \(url.absoluteString, privacy: .public)")
```

fileciteturn49file0L114-L130

URLs de imagens e podcasts podem carregar:

- tokens temporários;
- parâmetros assinados;
- identificadores;
- dados de campanha;
- caminhos que revelam conteúdo privado.

Mesmo sendo log local, não há necessidade de marcar a URL completa como pública.

### Correção

Registrar apenas:

- host;
- status;
- hash da URL;
- extensão;
- categoria do erro.

Ou usar `privacy: .private(mask: .hash)`.

---

## 14. A atualização em background pode criar um `FeedLoader` completo durante a tarefa curta

O scheduler mantém uma referência fraca ao loader. Quando ela não existe, o handler cria um novo:

```swift
let activeLoader = loader ?? FeedLoader()
```

fileciteturn10file0L6-L69

Isso pode iniciar:

- bancos;
- migrações;
- catálogo;
- stores;
- scheduler;
- estruturas observáveis;

dentro de um `BGAppRefreshTask`, que é concebido para uma atualização curta. citeturn206214search0turn206214search14

### Correção

O background task não deveria depender da camada observável da UI.

Criaria um serviço específico:

```swift
actor BackgroundRefreshService {
    func refreshDueSmartFeeds() async throws -> RefreshReport
}
```

Ele recebe diretamente:

- banco;
- scheduler;
- fetcher;
- stores necessários.

Sem `FeedLoader`, sem estado visual e sem reservoir de tela.

Outro detalhe: `earliestBeginDate = agora + 15 minutos` significa "não executar antes disso", e não "executar em 15 minutos". O sistema não garante o horário. citeturn206214search5

A interface não deve criar expectativa de atualização precisa.

---

# Problemas de prioridade média — P2

## 15. Favoritos não são retornados na ordem em que foram salvos

Primeiro, os IDs são consultados por `added_at DESC`.

Depois, os artigos são hidratados e reordenados por `published_at DESC`. fileciteturn48file0L105-L120

Assim, a ordem de salvamento é perdida.

### Correção

Carregar `item_id` e `added_at`, hidratar os artigos e reconstruir a ordem original; ou usar `ATTACH DATABASE` e fazer um join entre os bancos, caso a arquitetura permita.

---

## 16. O badge de não lidos usa conjuntos incompatíveis

O cálculo é:

```swift
let unread = loader.items.count - loader.readItemIDs.count
```

fileciteturn59file0L70-L73

`loader.items` representa os itens da tela/preset atual. `readItemIDs` pode conter itens lidos de outros presets, sessões e fontes.

### Resultado

O badge pode:

- subestimar os não lidos;
- ficar negativo e ser corrigido artificialmente para zero;
- mudar ao trocar de preset sem refletir uma contagem real.

### Correção

```swift
let visibleIDs = Set(loader.items.map(\.id))
let visibleRead = visibleIDs.intersection(loader.readItemIDs)
let unread = visibleIDs.count - visibleRead.count
```

Ou definir uma semântica global clara e fazer a consulta diretamente no SQLite.

---

## 17. A resolução de URLs relativas está incompleta

O `URLResolver` monta URLs relativas por concatenação de strings:

```swift
url.deletingLastPathComponent().absoluteString + href
```

fileciteturn21file0L154-L170

Isso falha ou produz resultados incorretos em casos como:

```text
../feed.xml
./rss
?output=rss
//cdn.example.com/feed
```

### Correção

```swift
URL(string: href, relativeTo: url)?.absoluteURL
```

---

## 18. A identificação de hosts aceita domínios parecidos

A classificação usa condições como:

```swift
host.contains("youtube.com")
host.contains("podcasts.apple.com")
```

fileciteturn22file0L98-L117

Isso pode classificar incorretamente hosts que apenas contêm esse texto.

### Correção

```swift
host == domain || host.hasSuffix(".\(domain)")
```

Criaria uma função única:

```swift
func host(_ host: String, belongsTo domain: String) -> Bool
```

---

## 19. URLs classificadas como feed não são confirmadas

Quando o `InputParser` conclui que uma URL "parece" feed pelo caminho — `.xml`, `.json`, `/feed`, `/rss` — o `URLResolver` devolve sucesso diretamente, sem probe. fileciteturn21file0L75-L97

A classificação também considera qualquer `.json` como potencial feed. fileciteturn22file0L120-L134

### Impacto

Uma API JSON comum pode ser adicionada como fonte e falhar repetidamente depois.

### Correção

Toda fonte adicionada pelo usuário deveria passar por uma validação inicial mínima:

- status HTTP;
- tamanho;
- MIME;
- parse real como RSS, Atom ou JSON Feed;
- presença de metadata básica;
- URL final após redirects.

---

## 20. A descoberta de feeds tenta caminhos comuns sequencialmente

Quando não encontra `<link rel="alternate">`, o resolver tenta vários paths um após o outro. fileciteturn21file0L100-L123

Com um site lento, isso pode transformar uma tentativa de adicionar fonte numa operação muito demorada.

### Correção

- tentar os paths em paralelo com concorrência 2 ou 3;
- cancelar os restantes após encontrar o primeiro válido;
- aplicar deadline global;
- preservar preferência editorial: Atom/RSS principal antes de comentários ou categorias.

---

## 21. A importação local desativa validação por padrão

A API pública de importação utiliza `validate: false` como padrão, e a importação de coleção também passa `false`. fileciteturn56file0L223-L245

Isso pode ser útil para importar rapidamente milhares de fontes, mas mistura duas decisões diferentes:

- validar a estrutura e a URL;
- fazer uma requisição de rede para cada feed.

### Melhor divisão

```swift
enum ImportValidation {
    case syntaxOnly
    case sampleNetwork
    case fullNetwork
}
```

`syntaxOnly` ainda deveria:

- aceitar apenas HTTP/HTTPS;
- exigir host;
- rejeitar URL vazia;
- normalizar;
- deduplicar;
- detectar OPML malformado.

A validação de rede poderia trabalhar em amostra ou continuar progressivamente depois da importação.

---

## 22. Erros importantes ainda são descartados silenciosamente

Exemplos encontrados:

- atualização das contagens de podcast com `catch {}`;
- atualização das listas de favoritos;
- toggle de bookmark com `try?`;
- criação da lista legada com `try?`;
- algumas gravações de cache.

Um exemplo está em `refreshPodcastCounts`, onde uma falha no banco simplesmente desaparece. fileciteturn37file0L70-L85

### Regra que eu adotaria

- Cache opcional: erro pode ser ignorado, mas registrado.
- Dados do usuário: erro nunca deve ser ignorado.
- Operação iniciada pelo usuário: precisa produzir feedback visível.
- Migração: precisa falhar de forma explícita e recuperável.

No toggle de favorito, a UI não deveria assumir sucesso antes de a transação confirmar.

---

## 23. Existem duas fontes de verdade para configuração do projeto

O repositório contém `project.yml`, mas o README avisa para não regenerar o `.xcodeproj`, porque isso removeria a dependência do GRDB. fileciteturn6file0L24-L36

Isso é uma armadilha para qualquer pessoa que entrar no projeto depois.

### Correção

Escolher uma:

1. `project.yml` volta a ser realmente autoritativo e reproduz o projeto inteiro; ou
2. remover `project.yml` e documentar que o `.xcodeproj` é a fonte de verdade.

Manter um arquivo de geração que não pode ser usado é mais perigoso do que não ter gerador.

---

## 24. O OPML bundled está bem tratado, mas o importado usa uma implementação diferente

O parser do catálogo bundled possui:

- cache versionado;
- ordem determinística;
- concorrência limitada;
- tratamento de cancelamento;
- contagem de arquivos inválidos;
- recusa em salvar cache parcial. fileciteturn74file0L90-L209

Já o parser minimalista de importação possui regras próprias e muito menos validação. fileciteturn20file0L13-L57

### Risco

O mesmo OPML pode se comportar de maneira diferente dependendo de ter vindo:

- do bundle;
- do catálogo atualizado;
- do Files;
- de uma URL;
- de um deep link.

### Correção

Extrair um parser OPML comum com opções:

```swift
OPMLParser.parse(
    data,
    mode: .catalog | .userImport,
    fallbackCategory: ...
)
```

As regras de estrutura, XML, URLs e categorias deveriam ser compartilhadas.

---

## 25. Há uma string de acessibilidade fixa em português

O status compacto mostra interface em inglês, mas o `accessibilityLabel` contém:

```swift
"\(count) de \(total) fontes verificadas"
```

fileciteturn57file0L24-L43

Em um aparelho configurado em inglês, o VoiceOver pode anunciar essa parte em português.

Isso também indica que vale rodar uma auditoria de strings fora do mecanismo de localização, principalmente porque o `Info.plist` declara muitas localizações. fileciteturn9file0L35-L76

---

# Pontos fortes do código

Não quero que a lista de bugs esconda o fato de que há decisões muito boas aqui.

## Concorrência

Há uso consistente de:

- atores para rede e importação;
- sliding-window concurrency;
- cancelamento;
- limites de conexões;
- geração monotônica para descartar resultados antigos;
- trabalho pesado movido para `Task.detached`.

O `fetchAll` mantém uma janela de concorrência real em vez de esperar chunks inteiros. fileciteturn24file0L141-L205

O parser bundled também limita a concorrência de acordo com os cores disponíveis e mantém a ordem editorial determinística. fileciteturn74file0L140-L188

## Rede

A camada HTTP possui:

- ETag;
- Last-Modified;
- 304;
- Cache-Control;
- Expires;
- Retry-After;
- redirects;
- estados separados para throttling e falhas. fileciteturn25file0L31-L160

Isso é muito mais sofisticado que um leitor RSS comum de primeira versão.

## Banco

O uso de GRDB, WAL, foreign keys e migrations é uma boa base. fileciteturn46file0L34-L49

A separação entre:

- identidade do usuário;
- conteúdo regenerável;
- catálogo;

é conceitualmente correta. Os problemas atuais estão mais na execução da migração e nos diretórios do que no desenho.

## Imagens

A arquitetura de imagens possui:

- downsampling;
- cache em memória;
- cache em disco;
- deduplicação global;
- fallback de imagem do YouTube;
- limite de download;
- resolução de artwork sem bloquear o pipeline principal.

É uma das partes mais maduras do aplicativo.

## Atualizador de catálogo

Staging, validação, compilação antes da ativação e rollback são excelentes decisões. A assinatura do manifesto é a principal peça que falta.

## Privacidade

O projeto possui `PrivacyInfo.xcprivacy`, declara UserDefaults e timestamps, e não declara coleta ou tracking. fileciteturn33file0L7-L31

A Apple exige que APIs de required reasons estejam corretamente descritas no privacy manifest, então essa preparação é necessária. citeturn206214search13turn206214search15

## Testes

Há uma boa variedade de suites:

- scheduler;
- reservoir;
- banco;
- performance;
- filtros;
- taxonomia;
- catálogo;
- UI;
- curated feeds.

fileciteturn30file0L1-L40

O problema não é falta total de testes. É a ausência deles nos novos limites mais sensíveis e o fato de o runner não bloquear falhas.

---

# Testes que eu adicionaria antes do próximo build

## Suite `LegacyMigrationTests`

- default list com bookmarks;
- múltiplas listas;
- IDs conflitantes;
- migração interrompida;
- execução idempotente;
- conteúdo expirado;
- banco legado corrompido.

## Suite `ImportedSourcePersistenceTests`

- remover a última fonte;
- reiniciar;
- arquivo vazio;
- arquivo corrompido;
- falha de gravação;
- importações concorrentes;
- duplicação com diferenças de trailing slash.

## Suite `ImportPipelineTests`

- OPML válido;
- OPML parcialmente válido;
- XML malformado;
- URL `file://`;
- URL sem host;
- `httpx://`;
- JSON comum;
- JSON Feed;
- resposta de 100 MB;
- mais de dez mil outlines;
- mesma URL repetida no mesmo input.

## Suite `URLResolverTests`

- paths relativos;
- `../feed.xml`;
- URLs protocol-relative;
- redirects;
- domínio parecido com YouTube;
- `.json` que não é feed;
- deadline global;
- cancelamento depois do primeiro feed encontrado.

## Suite `ColdStartNetworkTests`

- feed rápido;
- feed travado;
- mix de rápidos e lentos;
- cancelamento no deadline;
- retorno com runway suficiente;
- comportamento offline;
- servidor 429 e 503.

## Suite `CatalogTransportSecurityTests`

O compilador do catálogo deve falhar quando encontrar:

```text
xmlUrl=http://...
```

Ou produzir um relatório explícito de exceções aprovadas.

## Suite `AudioPlayerPersistenceTests`

- salvar posição;
- trocar episódio;
- terminar episódio;
- reproduzir novamente;
- episódio com duração inicialmente desconhecida;
- interrupção;
- remoção de fone;
- troca rápida de artwork.

---

# Gate mínimo de release

Eu congelaria features e só criaria outro build depois desta sequência:

1. Corrigir os sete P0.
2. Corrigir o resume do áudio.
3. Mover os bancos para diretórios apropriados ou, no mínimo, excluir corretamente o cache de backup.
4. Adicionar os testes de migração, importação e cold start.
5. Fazer o `Makefile` falhar de verdade.
6. Executar todos os unit tests em simulador.
7. Executar UI tests.
8. Fazer build `Release`.
9. Rodar `xcodebuild analyze`.
10. Testar upgrade a partir do build TestFlight anterior.
11. Testar instalação limpa.
12. Testar com rede lenta e offline.
13. Importar um OPML grande.
14. Testar com armazenamento quase cheio.
15. Reproduzir podcast com app em background.
16. Simular background refresh.
17. Rodar Instruments para launch, memory e hangs.
18. Criar tag e registrar SHA.
19. Gerar novo archive da tag.
20. Subir como novo build do TestFlight.

Também continuam pendentes no checklist existente:

- privacy-policy URL;
- respostas de App Privacy;
- metadata;
- screenshots;
- review contact e demais campos;
- configuração dos testers. fileciteturn35file0L40-L49

---

# Minha recomendação final

O Feedmine já tem uma base técnica publicável. Ele não precisa de uma reescrita nem de uma grande mudança de arquitetura.

Mas eu faria um **release hardening curto e rigoroso** antes de enviar:

1. pipeline de release confiável;
2. migração de favoritos;
3. persistência de fontes importadas;
4. auditoria e remoção de feeds HTTP;
5. correção do cold-start fetcher;
6. limites defensivos de rede;
7. retirada de I/O do MainActor.

Depois disso, os problemas restantes podem entrar num `1.0.1` ou `1.1` sem comprometer a confiança inicial. No estado atual, o risco maior não é um detalhe cosmético: é um usuário atualizar, não ver seus favoritos, remover uma fonte e vê-la voltar, ou receber um catálogo onde algumas fontes nunca funcionam.
