# Onboarding Composer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 6-stage onboarding with Welcome → Composer → Feed, with persistent `FeedRecipeDefinition`, circadian-aware Composer, async preview pipeline, coalesced controls, and full P0 accessibility.

**Architecture:** New `FeedRecipeDefinition` persisted as `recipe_json` in `curated_feed` table alongside existing `definition_json`. A `FeedRecipeResolver` merges explicit recipe + learned evidence into the effective profile. `FeedComposerScene` renders 2 preview cards with prepared `FeedCardPresentation` values, computed via a cancellable async pipeline with 100ms coalescing. Controls update instantly but preview recomposition is debounced. `CuratedOnboardingView` drops to 2 stages (welcome, composer). Existing `CuratedProfileControls` and `CuratedFeedInspectorView` continue to work for post-onboarding editing.

**Tech Stack:** SwiftUI, GRDB (SQLite), Swift Concurrency (`async/await`, `Task` cancellation), XCTest, existing `CircadianEngine`, existing `FeedCardPresentation`

## Global Constraints

- Welcome screen uses fixed deep navy (`#050A18`) brand palette; Composer inherits active circadian theme via `engine.pageBackground` and `engine.accent`
- New York system serif (`.fontDesign(.serif)`) ONLY on Welcome headline + Composer title — nowhere else
- All type sizes use semantic styles (`.largeTitle`, `.title`, `.body`, `.caption`) with `relativeTo:` — no fixed point sizes
- "Shape your first feed" as Composer title; "Shape my feed" / "Start broad" as Welcome CTAs
- `PreferenceLevel` enum: `.less`, `.neutral`, `.more` — UI translates per context (Normal for topics, Balanced for sources)
- Card category stripe uses category color — do NOT repurpose for topic preference state
- Minimum 1 language required; zero topics is valid
- Zero network requests from moving controls — all data from local catalog
- First preview within 1.5s on iPhone SE (measured)
- All animations respect Reduce Motion (instant cuts)
- Full Dynamic Type, VoiceOver, RTL, Reduce Transparency, Differentiate Without Color in P0
- All user-visible strings use `String(localized:)` or `LocalizedStringKey`
- Minimum 44pt × 44pt touch targets
- Do NOT delete StoryDuel code — preserve for P2 "Tune with examples"
- "Learned"/"learning" language → "recipe"
- Feed name: auto-generated from top topic(s) or "My Feed"

---

### Task 1: FeedRecipeDefinition — Persistent Model

**Files:**
- Create: `feedmine/Models/FeedRecipeDefinition.swift`
- Modify: `feedmine/Models/CuratedFeed.swift:9-15` (add `recipe` field)
- Modify: `feedmine/Services/UserStateStore.swift:851-951` (CuratedFeedStore — add `recipe_json` column, update CRUD)
- Create: `feedmineTests/FeedRecipeDefinitionTests.swift`

**Interfaces:**
- Consumes: `CuratedTopic` (existing), `CuratedEditorialStyle` (existing)
- Produces:
  - `enum PreferenceLevel: String, Codable, Sendable { case less, neutral, more }`
  - `struct FeedRecipeDefinition: Codable, Sendable, Hashable` with `languages`, `discoveryLevel`, `topicPreferences`, `editorialPreferences`, `mediaTypes`, `adjustFromOpens`, `modelVersion`
  - `enum MediaType: String, Codable, Sendable, CaseIterable { case article, podcast, video }`
  - `CuratedFeed.recipe: FeedRecipeDefinition?`
  - `CuratedFeedStore.create(name:definition:recipe:)`, `CuratedFeedStore.update(id:name:definition:recipe:)`

- [ ] **Step 1: Define PreferenceLevel and MediaType enums, FeedRecipeDefinition struct**

Create `feedmine/Models/FeedRecipeDefinition.swift`:

```swift
import Foundation

enum PreferenceLevel: String, Codable, Sendable, CaseIterable {
    case less
    case neutral
    case more

    /// UI label for topic rows (Less / Normal / More)
    var topicLabel: String {
        switch self {
        case .less: return String(localized: "Less")
        case .neutral: return String(localized: "Normal")
        case .more: return String(localized: "More")
        }
    }

    /// UI label for source balance rows (Less / Balanced / More)
    var balanceLabel: String {
        switch self {
        case .less: return String(localized: "Less")
        case .neutral: return String(localized: "Balanced")
        case .more: return String(localized: "More")
        }
    }

    /// Maps to profile weight
    var profileWeight: Double {
        switch self {
        case .less: return -1.5
        case .neutral: return 0
        case .more: return 1.5
        }
    }

    /// Cycle to next state: neutral → more → less → neutral
    func next() -> PreferenceLevel {
        switch self {
        case .neutral: return .more
        case .more: return .less
        case .less: return .neutral
        }
    }
}

enum MediaType: String, Codable, Sendable, CaseIterable {
    case article
    case podcast
    case video

    var displayName: String {
        switch self {
        case .article: return String(localized: "Articles")
        case .podcast: return String(localized: "Podcasts")
        case .video: return String(localized: "Video")
        }
    }

    var featureKey: String { "media:\(rawValue)" }
}

struct FeedRecipeDefinition: Codable, Sendable, Hashable {
    var languages: [String]
    var discoveryLevel: Double
    var topicPreferences: [String: PreferenceLevel]
    var editorialPreferences: [String: PreferenceLevel]
    var mediaTypes: Set<MediaType>
    var adjustFromOpens: Bool
    var modelVersion: Int

    static let currentModelVersion = 1

    init(
        languages: [String] = [],
        discoveryLevel: Double = 0.5,
        topicPreferences: [String: PreferenceLevel] = [:],
        editorialPreferences: [String: PreferenceLevel] = [:],
        mediaTypes: Set<MediaType> = [.article, .podcast, .video],
        adjustFromOpens: Bool = false,
        modelVersion: Int = FeedRecipeDefinition.currentModelVersion
    ) {
        self.languages = Array(Set(languages.map {
            $0.lowercased().split(separator: "-").first.map(String.init) ?? $0.lowercased()
        })).sorted()
        self.discoveryLevel = min(1, max(0, discoveryLevel))
        self.topicPreferences = topicPreferences
        self.editorialPreferences = editorialPreferences
        self.mediaTypes = mediaTypes.isEmpty
            ? [.article, .podcast, .video]
            : mediaTypes
        self.adjustFromOpens = adjustFromOpens
        self.modelVersion = modelVersion
    }

    /// The neutral, broad recipe used by "Start broad" and "Reset to neutral."
    /// Languages default to device language at call site.
    static func neutral(languages: [String]) -> FeedRecipeDefinition {
        FeedRecipeDefinition(
            languages: languages,
            discoveryLevel: 0.55,
            topicPreferences: [:],
            editorialPreferences: [:],
            mediaTypes: [.article, .podcast, .video],
            adjustFromOpens: false,
            modelVersion: currentModelVersion
        )
    }
}
```

- [ ] **Step 2: Write model tests**

Create `feedmineTests/FeedRecipeDefinitionTests.swift`:

