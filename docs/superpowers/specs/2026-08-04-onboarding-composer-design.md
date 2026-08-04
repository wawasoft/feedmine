# Onboarding Composer — Visual Design Spec v2

**Date:** 2026-08-04
**Status:** Product direction approved — v2 addresses 14 technical/architectural issues from v1 review
**Direction:** Warm Editorial (circadian system + deep navy brand opening)

---

## Summary

Replace the 6-stage onboarding (Welcome → Intent → Topics → Languages → StoryDuel → Review) with a 2-screen flow: **Welcome → Composer → Feed**. The onboarding becomes a feed editor, not a questionnaire or recommendation trainer. The core principle: *the onboarding IS FeedMine in edit mode, temporarily.*

---

## 1. Visual Identity

### Brand vs. Product distinction

- **Welcome screen:** Deep navy (`#050A18`) brand opening — wordmark, splash character, amber-coral gradient on the symbol only. This is the *only* screen that uses the fixed dark brand palette.
- **Composer screen:** Inherits the active circadian theme — `engine.pageBackground`, `engine.accent`, light/dark appearance, active palette family, typographic configuration. Whatever theme the user will see in their feed is what they see in the Composer. The sheet uses semantic surface tokens (`.regularMaterial` or equivalent), not a hardcoded `#1A2030`.

The spec must work in both light and dark appearances across all five palette families.

### Color tokens (Welcome only)

```
Background:
  Deep navy:        #050A18

Accent — Warm Earth circadian:
  Dawn:     #FFB238  (brand amber)
  Morning:  #FF9A3C  (amber-coral)
  Afternoon:#FF7A45  (brand coral)
  Evening:  #E8483C  (deep coral)
  Night:    #B8403A  (deeper coral)

Text on navy:
  Primary:   #FFFFFF
  Secondary: #8899AA
  Trust badges: matching secondary
```

### Color tokens (Composer)

The Composer uses **no hardcoded colors**. All surfaces, text, accents, and dividers come from the active `CircadianEngine` theme + system appearance. The editorial sheet uses `.regularMaterial` or equivalent semantic material, tinted by the circadian background. If the active palette is Cool Sky, the Composer is cool. If Botanical, it's green-warm. The controls adapt.

### Typography

```
Display — New York (system serif, .fontDesign(.serif)):
  Welcome headline — .largeTitle, weight .bold
  Composer title   — .title, weight .bold

Body — SF Pro (all semantic styles, full Dynamic Type):
  Body text         — .body
  Control labels    — .body, weight .medium
  Captions          — .caption
  Section labels    — .caption, weight .semibold, uppercase
  Pill text         — .caption, weight .medium
  Button text       — .body, weight .semibold
```

New York appears in exactly **two** places: Welcome headline and Composer title. Nowhere else. Card titles use whatever typography the active feed configuration provides — no override. Buttons always use SF Pro. All sizes are semantic styles (`.largeTitle`, `.title`, `.body`, `.caption`) with `relativeTo:` for Dynamic Type, not fixed point sizes.

### Wordmark

The existing Wawasoft "W" symbol with the amber-coral gradient on "mine" in the wordmark. Present on the Welcome screen, subordinate to the headline. Not shown on the Composer.

### Card category stripe

The card category stripe uses **category color** (technology, news, science, design, culture, etc.) — not the circadian accent. This is existing behavior and must be preserved. The stripe communicates what the story is about, not the user's preference. Do not reuse this stripe geometry for topic preference state in the Composer.

---

## 2. Welcome Screen

### Layout (top to bottom, deep navy background)

1. **Card cascade** — 6 real `FeedItemCardView` instances drifting upward at staggered speeds through a `.regularMaterial` veil at ~60% opacity. Cards show real content from the default feed: a major publication, a specialist blog, a podcast, a video channel, a non-English source. 16:9 images, source name above title, category stripe (category-colored) faintly visible through the glass.

2. **Wordmark** — existing Wawasoft logo + "FeedMine" with amber gradient on "mine." Centered, small scale, above the headline.

3. **Amber rule** — 1pt horizontal line, circadian accent color, separating wordmark zone from headline.

4. **Headline** — "The open web, arranged by you." in New York `.largeTitle` bold, white, centered, max 2 lines. The word "you" is set in the circadian amber accent.

