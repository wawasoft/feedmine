# Feedmine Content Ingress & Egress Design

**Date:** 2026-07-11
**Status:** Approved
**Scope:** Share Extension, feed auto-discovery, OPML import via Share, rich text share output

## Overview

Feedmine currently has two content doors: bundled OPML files (immutable per build) and file-based OPML import via `fileImporter` in `SourceManagementView`. Content exits via `ShareLink` (link), `UIActivityViewController` (image card), and `UIPasteboard` (copy link).

This design adds a **Share Extension** as the primary ingress path — users discover content in Safari, Messages, or any app, tap Share → Feedmine, and the feed is queued for import. On the egress side, it adds **rich text sharing** with deep links back to Feedmine.

### Goals

- Let users add feeds naturally while browsing, without switching apps
- Accept URLs, OPML files, and text containing links via iOS Share
- Auto-discover RSS feeds from regular website URLs
- Preview discovered feeds before confirming import
- Share articles outward with rich text (title + excerpt + deep link)
- Keep the extension lightweight — heavy work stays in the main app

### Non-Goals

- Full feed reader inside the extension
- Background processing when the app is killed
- QR code / image-based feed URL detection
- Social media or analytics integrations on share outbound

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        APP GROUP                                │
│                   group.app.feedmine                            │
│                                                                 │
│  ┌──────────────────────┐    ┌──────────────────────────────┐   │
│  │   FeedmineShare      │    │        Feedmine (Main App)    │   │
│  │   (Extension Target) │    │                              │   │
│  │                      │    │   ┌──────────────────────┐   │   │
│  │  ShareReceiver       │    │   │ PendingItemsMonitor  │   │   │
│  │  • URL detection     │    │   │ (scenePhase.active)  │   │   │
│  │  • Text extraction   │    │   │ reads pending_queue  │   │   │
│  │  • OPML validation   │    │   └──────────┬───────────┘   │   │
│  │  • HTML fetch        │    │              │               │   │
│  │  • Feed discovery    │    │   ┌──────────▼───────────┐   │   │
│  │  • Queue writes ─────┼────┼──▶│ FeedDiscoverySheet   │   │   │
│  │                      │    │   │ (preview + confirm)  │   │   │
│  └──────────────────────┘    │   └──────────┬───────────┘   │   │
│                              │              │               │   │
│  pending_queue.json          │   ┌──────────▼───────────┐   │   │
│  (read/write via             │   │ FeedLoader           │   │   │
│   FileCoordinator)           │   │ .addSources()        │   │   │
│                              │   │ (persist + seed)     │   │   │
│                              │   └──────────────────────┘   │   │
│                              │                              │   │
│                              │   RichShareFormatter         │   │
│                              │   • título + excerpt         │   │
│                              │   • deep link feedmine://    │   │
│                              │   • fallback HTTP URL        │   │
│                              └──────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Design Principles

- **Extension is a scout, not a warehouse.** It finds feeds and writes pointers. The main app does all parsing, persistence, and UI.
- **App Group is the bridge.** A shared JSON file is the only communication channel — no SQLite from the extension, no Darwin notifications, no XPC.
- **Preview in the right place.** Feed auto-discovery happens in the extension (lightweight HTML parse). Feed content preview (items, titles, images) happens in the main app where FeedKit and the network stack are reliable.
- **Respect existing patterns.** `FeedLoader.addSources()` and `OPMLParser` already handle import — the new paths feed into them rather than duplicating logic.

---

## Component Details

### 1. App Group & Pending Queue

**Container:** `group.app.feedmine` (configured in Xcode project for both targets)

**`PendingQueue.swift`** — single source of truth, compiled into both targets via file reference (not target membership copy):

```swift
struct PendingQueue {
    static let containerURL: URL = {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.app.feedmine"
        )!.appendingPathComponent("pending_queue.json")
    }()

    struct Item: Codable, Identifiable {
        let id: String          // UUID
        let type: ItemType
        let sourceURL: String
        let foundFeeds: [DiscoveredFeed]
        let fileName: String?   // only for opml_import
        let feedCount: Int?     // only for opml_import
        let receivedAt: Int     // epoch seconds

        struct DiscoveredFeed: Codable {
            let title: String
            let url: String
        }
    }

    enum ItemType: String, Codable {
        case feedDirect = "feed_direct"
        case feedDiscovery = "feed_discovery"
        case opmlImport = "opml_import"
    }

    /// Append items from the extension. Uses FileCoordinator to avoid races.
    static func append(_ items: [Item]) { /* ... */ }

    /// Read all pending items. Called by main app on foreground.
    static func readAll() -> [Item] { /* ... */ }

    /// Clear the queue after successful processing.
    static func clear() { /* ... */ }
}
```

