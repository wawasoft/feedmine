# Feedmine — Redesign completo do onboarding

## Direção principal

O onboarding não deve parecer:

* configuração de aplicativo;
* questionário psicológico;
* treinamento de algoritmo;
* formulário de categorias;
* tutorial com quatro telas explicativas.

Ele deve parecer que o usuário está **editando a primeira edição do próprio feed**.

A metáfora recomendada é:

> Feedmine coloca algumas histórias sobre a mesa.
> O usuário faz pequenas escolhas editoriais.
> O primeiro feed nasce diante dele.

O onboarding atual já possui quatro estágios — apresentação, idiomas, comparações e revisão — e carrega o feed real por trás da experiência. Essa base arquitetural é boa e deve ser mantida.

---

# 1. Diagnóstico da experiência atual

## O conceito é mais forte que a execução visual

A frase atual, "A feed that explains itself", expressa muito bem a transparência do Feedmine. A tela, porém, utiliza:

* ícone genérico de sliders;
* pontos orbitando;
* cards fantasmagóricos;
* vidro pesado;
* background com imagens desfocadas;
* headline animada palavra por palavra.

São muitos símbolos visuais tentando comunicar simultaneamente:

* personalização;
* transparência;
* feed;
* tecnologia;
* inteligência;
* movimento.

O resultado corre o risco de parecer uma apresentação de produto de IA, justamente algo do qual o Feedmine deseja se diferenciar.

A solução não é deixar a abertura mais decorada. É fazer a própria interface demonstrar a proposta.

---

## A jornada parece longa antes mesmo de começar

O topo mostra:

* nome da etapa;
* barra de progresso;
* botão voltar;
* botão fechar;
* durante as comparações, "CHOICE N".

A sessão exige no mínimo 8 escolhas, considera 14 o objetivo e pode chegar a 20.

Mesmo que cada escolha seja rápida, "Choice 1", "Choice 2", "Choice 3" comunica trabalho restante. O usuário sente que está preenchendo um teste.

O onboarding deveria comunicar **confiança crescente**, não quantidade de tarefas restantes.

---

## A seleção de idiomas tem atrito excessivo

A tela apresenta imediatamente:

* título;
* explicação de privacidade;
* campo de busca;
* grade com todos os idiomas;
* número de fontes em cada idioma;
* botão de continuação.

O idioma do dispositivo já é pré-selecionado. Portanto, para a maioria das pessoas, a tela inteira existe apenas para confirmar algo que o app já sabe.

Há outros problemas:

* idiomas são representados por bandeiras nacionais;
* português aparece associado ao Brasil;
* espanhol à Espanha;
* chinês à China;
* idiomas globais como árabe e russo recebem símbolos genéricos;
* quando o catálogo ainda não carregou, opções fallback podem mostrar "0 sources".

Idioma não é país. Esse uso de bandeiras cria associações imprecisas e pode excluir variedades regionais.

---

## As comparações são visualmente apertadas

As duas histórias aparecem lado a lado em um `HStack`. Cada card contém:

* imagem 4:3;
* marcador A ou B;
* fonte;
* classificação editorial;
* título de até três linhas;
* instrução "I'd open this".

Em um iPhone, cada card recebe aproximadamente metade da largura disponível. Isso reduz:

* legibilidade dos títulos;
* importância das imagens;
* tamanho das áreas de toque;
* clareza da diferença entre as histórias.

A comparação é a parte mais importante do onboarding e, paradoxalmente, é onde o conteúdo recebe menos espaço.

---

## As comparações ainda podem ser visualmente injustas

O código aquece as imagens antes de apresentar o par, mas para de esperar assim que **pelo menos uma** das imagens entra no cache.

Além disso, os cards ainda utilizam `CachedAsyncImage` e podem resolver a própria imagem depois de aparecer.

Isso permite uma comparação como:

```text
História A: fotografia pronta e atraente
História B: gradiente com ícone
```

Mesmo que o usuário prefira o assunto B, a qualidade visual pode empurrá-lo para A.