5. **Body** — "FeedMine brings together independent publications, podcasts, video channels and public sources. Set the mix yourself — or start broad and explore." SF Pro `.body`, secondary color, centered, 32pt horizontal padding.

6. **Primary CTA** — "Shape my feed" `borderedProminent` button, amber fill, SF Pro `.body` semibold, 16pt corner radius, full width with 24pt horizontal padding.

7. **Secondary CTA** — "Start broad" plain text, secondary color, `.subheadline`, centered. No icon.

8. **Trust badges** — "On-device · No account · Fully editable" in `.caption` style, secondary color. Carried over from existing design.

### Animation Sequence

All animations respect `UIAccessibility.isReduceMotionEnabled`. When true, all elements appear instantly at final positions.

1. Cards fade + drift upward, staggered 120ms each (0.6s total)
2. Wordmark + amber rule fade in (0.3s, after cards settle)
3. Headline fades + rises 16pt (0.5s, after rule)
4. Body fades + rises 12pt (0.4s, after headline)
5. CTAs fade + rise 8pt (0.3s, after body)
6. Badges fade in (0.3s, after CTAs)

Total sequence: ~2.1s.

### "Start broad" behavior

Creates and persists a neutral `FeedRecipeDefinition` (see Section 4), saves it as a curated feed named "My Feed," activates it as the current preset, and dismisses onboarding. The user lands in the feed directly.

### Transition to Composer

0.5s spring: cards accelerate upward and dissolve, type block fades out. The deep navy background crossfades into the active circadian `pageBackground` as the Composer preview cards rise from below.

---

## 3. Composer Screen

### Core principle

The feed is always visible behind the editorial controls. Every control change updates the preview deterministically. The Composer uses the same theme as the feed that will follow.

### Layout strategy: two sheet positions

The editorial sheet has **two detent positions** to handle compact screens and keyboard presentation:

**Compact (default):** Preview cards visible above. Sheet shows: title, discovery slider, source balance (3 rows), up to 4 topic rows, and the persistent "Open my feed" button. The button is pinned to the bottom of the sheet — always visible, never scrolled away.

**Expanded (languages, full topic list, or keyboard):** Sheet covers most of the screen. Used for language search, full topic browsing, or when the keyboard appears. The preview cards are partially obscured — this is acceptable because the user is making a focused selection.

The compact position fits on iPhone SE (320pt logical width, 568pt height) without internal scrolling for the default control set.

```
┌─ Screen: circadian pageBackground ────────┐
│                                            │
│  ┌── Card 1 (real FeedItemCardView) ────┐  │
│  │  16:9 image, source, title,          │  │
│  │  category stripe (category color)    │  │
│  └──────────────────────────────────────┘  │
│  ┌── Card 2 (partial peek) ────────────┐  │
│  │  ...                                  │  │
│  └──────────────────────────────────────┘  │
│                                            │
│ ┌─ Editorial sheet ──────────────────────┐ │
│ │  Shape your first feed                 │ │
│ │  Optional. Change anything later.      │ │
│ │                                        │ │
│ │  ── Languages ──                      │ │
│ │  [English] [+ Add another]            │ │
│ │                                        │ │
│ │  ── Discovery ──                      │ │
│ │  Focused ━━━●━━━ Exploratory          │ │
│ │                                        │ │
│ │  ── Source balance ──                 │ │
│ │  Established     Less ●Balanced More  │ │
│ │  Specialist      Less ●Balanced More  │ │
│ │  Independent     Less ●Balanced More  │ │
│ │                                        │ │
│ │  ── Topics ──                         │ │
│ │  Science                      More    │ │
│ │  Technology                  Normal   │ │
│ │  Arts & Culture               More    │ │
│ │  Politics                     Less    │ │
│ │  + Add topics                         │ │
│ │                                        │ │
│ │  ┌──────────────────────────────────┐  │ │
│ │  │        Open my feed              │  │ │  ← pinned, always visible
│ │  └──────────────────────────────────┘  │ │
│ └────────────────────────────────────────┘ │
│                                            │
│  Start broad    Reset to neutral          │  ← below sheet, always accessible
└────────────────────────────────────────────┘
```

### Exit and recovery

