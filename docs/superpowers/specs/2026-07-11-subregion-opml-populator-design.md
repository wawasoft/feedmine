# Sub-Region OPML Populator — Design Spec

**Date:** 2026-07-11
**Status:** ready
**Goal:** Preencher 1421 OPMLs de sub-região vazios com feeds locais descobertos automaticamente

---

## Problem

O Feedmine tem 1919 arquivos OPML em 101 países. Desses, 498 estão populados e **1421 estão vazios** (74%). Os vazios são quase todos OPMLs de sub-região — cidades, estados, províncias dentro de cada país. O pipeline de descoberta atual (`scripts/feed_discovery/pipeline.py`) só opera a nível de país, sem noção de sub-região.

Exemplo concreto: Nigéria tem `nigeria.opml` com 271 feeds nacionais, mas 37 arquivos como `nigeria-lagos.opml`, `nigeria-kano.opml` completamente vazios (`<body></body>`).

## Design Decisions

| Decisão | Escolha | Rationale |
|---------|---------|-----------|
| Escopo de conteúdo | Quantidade mista (texto + podcasts + YouTube) | Maximizar volume por sub-região, pipeline 100% automatizado |
| Prioridade | Maior população primeiro | Impacto máximo por feed descoberto |
| Metadados de sub-região | Expandir `countries.json` com todas as sub-regiões | Cobertura 100%, queries de busca mais precisas |
| Ritmo de execução | Batch progressivo (1 país por vez, sub-regiões em paralelo) | Progresso visível, correção de rota, ~1 mês pra tudo |

---

## Architecture

```
scripts/feed_discovery/subregion/
├── __init__.py
├── enrich_countries.py      # Expande countries.json com metadados de sub-regiões
├── discover_subregion.py    # Descoberta de feeds para UMA sub-região
├── populate.py              # Orquestrador: 1 país por vez, sub-regiões em paralelo
├── opml_writer.py           # Escreve resultados nos OPMLs (preserva estrutura existente)
└── progress.json            # Tracking do que já foi processado
```

Localizado dentro de `scripts/feed_discovery/` para aproveitar os imports relativos existentes (`from .. import search, discover, verify`, etc.).

### Componentes

#### 1. `enrich_countries.py` — Expansão de metadados

**Input:** `scripts/feed_discovery/data/countries.json` (101 países, ~5 cidades cada)
**Output:** `scripts/feed_discovery/data/countries_enriched.json`

Para cada país, varre os OPMLs de sub-região existentes em `feedmine/Resources/Feeds/countries/{slug}/` e extrai o nome da sub-região do nome do arquivo (`{pais}-{subregiao}.opml`). Gera um objeto `SubRegion` com:

```python
@dataclass
class SubRegion:
    slug: str           # "nigeria-lagos"
    name: str           # "Lagos" (derivado do filename, humanizado)
    parent_country: str # "nigeria"
    iso2: str           # herdado do país
    iso3: str           # herdado do país
    ddg_region: str     # herdado do país
```

**Humanização de nomes:** `nigeria-akwa-ibom.opml` → "Akwa Ibom", `romania-cluj-napoca.opml` → "Cluj-Napoca" (split por hífen, capitaliza cada palavra).

#### 2. `discover_subregion.py` — Descoberta por sub-região

**Input:** `SubRegion`, `Config`, `aiohttp.ClientSession`
**Output:** `list[Candidate]`

Três vias de descoberta, executadas em paralelo:

##### Via 1 — Texto/News (DDG Search)
- Queries específicas de cidade:
  - `"{subregion_name} {country_name} news"`
  - `"{subregion_name} {country_name} newspaper"`
  - `"{subregion_name} {country_name} blog"`
  - `"{subregion_name} notícias"` (se país tem `native_name`)
- Reusa `search.search()`, `discover.discover_feeds()`, `verify.verify_feed()` do pipeline existente
- Classificação: novo `is_local()` no `heuristic.py` que verifica se o feed pertence àquela sub-região. A lógica é mais relaxada que `is_national()` e usa múltiplos sinais:
  - **Domínio local:** O domínio do feed contém o nome da cidade/região (ex: `lagosnews.com` → Lagos)
  - **Título do feed:** O título menciona a cidade/região
  - **Descrição do feed:** A description tag menciona a cidade
  - **Host geográfico:** Para alguns países, o ccTLD de segundo nível indica a região (ex: `.rio.br` → Rio de Janeiro, `.co.uk` → genérico UK)
  - **Fallback:** Se nenhum sinal bater mas o feed foi descoberto por uma query da cidade, aceita como `national_reason="discovered_by_city_query"` (menos preciso mas garante volume)
  - Blocklist de domínios globais que nunca são locais: `cnn.com`, `bbc.com`, `nytimes.com`, etc.

