# Onboarding Composer — Visual Design Spec

**Date:** 2026-08-04
**Status:** Approved — awaiting implementation plan
**Direction:** Warm Editorial (deep navy + circadian amber-coral)

---

## Summary

Replace the 6-stage onboarding (Welcome → Intent → Topics → Languages → StoryDuel → Review) with a 2-screen flow: **Welcome → Composer → Feed**. The onboarding becomes a feed editor, not a questionnaire or recommendation trainer. The core principle: *the onboarding IS FeedMine in edit mode, temporarily.*

---

## 1. Visual Identity

### Color Token System

```
Background:
  Deep navy:        #050A18  (screen background)
  Ink:              #141C2A  (card surfaces, elevated panels)
  Editorial sheet:  #1A2030  (composer overlay background)

Accent — Warm Earth circadian (preserved from existing CircadianEngine):
  Dawn:     #FFB238  (brand amber)
  Morning:  #FF9A3C  (amber-coral)
  Afternoon:#FF7A45  (brand coral)
  Evening:  #E8483C  (deep coral)
  Night:    #B8403A  (deeper coral)

Text:
  Primary:   #FFFFFF
  Secondary: #8899AA  (cool blue-gray — readable on navy without harsh contrast)
  Tertiary:  #5E6473  (existing muted — matching current app secondary)

Surfaces & Decor:
  Card fill:           #141C2A (ink)
  Card category stripe: circadian accent @ 80% opacity, 3pt wide, left-aligned
  Selection pill:       circadian accent, filled
  Divider/rule:         white @ 8% opacity, 1pt
  Sheet border:         white @ 6% opacity, 1pt
```

### Typography

```
Display — New York (system serif, .fontDesign(.serif)):
  Welcome headline:   38pt, weight .bold, -0.3pt tracking
  Composer title:     28pt, weight .bold
  Card titles:        17pt, weight .semibold

Body — SF Pro:
  Body text:          16pt, weight .regular, +0.3pt line height
  Control labels:     15pt, weight .medium
  Captions:           13pt, weight .regular

Utility — SF Pro:
  Section labels:     12pt, weight .semibold, uppercase, +1.2pt tracking
  Pill text:          12pt, weight .medium
```

New York appears in four locations: Welcome headline, Composer title, feed card titles, "Open my feed" button. Everything else uses SF Pro.

### Wordmark

The existing Wawasoft "W" symbol with the amber-coral gradient on "mine" in the wordmark. Present on the Welcome screen, subordinate to the headline. Not shown on the Composer.

---

## 2. Welcome Screen

### Layout (top to bottom)

1. **Card cascade** — 6 real `FeedItemCardView` instances drifting upward at staggered speeds through a `.regularMaterial` veil at ~60% opacity. Cards show real content from the default feed: a major publication, a specialist blog, a podcast, a video channel, a non-English source. 16:9 images, source name above title, category stripe faintly visible through the glass.

2. **Wordmark** — existing Wawasoft logo + "FeedMine" with amber gradient on "mine." Centered, small scale, above the headline.

3. **Amber rule** — 1pt horizontal line, accent color, separating wordmark zone from headline.

4. **Headline** — "The open web, arranged by you." in New York 38pt bold, white, centered, max 2 lines. The word "you" is set in the circadian accent color.

5. **Body** — "FeedMine brings together independent publications, podcasts, video channels and public sources. Set the mix yourself — or start broad and explore." SF Pro 16pt, secondary color, centered, 32pt horizontal padding.

6. **Primary CTA** — "Shape my feed" borderedProminent button, amber fill, SF Pro 16pt semibold, 16pt corner radius, full width with 24pt horizontal padding.

7. **Secondary CTA** — "Start broad" plain text, secondary color, 14pt, centered. No icon.

8. **Trust badges** — "On-device · No account · Fully editable" in caption style, secondary color. Carried over from existing design.

### Animation Sequence

All animations respect `UIAccessibility.isReduceMotionEnabled`. When true, all elements appear instantly at final positions.