Always available below the sheet (or in the sheet header for compact devices):
- **Start broad** — saves neutral recipe, dismisses onboarding. Always visible.
- **Reset to neutral** — resets the current draft to the neutral recipe without dismissing. The preview updates to reflect the reset.

The user is never trapped. There is always a way out and a way back to neutral.

### Preview zone

Two `FeedCardPresentation` instances (see Section 5) displayed as real cards using the active feed's card component. A third card peeks from the bottom edge as a scroll affordance.

**Preview states:**
1. **Preparing** — initial load. Show 2 card skeletons matching the feed card geometry. No spinner text.
2. **Ready** — cards displayed. Controls active.
3. **No results** — the current combination produces no matches. Show explanation: "This combination is very specific. Try adjusting one of the controls." The "Open my feed" button remains active — an empty recipe is valid.
4. **Offline with content** — normal operation. The catalog is local.
5. **Error** — recoverable error message with retry. "Start broad" remains available as escape.

### Editorial sheet

**Surface:** Semantic material (`.regularMaterial` or system equivalent) tinted by the circadian page background. Top corners rounded 20pt. No hardcoded border color — use semantic separators.

**Header:**
- "Shape your first feed" — New York `.title` bold, primary color
- "Optional. Change anything later." — SF Pro `.caption`, secondary
- No progress bar, step counter, or close button. A subtle dismiss gesture (drag down) returns to Welcome.

**Languages section:**
- Uses extracted `LanguageSelectionControl` (see Section 6) — not the full `LanguageScene`
- Device language pre-selected as a chip using the circadian accent
- "+ Add another language" expands the sheet to show the language picker
- Minimum one language required. If the user removes the last language, revert to device language. "Every control is optional" applies to topics and source balance, not languages — zero languages is not a valid state.

**Discovery section:**
- Single continuous slider using circadian accent for the active track, semantic secondary fill for the inactive portion, 18pt thumb with subtle shadow
- Labels: "Focused" (left) / "Exploratory" (right) in `.caption` secondary
- No percentage display
- Maps to `discoveryLevel` (0.0 = Focused, 1.0 = Exploratory)

**Source balance section:**
- Three rows, each a custom three-state segmented control
- Labels: "Established references," "Specialist sources," "Independent voices"
- UI states: Less / Balanced / More — selected state = filled circadian accent pill
- Maps to editorial style weights: Less = -1.5, Balanced = 0, More = +1.5
- Thin semantic separators between rows

**Topics section:**
- Clean vertical list, not a grid
- Each row: topic name (SF Pro `.body` medium, primary) + state indicator
  - "More": filled accent chip, text "More"
  - "Normal": no chip, plain text
  - "Less": outlined chip in secondary, text "Less"
- Tapping cycles: Normal → More → Less → Normal
- Do **not** reuse the card category stripe geometry for topic state — use a distinct visual treatment (chips, not stripes) so the same visual element doesn't mean two different things
- "+ Add topics" expands the sheet to show a searchable topic picker
- No topic selection required. Zero topics = broad feed with no topic bias.

**Button:**
- "Open my feed" — circadian-accent-filled `borderedProminent`, SF Pro `.body` semibold, 16pt corner radius, full width within sheet
- **Pinned to the bottom of the sheet** — always visible regardless of scroll position

### Control → Preview feedback

- **The control itself responds instantly** — no input lag on slider drag or tap
- **Preview recomposition is coalesced** — 100ms debounce window. If the user drags the discovery slider from 0.3 to 0.7, the preview updates once at the final value, not at every intermediate step
- **Previous computation is cancelled** when a new state arrives before the previous one completes
- **The current preview remains visible** while the next one is being computed — no flash of empty state
- **If the top cards don't change** after a control adjustment (e.g., small slider move, same ranking), the cards stay stable. Do NOT force a visual change just to prove something happened. The update is deterministic; visual stability when results are unchanged is correct behavior.
- **If recomputation takes >500ms**, show a subtle progress indicator in the preview zone header. Measure on a physical iPhone SE (the slowest supported device).

### On appear animation

1. Preview cards fade in and settle (0.4s)
2. Editorial sheet slides up with spring (0.5s, damping 0.75)
3. Sheet content appears at final positions — no internal stagger

### Reduce Motion

