# Offline Content — Design Spec

**Date:** 2026-07-24
**Branch:** `offline-features`
**Status:** Draft

## Overview

Feedmine today requires connectivity for its most valuable features: reading articles
(WKWebView loads live URLs), viewing uncached images, and playing podcasts (AVPlayer
streams from the network). This spec defines a complete offline experience: automatic
and manual download of articles and podcasts, transparent Airplane Mode detection,
and a unified "Downloaded" filter that works across every view in the app.

## Guiding Principles

1. **Offline is not a mode — it's a filter.** Downloaded content is exposed through
   a "Downloaded" filter, identical in behavior to existing region/language/content-type
   filters. When active, every view shows only downloaded items.

2. **Airplane Mode is the trigger.** We detect Airplane Mode via `NWPathMonitor`
   (`availableInterfaces.isEmpty`), not via flaky connectivity checks. No false
   positives from WiFi drops or cellular dead zones.

3. **Auto-download respects user intent.** Users configure per-source or per-collection
   rules. The app downloads new items automatically on WiFi (configurable), respecting
   storage limits and episode caps.

4. **Everything is SQLite.** Download state, rules, and file paths live in SQLite.
   No new plist files, no UserDefaults bloat. The existing `feedmine.sqlite` schema
   is extended.

---

## Feature 1: Download Infrastructure — Multi-Asset Bundles

A "download" is not a single file — it's a **bundle of assets** that together
make the content fully available offline. What gets downloaded depends on the
content type.

### 1.1 What Gets Downloaded Per Content Type

**Podcast = Audio file (mandatory) + Show notes page (best-effort):**

| Asset | Required | Description |
|-------|----------|-------------|
| Audio file | ✅ Mandatory | From `FeedItem.audioPlaybackURL`. Download fails without this. |
| Show notes page | ⬜ Best-effort | From `FeedItem.url`. The episode's web page with description, links, transcript. If unreachable or paywalled, the audio alone still counts as a completed download. |
| Page images | ⬜ Best-effort | `<img>` tags found in the show notes page, downloaded to ImageCache. |

**Article = Page content (mandatory) + Embedded images (best-effort):**

| Asset | Required | Description |
|-------|----------|-------------|
| Article HTML | ✅ Mandatory | From `FeedItem.url`. Sanitized: scripts, ads, nav stripped. Download fails without this. |
| Embedded images | ⬜ Best-effort | `<img>` tags found in the article. Downloaded to ImageCache. Broken images show placeholders. |

### 1.2 Bundle Storage

Each downloaded item gets its own directory:

```
Caches/Downloads/<itemID>/
├── audio.mp3            # podcast only: the audio file
├── page.html            # show notes or article content (sanitized)
└── images/              # symlinks or copies to ImageCache entries
```

Benefits of per-item directories:
- Atomic delete: remove the directory, all assets are gone
- Easy size accounting: `du -s <itemID>/` gives total
- No filename collisions: `audio.mp3` is always `audio.mp3` within the bundle

### 1.3 Schema

```sql
-- Migration v22 (after current latest)

CREATE TABLE download_rule (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    target_type TEXT NOT NULL,   -- 'source' | 'collection'
    target_id TEXT NOT NULL,     -- source URL or collection ID (INT64 as string)
    max_items INTEGER NOT NULL DEFAULT 3,
    mode TEXT NOT NULL DEFAULT 'wifi',  -- 'wifi' | 'cellular'
    enabled INTEGER NOT NULL DEFAULT 1,
    UNIQUE(target_type, target_id)
);

CREATE TABLE download (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id TEXT NOT NULL UNIQUE,
    source_url TEXT NOT NULL,
    content_type TEXT NOT NULL DEFAULT 'podcast',
        -- 'podcast' | 'article'
    audio_url TEXT,            -- podcast: the audio file URL
    page_url TEXT NOT NULL,    -- the item.url (show notes or article)
    bundle_path TEXT,          -- path to the item's bundle directory
    audio_path TEXT,           -- relative path to audio within bundle
    page_path TEXT,            -- relative path to page.html within bundle
    audio_bytes INTEGER DEFAULT 0,
    audio_downloaded INTEGER DEFAULT 0,
    page_bytes INTEGER DEFAULT 0,
    page_downloaded INTEGER DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'queued',
        -- 'queued' | 'downloading_audio' | 'downloading_page'
        -- | 'completed' | 'failed_audio' | 'failed_page'
    created_at INTEGER NOT NULL,
    completed_at INTEGER
);

CREATE INDEX idx_download_status ON download(status);
CREATE INDEX idx_download_source ON download(source_url);
```

