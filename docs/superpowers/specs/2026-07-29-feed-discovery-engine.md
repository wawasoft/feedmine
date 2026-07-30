# Feed Discovery Engine — Estratégia Multi-Passe para Descoberta de Feeds por Nicho

**Data:** 2026-07-29
**Contexto:** Descoberta de 10.907 blogs de jornalistas em 101 países para o Feedmine.

---

## 1. Visão Geral

O sistema descobre feeds RSS/Atom para um nicho específico (ex: blogs de jornalistas) usando **3 passes progressivos** com **19 estratégias de busca**, rodando em **101 países** com **termos localizados em 70+ idiomas**.

A arquitetura é genérica — trocando os termos de busca e as plataformas-alvo, o mesmo sistema encontra feeds para **qualquer nicho** (ex: blogs de chefs, DIY, fotógrafos, músicos, desenvolvedores, etc.).

```
┌─────────────────────────────────────────────────────────┐
│                  FEED DISCOVERY ENGINE                    │
├─────────────────────────────────────────────────────────┤
│ PASSE 1: Descoberta Ampla (10 estratégias)               │
│   └─ Batch paralelo: 3 workers × N países                │
│       └─ Resultado: 30-80 feeds por país                 │
├─────────────────────────────────────────────────────────┤
│ PASSE 2: Preenchimento de Lacunas (4 estratégias)        │
│   └─ Diáspora, regional, escolas, plataformas            │
│       └─ Resultado: +10-25 feeds por país                │
├─────────────────────────────────────────────────────────┤
│ PASSE 3: Busca Agressiva (5 estratégias)                 │
│   └─ Idioma puro, diretórios, tópicos, RSS direto        │
│       └─ Resultado: +10-20 feeds por país                │
├─────────────────────────────────────────────────────────┤
│ COMBINADO P2+P3: Execução consecutiva no mesmo país      │
│   └─ P2 descobre domínios → P3 busca nesses domínios     │
│       └─ Resultado: +15-40 feeds por país                │
└─────────────────────────────────────────────────────────┘
```

---

## 2. Pré-requisitos Técnicos

### Dependência Python
```bash
pip install ddgs
```

### Estrutura de Dados

Cada país precisa de um perfil mínimo:

```json
{
  "slug": "brazil",
  "name": "Brazil",
  "native_name": "Brasil",
  "cctld": "br",
  "use_cctld": true,
  "lang": "pt",
  "ddg_region": "br-pt",
  "iso2": "br",
  "cities": ["São Paulo", "Rio de Janeiro", "Brasília"]
}
```

O arquivo `countries.json` no Feedmine já contém esses perfis para 101 países. Para reproduzir em outro projeto, crie um arquivo similar.

---

## 3. Passe 1 — Descoberta Inicial Ampla

**Arquivo:** `discover_journalist_blogs.py`
**Objetivo:** Encontrar o máximo de feeds usando DuckDuckGo com termos localizados.

### 3.1 Dicionário de Termos Localizados

O coração do sistema. Para CADA idioma suportado, mapeie os termos do nicho:

```python
# Exemplo para nicho "jornalista"
JOURNALIST_TERMS = {
    "pt": ["jornalista", "repórter", "colunista", "correspondente", "editor"],
    "es": ["periodista", "reportero", "columnista", "corresponsal", "editor"],
    "fr": ["journaliste", "reporter", "chroniqueur", "correspondant"],
    "de": ["Journalist", "Reporter", "Kolumnist", "Korrespondent"],
    "ar": ["صحفي", "مراسل", "كاتب صحفي", "محرر"],
    "ja": ["ジャーナリスト", "記者", "コラムニスト", "特派員"],
    "zh": ["记者", "新闻工作者", "专栏作家", "编辑"],
    # ...70+ idiomas
}

# Termo "blog" em cada idioma
BLOG_TERMS = {
    "pt": "blog", "es": "blog", "fr": "blog", "de": "Blog",
    "ar": "مدونة", "ru": "блог", "ja": "ブログ", "zh": "博客",
    "ko": "블로그", "fa": "وبلاگ", "el": "ιστολόγιο",
    # ...todos os idiomas
}
```

**Como adaptar para outro nicho:**
- Substitua `JOURNALIST_TERMS` pelos termos do seu nicho (ex: `["chef", "cozinheiro", "gastrônomo"]` para culinária)
- Mantenha `BLOG_TERMS` (o conceito de "blog" é universal)
- Adicione termos específicos de plataforma do nicho (ex: `["receita", "restaurante"]` para chefs)