All animations collapse to instant cuts.

### Transition to Feed

**P0 requirement:** Compositional continuity. The feed opens with the same recipe, and the preview zone remains visible (with a gentle fade) until the feed's first real composition is ready. This avoids a flash of different content.

**P1 aspiration:** Literal card identity continuity — the preview cards become the first feed cards. This requires a shared snapshot handoff mechanism not present in the current architecture. P0 guarantees the recipe is the same; P1 guarantees the cards are literally the same instances.

The transition:
1. Editorial sheet slides down and fades out (0.35s)
2. Preview cards hold position with a subtle fade
3. Feed composition begins with the saved recipe
4. Once ready (or after a short timeout), feed cards replace the preview — crossfade
5. Feed chrome fades in

No separate "review" screen. The preview IS the result.

---

## 4. FeedRecipeDefinition (Persistent Model)

A **persistent, round-trippable** representation of explicit user choices. Separate from `CuratedProfileDefinition`. Stored alongside it in the curated feed.

```swift
enum PreferenceLevel: String, Codable, Sendable {
    case less
    case neutral
    case more
}

struct FeedRecipeDefinition: Codable, Sendable, Hashable {
    var languages: [String]
    var discoveryLevel: Double              // 0.0 focused ... 1.0 exploratory
    var topicPreferences: [String: PreferenceLevel]   // topic ID → level
    var editorialPreferences: [String: PreferenceLevel] // editorial style → level
    var mediaTypes: Set<MediaType>
    var adjustFromOpens: Bool
    var modelVersion: Int

    static let currentModelVersion = 1
}
```

`CuratedFeed` gains an optional `recipe: FeedRecipeDefinition?` field. Feeds created through the old onboarding have `recipe = nil` and continue to work. Feeds created through the Composer have an explicit recipe.

### How recipe + learned signals combine

```text
FeedRecipeDefinition (explicit, user-editable)
        +
CuratedProfileDefinition evidence (learned from comparisons/opens)
        ↓
Effective profile used for ranking
```

The `CuratedPreferenceEngine` (or a new `FeedRecipeResolver`) merges the two:
1. Start with recipe weights (topic × preference level, editorial × preference level)
2. Layer learned evidence on top (additive, bounded to [-3, +3])
3. Recipe values serve as baseline, not as "evidence"
4. When `adjustFromOpens == false`, explicit opens do not modify the profile
5. When the user reopens the recipe editor, it reconstructs exactly what they chose — not the merged effective state

This enables:
- Faithful round-trip editing
- Reset to recipe baseline ("discard learned adjustments")
- Future recipe sharing
- Provenance display ("Science is More because you selected it")
- Disabling learning without losing explicit choices
- Migration as the model evolves

### Neutral recipe (used by "Start broad" and "Reset")

```swift
FeedRecipeDefinition(
    languages: [deviceLanguage],
    discoveryLevel: 0.55,
    topicPreferences: [:],           // no topic bias
    editorialPreferences: [:],       // all balanced (weight 0)
    mediaTypes: [.article, .podcast, .video],
    adjustFromOpens: false,
    modelVersion: 1
)
```

### Feed name

Auto-generated from the recipe at save time:
- If topics are set: derive from the top-weighted topic(s), e.g., "Science & Technology Feed"
- If no topics: "My Feed"
- The user can rename later in the feed editor (existing `CuratedFeedInspectorView`)

---

## 5. Preview Pipeline

### API

```swift
func previewCuratedCards(
    recipe: FeedRecipeDefinition,
    limit: Int
) async -> [FeedCardPresentation]
```

Returns `FeedCardPresentation` values (item + prepared media), not raw `[FeedItem]`. The presentation includes enough state for the card component to render its primary image path without a separate async resolution step.

If `FeedCardPresentation` doesn't exist yet, create it as a simple struct wrapping `FeedItem` + optional prepared image reference. The key requirement: the preview cards and the feed cards use the same rendering path so they look identical.

### Performance contract

- Uses `sourceMultipliers` from the existing engine (same ranking as the real feed)
- Cancellable — a new request cancels the previous one
- Runs off the main actor where possible
- On a physical iPhone SE, the first preview must appear within 1.5 seconds of the Composer appearing
- No network requests triggered by moving a control — all data comes from the local catalog
- Measure, don't assume. Profile on device before removing the "preparing" state timeout.