```swift
import XCTest
@testable import feedmine

final class FeedRecipeDefinitionTests: XCTestCase {
    func testNeutralRecipeHasNoTopicBias() {
        let recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        XCTAssertTrue(recipe.topicPreferences.isEmpty)
        XCTAssertTrue(recipe.editorialPreferences.isEmpty)
        XCTAssertEqual(recipe.discoveryLevel, 0.55)
        XCTAssertFalse(recipe.adjustFromOpens)
    }

    func testNeutralRecipeIncludesDefaultMediaTypes() {
        let recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        XCTAssertEqual(recipe.mediaTypes, [.article, .podcast, .video])
    }

    func testEmptyMediaTypesFallBackToDefaults() {
        var recipe = FeedRecipeDefinition(languages: ["en"], mediaTypes: [])
        XCTAssertEqual(recipe.mediaTypes, [.article, .podcast, .video])
    }

    func testDiscoveryLevelClamped() {
        let low = FeedRecipeDefinition(languages: ["en"], discoveryLevel: -0.5)
        XCTAssertEqual(low.discoveryLevel, 0.0)
        let high = FeedRecipeDefinition(languages: ["en"], discoveryLevel: 1.5)
        XCTAssertEqual(high.discoveryLevel, 1.0)
    }

    func testLanguagesNormalizedToRootCodes() {
        let recipe = FeedRecipeDefinition(languages: ["en-US", "pt-BR", "en-GB"])
        XCTAssertEqual(recipe.languages, ["en", "pt"])
    }

    func testPreferenceLevelCycle() {
        XCTAssertEqual(PreferenceLevel.neutral.next(), .more)
        XCTAssertEqual(PreferenceLevel.more.next(), .less)
        XCTAssertEqual(PreferenceLevel.less.next(), .neutral)
    }

    func testPreferenceLevelProfileWeight() {
        XCTAssertEqual(PreferenceLevel.less.profileWeight, -1.5)
        XCTAssertEqual(PreferenceLevel.neutral.profileWeight, 0)
        XCTAssertEqual(PreferenceLevel.more.profileWeight, 1.5)
    }

    func testRoundTripJSON() throws {
        var recipe = FeedRecipeDefinition(
            languages: ["en", "pt"],
            discoveryLevel: 0.7,
            topicPreferences: ["topic:technology-science": .more],
            editorialPreferences: ["editorial:specialist": .more]
        )
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(FeedRecipeDefinition.self, from: data)
        XCTAssertEqual(decoded.languages, recipe.languages)
        XCTAssertEqual(decoded.discoveryLevel, recipe.discoveryLevel)
        XCTAssertEqual(decoded.topicPreferences, recipe.topicPreferences)
    }
}
```

- [ ] **Step 3: Run tests, verify they pass**

```bash
xcodebuild test -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:feedmineTests/FeedRecipeDefinitionTests 2>&1 | tail -20
```

Expected: All 8 tests pass.

- [ ] **Step 4: Add `recipe` field to CuratedFeed**

In `feedmine/Models/CuratedFeed.swift`, modify the struct:

```swift
struct CuratedFeed: Identifiable, Sendable, Hashable {
    let id: Int64
    let name: String
    let definition: CuratedProfileDefinition
    let recipe: FeedRecipeDefinition?       // ← ADD
    let createdAt: Date
    let updatedAt: Date
}
```

- [ ] **Step 5: Add `recipe_json` column to CuratedFeedStore**

In `feedmine/Services/UserStateStore.swift`, modify `CuratedFeedStore`:

- Add `recipe_json TEXT` to the schema creation (find where `curated_feed` table is created in UserStateStore migrations)
- Update `create(name:definition:)` → `create(name:definition:recipe:)`
- Update `update(id:name:definition:)` → `update(id:name:definition:recipe:)`
- Update `feed(from:)` to decode `recipe_json`

```swift
// Migration: add recipe_json column
// In the migration block where curated_feed is created, add:
//   recipe_json TEXT

@discardableResult
func create(
    name: String,
    definition: CuratedProfileDefinition,
    recipe: FeedRecipeDefinition? = nil
) async throws -> Int64 {
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanName.isEmpty else { throw CuratedFeedError.emptyName }
    guard !definition.languages.isEmpty else { throw CuratedFeedError.emptyLanguages }
    let data = try JSONEncoder().encode(definition)
    guard let json = String(data: data, encoding: .utf8) else {
        throw CuratedFeedError.invalidDefinition
    }
    let recipeJSON: String?
    if let recipe {
        let recipeData = try JSONEncoder().encode(recipe)
        recipeJSON = String(data: recipeData, encoding: .utf8)
    } else {
        recipeJSON = nil
    }
    return try await db.write { db in
        let order = try Int.fetchOne(
            db,
            sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM curated_feed"
        ) ?? 0
        let now = Int(Date().timeIntervalSince1970)
        try db.execute(sql: """
            INSERT INTO curated_feed
                (name, definition_json, recipe_json, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [cleanName, json, recipeJSON, order, now, now])
        return db.lastInsertedRowID
    }
}

func update(
    id: Int64,
    name: String,
    definition: CuratedProfileDefinition,
    recipe: FeedRecipeDefinition? = nil
) async throws {
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanName.isEmpty else { throw CuratedFeedError.emptyName }
    guard !definition.languages.isEmpty else { throw CuratedFeedError.emptyLanguages }
    let data = try JSONEncoder().encode(definition)
    guard let json = String(data: data, encoding: .utf8) else {
        throw CuratedFeedError.invalidDefinition
    }
    let recipeJSON: String?
    if let recipe {
        let recipeData = try JSONEncoder().encode(recipe)
        recipeJSON = String(data: recipeData, encoding: .utf8)
    } else {
        recipeJSON = nil
    }
    try await db.write { db in
        try db.execute(sql: """
            UPDATE curated_feed
            SET name = ?, definition_json = ?, recipe_json = ?, updated_at = ?
            WHERE id = ?
            """, arguments: [
                cleanName, json, recipeJSON,
                Int(Date().timeIntervalSince1970), id,
            ])
    }
}

nonisolated private static func feed(from row: Row) -> CuratedFeed? {
    let json: String = row["definition_json"]
    guard let data = json.data(using: .utf8),
          let definition = try? JSONDecoder().decode(
            CuratedProfileDefinition.self, from: data
          ) else { return nil }
    let recipe: FeedRecipeDefinition?
    if let recipeStr: String = row["recipe_json"],
       let recipeData = recipeStr.data(using: .utf8) {
        recipe = try? JSONDecoder().decode(FeedRecipeDefinition.self, from: recipeData)
    } else {
        recipe = nil
    }
    let createdAt: Int = row["created_at"]
    let updatedAt: Int = row["updated_at"]
    return CuratedFeed(
        id: row["id"],
        name: row["name"],
        definition: definition,
        recipe: recipe,
        createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
        updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
    )
}
```

- [ ] **Step 6: Update all call sites**

Find all callers of `CuratedFeedStore.create` and `CuratedFeedStore.update`, update signatures. Key locations:
- `FeedStore.createCuratedFeed(name:definition:)` → add `recipe:` parameter
- `FeedStore.updateCuratedFeed(id:name:definition:)` → add `recipe:` parameter
- `FeedLoader.createCuratedFeed(name:definition:)` → add `recipe:` parameter
- `FeedLoader.updateCuratedFeed(id:name:definition:)` → add `recipe:` parameter

- [ ] **Step 7: Add database migration for existing curated_feed table**

Find the migration chain in `UserStateStore.swift`. Add a migration that runs `ALTER TABLE curated_feed ADD COLUMN recipe_json TEXT` if the column doesn't exist. Use a safe migration pattern:

```swift
// In the appropriate migration block:
try db.execute(sql: """
    ALTER TABLE curated_feed ADD COLUMN recipe_json TEXT
    """)
// Wrap in do/catch — ignore "duplicate column" error if migration already ran
```

- [ ] **Step 8: Run full test suite to verify no regressions**

```bash
xcodebuild test -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -30
```

- [ ] **Step 9: Commit**

```bash
git add feedmine/Models/FeedRecipeDefinition.swift \
        feedmine/Models/CuratedFeed.swift \
        feedmine/Services/UserStateStore.swift \
        feedmine/Services/FeedStore.swift \
        feedmine/Services/FeedLoader.swift \
        feedmineTests/FeedRecipeDefinitionTests.swift
git commit -m "feat: add FeedRecipeDefinition model with persistence

- PreferenceLevel enum: less/neutral/more with profileWeight mapping
- FeedRecipeDefinition: languages, discovery, topic/editorial prefs, media types
- CuratedFeed gains optional recipe field
- CuratedFeedStore adds recipe_json column with migration
- Create/update methods accept optional recipe parameter
- Round-trip JSON coding + 8 model tests

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: FeedRecipeResolver — Merge Recipe + Evidence

**Files:**
- Create: `feedmine/Services/FeedRecipeResolver.swift`
- Create: `feedmineTests/FeedRecipeResolverTests.swift`

**Interfaces:**
- Consumes: `FeedRecipeDefinition`, `CuratedProfileDefinition`, `CuratedPreferenceEngine.sourceMultipliers`
- Produces: `FeedRecipeResolver.effectiveProfile(recipe:evidence:) -> CuratedProfileDefinition`

- [ ] **Step 1: Write the failing test**

Create `feedmineTests/FeedRecipeResolverTests.swift`:

```swift
import XCTest
@testable import feedmine