**Failure modes encoded in status:**
- `failed_audio` — audio download failed (podcast is unusable offline). User must retry.
- `failed_page` — audio succeeded but page failed (podcast is still usable — playable, just no show notes offline).
- `completed` — everything succeeded.

### 1.4 DownloadManager Actor

```
actor DownloadManager {
    static let shared = DownloadManager()

    // Config
    var mode: DownloadMode           // .wifi | .cellular
    var storageLimit: Int64          // bytes, default 2 GB
    var autoDelete: AutoDeletePolicy // .afterConsumed | .manual

    // Background session for suspended downloads
    private let session: URLSession
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private let maxConcurrent = 2    // audio + page can run in parallel

    // Public API
    func enqueue(item: FeedItem, contentType: DownloadContentType) async
    func cancel(itemID: String) async
    func delete(itemID: String) async    // removes bundle dir + DB row
    func status(for itemID: String) -> DownloadStatus
    func progress(for itemID: String) -> Double  // weighted avg 0...1
    func isDownloaded(itemID: String) -> Bool
    func localPagePath(for itemID: String) -> URL?  // for ArticleReaderView
    func localAudioPath(for itemID: String) -> URL? // for AudioPlayerManager

    // Auto-download trigger
    func evaluateRules(for items: [FeedItem]) async

    // Storage
    func storageUsed() -> Int64
    func enforceStorageLimit() async   // evicts oldest completed
}
```

### 1.5 Download Flow (Podcast Example)

```
1. User taps ⬇️ on Shipping Podcast episode
2. DownloadManager.enqueue(item, contentType: .podcast)
   → INSERT INTO download (status='queued')
3. processQueue picks the task:

   Phase A — Audio (mandatory, runs first):
     a. URLSessionDownloadTask for audio_url
     b. Progress tracked in audio_downloaded / audio_bytes
     c. On complete → move to bundle/audio.mp3
     d. Status → 'downloading_page'
     e. If fails → status='failed_audio', stop

   Phase B — Page (best-effort, runs after audio):
     a. ContentSanitizer.fetchAndSanitize(page_url)
     b. Extract <img> tags → download to ImageCache
     c. Rewrite img src → local paths
     d. Write sanitized HTML to bundle/page.html
     e. If succeeds → status='completed'
     f. If fails → status='failed_page' (audio alone is enough)

4. If storage exceeded → enforceStorageLimit()
```

**Article download** is identical except Phase A is skipped (no audio), and the
page fetch in Phase B is mandatory (status='failed_page' on failure, which is
effectively failed for articles).

### 1.6 Multi-Asset Progress Tracking

The card shows a single progress ring. Under the hood:

```
totalProgress = (audioProgress * audioWeight) + (pageProgress * pageWeight)

Where:
  audioWeight = audio_bytes / (audio_bytes + page_bytes)
  pageWeight  = page_bytes / (audio_bytes + page_bytes)

If page download hasn't started yet (still in Phase A):
  totalProgress = audioProgress * 0.85    // reserve 15% for Phase B

If page download fails:
  totalProgress jumps 85% → 100% (audio alone completes the podcast download)
```

### 1.7 ContentSanitizer

A new utility for intelligent HTML processing:

```
enum ContentSanitizer {
    /// Downloads a web page and produces clean, readable HTML suitable
    /// for offline storage and WKWebView display.
    static func fetchAndSanitize(
        url: URL,
        maxBytes: Int = 2_000_000  // 2 MB cap
    ) async throws -> SanitizedContent

    struct SanitizedContent {
        let html: String           // Clean HTML string
        let imageURLs: [URL]       // <img> src URLs found in the page
        let title: String?         // Extracted <title>
        let textPreview: String    // First ~500 chars of visible text
    }
}
```

**Sanitization steps:**
1. Fetch HTML via URLSession (max 2 MB, 15s timeout)
2. Check Content-Type header — if not HTML (e.g. PDF, audio), return early
   with just the URL reference (user opens in Safari when online)