**Contract:**
- Extension writes only (append to `items` array), never reads or clears
- Main app reads, processes, and clears the entire queue atomically
- `NSFileCoordinator` with `NSFileCoordinatorWritingOptions.forMerging` guards writes
- Max 100 pending items; overflow drops oldest-first
- JSON is human-readable for debugging with Finder / Xcode

### 2. Share Extension (FeedmineShare)

**Target:** `FeedmineShare.appex`, embedded in Feedmine.app

**`Info.plist`** configures:
- `NSExtensionPrincipalClass` → `$(PRODUCT_MODULE_NAME).ShareViewController`
- `NSExtensionActivationRule` → `TRUEPREDICATE` with `NSExtensionActivationSupportsWebURLWithMaxCount: 5`, `NSExtensionActivationSupportsFileWithMaxCount: 1`, `NSExtensionActivationSupportsText: true`

**`ShareViewController`** — orchestrates the extension lifecycle:

1. Extract input items from `extensionContext.inputItems`
2. For each `NSExtensionItem`:
   - **URL attachment** → detect if it's a direct feed URL (`xml/rss/atom` path, YouTube feeds, known podcast hosts) or a regular website → run `FeedDiscoveryService` for website URLs
   - **File attachment** → if `pathExtension == "opml"`, validate XML root `<opml>`, write `opmlImport` item
   - **Text (`attributedContentText`)** → run `NSDataDetector` for URLs, process each as above
3. Write discovered items to `PendingQueue`
4. Present confirmation UI (`ShareView`)
5. Complete request with `.done` or dismiss

**`ShareView`** — single-screen SwiftUI:

```
┌─────────────────────────────────┐
│          ⬆️ Feedmine            │
│                                 │
│   ┌─────────────────────────┐   │
│   │  🌐 nytimes.com         │   │
│   │  2 feeds encontrados    │   │
│   └─────────────────────────┘   │
│                                 │
│   ┌─────────────────────────┐   │
│   │  📄 podcasts.opml       │   │
│   │  127 feeds detectados   │   │
│   └─────────────────────────┘   │
│                                 │
│   Enviado para o Feedmine  ✓    │
│                                 │
│           [Abrir Feedmine]       │
└─────────────────────────────────┘
```

**Timeout & error strategy:**
- HTML fetch timeout: 3 seconds per URL
- If fetch times out, still queue the item with `foundFeeds: []` — the main app will retry discovery
- The extension never shows an error for timeout — it delegates to the main app
- Only hard errors (no URL found, app group inaccessible) show an alert in the extension

### 3. Feed Auto-Discovery

**`FeedDiscoveryService`** — compiled into both targets:

```swift
struct FeedDiscoveryService {
    /// Known site → feed URL mappings, bundled and updatable.
    static let knownFeeds: [String: [DiscoveredFeed]] = [
        "nytimes.com": [DiscoveredFeed(title: "NYT Home", url: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml")],
        // ... ~50 popular domains
    ]

    /// Detect whether a URL is already a direct feed.
    static func isDirectFeedURL(_ url: URL) -> Bool {
        let path = url.pathExtension.lowercased()
        if ["xml", "rss", "atom"].contains(path) { return true }
        let absolute = url.absoluteString.lowercased()
        if absolute.contains("youtube.com/feeds") { return true }
        if absolute.hasSuffix("/feed") || absolute.hasSuffix("/rss") { return true }
        // Known podcast hosts
        if absolute.contains("anchor.fm") || absolute.contains("spreaker.com") { return true }
        return false
    }

    /// Discover RSS/Atom feeds from an HTML page.
    /// 1. Check knownFeeds dictionary (instant, no network)
    /// 2. Fetch HTML with 3s timeout
    /// 3. Parse for <link rel="alternate" type="application/rss+xml|atom+xml" href="...">
    /// 4. Fallback: regex scan for <a href="...rss">, <a href="...feed">
    /// 5. Resolve relative URLs to absolute
    static func discover(url: URL) async throws -> [DiscoveredFeed] { /* ... */ }
}
```

**Discovery priority:**
1. Known feeds dictionary (0 network, instant)
2. `<link rel="alternate">` meta tags (standards-compliant)
3. Anchor tag heuristics (last resort)

### 4. Pending Items Monitor (Main App)

**`PendingItemsMonitor`** — observes `scenePhase`:

```swift
@MainActor
final class PendingItemsMonitor {
    private let store: FeedStore
    private var lastProcessedIDs: Set<String> = []

    /// Called from FeedmineApp.onChange(of: scenePhase)
    func scenePhaseDidChange(_ phase: ScenePhase) {
        guard phase == .active else { return }
        let items = PendingQueue.readAll()
        let newItems = items.filter { !lastProcessedIDs.contains($0.id) }
        guard !newItems.isEmpty else { return }
        pendingItems = newItems
        showDiscoverySheet = true
    }

    /// Called when user confirms in FeedDiscoverySheet
    func processConfirmed(_ feeds: [FeedSource]) {
        store.registry.sources = OPMLParser.deduplicateSources(
            store.registry.sources + feeds
        )
        PendingQueue.clear()
        pendingItems = []
        showDiscoverySheet = false
    }
}
```

### 5. Feed Discovery Sheet (Main App)

**`FeedDiscoverySheet`** — presented as `.sheet` on `FeedScreen`:

```
┌─────────────────────────────────┐
│  New Feeds Found          [ ✕ ] │
│                                 │
│  🌐 nytimes.com                 │
│  ┌──────────────────────────┐   │
│  │ ☑ NYT Home Page          │   │
│  │   15 recent articles      │   │
│  │   • "Climate Report..."  │   │
│  │   • "Election Update..." │   │
│  │   • "Markets Rally..."   │   │
│  │              [Expand ▾]  │   │
│  └──────────────────────────┘   │
│  ┌──────────────────────────┐   │
│  │ ☑ NYT Technology         │   │
│  │ ⚠️ Already in Feedmine   │   │
│  └──────────────────────────┘   │
│                                 │
│  Category: [Imported ▾]         │
│                                 │
│  [Skip]              [Add All]  │
└─────────────────────────────────┘
```

**States:**
- **Loading:** Fetching feed contents — shows spinner per feed row
- **Loaded with items:** Shows feed title, item count, preview of 3 latest items (expandable to 10)
- **Already added:** Greyed out row with ⚠️ badge, checkbox disabled
- **Error:** Row shows "Couldn't reach feed" with retry button
- **Empty:** Row shows "No recent items" — user can still add

**OPML import variant** — shows a list of feeds from the OPML, grouped by category, with "Add All (N)" and individual toggles.

**Confirmation:** "Add All" calls `PendingItemsMonitor.processConfirmed()` with deduplicated `FeedSource` array. All new sources get `region: "imported"` and `category: "Imported"`.

### 6. Rich Share Output

**New context menu option** in `FeedItemView`:

```
[Share Link]        → ShareLink with URL (existing)
[Share as Image]    → renderCardAsImage, UIActivityViewController (existing)
[Share as Text]     → NEW: title + excerpt + link + "via Feedmine"
[Copy Link]         → UIPasteboard (existing)
```

**`RichShareFormatter`:**

```swift
struct RichShareFormatter {
    static func attributedString(for item: FeedItem) -> AttributedString {
        var str = AttributedString("\(item.title)\n\n")
        // title: bold, title3 size
        str += AttributedString("\(item.excerpt)\n\n")
        // excerpt: secondary color
        str += AttributedString("Read on Feedmine: feedmine://article/\(item.id)")
        // deep link: accent color
        return str
    }

    static func plainText(for item: FeedItem) -> String {
        """
        \(item.title)

        \(item.excerpt)

        Read on Feedmine: \(item.url)
        """
    }
}
```

**Deep link URL scheme** — `feedmine://` registered in main app `Info.plist`:
- `feedmine://article/{id}` → opens `ArticleReaderView` for that item
- `feedmine://` (bare) → opens the main feed

On iOS, `ShareLink` with an `AttributedString` automatically renders rich text in Messages, Mail, and other apps that support it. The `UIActivityViewController` path uses the plain text variant as fallback.

### 7. Existing Code Changes

**Minimal modifications to existing files:**

| File | Change |
|------|--------|
| `FeedItemView.swift` | Add "Share as Text" button to context menu, invoking `RichShareFormatter` |
| `FeedLoader.swift` | No changes — `addSources()` already handles imported feeds |
| `FeedStore.swift` | No changes needed |
| `SourceManagementView.swift` | Keep existing file importer as an alternative path; add note about Share Extension |
| `OPMLParser.swift` | No changes — `parseImportedFile(url:)` already handles external OPML |
| `project.yml` | Add `FeedmineShare` target with App Group entitlement |
| `feedmineApp.swift` | Add `PendingItemsMonitor` and observe `scenePhase` |
| `FeedScreen.swift` | Add `.sheet` modifier for `FeedDiscoverySheet` |

### 8. Edge Cases & Error Handling