1. Cards fade + drift upward, staggered 120ms each (0.6s total)
2. Wordmark + amber rule fade in (0.3s, after cards settle)
3. Headline fades + rises 16pt (0.5s, after rule)
4. Body fades + rises 12pt (0.4s, after headline)
5. CTAs fade + rise 8pt (0.3s, after body)
6. Badges fade in (0.3s, after CTAs)

Total sequence: ~2.1s. Equivalent to existing WelcomeScene animation duration.

### "Start broad" behavior

Creates a neutral `CuratedProfileDefinition`:
- Languages: device language only
- All topics: weight 0, no evidence
- All editorial styles: weight 0
- Discovery: 0.55 (slightly exploratory)
- Learning enabled: false

Dismisses onboarding and opens the feed directly with the neutral recipe saved as the active preset.

### Transition to Composer

0.5s spring animation: cards accelerate upward and dissolve, type block fades out, Composer preview cards rise from below. The amber rule persists across the transition, repositioning into the Composer as a section divider.

---

## 3. Composer Screen

### Core principle

The feed is always visible. The editorial sheet floats over it. Every control change updates the preview cards immediately. The preview IS the product.

### Layout

```
┌─ Screen: deep navy ─────────────────────┐
│                                          │
│  ┌── Card 1 (real FeedItemCardView) ──┐  │
│  │  16:9 image, source, title, stripe │  │
│  └────────────────────────────────────┘  │
│  ┌── Card 2 (partial, bottom edge) ───┐  │
│  │  ...                                │  │
│  └────────────────────────────────────┘  │
│                                          │
│ ┌─ Editorial sheet (#1A2030) ──────────┐ │
│ │  Your first edition                  │ │
│ │  Every control is optional. ...      │ │
│ │                                      │ │
│ │  ── Languages ──                    │ │
│ │  [English] [+ Add another]          │ │
│ │                                      │ │
│ │  ── Discovery ──                    │ │
│ │  Focused ━━━●━━━ Exploratory        │ │
│ │                                      │ │
│ │  ── Source balance ──               │ │
│ │  Established     Less ●Bal More     │ │
│ │  Specialist      Less ●Bal More     │ │
│ │  Independent     Less ●Bal More     │ │
│ │                                      │ │
│ │  ── Topics ──                       │ │
│ │  Science                    More    │ │
│ │  Technology                Normal   │ │
│ │  Arts & Culture             More    │ │
│ │  Politics                   Less    │ │
│ │  + Add topics                       │ │
│ │                                      │ │
│ │  ┌────────────────────────────────┐  │ │
│ │  │        Open my feed            │  │ │
│ │  └────────────────────────────────┘  │ │
│ └──────────────────────────────────────┘ │
└──────────────────────────────────────────┘
```

### Preview zone (top ~35%)

Two fully rendered `FeedItemCardView` instances using `loader.previewCuratedFeed(profile:limit:)` with the current recipe draft. A third card peeks from the bottom edge as a scroll affordance. When controls change, cards crossfade (250ms). On significant changes (e.g., editorial balance shifts), one card slides out and a new one slides in from the right.

### Editorial sheet (bottom ~60%)

**Surface:** `#1A2030` with top corners rounded 20pt, 1pt white-at-6% border. Scrolls internally if content overflows on compact devices (iPhone SE). Slides up from bottom on appear with spring animation (0.5s, damping 0.75).

**Header:**
- "Your first edition" — New York 28pt bold, white
- "Every control is optional. You can change these anytime." — SF Pro 13pt, secondary
- No progress bar, step counter, or close button

**Languages section:**
- Reuses existing `LanguageScene` search grid expanded inline
- Device language pre-selected as a filled amber chip
- "+ Add another language" button in secondary below
- Expanding the picker smoothly grows the sheet height