final class FeedRecipeResolverTests: XCTestCase {
    func testRecipeWeightsBecomeProfileBaseline() {
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        recipe.topicPreferences = ["topic:technology-science": .more]

        let evidence = CuratedProfileDefinition(languages: ["en"])
        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        XCTAssertEqual(
            effective.weight(for: "topic:technology-science"),
            1.5,
            "Recipe 'more' should set weight to +1.5"
        )
    }

    func testEvidenceLayersOnTopOfRecipe() {
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        recipe.topicPreferences = ["topic:technology-science": .more]

        var evidence = CuratedProfileDefinition(languages: ["en"])
        evidence.weights["topic:technology-science"] = 0.5
        evidence.evidenceCounts["topic:technology-science"] = 2

        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        // Recipe baseline +1.5 + evidence +0.5 = +2.0, clamped to 3.0
        XCTAssertEqual(effective.weight(for: "topic:technology-science"), 2.0)
    }

    func testWeightClampedToRange() {
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        recipe.topicPreferences = ["topic:technology-science": .more]

        var evidence = CuratedProfileDefinition(languages: ["en"])
        evidence.weights["topic:technology-science"] = 2.0

        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        // +1.5 + 2.0 = 3.5, clamped to 3.0
        XCTAssertEqual(effective.weight(for: "topic:technology-science"), 3.0)
    }

    func testDiscoveryLevelFromRecipeWhenNoEvidence() {
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        recipe.discoveryLevel = 0.8

        let evidence = CuratedProfileDefinition(languages: ["en"])
        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        XCTAssertEqual(effective.discoveryLevel, 0.8)
    }

    func testLearningEnabledFromRecipe() {
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        recipe.adjustFromOpens = false

        let evidence = CuratedProfileDefinition(languages: ["en"])
        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        XCTAssertFalse(effective.learningEnabled)
    }

    func testMissingRecipeProducesEvidenceOnlyProfile() {
        let evidence = CuratedProfileDefinition(
            languages: ["en"],
            weights: ["topic:technology-science": 1.0],
            discoveryLevel: 0.6,
            learningEnabled: true
        )

        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: nil,
            evidence: evidence
        )

        XCTAssertEqual(effective.weight(for: "topic:technology-science"), 1.0)
        XCTAssertEqual(effective.discoveryLevel, 0.6)
        XCTAssertTrue(effective.learningEnabled)
    }

    func testEditorialPreferencesMapToFeatureKeys() {
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        recipe.editorialPreferences = [
            "editorial:reference": .more,
            "editorial:distinctive": .less,
        ]

        let evidence = CuratedProfileDefinition(languages: ["en"])
        let effective = FeedRecipeResolver.effectiveProfile(
            recipe: recipe,
            evidence: evidence
        )

        XCTAssertEqual(effective.weight(for: "editorial:reference"), 1.5)
        XCTAssertEqual(effective.weight(for: "editorial:distinctive"), -1.5)
        XCTAssertEqual(effective.weight(for: "editorial:specialist"), 0)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
xcodebuild test -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:feedmineTests/FeedRecipeResolverTests 2>&1 | tail -20
```

Expected: Compilation error — `FeedRecipeResolver` not found.

- [ ] **Step 3: Implement FeedRecipeResolver**

Create `feedmine/Services/FeedRecipeResolver.swift`:

```swift
import Foundation

enum FeedRecipeResolver {
    /// Combine an explicit recipe with learned evidence into the effective
    /// profile used for feed ranking.
    ///
    /// Recipe weights are the baseline. Evidence weights are additive on top,
    /// bounded to [-3, +3]. Recipe discovery and learning settings take
    /// precedence over evidence defaults.
    static func effectiveProfile(
        recipe: FeedRecipeDefinition?,
        evidence: CuratedProfileDefinition
    ) -> CuratedProfileDefinition {
        guard let recipe else {
            return evidence
        }

        var weights: [String: Double] = [:]

        // Start with recipe baselines
        for (topicKey, level) in recipe.topicPreferences {
            weights[topicKey] = level.profileWeight
        }
        for (editorialKey, level) in recipe.editorialPreferences {
            weights[editorialKey] = level.profileWeight
        }

        // Layer evidence on top (additive)
        for (key, evidenceWeight) in evidence.weights {
            let baseline = weights[key, default: 0]
            weights[key] = min(3, max(-3, baseline + evidenceWeight))
        }

        // Transfer evidence counts from learned evidence (not from recipe)
        let evidenceCounts = evidence.evidenceCounts

        return CuratedProfileDefinition(
            languages: recipe.languages,
            weights: weights,
            evidenceCounts: evidenceCounts,
            discoveryLevel: recipe.discoveryLevel,
            learningEnabled: recipe.adjustFromOpens,
            evidence: evidence.evidence,
            modelVersion: CuratedProfileDefinition.currentModelVersion
        )
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
xcodebuild test -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:feedmineTests/FeedRecipeResolverTests 2>&1 | tail -20
```

Expected: All 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add feedmine/Services/FeedRecipeResolver.swift \
        feedmineTests/FeedRecipeResolverTests.swift
git commit -m "feat: add FeedRecipeResolver — merge recipe + evidence

Recipe weights serve as baseline; evidence weights are layered additively
on top, clamped to [-3, +3]. Recipe discovery and learning settings take
precedence. Nil recipe passes evidence through unchanged.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Extract LanguageSelectionControl

**Files:**
- Create: `feedmine/Views/Onboarding/LanguageSelectionControl.swift`
- Modify: `feedmine/Views/Onboarding/LanguageScene.swift` (wrap the new control)

**Interfaces:**
- Consumes: `FeedLoader.LanguageInfo` (existing)
- Produces: `LanguageSelectionControl` — `@Binding var selectedLanguages: Set<String>`, `availableLanguages: [FeedLoader.LanguageInfo]`, `accent: Color`, minimum 1 language enforced

- [ ] **Step 1: Create LanguageSelectionControl**

Create `feedmine/Views/Onboarding/LanguageSelectionControl.swift`:

```swift
import SwiftUI

/// Reusable language picker — chips for selected languages + expandable
/// search grid. Enforces minimum 1 language.
struct LanguageSelectionControl: View {
    @Binding var selectedLanguages: Set<String>
    @State private var languageSearch = ""
    @State private var isExpanded = false

    let availableLanguages: [FeedLoader.LanguageInfo]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Selected language chips
            if !selectedLanguages.isEmpty {
                FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(Array(selectedLanguages).sorted(), id: \.self) { code in
                        languageChip(code)
                    }
                }
            }

            // Add another language
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add another language")
                }
                .font(.subheadline)
                .foregroundStyle(accent)
            }
            .accessibilityLabel("Add another language")

            if isExpanded {
                searchAndPicker
            }
        }
        .onChange(of: selectedLanguages) { _, newValue in
            // Enforce minimum 1 language — revert to device language
            if newValue.isEmpty {
                let deviceCode = Locale.current.language.languageCode?
                    .identifier ?? "en"
                selectedLanguages = [deviceCode]
            }
        }
    }

    private func languageChip(_ code: String) -> some View {
        let name = availableLanguages
            .first(where: { $0.code == code })?.name ?? code
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                _ = selectedLanguages.remove(code)
            }
        } label: {
            HStack(spacing: 4) {
                Text(name)
                    .font(.subheadline)
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(accent.opacity(0.15))
            }
            .overlay {
                Capsule()
                    .strokeBorder(accent.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(name)")
        .accessibilityHint("Removes this language from your feed")
    }

    private var filteredOptions: [FeedLoader.LanguageInfo] {
        let query = languageSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return availableLanguages }
        return availableLanguages.filter {
            $0.name.localizedCaseInsensitiveContains(query)
            || $0.code.localizedCaseInsensitiveContains(query)
        }
    }

    private var searchAndPicker: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find a language", text: $languageSearch)
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.thinMaterial)
            }
            .transition(.opacity.combined(with: .move(edge: .top)))

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: 10)],
                spacing: 10
            ) {
                ForEach(filteredOptions) { language in
                    languageOptionButton(language)
                }
            }
            .transition(.opacity)
        }
    }

    private func languageOptionButton(_ language: FeedLoader.LanguageInfo) -> some View {
        let isSelected = selectedLanguages.contains(language.code)
        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                if isSelected {
                    _ = selectedLanguages.remove(language.code)
                } else {
                    selectedLanguages.insert(language.code)
                }
                languageSearch = ""
            }
        } label: {
            HStack(spacing: 6) {
                Text(language.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? accent.opacity(0.18) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? accent.opacity(0.4) : Color.secondary.opacity(0.15)
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isSelected
            ? "Double-tap to remove this language"
            : "Double-tap to add this language")
    }
}
```

**Note:** `FlowLayout` already exists in `PreferenceSummaryChips.swift`. If it's `private`, extract it to a shared utility or reference it as `PreferenceSummaryChips.FlowLayout` if accessible.

- [ ] **Step 2: Update LanguageScene to use LanguageSelectionControl**

In `feedmine/Views/Onboarding/LanguageScene.swift`, replace the inline language selection with `LanguageSelectionControl`, keeping the scene's headline, intro text, and Continue button:

```swift
// Replace the existing language grid + selected list with:
LanguageSelectionControl(
    selectedLanguages: $selectedLanguages,
    availableLanguages: availableLanguages,
    accent: accent
)
```

- [ ] **Step 3: Build and verify LanguageScene still works**

```bash
xcodebuild build -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add feedmine/Views/Onboarding/LanguageSelectionControl.swift \
        feedmine/Views/Onboarding/LanguageScene.swift
