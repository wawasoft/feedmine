# Onboarding: Intent + Topics Seed (Insight Timer-inspired)

**Date:** 2026-08-01
**Status:** Implemented (build verified 2026-08-01)

## Summary

Add two new Insight Timer-inspired screens between Welcome and Languages in the
curated onboarding flow. The screens ask "What brings you here?" (single-select
intent) and "What fascinates you?" (multi-select topics), seeding the story-duel
candidate pool so comparisons start from relevant content instead of raw discovery.

## New flow

```
Welcome → Intent → Topics → Languages → Duels → Review
  (1)      (2)      (3)       (4)        (5)      (6)
```

Each new screen follows the Insight Timer pattern: one question, tappable chips,
no typing, consistent visual container.

## What changes

### New files
- `Models/OnboardingSeed.swift` — `OnboardingIntent` enum + `OnboardingSeed` struct
- `Views/Onboarding/IntentScene.swift` — Tela 2
- `Views/Onboarding/TopicsScene.swift` — Tela 3

### Modified files
- `Views/CuratedOnboardingView.swift` — adds `.intent` and `.topics` to `Stage` enum,
  state for `OnboardingSeed`, wiring into `startComparisons()`, updated navigation
- `Services/CuratedPreferenceEngine.swift` — `CuratedOnboardingSession.init` accepts
  optional `OnboardingSeed`, pre-populates topic weights and discovery level

### How seeding works
1. User picks intent → stored in `OnboardingSeed.intent`
2. User picks topics → stored in `OnboardingSeed.topicIDs`
3. On Continue from Topics, seed applies:
   - `topicIDs` → boosts those topic feature keys to +1.5 in profile weights
   - `intent` → adjusts `discoveryLevel`:
     - `discoverNewIdeas` → 0.8 (exploratory)
     - `deepUnderstanding` → 0.3 (familiar/focused)
     - others → 0.5 (balanced)
   - Languages screen follows normally; Duels pool is already filtered by the
     boosted topic weights so `CuratedPreferenceEngine.makeCandidates` naturally
     favors matching content
4. `ConfidenceProgressView` starts at ~30% since the seed provides initial signal

### Design principles (from Insight Timer)
- One question per screen — zero cognitive load
- Chips, not text fields — one tap to answer
- Consistent background across all screens (circadian gradient + ambient blobs)
- "Before we start" framing — intent question feels optional/warm
- Continue button disabled until a selection is made (encourages engagement)