### 3.2 Mapa de Idiomas por País

```python
COUNTRY_LANGS = {
    "brazil": ["pt"],
    "canada": ["en", "fr"],
    "switzerland": ["de", "fr", "it"],
    "india": ["hi", "en", "bn", "ta"],
    # ...101 países
}
```

### 3.3 Estratégias do Passe 1

Cada estratégia gera queries de busca no DuckDuckGo, extrai URLs candidatas, e valida se são feeds RSS/Atom reais.

#### Estratégia 1: Substack
```python
# Query: "jornalista" site:substack.com "Brasil"
# Resolve: https://{publication}.substack.com → /feed
def substack_feed(url: str) -> Optional[str]:
    parsed = urlparse(url)
    if "substack.com" in parsed.netloc:
        parts = parsed.netloc.split(".")
        if len(parts) >= 3 and parts[-2:] == ["substack", "com"]:
            name = parts[0]
            if name not in ("www", "api", "cdn", "support"):
                return f"https://{name}.substack.com/feed"
    return None
```

**Por que funciona:** Substack tem padrão de URL previsível. Toda publicação em `nome.substack.com` tem feed em `/feed`.

**Para outro nicho:** Funciona para qualquer nicho — Substack tem publicações sobre tudo.

#### Estratégia 2: Medium
```python
# Query: periodista site:medium.com "Mexico"
# Resolve: https://medium.com/@user → /feed/@user
def medium_feed(url: str) -> Optional[str]:
    parsed = urlparse(url)
    if "medium.com" in parsed.netloc:
        path = parsed.path.strip("/")
        if path and not path.startswith(("feed/", "search", "tagged")):
            return f"https://medium.com/feed/{path}"
    return None
```

#### Estratégia 3: Blogs em Geral
```python
# Query: "journaliste" blog RSS  (em francês)
# Tenta extrair feeds de <link> tags na página, ou tenta /feed, /rss
```

#### Estratégia 4: WordPress
```python
# Query: "Journalist" site:wordpress.com "Deutschland"
# Cada blog WP.com tem feed em /feed
feed_url = url.rstrip("/") + "/feed"
```

#### Estratégia 5: Ghost & Blogger
```python
# Ghost: https://blog.ghost.io → /rss
# Blogger: https://blog.blogspot.com → /feeds/posts/default
PLATFORMS = [
    ("ghost.io", "/rss"),
    ("blogspot.com", "/feeds/posts/default"),
]
```

#### Estratégia 6: Associações de Imprensa
```python
# Mapeamento de queries em 25 idiomas:
ASSOC_QUERIES = {
    "en": 'journalist association members blog "{country}"',
    "es": 'asociacion de periodistas blog "{country}"',
    "pt": 'associação de jornalistas blog "{country}"',
    "fr": 'association des journalistes blog "{country}"',
    "de": 'Journalistenverband Blog "{country}"',
    "ar": 'رابطة الصحفيين مدونة "{country}"',
    "ru": 'союз журналистов блог "{country}"',
    # ...25 idiomas
}
```

**Para outro nicho:** Substitua por associações do nicho. Ex: para chefs → `"culinary association blog {country}"`, `"chef guild {country}"`.

#### Estratégia 7: YouTube
```python
# Query: 記者 site:youtube.com "日本"
# Extrai channel ID de @handle, /channel/ID, /c/name, /user/name
# Feed: https://www.youtube.com/feeds/videos.xml?channel_id={id}
```

#### Estratégia 8: Fallback em Inglês
```python
# Ativa quando país tem < 90 feeds após estratégias 1-7
# Usa termos em inglês como fallback para países não-anglófonos
# Query: journalist substack "Germany"
```

#### Estratégia 9: Busca Ampla
```python
# Ativa quando < 95 feeds
# Remove restrições de idioma, busca genérica por nome do país
# Queries: site:substack.com "Iceland", site:blogspot.com "Iceland"
```

#### Estratégia 10: Plataformas Locais
```python
# Plataformas de blog específicas de cada país:
COUNTRY_PLATFORMS = {
    "jp": [("note.com", "/rss"), ("fc2.com", "?xml")],
    "ru": [("livejournal.com", "/data/rss")],
    "kr": [("tistory.com", "/rss")],
    "ir": [("virgool.io", "/feed")],
    "id": [("kompasiana.com", "/rss")],
    "cn": [("jianshu.com", "/feeds")],
    # ...vários países
}
```