git commit -m "feat: extract LanguageSelectionControl from LanguageScene

Reusable component with selected language chips, expandable search grid,
and minimum-1-language enforcement. LanguageScene now wraps this control.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Composer Controls

**Files:**
- Create: `feedmine/Views/Onboarding/DiscoverySlider.swift`
- Create: `feedmine/Views/Onboarding/EditorialBalanceControl.swift`
- Create: `feedmine/Views/Onboarding/TopicPreferenceRow.swift`
- Create: `feedmine/Views/Onboarding/MediaTypeToggles.swift`

**Interfaces:**
- Consumes: `CircadianEngine.accent` (via environment or parameter)
- Produces:
  - `DiscoverySlider(value: Binding<Double>, accent: Color)`
  - `EditorialBalanceControl(preferences: Binding<[String: PreferenceLevel]>, accent: Color)`
  - `TopicPreferenceRow(topicKey: String, topicName: String, level: Binding<PreferenceLevel>, accent: Color)`
  - `MediaTypeToggles(selected: Binding<Set<MediaType>>, accent: Color)`

- [ ] **Step 1: Create DiscoverySlider**

Create `feedmine/Views/Onboarding/DiscoverySlider.swift`:

```swift
import SwiftUI

/// Single continuous slider for discovery level.
/// Maps 0.0 (Focused) … 1.0 (Exploratory). No percentage display.
struct DiscoverySlider: View {
    @Binding var value: Double
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Discovery")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Slider(value: $value, in: 0...1) {
                Text("Discovery level")
            }
            .tint(accent)
            .accessibilityValue(
                "\(Int(value * 100)) percent toward exploratory"
            )

            HStack {
                Text("Focused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Exploratory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Discovery")
        .accessibilityHint("Slide left for focused, right for exploratory")
    }
}
```

- [ ] **Step 2: Create EditorialBalanceControl**

Create `feedmine/Views/Onboarding/EditorialBalanceControl.swift`:

```swift
import SwiftUI

/// Three-row segmented control for source balance.
/// Less / Balanced / More per editorial style.
struct EditorialBalanceControl: View {
    @Binding var preferences: [String: PreferenceLevel]
    let accent: Color

    private let rows: [(key: String, label: String)] = [
        ("editorial:reference", String(localized: "Established references")),
        ("editorial:specialist", String(localized: "Specialist sources")),
        ("editorial:distinctive", String(localized: "Independent voices")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Source balance")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            ForEach(Array(rows.enumerated()), id: \.element.key) { index, row in
                balanceRow(key: row.key, label: row.label)
                if index < rows.count - 1 {
                    Divider()
                        .opacity(0.3)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source balance")
    }

    private func balanceRow(key: String, label: String) -> some View {
        let current = Binding<PreferenceLevel>(
            get: { preferences[key, default: .neutral] },
            set: { preferences[key] = $0 }
        )

        return HStack(spacing: 0) {
            Text(label)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(PreferenceLevel.allCases, id: \.self) { level in
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            current.wrappedValue = level
                        }
                    } label: {
                        Text(level.balanceLabel)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background {
                                if current.wrappedValue == level {
                                    Capsule()
                                        .fill(accent)
                                }
                            }
                            .foregroundStyle(
                                current.wrappedValue == level
                                    ? .white
                                    : .secondary
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(label): \(level.balanceLabel)")
                    .accessibilityAddTraits(
                        current.wrappedValue == level ? .isSelected : []
                    )
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityValue(current.wrappedValue.balanceLabel)
    }
}
```

- [ ] **Step 3: Create TopicPreferenceRow**

Create `feedmine/Views/Onboarding/TopicPreferenceRow.swift`:

```swift
import SwiftUI

/// Single topic row. Tapping cycles More → Normal → Less → Normal.
/// State displayed as a trailing chip (filled = More, plain = Normal,
/// outlined = Less). Does NOT use card category stripe geometry.
struct TopicPreferenceRow: View {
    let topicKey: String
    let topicName: String
    @Binding var level: PreferenceLevel
    let accent: Color

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                level = level.next()
            }
        } label: {
            HStack {
                Text(topicName)
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()

                stateChip
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(topicName): \(level.topicLabel)")
        .accessibilityHint("Double-tap to cycle through Less, Normal, and More")
    }

    @ViewBuilder
    private var stateChip: some View {
        switch level {
        case .neutral:
            Text(level.topicLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        case .more:
            Text(level.topicLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    Capsule()
                        .fill(accent)
                }
        case .less:
            Text(level.topicLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    Capsule()
                        .strokeBorder(.secondary.opacity(0.4))
                }
        }
    }
}
```

- [ ] **Step 4: Create MediaTypeToggles**

Create `feedmine/Views/Onboarding/MediaTypeToggles.swift`:

```swift
import SwiftUI

/// Simple on/off toggles for content types.
struct MediaTypeToggles: View {
    @Binding var selected: Set<MediaType>
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Content types")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(MediaType.allCases, id: \.self) { type in
                Toggle(isOn: Binding(
                    get: { selected.contains(type) },
                    set: { isOn in
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                            if isOn {
                                selected.insert(type)
                            } else {
                                selected.remove(type)
                            }
                        }
                    }
                )) {
                    Text(type.displayName)
                        .font(.body)
                }
                .tint(accent)
                .accessibilityLabel("Include \(type.displayName)")
            }
        }
    }
}
```

- [ ] **Step 5: Build and verify**