Em uma rotina que aprende com escolhas, essa assimetria não é apenas um problema estético. Ela contamina o sinal coletado.

Os dois cards precisam entrar:

* ambos com imagem final;
* ambos com placeholder equivalente;
* ou ambos num layout predominantemente textual.

---

## Os rótulos editoriais influenciam a resposta

Antes da escolha, cada card mostra categorias como referência, especialista ou voz distintiva.

Essas informações tornam o sistema transparente, mas também preparam o usuário a escolher o que parece mais respeitável.

Uma pessoa pode pensar:

> "Eu deveria escolher o especialista."

O onboarding deixa de medir qual história ela abriria e passa a medir qual classificação ela considera socialmente desejável.

Esses rótulos deveriam aparecer **depois da escolha**, explicando o que foi aprendido.

---

## "Neither" não é o mesmo que "skip"

Atualmente existem quatro resultados:

* A;
* B;
* Both;
* Neither.

Mas há situações em que o usuário:

* não conhece nenhum dos assuntos;
* não gostou das manchetes;
* não consegue decidir;
* considera o par desequilibrado;
* simplesmente quer outra comparação.

"Nenhuma" transmite rejeição aos atributos das duas histórias. "Pular" deveria transmitir ausência de evidência.

O onboarding precisa das duas ações.

---

## A revisão é avançada demais para o primeiro uso

A etapa final apresenta:

* campo obrigatório para nome;
* sliders por tópico;
* sliders por estilo editorial;
* valores positivos e negativos;
* níveis de confiança;
* controle percentual de descoberta;
* toggle de aprendizado;
* botão para salvar.

Essa transparência é uma feature valiosa, mas representa a interface de manutenção de um feed, não a conclusão de um onboarding.

A etapa final deveria responder visualmente:

> "O que vou receber?"

Hoje ela responde:

> "Quais valores numéricos foram gravados?"

O atual `CuratedProfileControls` deve continuar existindo no "Open Hood", onde já é reutilizado pelo inspector.

Ele não deveria ocupar o caminho obrigatório antes de o usuário conhecer o feed.

---

# 2. Conceito recomendado

## "Edit your first edition"

A rotina inteira deve ser tratada como a criação de uma primeira edição editorial.

A experiência proposta possui quatro momentos:

```text
1. Ver a proposta
2. Confirmar idiomas
3. Fazer escolhas editoriais
4. Abrir a primeira edição
```

A diferença é que cada momento deve demonstrar algo concreto e ter uma ação clara.

---

# 3. Tela 1 — A abertura

## Objetivo

Comunicar em poucos segundos:

* o feed é construído a partir de histórias reais;
* o usuário controla o resultado;
* nada será inferido sobre sua identidade;
* a configuração será breve.

## Visual recomendado

Manter a metáfora atual dos cards atrás do vidro, mas torná-la funcional.

No início:

* um feed real aparece desfocado;
* fontes, manchetes e imagens estão presentes, mas escondidas pelo vidro;
* uma faixa vertical translúcida atravessa lentamente a tela;
* dentro dessa faixa, o conteúdo fica perfeitamente nítido;
* a faixa funciona como uma "janela de transparência".

Isso mostra literalmente:

> No Feedmine, você pode ver o que está por trás do feed.

Não usaria:

* pontos orbitando;
* símbolo de sliders como elemento principal;
* constelação;
* ícones tecnológicos;
* múltiplas animações independentes.

## Composição

```text
┌──────────────────────────────────┐
│                         Skip     │
│                                  │
│      [feed real desfocado]       │
│          │ janela nítida │       │
│                                  │
│     A feed you can see through.  │
│                                  │
│  Choose a few real stories.      │
│  See and change what this feed   │
│  learns from every choice.       │
│                                  │
│  On-device · No account · Editable│
│                                  │
│      [ Build my first feed ]     │
│        Start with everything     │
└──────────────────────────────────┘
```

## Copy recomendada

**Headline**

> A feed you can see through.

**Texto**

> Choose a few real stories. Feedmine will build a mix you can inspect and change anytime.

**Sinais de confiança**

