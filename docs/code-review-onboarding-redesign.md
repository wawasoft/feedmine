# Onboarding Redesign — Code Review (2026-07-28)

> Branch: `worktree-onboarding-redesign` | Base: `main` | Status: em revisão

## Veredito

O redesign ficou **muito melhor arquiteturalmente**: view monolítica dividida em cenas, conclusão adaptativa, Skip não contamina o perfil, preferências mais humanas, separação clara entre escolha/resumo/inspector.

---

## Status dos Bloqueadores

### Corrigidos (14 de 18)

| # | Issue | Fix |
|---|-------|-----|
| 1 | OnboardingPairQueue não conectado | Removido |
| 2 | Undo não desfaz | `onUndo` → `dismissFeedback(undo: true)` → `session.undo()` |
| 3 | New pair não funciona | Botão removido. Skip pill supre |
| 4 | Feedback direção errada | `CuratedEvidence.weightChanges` com deltas assinados |
| 5 | Altera feed principal antes do Save | Snapshot/restore `preOnboardingLanguages` |
| 6 | Skip mostra "Your mix is ready" | `NotificationCenter.onboardingDidSaveCuratedFeed` só no save |
| 7 | Preview não usa o profile | `FeedLoader.previewCuratedFeed(profile:limit:)` com `sourceMultipliers` |
| 10 | Só primeiro par aquecido | `warmNextTask` inicia warming durante o feedback overlay |
| 11 | Layout não cabe em telas compactas | `ScrollView` no `StoryDuelScene` |
| 12 | Estado contraditório de idiomas | `resolvedAvailableLanguages` sintetiza entradas |
| 13 | Nome automático usa tópicos rejeitados | Filtro `weight > 0.1` |
| 14 | Chips são botões inertes | `Text` quando `onAdjust == nil`, `Button` só editável |
| 15 | Regras com path nunca correspondem | `isOnboardingShowcase` faz split host+path |
| 18 | answerDelayTask não cancelada | Cancelada no `onDisappear` + `DispatchWorkItem` cancelável |

**Correções adicionais (pós segunda revisão):**
- **weightChanges decoding**: `init(from:)` customizado com `decodeIfPresent` + fallback `[:]`. Curated Feeds antigos não quebram mais.
- **Preview fora do body**: `previewItems` em `@State`, calculado ao entrar em `.review`. Não recalcula durante digitação no TextField.
- **Snapshot de filtro**: `preOnboardingLanguages` só é salvo na primeira entrada (`if nil`).
- **Undo + nome**: Botão Undo inferior agora chama `updateAutoName()`.

### Pendentes (5 itens)

| # | Issue | Complexidade | Nota |
|---|-------|-------------|------|
| 8 | Prefetch do pool inteiro | Médio | `warmPairImages` limita a 2 imagens/par. `curatedOnboardingCandidates()` carrega 1.200 itens — otimização futura |
| 9 | Processamento no MainActor | Alto | `makeCandidates()` faz NLP + 3.160 combinações na main thread — refactor grande |
| 10 | Aquecimento não controla publicação | Médio | Par é publicado antes do aquecimento terminar — reordenar fluxo |
| 16 | Multilíngues priorizados por um idioma | Médio | Usa `languages.first` — pré-existente |
| 17 | Merge desfaz round-robin editorial | Médio | `updateCandidates()` reordena — pré-existente |

### Fora do escopo (não introduzidos por esta branch)

- Localização (textos em inglês)
- Makefile (`pipefail`)
- Migração de favoritos (`legacyCount > 1`)
- Testes de unidade para as novas regras

---

## Bloqueadores gerais (pré-existentes, não modificados pela branch)

- **Makefile** mascara falhas com pipes sem `pipefail` e `|| true`
- **Migração de favoritos** ignora usuários com `legacyCount == 1`

---

## Ordem recomendada (atualizada)

1. ~~Remover ou integrar `OnboardingPairQueue`~~ ✅
2. ~~Corrigir Undo, New pair, direção do feedback~~ ✅
3. ~~Isolar onboarding do filtro global~~ ✅
4. Criar preview real do profile (#7)
5. Limitar prefetch; tirar NLP/scoring do MainActor (#8, #9)
6. ~~Adaptar layout para telas compactas~~ ✅
7. ~~Corrigir toast, tarefas canceláveis, fallback idiomas~~ ✅
8. Adicionar unit tests do onboarding
9. Corrigir gates do Makefile
10. Corrigir migração de favoritos

---

## Histórico de commits

```
801fe49a fix: feedback shows correct up/down arrows via weightChanges (#4)
6f1138e5 fix: 10 review items — Undo, Skip, filter isolation, toast, layout, fallback
52fa78cb test: fix UI test — English pre-selected, skip language tap step
0e051fab test: update UI test for redesigned onboarding flow
af8e5ec7 feat: continuous transition — 0.4s crossfade onboarding→feed with toast
f000e654 refactor: CuratedOnboardingView slimmed to coordinator (~740 lines)
1f094c2d feat: new onboarding scene components
9ec81102 feat: OnboardingPairQueue — background pair preloading
4b488071 feat: optional feed name with auto-generation
356c0eae feat: add .skip outcome + adaptive onboarding completion
```
