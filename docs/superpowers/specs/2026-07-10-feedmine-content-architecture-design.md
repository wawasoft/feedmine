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

Three states, single sheet:

### Loading
- URL displayed at top in SF Mono caption
- Circular `ProgressView` (2pt stroke, circadian accent)
- Text: "Looking for feeds…" → "Checking N paths…"

### Result: 1 feed
- Card with feed title, URL, category hint
- Preview: last 3 items (title + date) if feed responded to initial probe
- "Add to Library" button → expands destination picker

### Result: multiple feeds
- List with circular checkboxes (accent fill when selected)
- Select all / deselect all
- "Add N feeds" → destination picker

### Result: OPML pack
- Summary card: name, "N feeds, M categories"
- Category structure in compact disclosure groups
- "Import" → auto-creates library node with hierarchy

### Destination picker
- Library tree displayed
- User picks existing node or creates new one
- "Save here" confirms

## Library Browser UI

Single screen replacing the three country/region drill-down screens.

### Tree view
- Recursive `DisclosureGroup` with indentation
- Each node: chevron + name + toggle (circle, filled when enabled)
- Disabling a parent dims children
- Toggle state from `library_node.enabled`

### Feed rows
- Feed title + source count for groups
- Preview dots: 3 tiny circles to the right. Filled when feed published in last 24h
- Long press or swipe reveals last 3 post titles
- "• N more…" when group has unlisted children

### "More in this category"
- At end of each expanded group: subtle link "+ N more Science feeds →"
- Shows inactive feeds in that category
- Can enable inline

### Search
- Filters tree by feed/node name
- Collapses tree to show only matches and their ancestors
- In-memory filter, no SQL needed

### Edit mode
- Drag to reorder (updates `sort_order`)
- Swipe to delete (only user/imported nodes; bundled asks confirmation)
- "+ New Node" at bottom

## Export Hub

Single screen, 5 options. Each generates locally and opens Share Sheet.

| Format | Generates | Use case |
|---|---|---|
| **OPML** | Feed list grouped by category | Migrate to another RSS reader |
| **CSV** | Bookmarks: title, URL, source, date saved | Spreadsheet analysis |
| **JSON** | Full backup: library tree, channels, lists, settings | Backup/restore, device migration |
| **HTML** | Bookmarks as self-contained web page | Share reading list with anyone |
| **PDF** | Reading stats + bookmark list, formatted | Print or share visually |

### OPML export
- Quick picker: "All sources" or "User sources only" (origin = `.user` | `.imported`)
- Uses existing `OPMLParser.exportOPML()`

### JSON backup
- Complete state: library tree, channels, lists with items, user preferences
- `.feedmine.json` extension
- Import reads this file back → restores state

### HTML/PDF
- Inline CSS, no external dependencies
- Works offline
- PDF uses `UIGraphicsPDFRenderer`

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