> On-device · No account · Fully editable

**CTA**

> Build my first feed

**Secundário**

> Start with everything

"Start with everything" deve aparecer como texto, não escondido semanticamente num ícone X. Atualmente o X representa essa ação apenas por meio do accessibility label.

---

# 4. Tela 2 — Idiomas sem formulário

## Objetivo

Confirmar rapidamente os idiomas do conteúdo.

## Comportamento

Em vez de abrir uma grade completa, mostrar inicialmente:

```text
What do you read?

[ English ✓ ]

+ Add another language
```

Quando o usuário toca em "Add another language":

* a tela expande;
* aparece a busca;
* aparecem idiomas recomendados;
* depois a lista completa.

O idioma do dispositivo continua selecionado por padrão.

## Visual

Usar:

* nome localizado;
* nome nativo quando possível;
* código discreto;
* símbolo neutro de linguagem.

Exemplos:

```text
English
Português
Español
Français
日本語
العربية
```

Evitar bandeiras.

Também removeria a quantidade de fontes da seleção principal. "12,482 sources" não ajuda a responder "eu leio este idioma?" e pode fazer o usuário evitar um idioma aparentemente menos abastecido.

A disponibilidade pode ser comunicada apenas quando for um problema:

> Limited sources currently available

## CTA

Não usar:

> Continue with 1 language

Usar simplesmente:

> Continue

A quantidade pode aparecer discretamente no resumo:

> English · Português

---

# 5. Tela 3 — O coração do onboarding

## Novo formato: Story Duel vertical

Em vez de dois cards estreitos lado a lado, dividir a tela horizontalmente.

```text
┌──────────────────────────────────┐
│  Which would you open first?     │
│                                  │
│ ┌──────────────────────────────┐ │
│ │ REUTERS                     │ │
│ │                              │ │
│ │       imagem da história     │ │
│ │                              │ │
│ │ A new map of the universe…   │ │
│ └──────────────────────────────┘ │
│                                  │
│       [ Both ]   [ Neither ]     │
│                                  │
│ ┌──────────────────────────────┐ │
│ │ QUANTA MAGAZINE             │ │
│ │                              │ │
│ │       imagem da história     │ │
│ │                              │ │
│ │ The mathematician who…       │ │
│ └──────────────────────────────┘ │
│                                  │
│ Undo                 New pair ↻ │
└──────────────────────────────────┘
```

Cada história recebe praticamente toda a largura da tela.

Isso permite:

* títulos legíveis;
* imagens mais significativas;
* fontes claramente reconhecíveis;
* áreas de toque grandes;
* comparação mais justa;
* melhor adaptação ao Dynamic Type.

## Estrutura dos cards

Durante a escolha, mostrar apenas:

* fonte;
* imagem ou placeholder final;
* título;
* formato, quando relevante: podcast ou vídeo.

Não mostrar:

* A/B;
* classificação editorial;
* categoria inferida;
* ícone "hand.tap";
* texto "I'd open this".

O próprio card já é a ação.

---

# 6. Feedback depois de cada escolha

Atualmente a escolha troca rapidamente o par e dispara haptic feedback.

Eu adicionaria uma confirmação de aproximadamente 500–700 ms.

Quando o usuário escolhe:

1. o card selecionado cresce levemente;
2. o outro reduz opacidade;
3. surgem dois pequenos sinais do que foi aprendido;
4. o próximo par entra.

Exemplo:

```text
You chose this

Science ↑
Specialist voices ↑

Undo
```

Para "Both":

```text
Keeping both directions

Culture ↑
Global reporting ↑
```

Para "Neither":

```text
Showing less of this mix
```

Isso resolve uma questão essencial:

> O onboarding afirma que o feed é transparente, mas precisa mostrar essa transparência durante a interação, não apenas numa tela técnica ao final.

Os sinais devem usar linguagem humana. Nunca mostrar:

```text
Science +66
Specialist +33
Confidence 0.72
```

---

# 7. Progresso sem parecer prova

Remover:

```text
CHOICE 4
4 of 14
```

