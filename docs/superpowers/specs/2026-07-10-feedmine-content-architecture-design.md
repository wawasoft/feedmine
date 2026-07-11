# Feedmine Content Architecture — Design Spec

**Date:** 2026-07-10
**Context:** Redesign of how sources are organized, discovered, and exported in the Feedmine iOS app. Replaces the flat toggle system (SourceRegistry with string-keyed disabled/enabledOverrides sets) with a hierarchical Library model, adds share-sheet-based feed discovery, and introduces multi-format data export.

## Philosophy

- **User controls sources, not algorithms.** Library + Channel give the user explicit control over what enters their feed.
- **Anti-filter-bubble.** 190 countries, fair interleave, no engagement optimization.
- **Data portability.** Export in multiple formats. Import backups. Your data is yours.
- **Respect for publishers.** WKWebView opens original sites. No reader mode, no content extraction.

## Architecture Overview

Three new concepts replace the current toggle-and-filter system:

| Concept | Organizes | Relationship | Persistence |
|---|---|---|---|
| **Library** | Feed sources (URLs) | Tree, single parent | SQLite `library_node` + `library_source` |
| **Channel** | Library nodes (cross-cutting) | Many-to-many | SQLite `channel` + `channel_node` |
| **List** | Feed items (content) | Many-to-many, fixed | SQLite `bookmark_list` + `bookmark_item` (existing) |

### What changes

| Today | Becomes |
|---|---|
| `SourceRegistry.disabled` / `enabledOverrides` (string-keyed sets) | `library_node.enabled` (boolean on tree node) |
| `FeedStore.activeRegion` / `activeCategory` / `activeContentType` | `FeedStore.selectedChannel` (references Channel) |
| `CountriesListScreen` + `CountryDetailScreen` + `RegionDetailScreen` (3 drill-down screens) | Single `LibraryBrowser` with recursive tree |
| `FilterSheetView` (category/mood/type picker) | Channel picker + quick mood/type filters |
| `SourceScheduler.nextBatch(activeRegion:activeCategory:)` | `nextBatch(sourcesFromChannel:)` — receives flat source list |
| `BookmarkList` (model name) | Renamed to "List" in UI only; schema unchanged |
| `SourceManagementView` (flat list by category) | Replaced by `LibraryBrowser` |

### What is new

| Component | File | Purpose |
|---|---|---|
| `FeedDetector` | `Services/FeedDetector.swift` | Actor. Given URL: detect feed/OPML/webpage. |
| `SourceOrigin` | `Models/FeedSource.swift` | Enum: `.bundled`, `.imported`, `.user` |
| `LibraryNode` | Models + GRDB record | Tree node: id, parentId, name, sortOrder, origin, enabled |
| `Channel` | Models + GRDB record | Named channel referencing library nodes |
| `ShareResultView` | `Views/ShareResultView.swift` | Post-detection sheet: loading → result → destination picker |
| `LibraryBrowser` | `Views/LibraryBrowser.swift` | Recursive tree with toggles, previews, search |
| `ExportHub` | `Views/ExportHub.swift` | Export options: OPML, CSV, JSON, HTML, PDF |

### What stays

- `FeedItem` / `FeedItemRecord` — no schema change
- `Reservoir` — same buffer logic
- `RSSFetcher` — same parsing
- `OPMLParser` — same parsing; output feeds Library tree instead of region strings
- `BookmarkListRecord` / `BookmarkItemRecord` — same tables (v1 migration)
- `CircadianEngine`, `MomentGreeting`, `AudioPlayerManager` — zero impact
- `ImageCache`, `ImagePrefetcher`, `NetworkMonitor` — zero impact

## Data Model

### SourceOrigin

```swift
enum SourceOrigin: String, Codable, Sendable {
    case bundled   // from bundled OPML files
    case imported  // user imported OPML file
    case user      // user added via URL / share sheet
}
```

Added to `FeedSource`. Set at creation time by the parser/detector. Not persisted in SQLite — FeedSource lives in memory.

### Library (SQLite migration v6)