| Scenario | Behavior |
|----------|----------|
| Feed URL already in SourceRegistry (exact match after `normalizeURL`) | Sheet shows "Already in Feedmine", checkbox disabled |
| Feed URL already in SourceRegistry (different URL, same content) | Added as new source — dedup only catches URL match |
| HTML page has no RSS links | Shows "No feeds found on this page — try sharing the RSS link directly" |
| Feed fetch timeout (main app) | "Couldn't reach feed — tap to retry", individual retry per feed row |
| Feed returns invalid XML | "This doesn't appear to be a valid feed", item skipped from results |
| OPML with 0 valid feeds after parsing | "No valid feeds found in this file" |
| Queue has 100+ pending items | Oldest items dropped, logged to console |
| App Group container inaccessible | Extension shows "Couldn't send to Feedmine — open the app and try manually" |
| User dismisses sheet without confirming | Items stay in queue, reappear on next foreground |
| Extension killed by iOS (timeout) | Items already written before fetch — partial results processed by main app |
| Multiple rapid shares from Safari | Each creates a separate queue item with unique UUID; all processed together |
| Deep link tapped when app not installed | iOS falls back to the HTTP URL in the plain text fallback |

### 9. File Structure

```
feedmine/
├── feedmine/                             # Main app target
│   ├── Services/
│   │   ├── PendingQueue.swift            # NEW — App Group JSON queue
│   │   ├── PendingItemsMonitor.swift     # NEW — scenePhase observer
│   │   ├── FeedDiscoveryService.swift    # NEW — HTML parse, RSS link detection
│   │   ├── RichShareFormatter.swift      # NEW — attributed string builder
│   │   └── FeedStore.swift              # No changes needed
│   │   └── FeedLoader.swift             # No changes needed
│   ├── Views/
│   │   ├── FeedDiscoverySheet.swift      # NEW — preview/confirm UI
│   │   ├── FeedItemView.swift           # MODIFIED — add "Share as Text"
│   │   └── FeedScreen.swift             # MODIFIED — add .sheet for discovery
│   ├── Models/
│   │   └── PendingItem.swift            # NEW — Codable queue item types
│   └── feedmineApp.swift                # MODIFIED — scenePhase observation
├── FeedmineShare/                        # NEW target
│   ├── ShareViewController.swift         # NEW — extension entry point
│   ├── ShareView.swift                   # NEW — extension UI
│   ├── Info.plist                        # NEW — extension config
│   └── FeedDiscoveryService.swift        # file reference to feedmine/ copy
├── Shared/                               # NEW — App Group shared code
│   └── PendingQueue.swift                # file reference to feedmine/ copy
└── feedmine.xcodeproj/                   # MODIFIED — add target, App Group capability
```

### 10. Implementation Sequence

| Step | Component | Dependencies | Estimated Complexity |
|------|-----------|-------------|---------------------|
| 1 | App Group entitlement + `PendingQueue.swift` | None — foundation for everything | Low |
| 2 | `FeedmineShare` target + basic URL receipt | Step 1 | Medium |
| 3 | `FeedDiscoveryService` | Step 1 | Medium |
| 4 | `PendingItemsMonitor` + `scenePhase` hook | Step 1 | Low |
| 5 | `FeedDiscoverySheet` (preview UI) | Steps 3, 4 | High |
| 6 | `RichShareFormatter` + context menu | None — independent | Low |
| 7 | OPML import via Share | Step 2 | Low |
| 8 | Edge cases & error handling | Steps 2-7 | Medium |
| 9 | Deep link `feedmine://` handling | Step 6 | Low |
| 10 | Testing & polish | All steps | Medium |

Total: ~10 steps, roughly 3-4 implementation sessions.

---

## Spec Self-Review

### Placeholder Scan
- ✅ No TBD, TODO, or incomplete sections
- ✅ All component behaviors are specified
- ✅ Error handling table covers all identified edge cases

### Internal Consistency
- ✅ PendingQueue contract: extension writes only, main app reads + clears — no conflicting access patterns
- ✅ FeedDiscoveryService is shared via file reference between both targets — consistent behavior
- ✅ FeedDiscoverySheet references the same `PendingQueue.Item` types as the extension
- ✅ All new feeds get `region: "imported"` — consistent with existing `addSources()` path

### Scope Check
- ✅ Focused on content ingress (Share Extension) and egress (rich text share)
- ✅ No feature creep — QR codes, analytics, social media excluded in Non-Goals
- ✅ Each component has a single responsibility

### Ambiguity Check
- ✅ "Direct feed URL" detection has explicit criteria (extensions, YouTube pattern, podcast hosts)
- ✅ Auto-discovery algorithm is ordered by priority with explicit fallbacks
- ✅ Queue overflow behavior is explicit (FIFO drop at 100)
- ✅ Timeout values are specified (3s HTML fetch, inherited system timeout for extension)