No lugar, utilizar três estados qualitativos.

## Estado 1

> Finding your range

Visual: três pontos separados.

## Estado 2

> A pattern is forming

Visual: pontos começam a se conectar.

## Estado 3

> Your first mix is ready

Visual: pequena composição conectada.

A "constelação" atual pode ser aproveitada, mas com no máximo cinco ou seis nós maiores e sem representar literalmente cada uma das 14 respostas. Atualmente o código desenha um ponto para cada resposta-alvo.

O usuário não precisa saber que restam nove decisões. Ele precisa saber que o sistema já possui ou ainda não possui informação suficiente.

---

# 8. Quantidade de escolhas

Eu não manteria 14 escolhas obrigatórias na primeira experiência.

Minha recomendação:

* 5 ou 6 escolhas para abrir o feed;
* 2 ou 3 escolhas opcionais para refinar;
* aprendizado posterior com ações explícitas dentro do app.

Fluxo:

```text
Após 5 escolhas:
Your first mix is ready.

[ Open my feed ]
[ Refine it a little more ]
```

A decisão de encerrar deve depender da cobertura dos sinais, não apenas de um número fixo.

Por exemplo:

* pelo menos três tópicos avaliados;
* pelo menos dois estilos editoriais avaliados;
* ausência de uma preferência dominante baseada numa única escolha;
* confiança mínima em alguns sinais.

O mecanismo atual já mantém pesos e confidence por atributo, portanto existe base para uma conclusão adaptativa.

---

# 9. Both, Neither e Skip

A barra entre as histórias deveria ter:

```text
Both      Neither      Skip
```

Sem ícones excessivos.

Semântica:

* **Both:** os dois conjuntos de atributos recebem sinal positivo;
* **Neither:** atributos distintivos recebem sinal negativo;
* **Skip:** nenhum sinal é gravado;
* **Undo:** restaura a escolha anterior.

"New pair" também pode ser apresentado como um gesto de arrastar horizontalmente a faixa central, mas manteria um botão explícito para acessibilidade.

---

# 10. Preparação dos pares

A experiência precisa manter uma fila pronta:

```text
Par visível
Próximo par pronto
Segundo próximo par pronto
Terceiro próximo par sendo preparado
```

Nunca mostrar loading entre duas escolhas normais.

A busca de candidatos deve começar:

* assim que o onboarding aparece;
* usando inicialmente o idioma do dispositivo;
* continuar em background durante a tela de abertura;
* ser recalculada apenas quando o usuário altera os idiomas.

Atualmente a busca começa somente depois que `startComparisons()` é chamado.

## Regra visual obrigatória

Um par só pode ser apresentado quando os dois lados estiverem resolvidos.

Estado válido:

```text
imagem final × imagem final
placeholder final × placeholder final
textual × textual
```

Estado inválido:

```text
imagem × carregando
imagem × placeholder provisório
imagem excelente × thumbnail quebrado
```

Além disso, os lados superior e inferior devem ser alternados de maneira determinística durante a sessão para reduzir preferência posicional.

---

# 11. Tela 4 — A revelação do feed

A tela final atual funciona como um painel de configuração avançado. Eu a substituiria por uma prévia real do resultado.

## Visual recomendado

```text
┌──────────────────────────────────┐
│                                  │
│       Here's your first mix.     │
│                                  │
│ [ Science ] [ Independent voices ]
│ [ Balanced discovery ]           │
│                                  │
│ ┌──────────────────────────────┐ │
│ │ primeiro card real do feed   │ │
│ └──────────────────────────────┘ │
│ ┌──────────────────────────────┐ │
│ │ segundo card real            │ │
│ └──────────────────────────────┘ │
│                                  │
│      [ Open my feed ]            │
│                                  │
│  See everything Feedmine learned│
│                                  │
│ Stored on this device · Editable │
└──────────────────────────────────┘
```

## Resumo das preferências

Mostrar apenas três a cinco chips humanos:

```text
Science
Culture
Specialist voices
Local reporting
Balanced discovery
```

Cada chip pode abrir um controle simples:

```text
Less ───── Balanced ───── More
```

Não usar sliders com precisão de décimos nem valores de −100 a +100.

## Nome do feed

Não exigir que o usuário dê um nome.

Criar automaticamente:

* My Feed;
* My First Feed;
* Morning Mix;
* Reading Mix;
* Science & Culture;
* ou um nome baseado nas duas preferências mais fortes.

O nome pode ser editado depois.

O campo obrigatório atual adiciona uma decisão administrativa exatamente no momento em que o usuário deveria receber uma recompensa.

## Open Hood

"See everything Feedmine learned" abre o editor avançado existente.

Esse é o lugar correto para:

* todos os tópicos;
* pesos negativos;
* confidence;
* estilos editoriais;
* nível de descoberta;
* aprendizado contínuo;
* idiomas;
* evidências.

O inspector atual já possui uma boa estrutura para isso.

---

# 12. Transição para o feed

A transição final deve ser a maior recompensa visual da experiência.

## Recomendada

1. o primeiro card da prévia está na tela;
2. o usuário toca "Open my feed";
3. título, chips e botão desaparecem;
4. o card permanece exatamente no lugar;
5. os cards seguintes deslizam para baixo;
6. o header normal do Feedmine entra;
7. o card da prévia torna-se o primeiro card real do feed.

O usuário não deveria ver:

```text
onboarding
→ fade branco
→ loading
→ feed diferente
```

Ele deveria sentir:

```text
prévia
→ feed
```

A mesma história continua na mesma posição. Isso faz o onboarding parecer parte do produto, não uma tela descartável anterior ao produto.

Depois da transição, um toast discreto:

> Your mix is ready. Open the hood anytime.

---

# 13. Linguagem visual

## Manter

* paleta circadiana;
* materiais translúcidos com moderação;
* imagens reais;
* cantos arredondados;
* tipografia editorial;
* fundos quentes;
* animações suaves;
* ausência de ilustrações corporativas genéricas.

## Reduzir

* círculos orbitando;
* símbolos SF grandes como protagonistas;
* pontos e linhas decorativas;
* múltiplos níveis de vidro;
* animações contínuas;
* textos em caixa alta;
* labels técnicos;
* sombras em todos os elementos;
* ícones dentro de cada ação.

## Princípio

> O conteúdo real deve ser a ilustração do onboarding.

A interface não precisa desenhar uma metáfora de feed quando já possui histórias reais para mostrar.

---

# 14. Movimento

## Abertura

* blur reduzido de 18 para 0 dentro da janela;
* duração aproximada de 700 ms;
* nenhuma animação infinita obrigatória.

## Escolha

* card selecionado: escala 1 → 1,015;
* card não selecionado: opacidade 1 → 0,35;
* feedback de aprendizado entra por baixo;
* próximo par cruza verticalmente;
* duração total abaixo de 700 ms.

## Progresso

* nós aparecem gradualmente;
* conexão desenhada somente quando um novo tipo de sinal é descoberto;
* não animar continuamente.

## Redução de movimento

O fluxo atual possui rotações e animações repetidas sem uma política ampla de `Reduce Motion`.

Com redução de movimento:

* remover rotações;
* remover parallax;
* substituir slides por crossfade curto;
* manter apenas mudanças de opacidade;
* não utilizar blur animado.

---

# 15. Tom de voz

O tom atual é inteligente, porém excessivamente defensivo em alguns momentos:

> "It says nothing about where you live or who you are."

> "No answer defines you."

> "These are preferences, not a personality verdict."

Essas frases comunicam valores importantes, mas repetidas em todas as telas fazem o usuário imaginar práticas invasivas que talvez nem tivesse considerado.

A privacidade deve ser:

* clara;
* factual;
* presente;
* não ansiosa.

## Tom recomendado

### Abertura

> Choose a few real stories. Change the result anytime.

### Idiomas

> Which languages should appear in this feed?

### Comparações

> Which would you open first?

### Feedback

> More science. More specialist voices.

### Revisão

> Here's your first mix.

### Privacidade