```sql
CREATE TABLE library_node (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    parent_id INTEGER REFERENCES library_node(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    origin TEXT NOT NULL DEFAULT 'bundled',  -- bundled, imported, user
    enabled INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE library_source (
    node_id INTEGER NOT NULL REFERENCES library_node(id) ON DELETE CASCADE,
    source_url TEXT NOT NULL,
    PRIMARY KEY (node_id, source_url)
);

CREATE INDEX idx_library_parent ON library_node(parent_id);
CREATE INDEX idx_library_source_node ON library_source(node_id);
```

**Single parent enforced by composite PK on `(node_id, source_url)`.** A source URL can only appear once in the tree.

**Active sources query** uses recursive CTE:
```sql
WITH RECURSIVE active_tree AS (
    SELECT id FROM library_node WHERE enabled = 1 AND parent_id IS NULL
    UNION ALL
    SELECT n.id FROM library_node n
    JOIN active_tree a ON n.parent_id = a.id
    WHERE n.enabled = 1
)
SELECT DISTINCT ls.source_url FROM library_source ls
JOIN active_tree at ON ls.node_id = at.id;
```

**Seeding from OPML:** The OPML directory structure becomes the initial tree. `OPMLParser.parseAll()` creates `FeedSource` objects as before, but the `loadFromOPML()` method in SourceRegistry (or its replacement) builds `library_node` rows matching the file hierarchy:
- `Feedmine` (root, no sources)
  - `English General` (category-level OPMLs: apple.opml, tech.opml, news.opml…)
    - `Apple` (feeds from apple.opml)
    - `Tech` (feeds from tech.opml)
    - …
  - `International` (countries/ directory)
    - `Brasil` (countries/brazil/brazil.opml)
      - `São Paulo` (countries/brazil/brazil-sao-paulo.opml)
      - …
    - …

### Channel

```sql
CREATE TABLE channel (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE channel_node (
    channel_id INTEGER NOT NULL REFERENCES channel(id) ON DELETE CASCADE,
    node_id INTEGER NOT NULL REFERENCES library_node(id) ON DELETE CASCADE,
    PRIMARY KEY (channel_id, node_id)
);
```

Channel references **library nodes**, not individual source URLs. When a library node gains or loses sources, channels that reference it automatically reflect the change.

**"All" channel** is implicit: all enabled nodes in the library. No channel row needed.

### List (bookmarks) — no schema change

Existing `bookmark_list` + `bookmark_item` tables remain identical. Only UI label changes from "Bookmark Box" to "List."

Persistent search lists (query + region + category) continue working as before — the FTS5 matching runs against `feed_item`, not against the new library/channel tables.

## FeedDetector

### API

```swift
actor FeedDetector {
    enum DetectionResult {
        case feed(FeedSource)           // single RSS/Atom feed
        case multipleFeeds([FeedSource]) // multiple <link rel="alternate">
        case opml([FeedSource])         // OPML file with N feeds
        case noFeedFound
        case error(String)
    }

    func detect(url: URL) async -> DetectionResult
}
```

### Detection flow

1. **HEAD request** to URL. Inspect `Content-Type` header:
   - `application/rss+xml`, `application/atom+xml`, `application/feed+json` → `.feed`
   - `text/x-opml` or `.opml` extension → parse as OPML → `.opml`
   - `text/html` → proceed to step 2

2. **HTML autodiscovery:** GET the page. Parse for `<link rel="alternate" type="application/rss+xml">` and `<link rel="alternate" type="application/atom+xml">`. For each found:
   - Resolve relative URLs
   - HEAD the feed URL to confirm reachability
   - Create `FeedSource` with origin `.user`

3. **Path probes** (fallback): if no `<link>` tags found, HEAD common paths:
   `/feed/`, `/rss/`, `/rss.xml`, `/feed.xml`, `/atom.xml`, `/index.xml`, `/feeds/posts/default` (Blogger)

4. **Classification:**
   - 0 feeds found → `.noFeedFound`
   - 1 feed found → `.feed(source)`
   - 2+ feeds found → `.multipleFeeds(sources)`

### Error handling

- Network timeout (15s) → `.error("Could not reach server")`
- Non-200 response → `.error("Server returned \(code)")`
- HTML with no discoverable feeds → `.noFeedFound`

## Share Result UI

Single sheet, five states. Uses `.presentationDetents([.medium, .large])` consistent with existing sheets. Haptic: `.light` on detection complete, `.light` on feed selection toggle, `.medium` on save.