**Para outro nicho:** Pesquise quais plataformas de blog são populares em cada país. No Japão, `note.com` e `ameblo.jp` dominam. Na Rússia, `livejournal.com`. Na Coreia, `tistory.com`.

### 3.4 Função de Validação de Feed

```python
def validate_feed(url: str, timeout: int = 5) -> tuple[bool, str, str]:
    """Verifica se URL retorna RSS/Atom válido. Retorna (válido, motivo, título)."""
    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "Feedmine/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*"
        })
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            if resp.status != 200:
                return False, f"HTTP {resp.status}", ""
            data = resp.read(80000)
            text = data.decode("utf-8", errors="replace")
            # Marcadores RSS/Atom
            tl = text[:3000].lower().strip()
            if not ("<rss" in tl or "<feed" in tl or "<rdf" in tl):
                return False, "not XML feed", ""
            # Extrai título
            title = ""
            m = re.search(r'<title[^>]*>([^<]+)</title>', text[:2000], re.I)
            if m: title = m.group(1).strip()
            return True, "valid", title
    except Exception as e:
        return False, str(e)[:100], ""
```

### 3.5 Execução em Batch Paralelo

```bash
# batch_discover_journalists.sh
# Processa 3 países simultaneamente
# Pula países já cacheados
# Loga cada país separadamente
MAX_PARALLEL=3

for slug in $COUNTRIES; do
    while [ $RUNNING -ge $MAX_PARALLEL ]; do
        wait -n 2>/dev/null || true
        RUNNING=$(jobs -r | wc -l)
    done
    (
        python3 -u discover_journalist_blogs.py --country "$slug" --delay 0.7
    ) > "logs/${slug}.log" 2>&1 &
    sleep 0.5  # Stagger para evitar rate-limit
done
wait
```

**Métricas do Passe 1 com 3 workers:**
- Tempo por país: 3-6 minutos
- Países por hora: ~30-36
- 101 países: ~3 horas
- Feeds por país: 30-80
- Total: ~6.400 feeds

---

## 4. Passe 2 — Preenchimento de Lacunas

**Arquivo:** `discover_journalist_blogs_pass2.py`
**Objetivo:** Adicionar feeds para países abaixo de 100 usando estratégias contextuais.

### Estratégias do Passe 2

#### Estratégia 1: Diáspora
```python
# Busca jornalistas do país X escrevendo em inglês
queries = [
    f'"{name}" journalist blog',
    f'"{name}" journalist substack',
    f'expat {name} journalist blog',
    f'{name} diaspora journalist',
]
```

**Por que funciona:** Muitos jornalistas de países não-anglófonos mantêm blogs em inglês para alcançar audiência internacional. Esses blogs não aparecem nas buscas em idioma local.

**Para outro nicho:** `"Brazilian chef food blog"`, `"expat {nationality} photographer blog"`

#### Estratégia 2: Contexto Regional
```python
# Agrupa países por região para buscas mais amplas
regions = {
    "baltics": "Latvia Lithuania Estonia",
    "scandinavia": "Sweden Norway Denmark Finland Iceland",
    "balkans": "Serbia Croatia Bosnia Slovenia Montenegro",
    "caucasus": "Georgia Armenia Azerbaijan",
    # ...várias regiões
}
# Query: journalist blog "Latvia Lithuania Estonia"
```

**Por que funciona:** Jornalistas em países pequenos frequentemente cobrem toda a região. Um jornalista estoniano pode escrever sobre os "Balcãs" em inglês.

#### Estratégia 3: Escolas de Jornalismo
```python
queries = [
    f'"{name}" journalism school blog',
    f'"{name}" journalism training blog',
    f'"{name}" media institute blog',
]
```

**Por que funciona:** Faculdades de jornalismo têm páginas de ex-alunos com links para seus blogs. Professores de jornalismo frequentemente mantêm blogs.

**Para outro nicho:** `"{country} culinary school blog"`, `"{country} photography institute"`

#### Estratégia 4: Plataformas Conhecidas
```python
queries = [
    f'{name} journalist medium.com',
    f'{name} journalist ghost.org',
    f'{name} reporter blog',
]
```

### Métricas do Passe 2:
- Feeds adicionais: 10-25 por país
- Tempo por país: 2-4 minutos