```bash
xcodebuild build -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add feedmine/Views/Onboarding/DiscoverySlider.swift \
        feedmine/Views/Onboarding/EditorialBalanceControl.swift \
        feedmine/Views/Onboarding/TopicPreferenceRow.swift \
        feedmine/Views/Onboarding/MediaTypeToggles.swift
git commit -m "feat: add Composer controls — discovery, balance, topics, media

DiscoverySlider: focused/exploratory, no percentage.
EditorialBalanceControl: Less/Balanced/More per editorial style.
TopicPreferenceRow: cycle-tap More/Normal/Less with chip states.
MediaTypeToggles: Article/Podcast/Video on/off.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: Async Preview Pipeline

**Files:**
- Modify: `feedmine/Services/FeedLoader.swift:948-969` (add `previewCuratedCards`)
- Modify: `feedmine/Views/CollectionManagementView.swift` (reference `resolvePresentation` pattern)

**Interfaces:**
- Consumes: `FeedRecipeDefinition`, `FeedRecipeResolver`, `FeedCardPresentation`, existing `ResolvedCardMedia` resolution
- Produces: `FeedLoader.previewCuratedCards(recipe:evidence:limit:) async -> [FeedCardPresentation]`

- [ ] **Step 1: Add previewCuratedCards to FeedLoader**

In `feedmine/Services/FeedLoader.swift`, add after the existing `previewCuratedFeed`:

```swift
/// Returns fully prepared feed cards for the Composer preview zone.
/// Uses the recipe+evidence merge, scores via sourceMultipliers,
/// and resolves card presentations (image + layout) before returning.
/// Cancellable — check Task.isCancelled between stages.
func previewCuratedCards(
    recipe: FeedRecipeDefinition?,
    evidence: CuratedProfileDefinition,
    limit: Int = 3
) async -> [FeedCardPresentation] {
    let effective = FeedRecipeResolver.effectiveProfile(
        recipe: recipe,
        evidence: evidence
    )

    let sources = store.registry.sources
    let multipliers = CuratedPreferenceEngine.sourceMultipliers(
        sources: sources,
        profile: effective
    )

    let candidates: [FeedItem]
    if multipliers.isEmpty {
        candidates = Array(items.prefix(limit * 2))
    } else {
        candidates = items
            .map { item -> (FeedItem, Double) in
                (item, multipliers[item.sourceURL] ?? 1.0)
            }
            .filter { $0.1 > 1.0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit * 2)
            .map { $0.0 }
    }

    guard !candidates.isEmpty else { return [] }
    guard !Task.isCancelled else { return [] }

    // Resolve presentations in parallel
    return await withTaskGroup(
        of: (Int, FeedCardPresentation?).self
    ) { group in
        for (index, item) in candidates.enumerated() {
            group.addTask {
                guard !Task.isCancelled else { return (index, nil) }
                let presentation = await Self.resolvePresentation(for: item)
                return (index, presentation)
            }
        }

        var results: [(Int, FeedCardPresentation)] = []
        for await (index, presentation) in group {
            if let presentation {
                results.append((index, presentation))
            }
        }

        return results
            .sorted { $0.0 < $1.0 }
            .prefix(limit)
            .map { $0.1 }
    }
}

/// Resolve a single card presentation — mirrors CollectionManagementView pattern.
private nonisolated static func resolvePresentation(
    for item: FeedItem
) async -> FeedCardPresentation {
    let imageURL = item.imageURL.flatMap(URL.init(string:))
    let articleURL = URL(string: item.url)

    let media: ResolvedCardMedia
    if let resolvedImage = await ImageLoader.resolveImage(
        url: imageURL,
        articleURL: articleURL
    ) {
        media = .image(resolvedImage)
    } else if imageURL != nil || articleURL != nil {
        media = .placeholder
    } else {
        media = .none
    }

    let layout: FeedCardLayout
    switch media {
    case .image: layout = .hero
    case .placeholder: layout = .hero
    case .none: layout = .textOnly
    }

    return FeedCardPresentation(
        item: item,
        media: media,
        layout: layout,
        isRead: false,
        isBookmarked: false
    )
}
```

**Note:** Uses `ImageLoader.resolveImage(url:articleURL:)` — the same API used by `CollectionManagementView.resolvePresentation(for:)`. The key contract: the returned `FeedCardPresentation` has resolved media ready for display. Prefer `isRead: false, isBookmarked: false` for preview items (reading state not relevant in composer).

- [ ] **Step 2: Build and verify**

```bash
xcodebuild build -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add feedmine/Services/FeedLoader.swift
git commit -m "feat: add previewCuratedCards async pipeline

Returns [FeedCardPresentation] with resolved media, scored via
sourceMultipliers with recipe+evidence merge. Cancellable via
Task.isCancelled. Parallel presentation resolution.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: FeedComposerScene

**Files:**
- Create: `feedmine/Views/Onboarding/FeedComposerScene.swift`

**Interfaces:**
- Consumes: `FeedLoader`, `CircadianEngine`, `FeedRecipeDefinition`, `FeedCardPresentation`, all control components from Task 4, `LanguageSelectionControl` from Task 3
- Produces: `FeedComposerScene` — `@Binding var recipe: FeedRecipeDefinition`, `onSave: () -> Void`, `onStartBroad: () -> Void`, `onReset: () -> Void`

- [ ] **Step 1: Create FeedComposerScene**

Create `feedmine/Views/Onboarding/FeedComposerScene.swift`:

```swift
import SwiftUI

/// The main Composer screen — preview cards above, editorial sheet below.
/// Controls update instantly; preview recomposition is coalesced at 100ms.
struct FeedComposerScene: View {
    @Environment(FeedLoader.self) private var loader
    @Environment(CircadianEngine.self) private var engine

    @Binding var recipe: FeedRecipeDefinition
    let onSave: () -> Void
    let onStartBroad: () -> Void
    let onReset: () -> Void

    @State private var previewCards: [FeedCardPresentation] = []
    @State private var previewTask: Task<Void, Never>?
    @State private var previewState: PreviewState = .preparing
    @State private var recipeVersion = 0

    enum PreviewState {
        case preparing
        case ready
        case noResults
        case error(String)
    }

    var body: some View {
        ZStack {
            engine.pageBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Preview zone
                previewZone
                    .frame(maxHeight: .infinity)

                // Editorial sheet
                editorialSheet
            }
        }
        .onAppear { requestPreview() }
        .onChange(of: recipeVersion) { _, _ in
            schedulePreviewUpdate()
        }
        .onDisappear {
            previewTask?.cancel()
        }
    }

    // MARK: - Preview Zone

    private var previewZone: some View {
        VStack(spacing: 8) {
            switch previewState {
            case .preparing:
                previewPlaceholders
            case .ready:
                previewCardsView
            case .noResults:
                noResultsView
            case .error(let message):
                errorView(message)
            }
        }
        .padding(.top, 12)
    }

    private var previewCardsView: some View {
        VStack(spacing: 8) {
            ForEach(previewCards) { card in
                FeedItemCardView(
                    item: card.item,
                    presentation: card,
                    isRead: card.isRead,
                    isBookmarked: card.isBookmarked
                )
                .padding(.horizontal, 16)
            }

            // Peek hint
            if previewCards.count >= 2 {
                Text("Scroll for more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
    }

    private var previewPlaceholders: some View {
        VStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 14)
                    .fill(.thinMaterial)
                    .frame(height: 120)
                    .padding(.horizontal, 16)
            }
        }
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("This combination is very specific.")
                .font(.body)
                .multilineTextAlignment(.center)
            Text("Try adjusting one of the controls.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
            Button("Retry") { requestPreview() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Editorial Sheet

    private var editorialSheet: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shape your first feed")
                        .font(.title.weight(.bold))
                        .fontDesign(.serif)

                    Text("Optional. Change anything later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Languages
                sectionLabel("Languages")
                LanguageSelectionControl(
                    selectedLanguages: Binding(
                        get: { Set(recipe.languages) },
                        set: { langs in
                            recipe.languages = Array(langs).sorted()
                            bumpRecipe()
                        }
                    ),
                    availableLanguages: loader.availableLanguages,
                    accent: engine.accent
                )

                Divider()

                // Discovery
                DiscoverySlider(
                    value: Binding(
                        get: { recipe.discoveryLevel },
                        set: { val in
                            recipe.discoveryLevel = val
                            bumpRecipe()
                        }
                    ),
                    accent: engine.accent
                )

                Divider()

                // Source balance
                EditorialBalanceControl(
                    preferences: Binding(
                        get: { recipe.editorialPreferences },
                        set: { prefs in
                            recipe.editorialPreferences = prefs
                            bumpRecipe()
                        }
                    ),
                    accent: engine.accent
                )

                Divider()

                // Topics
                sectionLabel("Topics")
                ForEach(CuratedTopic.allCases) { topic in
                    TopicPreferenceRow(
                        topicKey: topic.featureKey,
                        topicName: topic.displayName,
                        level: Binding(
                            get: {
                                recipe.topicPreferences[topic.featureKey, default: .neutral]
                            },
                            set: { level in
                                if level == .neutral {
                                    recipe.topicPreferences.removeValue(forKey: topic.featureKey)
                                } else {
                                    recipe.topicPreferences[topic.featureKey] = level
                                }
                                bumpRecipe()
                            }
                        ),
                        accent: engine.accent
                    )
                    Divider().opacity(0.3)
                }

                Divider()

                // Media types
                MediaTypeToggles(
                    selected: Binding(
                        get: { recipe.mediaTypes },
                        set: { types in
                            recipe.mediaTypes = types
                            bumpRecipe()
                        }
                    ),
                    accent: engine.accent
                )

                // Open my feed button — always visible
                Button(action: onSave) {
                    Text("Open my feed")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .tint(engine.accent)
                .padding(.top, 8)
            }
            .padding(20)
        }
        .background(.regularMaterial)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 20,
                topTrailingRadius: 20
            )
        )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: - Preview Scheduling

    /// Increment the recipe version to trigger a coalesced preview update.
    private func bumpRecipe() {
        recipeVersion += 1
    }

    /// Coalesce at 100ms — cancel previous task, schedule new one.
    private func schedulePreviewUpdate() {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            requestPreview()
        }
    }

    private func requestPreview() {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            previewState = .preparing

            let evidence = CuratedProfileDefinition(languages: recipe.languages)
            let cards = await loader.previewCuratedCards(
                recipe: recipe,
                evidence: evidence,
                limit: 3
            )

            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.25)) {
                if cards.isEmpty {
                    previewCards = []
                    previewState = .noResults
                } else {
                    previewCards = cards
                    previewState = .ready
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild build -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED. Address any compilation errors.

- [ ] **Step 3: Commit**

```bash
git add feedmine/Views/Onboarding/FeedComposerScene.swift
git commit -m "feat: add FeedComposerScene with coalesced preview pipeline