##### Via 2 — Podcasts (iTunes Search API)
- Reusa `podcasts.discover()` existente, passando a sub-região como "país virtual":
  - `podcast_seed_terms()` usa o nome da sub-região como termo principal + nome do país como fallback
  - `itunes_search_url()` usa o ISO2 do país pai (para restringir a loja correta)
  - Filtro de país adaptado: além do match exato de ISO3, aceita resultados cujo `collectionName`, `artistName` ou `description` contenham o nome da cidade/região (case-insensitive, com fuzzy match para variações comuns como "Rio" vs "Rio de Janeiro")

##### Via 3 — YouTube (DDG + Channel About)
- Reusa `youtube.discover()` existente com adaptações:
  - `youtube_seed_queries()` adaptado: `"youtube {subregion_name} {country_name}"`, `"youtube {subregion_name}"`
  - Resolve canais da mesma forma (video pages → channelId → About page)
  - Filtro de país substituído por filtro de cidade: em vez de `channel_candidate_from_html()` comparar `country == country_name`, usa `is_local_channel()` que verifica se:
    - O título do canal contém o nome da cidade/região, OU
    - A descrição do canal (da About page) menciona a cidade, OU
    - O país do canal bate com o país pai E a query de descoberta era específica da cidade (fallback)

**Concurrency:** As 3 vias rodam em paralelo dentro de cada sub-região. Sub-regiões do mesmo país rodam em paralelo com `Semaphore(50)`.

#### 3. `populate.py` — Orquestrador

```
Para cada país (ordenado por população, decrescente):
  ├── Carrega SubRegions do país
  ├── Para cada SubRegion (em paralelo, semaphore=50):
  │     └── discover_subregion(subregion, session, cfg)
  ├── Coleta todos os Candidates das sub-regiões
  ├── Deduplica (normalize_url) entre sub-regiões do mesmo país
  ├── Para cada SubRegion com Candidates:
  │     └── opml_writer.write(subregion_opml_path, candidates)
  └── Atualiza progress.json com status do país

Ao final de cada país:
  ├── Log de sumário: X feeds descobertos, Y sub-regiões populadas
  └── Git commit opcional (--commit flag)
```

**Retry e resiliência:**
- `progress.json` trackeia cada sub-região: `{country_slug: {subregion_slug: "pending"|"done"|"failed"}}`
- Se o script quebrar, retoma de onde parou
- Sub-regiões que falharem (todas as 3 vias retornam 0 resultados) são marcadas como `"failed"` para revisão manual

#### 4. `opml_writer.py` — Escrita de OPML

**Input:** Caminho do OPML existente, lista de `Candidate`
**Output:** OPML atualizado in-place

Preserva a estrutura existente do OPML (cabeçalho, categorias). Adiciona feeds sob categorias padrão se a categoria não existir:

```xml
<outline text="News">
  <outline title="..." xmlUrl="..." type="rss"/>
</outline>
<outline text="Podcasts">
  <outline title="..." xmlUrl="..." type="rss"/>
</outline>
<outline text="YouTube">
  <outline title="..." xmlUrl="..." type="rss"/>
</outline>
```

Agrupa por `candidate.category` e dentro de cada categoria por `candidate.genre` (se disponível).

### Ordem de processamento (top 12)

| # | País | Pop. | Sub-regiões vazias |
|---|------|------|-------------------|
| 1 | Índia | 1.4B | 36 |
| 2 | China | 1.4B | 34 |
| 3 | Indonésia | 277M | 32 |
| 4 | Paquistão | 231M | 7 |
| 5 | Nigéria | 216M | 37 |
| 6 | Brasil | 214M | 27 |
| 7 | Bangladesh | 169M | 8 |
| 8 | Rússia | 144M | 10 |
| 9 | México | 128M | 32 |
| 10 | Etiópia | 126M | 12 |
| 11 | Japão | 125M | 47 |
| 12 | Filipinas | 115M | 17 |

### Métricas de sucesso

| Nível | Feeds por sub-região | Critério |
|-------|---------------------|----------|
| Mínimo viável | 10+ | Pipeline rodou sem erro e encontrou algo |
| Bom | 30+ | Mix de texto + podcasts ou YouTube |
| USA-level | 50+ | Jornais locais + podcasts + YouTube regional |

### O que NÃO faz parte deste escopo

- Curadoria humana dos resultados (vem depois, se necessário)
- Tradução de títulos de feeds
- Verificação de qualidade do conteúdo (só verificamos liveness)
- Modificação dos OPMLs de país já populados (só mexe nos de sub-região)
- Integração com o app Swift (os OPMLs já estão no bundle, é só rebuild)

### Dependências

- **Reusa:** `scripts/feed_discovery/search.py`, `discover.py`, `verify.py`, `heuristic.py`, `sources/podcasts.py`, `sources/youtube.py`, `models.py`, `opml.py`
- **Novo:** `scripts/feed_discovery/subregion/` (os 4 arquivos + `__init__.py`)
- **Dados existentes:** `countries.json` (input), OPMLs em `feedmine/Resources/Feeds/countries/` (output)
- **APIs externas:** DuckDuckGo (search), iTunes Search API, YouTube (About pages via scraping)
- **Estende:** `heuristic.py` com `is_local()`, `models.py` com dataclass `SubRegion`