3. Extract `<title>`, `<meta description>`
4. Remove: `<script>`, `<style>`, `<iframe>`, `<nav>`, `<footer>`,
   tracking pixels, social media embeds, comment sections, `<form>`
5. Preserve: `<article>`, `<main>`, `<p>`, `<h1>`-`<h6>`, `<img>`,
   `<blockquote>`, `<ul>`/`<ol>`, `<a>` (strip `onclick`/`onload` handlers)
6. Collect all `<img src>` URLs for later download
7. Wrap in minimal CSS for readability (max-width, system font, line-height)
8. Return `SanitizedContent` with the clean HTML, image URLs, and metadata

**Failure modes handled:**
| Scenario | Behavior |
|----------|----------|
| Timeout (15s) | Throw `.timeout` — caller may retry once |
| Paywall / 403 / login-wall | Throw `.paywalled` — page skipped, audio still counts |
| Non-HTML response | Throw `.notHTML` — store as link-only |
| Truncated HTML | Save what we got — best-effort, partial page |
| Malformed HTML | Parse with SwiftSoup, recover what we can |
| Page > 2 MB | Truncate at 2 MB — above the fold content is usually enough |

---

## Feature 2: Airplane Mode Detection

### 2.1 Enhanced NetworkMonitor

Extend the existing `NetworkMonitor`:

```swift
@MainActor @Observable
final class NetworkMonitor {
    // Existing
    private(set) var isConnected = true

    // NEW
    private(set) var isAirplaneMode = false
    // True when availableInterfaces is empty (no WiFi radio, no cellular radio).
    // This is the ONLY trigger for automatic offline mode activation.
}
```

### 2.2 Behavior

```
Airplane Mode ON:
  → FeedLoader activates Downloaded filter automatically
  → Banner: "✈️ Modo Avião — conteúdo offline"
  → If zero downloads exist → empty state with setup instructions

Airplane Mode OFF:
  → FeedLoader deactivates auto-Downloaded filter
  → Brief toast: "📶 Online"
  → If user had manually activated Downloaded → stays active
```

Manual toggle (user taps `[📥 Downloaded]` in filter bar) is independent.
It survives connectivity changes — only user action removes it.

---

## Feature 3: Downloaded Filter

### 3.1 Filter Semantics

The Downloaded filter is **global and transversal.** When active, it applies
BEFORE any other filter. All views respect it:

| View | Behavior with Downloaded ON |
|------|---------------------------|
| Main feed | Only downloaded items |
| Collection detail | Only downloaded items from that collection |
| Source detail | Only downloaded episodes from that source |
| Bookmarks | Only downloaded bookmarks |
| Search results | Only downloaded matches |
| What's New | Hidden (requires network) |

### 3.2 SQL Integration

The filter is applied at the SQL level in `reloadFromSQLite`:

```sql
-- When Downloaded filter is active, add:
AND feed_item.id IN (SELECT item_id FROM download WHERE status IN ('completed', 'failed_page'))
```

Note: `failed_page` items are included because they have usable audio (podcast)
or partial content (article). The user can still consume the primary asset.

The `applyFilters` in-memory path also checks:
```swift
if activeFilters.contains(.downloaded) {
    items = items.filter { await DownloadManager.shared.isDownloaded($0.id) }
}
```

### 3.3 UI

The filter appears as a chip/button in the existing filter UI:

```
[All] [Articles] [Podcasts] [🌐 EN] [📥 Downloaded]
```

When active, cards show a subtle checkmark badge on the thumbnail.
The Downloaded filter can be combined with any other filter.

---

## Feature 4: Auto-Download Rules

### 4.1 Per-Source Configuration

Accessed from Source detail screen. When user opens a source:

```
┌──────────────────────────────────────┐
│  ⬅️  Shipping Podcast                 │
│  🎙️ Audio · EN · 87 items            │
│                                      │
│  ⬇️ Auto-download                ○   │
│     New episodes automatically        │
│                                      │
│  📦 Keep latest               [3 ▼]  │
│     1 / 3 / 5 / 10 / All             │
│                                      │
│  📡 On                         [WiFi ▼]│
│     WiFi only / WiFi + Cellular       │
└──────────────────────────────────────┘
```

Settings are persisted to `download_rule` table.

### 4.2 Per-Collection Configuration