### Loading
- URL at top in SF Mono caption, circadian accent on the domain portion
- Thin `ProgressView` (2pt stroke, circadian accent)
- Text phase: "Looking for feeds…" (first 1.5s) → "Checking paths…" (if probes are running)
- Keep the animation quiet — this is a 1-3 second wait. No skeleton cards, no cycling messages.

### Result: 1 feed
- Card with feed title (from RSS `<title>` or HTML `<title>`), URL in SF Mono caption
- Lightweight metadata only: item count, last updated date. Do NOT parse items here — that doubles latency.
- "Preview" button as secondary action → fetches and shows last 3 items if user wants
- "Add to Library" button (primary) → opens destination picker
- Haptic `.light` when card appears

### Result: multiple feeds
- List with circular checkboxes using SF Symbols `circle` / `checkmark.circle.fill` in circadian accent
- Each row: feed title + URL. Selected state = filled checkmark.
- "Select all" / "Deselect all" at top
- "Add N feeds" button → destination picker
- Haptic `.light` on each checkbox toggle

### Result: OPML pack
- Summary card: pack name, "N feeds, M categories"
- Compact disclosure groups showing category structure (collapsed by default)
- "Import" → auto-creates library node with full hierarchy. Toast: "Imported N feeds."
- Haptic `.medium` on successful import

### No feed found
- Empty state with `magnifyingglass` icon in circadian accent
- Title: "No feeds found"
- Description: "This page doesn't link to any RSS or Atom feeds we could find."
- Actions: "Try a different URL" (dismisses sheet), "Browse catalog" (opens LibraryBrowser)

### Error
- Inline error card with `wifi.slash` icon, orange tint
- Specific message: "Could not reach server" / "Server returned 404" / "Connection timed out"
- "Try again" button retries detection
- Matches existing `CompactErrorBanner` pattern

### Destination picker
- Shows 3-5 most recently used library nodes + "Browse all" → opens full LibraryBrowser in selection mode
- "Create new" button at top for quick node creation
- Selected node highlighted with circadian accent
- "Save here" button confirms
- This uses the same tree component as LibraryBrowser, just in `selectionMode` rather than `navigationMode`

## Library Browser UI

Single screen replacing three country/region drill-down screens. Uses circadian accent, spacing, and font weight from the active period. Haptic: `.light` on toggle flip, `.light` on disclosure expand/collapse.

### Navigation
- Top-level shows root nodes (Feedmine, user-created)
- **Levels 1-2**: inline disclosure expansion (chevron, indentation)
- **Level 3+**: pushes to a new screen with breadcrumb navigation. This prevents iPhone screens from becoming unreadable with 6 levels of indentation.
- Breadcrumb at top: `Feedmine › International › Brasil › São Paulo`
- Each breadcrumb segment is tappable to jump back
- Back button returns to parent

### Tree view
- Each node row: SF Symbol chevron (rotates on expand) + name + toggle
- Toggle uses SF Symbols: `circle` (off) / `checkmark.circle.fill` (on) in circadian accent — consistent with existing bookmark.fill pattern
- Groups show source count: "Tech (12)"
- Disabling a parent dims children (opacity 0.4). No cascade-write — children keep their individual enabled state.
- Expanding a node animates with `.easeInOut(duration: 0.2)`

### Feed activity
- Each feed row shows a swipeable area on the right
- Swipe left on a feed row → reveals last 3 post titles inline, no long-press needed
- Each title shows relative date (e.g. "2h ago", "yesterday")
- Feeds with posts in last 24h get a subtle circadian accent dot (4pt) next to their name — immediate visual scan
- Swipe right or tap elsewhere to dismiss the preview

### "More in this category"
- At end of each expanded group: subtle row with "+ N more in Category →"
- Tapping opens a filtered list of inactive feeds in that category
- Each has an inline enable toggle
- Dismisses back to tree when done

### Search
- Magnifying glass icon in toolbar
- Filters tree by feed/node name (in-memory)
- Collapses tree to show only matches and their ancestors
- **Remembers pre-search expansion state** — restores it when search is cleared
- Empty search result: "No feeds matching 'query'" with suggestion to browse categories