**Discovery section:**
- Single continuous slider: amber track, white-at-12% unfilled, coral 18pt circle thumb with subtle shadow
- Labels: "Focused" (left) / "Exploratory" (right) in SF Pro 12pt secondary
- No percentage display
- Maps to `discoveryLevel` (0.0 = Focused, 1.0 = Exploratory)

**Source balance section:**
- Three rows, each a custom three-state segmented control
- Labels: "Established references," "Specialist sources," "Independent voices"
- States: Less / Balanced / More — selected state = filled amber pill
- Maps to `editorial:reference`, `editorial:specialist`, `editorial:distinctive` weights:
  - Less = -1.5, Balanced = 0, More = +1.5
- Thin 1pt dividers between rows, white at 6%

**Topics section:**
- Clean vertical list, not a grid
- Each row: topic name (SF Pro 15pt medium, white) + current state chip (amber filled = More, no chip = Normal, coral accent = Less)
- Tapping cycles: Normal → More → Less → Normal
- "More" state adds a thin amber leading stripe matching the card category stripe treatment
- "Less" shows a subtle coral stripe
- "Normal" has no stripe — neutral
- "+ Add topics" at bottom expands a searchable topic picker
- No topic selection required. Zero topics = broad feed.

**Button:**
- "Open my feed" — amber-filled borderedProminent, SF Pro 16pt semibold, 16pt corner radius, full width within sheet

### Control → Preview feedback

- Controls update instantly, no debounce
- Preview cards crossfade to new composition (250ms)
- No loading spinners, no "recalculating" placeholder
- The local catalog ensures sub-second response

### On appear animation

1. Preview cards fade in and settle (0.4s)
2. Editorial sheet slides up with spring (0.5s, damping 0.75)
3. Sheet content appears at final positions — no internal stagger

### Reduce Motion

All animations collapse to instant cuts. Sheet appears at final position.

### Transition to Feed

"Open my feed" triggers:
1. Editorial sheet slides down and fades out (0.35s)
2. Preview cards remain in place — they become the first cards of the live feed
3. Feed chrome (header, tab bar if applicable) fades in around them
4. The feed scroll position starts at card 1

No separate "review" screen. The preview IS the result.

---

## 4. FeedRecipeDraft (New Model)

A simple representation of user choices — separate from `CuratedProfileDefinition` to distinguish "explicit configuration" from "learned evidence."

```swift
enum PreferenceLevel: String, Codable {
    case less, normal, more
}

struct FeedRecipeDraft {
    var languages: Set<String>
    var discoveryLevel: Double          // 0.0 focused ... 1.0 exploratory
    var topicPreferences: [String: PreferenceLevel]   // topic ID → level
    var editorialPreferences: [CuratedEditorialStyle: PreferenceLevel]
    var adjustFromOpens: Bool
}
```

A mapper (`FeedRecipeMapper`) converts `FeedRecipeDraft` → `CuratedProfileDefinition` using the existing weight/evidence conventions, but marks the provenance as `source: explicitUserSetting` rather than `source: comparison` or `source: explicitOpen`. This prevents explicit configuration from being recorded as "learned evidence."

Default (neutral) recipe:
- Languages: `[deviceLanguage]`
- Discovery: 0.55
- All topics: `.normal`
- All editorial styles: `.balanced` (maps to weight 0)
- Adjust from opens: `false`

---

## 5. What to Reuse (Existing Code)

| Component | Location | Usage |
|-----------|----------|-------|
| `LanguageScene` | `Views/Onboarding/LanguageScene.swift` | Integrated inline into Composer |
| `FeedItemCardView` | Existing card component | Preview cards, Welcome cascade |
| `CuratedProfileDefinition` | `Models/CuratedFeed.swift` | Output of the mapper, saved as curated feed |
| `sourceMultipliers` | `CuratedPreferenceEngine` | Live preview scoring |
| `previewCuratedFeed` | `FeedLoader` | Feed preview cards in Composer |
| `createCuratedFeed` | `FeedStore` | Save on "Open my feed" |
| `CuratedBackdrop` | `CuratedOnboardingView.swift` | Welcome screen background |
| `CircadianEngine.accent` / `.pageBackground` | `Services/CircadianEngine.swift` | All screens |
| Existing toast + transition after save | `FeedScreen` notification handler | Post-save feedback |
| `CuratedProfileControls` | `CuratedOnboardingView.swift` | Basis for Composer controls |
| `CuratedFeedInspectorView` | `Views/CuratedFeedInspectorView.swift` | Post-onboarding editor |