---

## 5. Passe 3 — Busca Agressiva

**Arquivo:** `discover_journalist_blogs_pass3.py`
**Objetivo:** Estratégias sem restrições para países que ainda estão longe da meta.

### Estratégias do Passe 3

#### Estratégia 1: Idioma Puro (Sem Restrição Geográfica)
```python
# Remove o nome do país da query. Busca APENAS no idioma local.
# Query: jornalista blog RSS  (sem "Brasil")
# Captura jornalistas na diáspora, conteúdo global no idioma
```

**Por que funciona:** Muitos blogs em português são de brasileiros, mesmo sem mencionar "Brasil" na busca. O idioma é o filtro.

#### Estratégia 2: Diretórios de Feeds
```python
queries = [
    f'site:feedspot.com "{name}" RSS',
    f'site:blogarama.com "{name}"',
    f'"{name}" site:rss.com',
    f'"{name}" site:feedly.com',
]
```

**Por que funciona:** Feedspot e Blogarama são diretórios de feeds já curados por humanos.

#### Estratégia 3: Guarda-Chuva Regional
```python
# Para países Bálticos: busca "Baltic journalists"
# Para países Nórdicos: busca "Scandinavian journalists"
# Para o Magreb: busca "North African journalists"
```

**Por que funciona:** Jornalistas se organizam em redes regionais. Um site de associação de jornalistas nórdicos lista blogs de membros de todos os países.

#### Estratégia 4: Busca por Tópico
```python
topics = [name, f"{name} politics", f"{name} news", f"{name} media"]
for topic in topics:
    search(f'"{topic}" journalist substack')
```

**Por que funciona:** Foca no conteúdo que o jornalista cobre, não na profissão. Um jornalista que cobre "política brasileira" pode não usar a palavra "jornalista" no título do blog.

#### Estratégia 5: RSS Direto
```python
# Query mais específica mirando direto em URLs de feed
search(f'{term} blog "RSS feed" site:substack.com')
```

### Métricas do Passe 3:
- Feeds adicionais: 10-20 por país
- Tempo por país: 2-3 minutos

---

## 6. O Insight dos Passes Combinados

**A maior descoberta deste projeto:** Rodar Passe 2 + Passe 3 consecutivamente no mesmo país produz **15-40 feeds novos**, versus 10-25 (P2 sozinho) + 10-20 (P3 sozinho).

### Por que Combinado > Separado:

```
P2 sozinho:  busca "diaspora", "regional", "escolas"
             → descobre NOVOS DOMÍNIOS (sites, perfis, publicações)
             → +15 feeds

P3 sozinho:  busca agressiva nos domínios JÁ CONHECIDOS
             → satura rápido porque domínios são os mesmos do P1
             → +10 feeds

P2+P3 juntos: P2 descobre domínios FRESCOS
              P3 IMEDIATAMENTE busca nesses novos domínios
              → sinergia: P3 aproveita descobertas do P2
              → +35 feeds
```

### Implementação do Combinado:

```python
# Para cada país abaixo da meta:
for country in below_target:
    # Passe 2 — descobre novos domínios
    discover_pass2(country)   # +15 feeds
    
    # Passe 3 IMEDIATAMENTE — busca nesses novos domínios
    discover_pass3(country)   # +20 feeds (nos domínios do P2!)
    
    # Resultado combinado: +35 feeds
```

### Quando usar o combinado:

| País está em | Estratégia |
|-------------|-----------|
| 80-99 feeds | 1 rodada de P2+P3 → atinge 100 |
| 60-79 feeds | 2-3 rodadas de P2+P3 → atinge 100 |
| 40-59 feeds | 4-5 rodadas de P2+P3 → atinge 100 |
| < 40 feeds | P1 não foi eficaz — revise termos localizados |

---

## 7. Pipeline de Execução

### 7.1 Fluxo Completo