---

## 6. Extracted Language Component

`LanguageScene` currently is a full-screen scene with its own headline, intro text, Spacer, Continue button, and screen-level padding. It cannot be dropped inline into a sheet.

### Extraction

```
LanguageScene (preserved for backward compat or removed)
  └── LanguageSelectionControl (new, reusable)
        ├── SelectedLanguageChips
        ├── AddLanguageButton
        └── LanguagePicker (search + grid)
```

The Composer uses `LanguageSelectionControl`. If `LanguageScene` is still needed elsewhere, it can wrap the same control.

### Language validation

Zero languages is invalid. If the user removes the last language, revert to the device language. The "Every control is optional" copy in the sheet header refers to topics and source balance — languages are required for the feed to function.

---

## 7. Media Types

The Composer includes a media type section (not described in v1):

```
── Content types ──
Articles    [toggle on/off]
Podcasts    [toggle on/off]
Video       [toggle on/off]
```

Toggles, not Less/Balanced/More. You either include the type or you don't. Maps to the existing `media:text`, `media:audio`, `media:video` keys. Forums follow the same pattern if supported.

---

## 8. What to Reuse

| Component | Location | Usage |
|-----------|----------|-------|
| `LanguageSelectionControl` (extracted) | New | Inline language picker in Composer |
| `FeedItemCardView` + card component | Existing | Preview cards, Welcome cascade |
| `CuratedProfileDefinition` | `Models/CuratedFeed.swift` | Learned evidence — now layered with recipe |
| `sourceMultipliers` | `CuratedPreferenceEngine` | Live preview scoring |
| `createCuratedFeed` | `FeedStore` | Save on "Open my feed" |
| `CuratedBackdrop` | `CuratedOnboardingView.swift` | Welcome screen background |
| `CircadianEngine` theme system | `Services/CircadianEngine.swift` | All Composer surfaces |
| Existing toast + transition | `FeedScreen` notification handler | Post-save feedback |
| `CuratedFeedInspectorView` | `Views/CuratedFeedInspectorView.swift` | Post-onboarding editor |
| `CuratedPreferenceEngine` core scoring | `Services/CuratedPreferenceEngine.swift` | Recipe + evidence → effective profile |

## 9. What to Remove from First Use

| Component | Reason |
|-----------|--------|
| `IntentScene` | No personal questions |
| `TopicsScene` (grid version) | Replaced by editorial list in Composer |
| `StoryDuelScene` | Comparisons removed from required path |
| `ConfidenceProgressView` | No "learning" language |
| `ChoiceFeedbackOverlay` | No live feedback needed without comparisons |
| Candidate pool + image warming | No comparisons |
| Adaptive comparison completion | No comparisons |
| "Learned profile" / "learning" language | Replaced by "recipe" |
| `pendingPair`/`currentPair` handshake | Only if StoryDuel persists as optional |
| `OnboardingSeed` (intent + topicIDs) | Replaced by `FeedRecipeDefinition` |

Do **not** delete StoryDuel code yet — it is preserved for the P2 "Tune with examples" feature. Just remove it from the required onboarding path.

## 10. What to Create New

| Component | Purpose |
|-----------|---------|
| `FeedComposerScene` | Composer screen — preview zone + editorial sheet |
| `FeedRecipeDefinition` | Persistent, round-trippable explicit user choices |
| `FeedRecipeResolver` | Merges recipe + learned evidence → effective profile |
| `LanguageSelectionControl` | Extracted reusable language picker |
| `EditorialBalanceControl` | Three-row Less/Balanced/More segmented control |
| `TopicPreferenceRow` | Single topic row with cycle-tap (More → Normal → Less) |
| `DiscoverySlider` | Single continuous slider, no percentage label |
| `MediaTypeToggles` | Article/Podcast/Video on/off toggles |
| `FeedCardPresentation` | Item + prepared media for preview rendering |
| `previewCuratedCards(recipe:limit:)` | Async cancellable preview pipeline |

## 11. Accessibility (P0 — not P1)

Every item below is required before ship:

- **Dynamic Type:** All text uses semantic styles (`.largeTitle`, `.title`, `.body`, `.caption`) with `relativeTo:`. Test at maximum size on iPhone SE — the sheet must remain usable, preview cards must not collapse.
- **VoiceOver:** Every control announces its human-readable state. "Science: More" not "topic:science weight: 1.5". The discovery slider announces "Discovery: 65 percent toward exploratory" not "0.65". Custom actions for cycling topic states.
- **Reduce Motion:** All animations collapse to instant cuts. Crossfades become instant swaps.
- **Reduce Transparency:** The Welcome card cascade veil and Composer sheet material adapt — solid background when transparency is reduced.
- **Differentiate Without Color:** State labels ("More", "Less", "Balanced", "Focused", "Exploratory") are always visible as text, never communicated by color alone.
- **RTL:** Full right-to-left support. The editorial sheet, slider labels, topic rows, and language chips must lay out correctly in RTL locales.
- **Contrast:** All text meets WCAG AA on the active circadian background (both light and dark appearances, all five palette families). This must be verified, not assumed — measure it.
- **Touch targets:** Minimum 44pt × 44pt for all interactive elements: topic rows, editorial balance segments, language chips, toggle switches, the slider thumb, the "Open my feed" button, "+ Add" buttons.
- **Keyboard:** Full external keyboard navigation — tab through controls, space/enter to activate, arrow keys for slider adjustment.
- **Focus:** When the language picker or topic picker expands, focus moves to the search field. When dismissed, focus returns to the trigger button.
- **Localization:** All user-visible strings use `String(localized:)` or `LocalizedStringKey`. No hardcoded English in production code. The Welcome headline, body, button labels, section headers, control labels, and state text must all be localizable.

## 12. Success Criteria (revised)

- The user can open the feed without answering any personal questions
- No topic is mandatory
- Explicit configuration is persisted separately from learned signals
- The recipe can be reopened and edited without information loss
- The preview uses the same ranking mechanism as the feed
- Moving a control does not trigger network requests
- Consecutive rapid adjustments are coalesced and cancellable — no gesture blocking
- The first useful preview appears within 1.5s on an iPhone SE (measured)
- "Start broad" is visible, accessible, and produces a usable feed
- The Composer works offline when local content exists
- The Composer works with maximum Dynamic Type, VoiceOver, RTL, and Reduce Transparency
- Comparisons (StoryDuel) remain out of the required path but are not deleted
- The Composer matches the active circadian theme — it doesn't look like a different app

## 13. P0 / P1 / P2

**P0 — Ship the new flow:**
1. Define and persist `FeedRecipeDefinition` with version and migration path
2. Define how recipe + learned evidence combine (`FeedRecipeResolver`)
3. Create Welcome screen (deep navy brand opening) using semantic type
4. Create Composer screen using circadian semantic tokens — works in light + dark, all 5 palettes
5. Extract `LanguageSelectionControl` from `LanguageScene`
6. Build controls: Discovery slider, Editorial balance (Less/Balanced/More), Topic preference rows, Media type toggles
7. Auto-generate feed name from recipe
8. Create async cancellable preview pipeline (`previewCuratedCards`) returning prepared presentations
9. Handle all preview states: preparing, ready, no results, offline, error
10. Save recipe + create curated feed idempotently, activate as preset
11. Guarantee compositional continuity (same recipe → same feed)
12. Implement full accessibility: Dynamic Type, VoiceOver, Reduce Motion, Reduce Transparency, Differentiate Without Color, RTL, keyboard navigation, focus management, contrast verification
13. Localize all strings
14. Add tests: model persistence, recipe merging, preview pipeline, UI accessibility, performance benchmark on iPhone SE

**P1 — Polish:**
1. Welcome card cascade uses real `FeedItemCardView` instances (not abstract shapes)
2. Literal card identity continuity (preview cards become feed cards via snapshot handoff)
3. "Broad and balanced" / "Reset to neutral" affordance
4. Smooth crossfade between circadian themes during Welcome → Composer transition

**P2 — Evolution:**
1. "Tune with examples" optional StoryDuel post-onboarding, with suggested changes shown before applying
2. Provenance display per weight ("Science is More because you selected it")
3. Catalog collections / editorial bundles
4. Source governance and provenance metadata
5. Share recipes without sharing personal history