Preview zone shows 2-3 FeedCardPresentation cards with preparing/ready/
noResults/error states. Editorial sheet uses .regularMaterial with
circadian-tinted background. Controls bump recipeVersion → 100ms
coalesced preview update. Previous task cancelled on new request.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: WelcomeScene Redesign

**Files:**
- Modify: `feedmine/Views/Onboarding/WelcomeScene.swift`

**Interfaces:**
- Consumes: `CircadianEngine.accent` (via parameter), `FeedLoader.items` (for card cascade)
- Produces: `WelcomeScene(accent:onShape:onStartBroad:)` — updated headline, CTAs, card cascade

- [ ] **Step 1: Rewrite WelcomeScene**

Modify `feedmine/Views/Onboarding/WelcomeScene.swift`:

```swift
import SwiftUI

/// Opening screen — deep navy brand opening with cascading real feed cards
/// behind light glass. "The open web, arranged by you."
struct WelcomeScene: View {
    let accent: Color
    let onShape: () -> Void
    let onStartBroad: () -> Void

    @Environment(FeedLoader.self) private var loader
    @State private var appeared = false

    private let deepNavy = Color(hex: "#050A18")

    var body: some View {
        ZStack {
            deepNavy.ignoresSafeArea()

            // Cascading real feed cards
            cardCascade

            // Foreground content
            VStack(spacing: 0) {
                Spacer()

                // Wordmark — use existing Wawasoft "W" logo + amber-coral gradient
                // If the real wordmark is a view/component, replace this placeholder:
                Text("FeedMine")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .opacity(appeared ? 1 : 0)

                // Amber rule
                Rectangle()
                    .fill(accent)
                    .frame(width: 40, height: 1)
                    .padding(.top, 12)
                    .opacity(appeared ? 1 : 0)

                // Headline
                Text(headline)
                    .font(.largeTitle.weight(.bold))
                    .fontDesign(.serif)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)

                // Body
                Text("FeedMine brings together independent publications, podcasts, video channels and public sources. Set the mix yourself — or start broad and explore.")
                    .font(.body)
                    .foregroundStyle(Color(hex: "#8899AA"))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)

                // Trust signals
                HStack(spacing: 12) {
                    trustBadge("On-device")
                    Circle().fill(Color(hex: "#8899AA")).frame(width: 2, height: 2)
                    trustBadge("No account")
                    Circle().fill(Color(hex: "#8899AA")).frame(width: 2, height: 2)
                    trustBadge("Fully editable")
                }
                .font(.caption)
                .foregroundStyle(Color(hex: "#8899AA"))
                .padding(.top, 20)
                .opacity(appeared ? 1 : 0)

                Spacer()

                // CTAs
                VStack(spacing: 14) {
                    Button(action: onShape) {
                        Text("Shape my feed")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .tint(accent)
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                    .accessibilityIdentifier("welcome-shape")

                    Button("Start broad") {
                        onStartBroad()
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#8899AA"))
                    .opacity(appeared ? 1 : 0)
                    .accessibilityIdentifier("welcome-broad")
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
        }
    }

    private var headline: AttributedString {
        var text = AttributedString("The open web,\narranged by you.")
        if let range = text.range(of: "you") {
            text[range].foregroundColor = UIColor(accent)
        }
        return text
    }

    /// Real feed cards behind light glass
    private var cardCascade: some View {
        let sampleItems = Array(loader.items.prefix(6))
        return ZStack {
            if sampleItems.isEmpty {
                // Fallback: abstract cards
                ForEach(0..<6, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.04))
                        .frame(
                            width: CGFloat(140 + i * 8),
                            height: CGFloat(100 + i * 6)
                        )
                        .offset(
                            x: CGFloat(-80 + i * 40),
                            y: CGFloat(-180 + i * 50)
                        )
                        .opacity(appeared ? 0.4 - Double(i) * 0.04 : 0)
                        .animation(
                            .easeInOut(duration: 1.0).delay(Double(i) * 0.12),
                            value: appeared
                        )
                }
            } else {
                ForEach(Array(sampleItems.enumerated()), id: \.element.id) { i, item in
                    FeedItemCardView(
                        item: item,
                        isRead: false,
                        isBookmarked: false
                    )
                    .frame(width: 160, height: 110)
                    .scaleEffect(0.85)
                    .offset(
                        x: CGFloat(-90 + i * 45),
                        y: CGFloat(-190 + i * 55)
                    )
                    .opacity(appeared ? 0.45 : 0)
                    .animation(
                        .easeInOut(duration: 1.0).delay(Double(i) * 0.12),
                        value: appeared
                    )
                }
            }
        }
        .overlay(.ultraThinMaterial.opacity(0.88))
        .allowsHitTesting(false)
    }

    private func trustBadge(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.shield.fill")
                .font(.caption2)
            Text(text)
        }
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild build -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add feedmine/Views/Onboarding/WelcomeScene.swift
git commit -m "feat: redesign WelcomeScene — deep navy brand, new copy, real cards

Headline: 'The open web, arranged by you.' with 'you' in accent.
CTAs: 'Shape my feed' (primary) / 'Start broad' (secondary).
Card cascade: real FeedItemCardView instances through glass.
Wordmark placeholder + amber rule. Trust badges preserved.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: CuratedOnboardingView Rewrite

**Files:**
- Modify: `feedmine/Views/CuratedOnboardingView.swift` (reduce to 2 stages + FeedComposerScene)
- Modify: `feedmine/Views/OnboardingTipsView.swift` (update callbacks)

**Interfaces:**
- Consumes: `FeedRecipeDefinition`, `FeedComposerScene`, `WelcomeScene`, `FeedLoader`, `CircadianEngine`
- Produces: 2-stage onboarding (`.welcome`, `.composer`), save creates `CuratedFeed` with recipe + definition

- [ ] **Step 1: Rewrite CuratedOnboardingView**

Modify `feedmine/Views/CuratedOnboardingView.swift`. Reduce stages to `.welcome` and `.composer`. Remove: `OnboardingSeed`, `CuratedOnboardingSession`, `candidateTask`, `answerDelayTask`, `answerPulse`, `StoryDuelScene`, `TopicsScene`, `IntentScene`, `FeedRevealScene`, `ConfidenceProgressView`. Preserve: `CuratedProfileControls`, `CuratedBackdrop`, `CuratedPressStyle`, `CuratedOpenHoodGraphic` (these may be used elsewhere).

Key new state:
```swift
@State private var stage: Stage = .welcome
@State private var recipe = FeedRecipeDefinition.neutral(
    languages: [deviceLanguageCode]
)
@State private var isSaving = false
@State private var errorMessage: String?