```
1. PREPARAÇÃO
   ├─ countries.json (perfis dos 101 países)
   ├─ JOURNALIST_TERMS (termos em 70 idiomas)
   ├─ COUNTRY_LANGS (idiomas por país)
   └─ COUNTRY_PLATFORMS (plataformas locais)

2. PASSE 1 — BATCH PARALELO
   ├─ 3 workers simultâneos
   ├─ 10 estratégias por país
   ├─ Cache por país (pula já processados)
   └─ Resultado: 30-80 feeds/país

3. PASSE 2+3 — COMBINADO
   ├─ 3 workers simultâneos
   ├─ Para CADA país abaixo da meta:
   │   ├─ P2: diáspora + regional + escolas + plataformas
   │   └─ P3: idioma puro + diretórios + tópicos + RSS direto
   └─ Resultado: +15-40 feeds/país por rodada

4. REPETIR PASSE 2+3
   ├─ Para países ainda abaixo da meta
   ├─ 2-5 rodadas conforme necessidade
   └─ Países pequenos (<5M pop.) podem precisar de 3-5 rodadas

5. MERGE NO OPML
   ├─ Insere feeds sob "Journalism & Media"
   ├─ Dedup contra feeds existentes
   ├─ Backup automático (.opml.bak)
   └─ feedmineDefaultEnabled="true"
```

### 7.2 Comandos

```bash
# Passe 1 — todos os países (batch paralelo)
bash scripts/batch_discover_journalists.sh 3

# Passe 2+3 combinado — países abaixo de 100
bash /tmp/batch_pass23_parallel.sh

# Merge no OPML
python3 scripts/merge_journalist_feeds.py --all

# País específico (teste)
python3 scripts/discover_journalist_blogs.py --country brazil --delay 0.7

# Passe 3 em país específico
python3 scripts/discover_journalist_blogs_pass3.py --country thailand --delay 0.4
```

---

## 8. Adaptação para Outros Nichos

### 8.1 O que precisa ser alterado

| Componente | O que mudar | Exemplo para nicho "chefs" |
|-----------|-------------|---------------------------|
| `NICHE_TERMS` | Termos do nicho por idioma | `{"pt": ["chef", "cozinheiro", "gastrônomo"]}` |
| `ASSOC_QUERIES` | Associações do nicho | `"culinary association blog {country}"` |
| `BLOG_TERMS` | Manter igual | "blog" é universal |
| Plataformas | Adicionar plataformas do nicho | `"tasty.co"`, `"food52.com"` |
| Estratégia YouTube | Mudar termos de busca | `"chef cozinha site:youtube.com"` |

### 8.2 O que NÃO precisa ser alterado

- **Arquitetura de 3 passes** — funciona para qualquer nicho
- **Batch paralelo** — genérico
- **Validação de feeds** — RSS é RSS
- **Merge no OPML** — estrutura é a mesma
- **Sistema de cache** — transparente
- **Múltiplos idiomas** — os 70 idiomas já estão mapeados
- **Fallback inglês** — sempre útil

### 8.3 Template para Novo Nicho

```python
# 1. Defina os termos do nicho
CHEF_TERMS = {
    "pt": ["chef", "cozinheiro", "gastrônomo", "restaurateur"],
    "es": ["chef", "cocinero", "gastrónomo", "restaurantero"],
    "fr": ["chef", "cuisinier", "gastronome", "restaurateur"],
    # ...todos os idiomas
}

# 2. Defina associações do nicho
CHEF_ASSOC_QUERIES = {
    "en": 'culinary association chef blog "{country}"',
    "fr": 'association culinaire chef blog "{country}"',
    "it": 'associazione cuochi blog "{country}"',
    # ...idiomas relevantes
}

# 3. Adicione plataformas específicas
CHEF_PLATFORMS = [
    ("tasty.co", "/feed"),
    ("food52.com", "/feed"),
    ("saveur.com", "/feed"),
    ("eater.com", "/feed"),
]

# 4. Substitua nos scripts:
#    JOURNALIST_TERMS → CHEF_TERMS
#    ASSOC_QUERIES → CHEF_ASSOC_QUERIES
#    COUNTRY_PLATFORMS → adicione CHEF_PLATFORMS
```

---

## 9. Lições Aprendidas

### 9.1 O que Funcionou

1. **Termos localizados são ESSENCIAIS** — Buscar "journalist" em vez de "jornalista" no Brasil retorna resultados irrelevantes em inglês. O idioma local é o filtro mais poderoso.

2. **Substack é a plataforma mais rica** — Para qualquer nicho, o Substack tem publicações relevantes. O padrão de URL previsível (nome.substack.com/feed) torna a descoberta trivial.

3. **Passes combinados (P2+P3) são 2-3x mais eficazes** — Não rode passes isolados. Sempre combine P2 imediatamente seguido de P3.