Accessed from Collection detail screen. One toggle for the entire collection,
with per-source episode cap applied to each source within the collection.

### 4.3 Evaluation Trigger

Auto-download rules are evaluated after `persistFetchedItems` completes
successfully. The flow:

```
1. New items persisted to SQLite
2. DownloadManager.evaluateRules(for: newItems)
3. For each enabled download_rule:
   a. Skip if mode='wifi' and current interface is cellular
   b. Match items by source URL (or collection membership)
   c. Take the N newest (by published_at) that aren't already downloaded
   d. Enqueue each for download
4. processQueue() picks them up
```

### 4.4 Global Settings

In Settings → Downloads:

```
┌──────────────────────────────────────┐
│  ⬇️ Downloads                         │
│                                      │
│  📡 Prefer             [WiFi only ▼]  │
│  📦 Storage limit      [2 GB ▼]       │
│     500 MB / 1 GB / 2 GB / 5 GB      │
│  🗑️ Auto-delete        [After read ▼] │
│     After read / Manual / After 7d   │
│                                      │
│  ─── Active rules ───────────────────│
│  🎙️ Shipping Podcast        3 ep    > │
│  🎧 Favorites Podcasts     12 srcs  > │
│                                      │
│  ─── Queue ──────────────────────────│
│  ⬇️ Ep 142: Future of...      45%    │
│  ⬇️ Article: Apple Visio...   12%    │
└──────────────────────────────────────┘
```

---

## Feature 5: Download UX on Cards

### 5.1 Card States

Each card in the feed shows download state:

| State | Icon | Action on tap |
|-------|------|---------------|
| Not downloaded | ⬇️ | Start download |
| Downloading (Phase A) | ⬇️ circular fill | Cancel |
| Downloading (Phase B) | ⬇️ nearly-full fill | Cancel |
| Downloaded | ✅ | Delete (with confirmation) |
| Partial (audio ok, page failed) | ✅⃰ | Delete (with confirmation) |
| Failed | ⚠️ | Retry |

The icon appears on the card thumbnail overlay, top-right corner.
Partial downloads (✅⃰) have a subtle dot indicator — "audio is ready, show notes
are not."

### 5.2 Batch Download

Long-press on a source or collection row offers "Download All."
In collection detail: "Download New" (downloads latest N episodes across
all sources per their configured caps).

---

## Feature 6: Offline Audio Playback

### 6.1 AudioPlayerManager Changes

```
func play(item: FeedItem) -> Bool {
    // 1. Check for local download first
    if let localURL = await DownloadManager.shared.localAudioPath(for: item.id) {
        let playerItem = AVPlayerItem(url: localURL)
        // ... same setup as streaming (observers, now-playing, position)
        // AVPlayer handles local files natively — no special config needed
        return true
    }
    // 2. Fall back to streaming
    guard let url = item.audioPlaybackURL else { return false }
    // ... existing streaming logic
}
```

### 6.2 Position Persistence

Already implemented — `savePosition()` writes to UserDefaults.
Works identically for streamed and downloaded playback.

---

## Feature 7: Offline Article Reading

### 7.1 ArticleReaderView Changes

```swift
// In ArticleWebView:
if let pageURL = await DownloadManager.shared.localPagePath(for: item.id) {
    // Load cached sanitized HTML from disk
    let html = try String(contentsOfFile: pageURL.path)
    let baseURL = pageURL.deletingLastPathComponent()
    webView.loadHTMLString(html, baseURL: baseURL)
} else {
    // Live URL as before
    webView.load(URLRequest(url: URL(string: item.url)!))
}
```

### 7.2 Image Handling in Cached Pages

When `ContentSanitizer` processes the article HTML:
1. All `<img src="...">` URLs are collected
2. Each image is downloaded via `ImageCache` (the existing pipeline)
3. The `<img src>` in the sanitized HTML is rewritten to a local `file://` path
4. If an image fails to download, the `src` is left as the original URL
   (shows broken image placeholder offline, loads when back online)

### 7.3 Podcast Show Notes

For podcast downloads, the same `ContentSanitizer` processes the show notes page.
When the user opens a downloaded podcast episode's show notes (from the player
screen or a "View Show Notes" button), they see the cached page. This works
identically to article reading — `WKWebView.loadHTMLString` with the cached HTML.