enum Stage {
    case welcome
    case composer
}
```

Save flow:
```swift
private func save() async {
    isSaving = true
    defer { isSaving = false }

    let name = autoName()
    let evidence = CuratedProfileDefinition(languages: recipe.languages)
    let effectiveProfile = FeedRecipeResolver.effectiveProfile(
        recipe: recipe,
        evidence: evidence
    )

    do {
        let saved = try await loader.createCuratedFeed(
            name: name,
            definition: effectiveProfile,
            recipe: recipe
        )
        loader.setActivePreset(.curatedFeed(
            curatedFeedID: saved.id,
            curatedFeedName: saved.name
        ))
        onSaved(saved)
    } catch {
        errorMessage = error.localizedDescription
    }
}

private func autoName() -> String {
    let moreTopics = recipe.topicPreferences
        .filter { $0.value == .more }
        .compactMap { kv in
            CuratedTopic.allCases.first { $0.featureKey == kv.key }?.displayName
        }
    if moreTopics.count == 1 {
        return moreTopics[0]
    } else if moreTopics.count >= 2 {
        return "\(moreTopics[0]) & \(moreTopics[1])"
    }
    return "My Feed"
}

private var deviceLanguageCode: String {
    Locale.current.language.languageCode?.identifier ?? "en"
}
```

"Start broad" flow saves a neutral recipe immediately and dismisses:
```swift
private func startBroad() {
    recipe = FeedRecipeDefinition.neutral(languages: [deviceLanguageCode])
    Task { await save() }
}
```

- [ ] **Step 2: Update OnboardingTipsView callbacks**

In `feedmine/Views/OnboardingTipsView.swift`, update to match new `CuratedOnboardingView` init signature (changed callback names from `onCancel`/`onStart` to match the new 2-stage design).

- [ ] **Step 3: Build and verify**

```bash
xcodebuild build -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add feedmine/Views/CuratedOnboardingView.swift \
        feedmine/Views/OnboardingTipsView.swift
git commit -m "feat: rewrite CuratedOnboardingView to 2-stage Welcome→Composer

Removes: Intent, Topics, StoryDuel, Review stages, OnboardingSeed,
CuratedOnboardingSession, candidate pool, image warming, answer logic.
Adds: FeedComposerScene integration, auto-name from topic prefs,
neutral recipe Start-broad path, recipe+evidence save flow.
Preserves: CuratedProfileControls, CuratedBackdrop for inspector reuse.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Save + Transition + FeedScreen Integration

**Files:**
- Modify: `feedmine/Views/FeedScreen.swift` (transition from preview to feed)
- Modify: `feedmine/Views/CuratedOnboardingView.swift` (save flow if not done in Task 8)

**Interfaces:**
- Consumes: `FeedLoader.setActivePreset`, saved `CuratedFeed` with recipe
- Produces: Compositional continuity — same recipe, feed loads with the same effective profile

- [ ] **Step 1: Implement compositional continuity in FeedScreen**

When `onboardingDidSaveCuratedFeed` is received, `FeedScreen` already switches to the curated feed preset. Ensure the feed composition uses the same effective profile as the preview:

```swift
// In FeedScreen's notification handler for .onboardingDidSaveCuratedFeed:
// The preset is already set to .curatedFeed(id:name:) by the save flow.
// FeedStore.setPreset triggers a feed recomposition using the same
// sourceMultipliers that the preview used. No additional work needed
// for compositional continuity — the recipe+evidence merge is deterministic.
```

Verify that `FeedStore.setPreset(.curatedFeed(...))` triggers `rebuildPipeline` or equivalent, and that the first composition uses the `sourceMultipliers` from the saved `CuratedProfileDefinition`.

- [ ] **Step 2: Add toast text update**

Update the saved-feed toast to say "Feed ready" instead of any "learning"-related text:

```swift
// In the toast handler where feedName is displayed:
Text("\(feedName) is ready")
```

- [ ] **Step 3: Build and verify**

```bash
xcodebuild build -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add feedmine/Views/FeedScreen.swift
git commit -m "feat: ensure compositional continuity from Composer to Feed

Same recipe → same effective profile → same sourceMultipliers → same
ranking. Toast updated to remove 'learning' language.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: P0 Accessibility + Localization

**Files:**
- Modify: All new views (add accessibility modifiers, localize strings)
- Create: `feedmine/Localizable.xcstrings` entries for new strings

**Context:** All new views from Tasks 3-8 already use `String(localized:)` for user-visible text. This task audits and adds any missing accessibility modifiers and verifies the full accessibility checklist.

- [ ] **Step 1: Audit all new views for accessibility**

For each new/modified view, verify:
- [ ] Dynamic Type: All text uses semantic styles (`.largeTitle`, `.title`, `.body`, `.caption`) — no fixed font sizes
- [ ] VoiceOver: All interactive elements have `.accessibilityLabel`, `.accessibilityHint`, `.accessibilityValue` where state is communicated
- [ ] VoiceOver: Slider announces human-readable value ("65 percent toward exploratory")
- [ ] VoiceOver: Topic rows announce "Science: More" not raw keys
- [ ] Reduce Motion: All animations wrapped in `if !UIAccessibility.isReduceMotionEnabled` or use `withAnimation` which the system handles
- [ ] Reduce Transparency: Test that Welcome glass veil and Composer sheet adapt
- [ ] Differentiate Without Color: All state labels visible as text ("More", "Less", "Balanced")
- [ ] RTL: All layouts use leading/trailing (not left/right), LazyVGrid adapts
- [ ] Touch targets: Minimum 44pt × 44pt — verify topic rows, editorial segments, language chips
- [ ] Keyboard navigation: Tab order follows visual order

- [ ] **Step 2: Add Reduce Motion guards**

In `WelcomeScene`:
```swift
.onAppear {
    if UIAccessibility.isReduceMotionEnabled {
        appeared = true  // instant, no animation
    } else {
        withAnimation(.easeOut(duration: 0.6)) { appeared = true }
    }
}
```

In `FeedComposerScene` — the `.withAnimation` calls in control bindings already respect system settings. Verify the sheet slide-up animation respects Reduce Motion.

- [ ] **Step 3: Add Reduce Transparency support**

In `WelcomeScene`:
```swift
@Environment(\.accessibilityReduceTransparency) private var reduceTransparency

// In cardCascade overlay:
.overlay(reduceTransparency
    ? Color(deepNavy).opacity(0.92)
    : .ultraThinMaterial.opacity(0.88)
)
```

In `FeedComposerScene` editorial sheet:
```swift
@Environment(\.accessibilityReduceTransparency) private var reduceTransparency

.background(reduceTransparency
    ? Color(engine.pageBackground)
    : .regularMaterial
)
```

- [ ] **Step 4: Verify RTL layout**

Test with `.environment(\.layoutDirection, .rightToLeft)` in previews or run the app with an RTL language (Arabic, Hebrew). Verify:
- Welcome headline alignment
- Composer sheet layout
- Editorial balance control row order
- Topic row label alignment
- Language chip layout

- [ ] **Step 5: Add String Catalog entries**

For every `String(localized:)` call in new views, ensure entries exist in the String Catalog. Run:
```bash
xcodebuild -scheme feedmine -exportLocalizations
```
Then verify the generated `.xcloc` includes all new strings.

- [ ] **Step 6: Measure contrast**

Verify text contrast on the Welcome deep navy background:
- White on `#050A18`: 21:1 ✓
- `#8899AA` on `#050A18`: ~6.5:1 (meets AA for large text, close for body)