## 6. What to Remove from First Use

| Component | Reason |
|-----------|--------|
| `IntentScene` | No personal questions |
| `TopicsScene` (grid version) | Replaced by editorial list in Composer |
| `StoryDuelScene` | Comparisons removed from required path |
| `ConfidenceProgressView` | No "learning" language |
| `ChoiceFeedbackOverlay` | No live feedback needed without comparisons |
| Candidate pool + image warming | No comparisons |
| Adaptive comparison completion | No comparisons |
| "Learned profile" / "learning" language | Replaced by "recipe" / "edition" language |
| `pendingPair`/`currentPair` handshake | Only relevant if StoryDuel persists as optional feature |
| `OnboardingSeed` (intent + topicIDs) | Replaced by `FeedRecipeDraft` |

## 7. What to Create New

| Component | Purpose |
|-----------|---------|
| `FeedComposerScene` | Main Composer screen — preview zone + editorial sheet |
| `FeedRecipeDraft` | Simple model of user choices |
| `FeedRecipeMapper` | Converts draft → `CuratedProfileDefinition` |
| `EditorialBalanceControl` | Three-row Less/Balanced/More segmented control |
| `TopicPreferenceRow` | Single topic row with cycle-tap state |
| `DiscoverySlider` | Single continuous slider, no percentage label |

## 8. Success Criteria

- No personal questions asked
- Possible to start without selecting any topic
- No loading state for finding comparisons
- Every control produces a visible change in preview cards
- "Start broad" is a real alternative, not a hidden escape hatch
- The catalog is the visual protagonist, not the algorithm
- Feed presented as a recipe/edition, not a psychological profile
- Everything editable after onboarding
- First preview card = first feed card after transition
- Comparisons (StoryDuel) preserved as optional post-onboarding feature: "Tune with examples"

## 9. Accessibility

- All animations respect Reduce Motion (instant cuts)
- Dynamic Type: New York and SF Pro both support full Dynamic Type range
- VoiceOver: All controls labeled with human-readable values ("Science: More", not "topic:science weight: 1.5")
- Minimum touch target: 44pt for all interactive elements
- Color is never the sole differentiator — state labels ("More", "Less", "Balanced") always visible
- Sufficient contrast: white on navy (#FFFFFF on #050A18 = 21:1), secondary text on navy (#8899AA on #050A18 = ~6.5:1)

## 10. P0 vs P1 vs P2

**P0 — Ship the new flow:**
1. Replace `CuratedOnboardingView` stages: `welcome → composer` (remove intent, topics grid, comparisons, review)
2. Create `FeedComposerScene` with embedded preview + editorial sheet
3. Create `FeedRecipeDraft` + `FeedRecipeMapper`
4. Integrate `LanguageScene` inline in Composer
5. Wire discovery slider, editorial balance, topic rows to live preview
6. Implement "Start broad" neutral recipe path
7. Save + transition directly to feed on "Open my feed"
8. Rename "learned" to "recipe"/"edition" throughout

**P1 — Polish:**
1. Welcome card cascade uses real `FeedItemCardView` instances (not abstract shapes)
2. Seamless preview→feed transition (same cards persist)
3. "Broad and balanced" reset affordance in editor
4. Dynamic Type, VoiceOver, Reduce Motion pass
5. Localize hardcoded English strings

**P2 — Evolution:**
1. "Tune with examples" optional StoryDuel post-onboarding
2. Show why each change happened ("Science is More because you selected it")
3. Catalog collections / editorial bundles
4. Source provenance and governance display
5. Share recipes without sharing personal history