### Edit mode
- EditButton in toolbar toggles edit mode
- **Reorder**: drag handle on each row (standard iOS EditButton + `onMove`)
- **Delete**: swipe left reveals delete (only user/imported nodes; bundled shows "This is a built-in collection. Hide it instead?" with option to disable)
- **Create**: "+" button always visible at bottom, in both edit and non-edit mode. In edit mode it's "Add Node" with the same icon.
- Exit edit mode with Done button

### Empty states
- **No user feeds yet**: card with `plus.circle` icon, "Your first feed" + "Share a link from Safari or paste a URL to get started." + "Add a Feed" button that opens manual URL entry.
- **All nodes disabled**: muted illustration + "Everything is turned off. Enable at least one collection to see content." + "Reset to defaults" button.

## Export Hub

Single screen, accessible from Settings and Library toolbar. Uses circadian accent. Haptic: `.light` on format selection, `.medium` on export complete.

### Layout
Two sections with list-style rows (iOS Settings pattern, not identical cards):

**Data formats** — machine-readable, for backup and migration:
| Format | Icon | Description | Action |
|---|---|---|---|
| OPML | `doc.text` | Feed list for other RSS readers | Segmented picker: "All" / "Mine" → Export |
| CSV | `tablecells` | Bookmarks as spreadsheet | Export (instant) |
| JSON | `shippingbox` | Full backup: library, lists, channels, settings | Export / Import |

**Document formats** — human-readable, for sharing and printing:
| Format | Icon | Description | Action |
|---|---|---|---|
| HTML | `safari` | Bookmarks as self-contained web page | Export → Preview → Share |
| PDF | `doc.richtext` | Reading stats + bookmark list, formatted | Export → Preview → Share |

### OPML export
- Segmented control visible inline: "All sources" / "Mine only" (origin = `.user` | `.imported`)
- Uses existing `OPMLParser.exportOPML()`
- Opens Share Sheet

### JSON backup
- **Export**: Codable encode of complete state → `.feedmine.json` → Share Sheet
- **Import**: "Import backup" button in the same row → `.fileImporter` for `.json` and `.feedmine` files → reads state → "This will replace your current library, channels, and settings. Continue?" confirmation → restores

### HTML export
- Generates inline-CSS HTML (no external dependencies, works offline)
- Opens preview in a sheet with WKWebView before sharing
- "Share" button in preview toolbar

### PDF export
- Uses `UIGraphicsPDFRenderer` with stats template
- Preview before sharing (same pattern as HTML)

### Post-export
- After Share Sheet dismisses → toast: "Exported as [format]" with checkmark icon
- Auto-dismiss after 2s (same toast pattern as existing `showToast` in FeedScreen)
- JSON import shows confirmation dialog before overwriting

### Empty states
- **No bookmarks**: CSV, HTML, PDF rows disabled with "No bookmarks to export" caption
- **No user sources**: OPML "Mine only" segment disabled with "No user sources" caption
- JSON export/import always available (backup includes structure even if empty)

## Cross-Cutting Concerns

### Circadian integration
All three new screens inherit the active circadian period's tokens:
- **Accent color**: from `CircadianEngine.shared.accent`
- **Page background**: from `engine.pageBackground` (ShareResultView sheet, LibraryBrowser, ExportHub)
- **Typography**: font weight and letter-spacing from `engine.period.fontWeight` / `engine.period.letterSpacing`
- **Card styling**: radius from `engine.period.cardRadius`, gap from `engine.period.cardGap`
- **Transitions**: 2.0s easeInOut on period change (same as root FeedScreen)

This ensures the new screens don't feel bolted-on — they breathe with the same rhythm as the feed.

### Haptics
Consistent with existing app patterns (all `UIImpactFeedbackGenerator`):
- Detection complete → `.light`
- Checkbox toggle (multi-feed selection) → `.light`
- Library node toggle → `.light`
- Disclosure expand/collapse → `.light` (optional, only on explicit tap, not programmatic)
- Save/add/import → `.medium`
- Export complete → `.medium`
- Delete/destructive → `.rigid` (if used for confirmation gestures)