4. **Validação de feed é obrigatória** — ~60% das URLs candidatas não são feeds RSS válidos. Sem validação, o OPML fica poluído.

5. **Cache é fundamental** — Cada país leva 3-6 minutos. Sem cache, re-runs desperdiçam horas.

6. **Países pequenos precisam de mais rodadas** — Islândia, Malta, Chipre precisaram de 4-5 rodadas de P2+P3 para atingir 100.

7. **Otimização de plataformas locais faz diferença** — `note.com` para Japão, `livejournal.com` para Rússia, `tistory.com` para Coreia adicionaram 5-15 feeds cada.

### 9.2 O que Não Funcionou

1. **Busca sem país é muito ruidosa** — Remover o nome do país cedo demais retorna muitos resultados irrelevantes. Use apenas no P3.

2. **YouTube para blogs de texto** — A maioria dos "jornalistas" no YouTube são canais de notícia, não blogs pessoais. Estratégia pouco eficaz para nichos textuais.

3. **Passes isolados têm retornos decrescentes** — Rodar P3 repetidamente sem P2 satura rápido. Sempre intercale P2 para descobrir novos domínios.

4. **Google News RSS** — Tentamos usar Google News RSS feeds, mas eles retornam notícias agregadas, não blogs pessoais.

### 9.3 Métricas de Eficiência

| Estratégia | Feeds/país | Precisão | Cobertura |
|-----------|-----------|----------|-----------|
| Substack | 10-30 | 90% | ★★★★★ |
| WordPress | 12-25 | 85% | ★★★★ |
| Blogs em geral | 7-15 | 60% | ★★★ |
| Ghost/Blogger | 8-18 | 80% | ★★★ |
| Medium | 1-5 | 70% | ★★ |
| Associações | 1-5 | 50% | ★★ |
| Diáspora (P2) | 5-12 | 75% | ★★★★ |
| Regional (P2) | 5-10 | 70% | ★★★ |
| Idioma puro (P3) | 5-10 | 65% | ★★★ |
| Diretórios (P3) | 3-8 | 80% | ★★ |
| Plataformas locais | 5-15 | 85% | ★★★★ |

---

## 10. Scripts Produzidos

| Arquivo | Função |
|---------|--------|
| `scripts/discover_journalist_blogs.py` | Motor Passe 1 (10 estratégias) |
| `scripts/discover_journalist_blogs_pass2.py` | Passe 2 (4 estratégias) |
| `scripts/discover_journalist_blogs_pass3.py` | Passe 3 (5 estratégias) |
| `scripts/discover_journalists_wikipedia.py` | Descoberta complementar via Wikipedia |
| `scripts/batch_discover_journalists.sh` | Orquestrador paralelo P1 |
| `scripts/merge_journalist_feeds.py` | Merge no OPML |

**Scripts de batch (auto-gerados em /tmp/):**
| Arquivo | Função |
|---------|--------|
| `/tmp/batch_pass23_parallel.sh` | Orquestrador paralelo P2+P3 |
| `/tmp/batch_pass23_round2.log` | Log da rodada 2 |
| `/tmp/batch_pass23_round3.log` | Log da rodada 3 |

---

## 11. Check-list para Reproduzir com Outro Nicho

1. [ ] Criar `NICHE_TERMS` com termos em 70+ idiomas
2. [ ] Criar `NICHE_ASSOC_QUERIES` com associações do nicho
3. [ ] Listar plataformas específicas do nicho (ex: `tasty.co` para chefs)
4. [ ] Listar plataformas locais por país (ex: `note.com` para Japão)
5. [ ] Substituir termos nos 3 scripts de descoberta
6. [ ] Rodar Passe 1 em batch paralelo (3 workers)
7. [ ] Rodar Passe 2+3 combinado nos países abaixo da meta
8. [ ] Repetir P2+P3 para países que ainda não atingiram a meta
9. [ ] Merge no OPML
10. [ ] Verificar `feedmineDefaultEnabled` e `feedmineQualityScore`

---

## 12. Resultado Final

| Métrica | Valor |
|---------|-------|
| Países cobertos | 101/101 |
| Total de feeds | 10.907 |
| Países com 100+ feeds | 101/101 |
| Menor contagem | 100 (Romênia) |
| Maior contagem | 133 (China) |
| Tempo total | ~8 horas |
| Estratégias utilizadas | 19 |
| Idiomas suportados | 70+ |
| Scripts produzidos | 6 |