---

## Feature 8: Content Organization

### 8.1 Downloaded Items Are NOT a Separate Collection

They remain in their original contexts (main feed, collections, sources).
The Downloaded filter simply narrows the view. There is no "Downloads" tab
or separate screen — the filter bar is the entry point.

### 8.2 Storage Display

Used storage is shown in Settings → Downloads. Individual episode sizes
are visible in the download queue and can be deleted individually.

### 8.3 What Gets Downloaded (Size Estimates)

| Content Type | Assets | Typical Total |
|---|---|---|
| Podcast (30 min, 64 kbps) | Audio ~15 MB + Page ~0.5 MB | ~16 MB |
| Podcast (60 min, 128 kbps) | Audio ~55 MB + Page ~0.5 MB | ~56 MB |
| Article (text-heavy) | HTML ~0.3 MB + images ~1 MB | ~1.5 MB |
| Article (photo essay) | HTML ~0.5 MB + images ~5 MB | ~5.5 MB |

With 2 GB storage limit: ~35 hour-long podcasts or ~1,300 articles.

---

## Implementation Phases

### Phase 1: Foundation (1 week)
- Schema migration (download, download_rule tables)
- `DownloadManager` actor with queue, progress, bundle storage
- `ContentSanitizer` utility for intelligent HTML processing
- Enhanced `NetworkMonitor` with `isAirplaneMode`
- `Downloaded` filter in `FeedStore` (SQL + in-memory)

### Phase 2: Auto-Download (1 week)
- Per-source and per-collection auto-download rules UI
- `evaluateRules` integration with `persistFetchedItems`
- Settings screen: storage, mode, auto-delete
- Download action on cards (manual download/cancel/delete)
- Multi-asset progress tracking (audio + page)

### Phase 3: Playback & Reading (1 week)
- `AudioPlayerManager` local file playback path (prioritize downloaded files)
- `ArticleReaderView` cached HTML loading with rewritten image paths
- Podcast show notes viewing from cache
- Background URL session for suspended downloads

### Phase 4: Polish (3-4 days)
- Airplane Mode auto-activation / deactivation
- Empty states and onboarding for first-time offline users
- Storage enforcement and LRU eviction
- Edge cases: partial downloads, file system errors, migration from old schema

---

## File Manifest

| File | New/Modified | Purpose |
|------|-------------|---------|
| `Services/DownloadManager.swift` | NEW | Download actor, queue, bundle storage, multi-asset coordination |
| `Services/ContentSanitizer.swift` | NEW | HTML fetch, sanitize, image extraction |
| `Services/NetworkMonitor.swift` | MODIFIED | Add `isAirplaneMode` |
| `Services/FeedStore.swift` | MODIFIED | Schema migration (v22), SQL filter for Downloaded |
| `Services/FeedLoader.swift` | MODIFIED | Downloaded filter state, auto-activation |
| `Services/AudioPlayerManager.swift` | MODIFIED | Local file playback path |
| `Views/FeedScreen.swift` | MODIFIED | Airplane Mode banner |
| `Views/FeedItemCardView.swift` | MODIFIED | Download button overlay with multi-phase progress |
| `Views/SettingsSheetView.swift` | MODIFIED | Download settings section |
| `Views/FilterSheetView.swift` | MODIFIED | Downloaded filter chip |
| `Views/SourceManagementView.swift` | MODIFIED | Per-source auto-download toggle |
| `Views/ArticleReaderView.swift` | MODIFIED | Cached HTML loading |
| `Models/DownloadModels.swift` | NEW | Download, DownloadRule, DownloadStatus, DownloadContentType enums |

---

## Open Questions

1. **Background downloads on simulator?** Background URL sessions don't work
   reliably on simulator. Testing requires physical device.

2. **iCloud sync for downloads?** Out of scope for v1. Downloads are local only.

3. **What about video?** YouTube content is excluded from offline v1. Streaming
   video requires different infrastructure (HLS, AVAssetDownloadTask).

4. **Audio formats?** AVPlayer supports mp3, m4a, aac, wav. Opus and ogg may
   not play on all devices. v1 supports mp3/m4a/aac only — others are skipped
   with a user-visible warning.

5. **Duplicate downloads across devices?** Same episode downloaded on iPhone
   and iPad are independent. No cross-device sync in v1.