### Shared tree component
The library tree is rendered by a single component used in two modes:
- `LibraryTreeView(mode: .navigation)` — LibraryBrowser with full interaction
- `LibraryTreeView(mode: .selection(selectedID: Binding))` — destination picker with radio selection

One implementation, two contexts. Prevents code duplication and visual inconsistency.

### Accessibility
- Tree rows: `accessibilityElement(children: .combine)` with label "Tech, 12 feeds, enabled" or "Tech, 12 feeds, disabled"
- Toggle: `accessibilityAction(named: "Toggle")` as custom action
- Disclosure: standard iOS disclosure group accessibility (VoiceOver announces "expanded" / "collapsed")
- Preview swipe: `accessibilityAction(named: "Show recent posts")` as custom action
- Search result count announced on filter: "3 matches"
- Export formats: each row is a single accessibility element describing format + description
- `reduceMotion` check on period transition animations (consistent with existing WhatsNewCarousel pattern)

### Empty state principles
Every empty state follows the pattern: **icon + title + description + action**.
- Not mood-based ("Oops!", "Nothing here!") — direction-based ("Your first feed", "Everything is turned off")
- Every empty state has at least one action button, never a dead end
- Icons use circadian accent, not gray — empty is a moment, not an error

---

## Migration of Existing State

### source_toggle table (v5) → library_node

The v5 `source_toggle` table stores flat `(key, state)` pairs where key is `"region:brazil"`, `"cat:tech"`, `"url:https://..."`. During v6 migration:

1. Read all source_toggle rows
2. Map each key to the corresponding library_node (by name for regions/categories, by source_url for individual feeds)
3. Set `library_node.enabled` based on the toggle state
4. Keep the `source_toggle` table (don't drop it) for rollback safety; mark as deprecated

### SourceRegistry class

The `SourceRegistry` (~300 lines) is replaced incrementally:
- **Phase 1**: Library tree exists alongside SourceRegistry. Both are populated.
- **Phase 2**: SourceRegistry toggle methods become wrappers that update the library tree. `isSourceEnabled()` reads from the CTE.
- **Phase 3**: SourceRegistry is removed. Only the OPML loading logic survives (moved to a `LibrarySeeder`).

### Existing filter state (activeRegion / activeCategory)

On migration, create a Channel named "Previous filters" that references the library nodes matching the user's active region + category. This preserves the user's current view without data loss.

### Bookmark lists → Lists

No data migration. Tables unchanged. UI labels only.

### Toggle behavior clarification

Disabling a parent node **does not cascade-write** to children. The enabled state of each node is independent. The recursive CTE query excludes disabled nodes and all their descendants — so a disabled parent's children are hidden from the feed regardless of their own enabled flag. This means:
- Disable "Brasil" → all Brazilian feeds disappear from the feed
- Re-enable "Brasil" → children that were individually enabled come back; children that were individually disabled stay off
- No bulk updates on parent toggle. Just the CTE doing the work.

---

## Implementation Phases

### Phase 1 — Foundation (data layer)
1. Add `SourceOrigin` to `FeedSource`
2. Create `FeedDetector` actor
3. Migration v6: `library_node`, `library_source`, `channel`, `channel_node` tables
4. Seed library tree from OPML on first launch
5. Build recursive CTE query for active sources

### Phase 2 — Logic replacement
1. Replace `SourceRegistry` toggle logic with library tree queries
2. Replace `FeedStore` filter state with Channel selection
3. Update `SourceScheduler.nextBatch()` to accept flat source list
4. Wire `FeedDetector` into share sheet URL handling
5. Fix imported source persistence (use `SourceOrigin.imported`, persist to SQLite)

### Phase 3 — UI
1. `ShareResultView` — share sheet result + destination picker
2. `LibraryBrowser` — recursive tree replacing country screens
3. `ExportHub` — 5-format export
4. Remove old screens: `CountriesListScreen`, `CountryDetailScreen`, `RegionDetailScreen`, `FilterSheetView` (or simplify)
5. Rename "Bookmark Box" → "List" in UI labels

## Out of Scope (for now)

- iCloud sync
- Share Extension target (using onOpenURL only)
- RSS feed publishing (Feedmine as a feed source)
- Programmatic channel creation from persistent search results
- Regional/state OPML discovery pipeline (separate Python tool)