Verify text contrast on circadian light backgrounds across all 5 palettes. The existing app already meets this — the Composer inherits the same tokens.

- [ ] **Step 7: Build and run audit**

```bash
xcodebuild build -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

Run in simulator with:
- Dynamic Type max size
- VoiceOver enabled
- Reduce Motion enabled
- Reduce Transparency enabled
- RTL language

- [ ] **Step 8: Commit**

```bash
git add feedmine/Views/Onboarding/ \
        feedmine/Views/CuratedOnboardingView.swift \
        feedmine/Views/OnboardingTipsView.swift \
        feedmine/Resources/Localizable.xcstrings
git commit -m "feat: P0 accessibility + localization pass

Reduce Motion: instant cuts, no staggered animations.
Reduce Transparency: solid background fallbacks.
VoiceOver: human-readable labels, values, hints on all controls.
RTL: leading/trailing layout throughout.
Dynamic Type: all semantic styles, no fixed sizes.
Touch targets: verified 44pt minimum.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 11: Integration Tests

**Files:**
- Create: `feedmineTests/FeedComposerPreviewTests.swift`
- Create: `feedmineTests/FeedComposerUITests.swift` (or add to existing UI tests)

- [ ] **Step 1: Write preview pipeline integration test**

Create `feedmineTests/FeedComposerPreviewTests.swift`:

```swift
import XCTest
@testable import feedmine

@MainActor
final class FeedComposerPreviewTests: XCTestCase {
    func testPreviewCuratedCardsReturnsCorrectLimit() async {
        let loader = FeedLoader.shared  // or use test dependency injection
        let recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        let evidence = CuratedProfileDefinition(languages: ["en"])

        let cards = await loader.previewCuratedCards(
            recipe: recipe,
            evidence: evidence,
            limit: 2
        )

        XCTAssertLessThanOrEqual(cards.count, 2)
        for card in cards {
            XCTAssertNotNil(card.item.id)
            // Media should be resolved (image, placeholder, or none)
            switch card.media {
            case .image, .placeholder, .none: break
            }
        }
    }

    func testPreviewIsCancellable() async {
        let loader = FeedLoader.shared
        let recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        let evidence = CuratedProfileDefinition(languages: ["en"])

        let task = Task {
            await loader.previewCuratedCards(
                recipe: recipe,
                evidence: evidence,
                limit: 3
            )
        }
        task.cancel()
        let result = await task.value
        // Should return empty or partial — not crash
        XCTAssertTrue(result.isEmpty || result.count <= 3)
    }

    func testNeutralRecipeProducesCards() async {
        let loader = FeedLoader.shared
        let recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        let evidence = CuratedProfileDefinition(languages: ["en"])

        let cards = await loader.previewCuratedCards(
            recipe: recipe,
            evidence: evidence,
            limit: 3
        )

        // Neutral recipe should produce something (broad feed)
        XCTAssertFalse(cards.isEmpty, "Neutral recipe should return cards")
    }

    func testRestrictiveRecipeMayReturnEmpty() async {
        let loader = FeedLoader.shared
        var recipe = FeedRecipeDefinition.neutral(languages: ["en"])
        // Set all topics to less — should significantly narrow results
        for topic in CuratedTopic.allCases {
            recipe.topicPreferences[topic.featureKey] = .less
        }
        for style in CuratedEditorialStyle.allCases {
            recipe.editorialPreferences[style.featureKey] = .less
        }
        recipe.mediaTypes = []  // will fall back to defaults per init

        let evidence = CuratedProfileDefinition(languages: ["en"])
        let cards = await loader.previewCuratedCards(
            recipe: recipe,
            evidence: evidence,
            limit: 3
        )
        // May be empty — that's valid behavior
        XCTAssertTrue(cards.count <= 3)
    }
}
```

- [ ] **Step 2: Run integration tests**

```bash
xcodebuild test -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:feedmineTests/FeedComposerPreviewTests 2>&1 | tail -20
```

- [ ] **Step 3: Write performance benchmark**

Add to `FeedComposerPreviewTests`:

```swift
func testPreviewPerformance() async throws {
    let loader = FeedLoader.shared
    let recipe = FeedRecipeDefinition.neutral(languages: ["en"])
    let evidence = CuratedProfileDefinition(languages: ["en"])

    let start = CFAbsoluteTimeGetCurrent()
    let cards = await loader.previewCuratedCards(
        recipe: recipe,
        evidence: evidence,
        limit: 3
    )
    let elapsed = CFAbsoluteTimeGetCurrent() - start

    XCTAssertLessThanOrEqual(
        elapsed, 1.5,
        "Preview must complete within 1.5s on test device"
    )
    XCTAssertFalse(cards.isEmpty)
}
```

- [ ] **Step 4: Run performance test**

```bash
xcodebuild test -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:feedmineTests/FeedComposerPreviewTests/testPreviewPerformance 2>&1 | tail -10
```

- [ ] **Step 5: Run full test suite to confirm no regressions**

```bash
xcodebuild test -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add feedmineTests/FeedComposerPreviewTests.swift
git commit -m "test: add Composer preview pipeline integration + perf tests

Tests: limit enforcement, cancellability, neutral recipe produces cards,
restrictive recipe handling, 1.5s performance benchmark.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 12: Final Integration & Cleanup

**Files:**
- Modify: `feedmine/Views/CuratedOnboardingView.swift` (remove dead code paths)
- Modify: `feedmine/feedmineApp.swift` or test config (update launch args if needed)

- [ ] **Step 1: Remove dead code paths**

In `CuratedOnboardingView.swift`, remove any remaining references to old stages that are now dead code. Ensure `CuratedProfileControls` and `CuratedBackdrop` remain accessible (they may be used by `CuratedFeedInspectorView`).

- [ ] **Step 2: Update test launch arguments**

If `-UITestShowOnboarding` launch argument expects the old 6-stage flow, update it for the new 2-stage flow or remove it.

- [ ] **Step 3: Verify StoryDuel code preserved**

Confirm `StoryDuelScene.swift`, `StoryDuelCard.swift`, `ChoiceFeedbackOverlay.swift`, `ConfidenceProgressView.swift`, and the `CuratedPreferenceEngine` comparison methods are still in the project (not deleted — preserved for P2 "Tune with examples").

- [ ] **Step 4: Update any stale doc references**

In `docs/onboarding-redesign.md` and `docs/code-review-onboarding-redesign.md`, add a note at the top:
```markdown
> **Note (2026-08-04):** This document describes the 2026-07-28 redesign (6 stages).
> The current onboarding has been replaced by a 2-stage Welcome → Composer flow.
> See `docs/superpowers/specs/2026-08-04-onboarding-composer-design.md` for the new design.
```

- [ ] **Step 5: Final build and full test run**

```bash
xcodebuild build -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
xcodebuild test -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -30
```

Expected: BUILD SUCCEEDED, all tests pass.

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "chore: final integration cleanup for onboarding composer

Remove dead code paths from old 6-stage flow. Update test launch args.
Preserve StoryDuel code for P2. Add deprecation notes to old docs.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Implementation Order

Tasks must be executed sequentially — each builds on the previous:

```
1. FeedRecipeDefinition model  ──┐
2. FeedRecipeResolver           ──┤── Foundation
3. LanguageSelectionControl     ──┤
4. Composer Controls            ──┘
5. Preview Pipeline             ──┐
6. FeedComposerScene            ──┤── Screens
7. WelcomeScene Redesign        ──┤
8. CuratedOnboardingView Rewrite──┘
9. Save + Transition            ──┐
10. Accessibility + Localization──┤── Polish
11. Integration Tests           ──┤
12. Final Integration           ──┘
```