> Built and stored on this device.

A explicação completa permanece disponível em "How this works".

---

# 16. O que preservar da implementação atual

Não recomeçaria do zero.

Preservaria:

1. histórias reais em vez de categorias abstratas;
2. respostas A, B, ambos e nenhuma;
3. undo;
4. seleção explícita de idiomas;
5. modelo local;
6. perfil totalmente editável;
7. evidências humanas legíveis;
8. feed carregando por trás do onboarding;
9. seleção editorial prévia das fontes;
10. garantia de não repetir histórias.

A grande mudança é de hierarquia:

```text
Atual:
explicar → configurar → escolher → configurar tecnicamente → feed

Proposto:
demonstrar → confirmar → escolher → visualizar → feed
```

---

# 17. Estrutura de componentes recomendada

O `CuratedOnboardingView` atual concentra toda a experiência, controles, animações e ações num arquivo muito grande.

Eu separaria visualmente:

```text
CuratedOnboardingCoordinator
├── OnboardingWelcomeScene
├── OnboardingLanguageScene
├── StoryDuelScene
│   ├── StoryDuelCard
│   ├── ChoiceFeedbackOverlay
│   └── ConfidenceProgressView
├── FeedRevealScene
│   ├── PreferenceSummaryChips
│   └── FeedPreview
└── OnboardingPairQueue
```

Estado principal:

```swift
enum OnboardingStage {
    case welcome
    case languages
    case calibrating
    case ready
    case revealing
}
```

O conceito de `review` deixa de ser configuração avançada e passa a ser `ready`.

---

# 18. Critérios de qualidade

O onboarding estará refinado quando:

1. uma pessoa puder concluir o caminho normal em menos de um minuto;
2. o usuário fizer no máximo uma escolha administrativa;
3. nenhuma tela parecer formulário;
4. nenhuma comparação possuir mídia visualmente desigual;
5. não houver loading entre escolhas;
6. o usuário entender o que foi aprendido após cada resposta;
7. "Skip" não alterar preferências;
8. o primeiro feed for visualmente igual à prévia;
9. controles avançados forem opcionais;
10. o nome do feed não for obrigatório;
11. o usuário puder começar com tudo sem procurar um ícone X;
12. a experiência funcionar integralmente com Reduce Motion e Dynamic Type;
13. todas as strings estiverem localizadas;
14. o onboarding não depender de animações infinitas;
15. a saída para o feed parecer continuidade, não troca de aplicativo.

---

# 19. Prioridade de implementação

## P0 — experiência fundamental

* substituir comparação lado a lado por cards verticais;
* resolver igualmente as imagens dos dois candidatos;
* adicionar Skip;
* começar prefetch durante a abertura;
* manter fila de pares prontos;
* reduzir primeira sessão para um ponto adaptativo de conclusão;
* substituir review técnico por feed preview;
* tornar nome opcional;
* transição contínua para o feed.

## P1 — refinamento visual

* janela de transparência na abertura;
* feedback visual do que foi aprendido;
* progresso qualitativo;
* preference chips;
* animação de revelação;
* neutralizar ícones e bandeiras;
* reduzir materiais e elementos orbitais.

## P2 — qualidade completa

* Reduce Motion;
* Dynamic Type;
* VoiceOver;
* localização;
* métricas de abandono;
* medição de viés posicional;
* instrumentação de tempo entre escolhas;
* testes de equivalência visual dos pares.

---

# Conclusão

O onboarding atual possui uma ideia rara e realmente diferenciada:

> em vez de perguntar o que o usuário gosta, mostra histórias reais e deixa que ele escolha.

Isso deve permanecer como o centro absoluto da experiência.

O maior erro atual é cercar essa ideia com interface de configuração e linguagem de algoritmo. O onboarding deveria ser mais simples, mais editorial e mais visual:

```text
Histórias reais
→ pequenas escolhas
→ aprendizado visível
→ primeira edição pronta
```

Minha recomendação final é tratar o processo não como "configurar preferências", mas como **editar a primeira edição do seu próprio feed**.
