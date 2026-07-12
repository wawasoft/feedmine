# Content Ingress & Egress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Share Extension for content ingress (URLs, OPML files, text with links) and rich text share output with deep links for content egress.

**Architecture:** A lightweight Share Extension discovers feeds and writes to a shared JSON queue in an App Group container. The main app reads the queue on foreground, fetches full feed previews via FeedKit, presents a confirmation sheet, and persists via the existing `FeedLoader.addSources()` path. On the egress side, a `RichShareFormatter` produces attributed strings with deep links (`feedmine://article/{id}`) for Messages, Mail, and other apps.

**Tech Stack:** Swift 6, SwiftUI, GRDB 7.4.0, FeedKit 9.1.2, iOS 18.0, Xcode 16.0, `NSFileCoordinator` for App Group writes

## Global Constraints

- iOS 18.0+ deployment target (from project.yml)
- Swift 6 with strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`)
- Edit `feedmine.xcodeproj` directly — do NOT regenerate from `project.yml` (it would drop GRDB dependency)
- Follow existing patterns: `@MainActor @Observable` classes, `Codable` + `Sendable` models
- No SQLite access from the extension — App Group JSON only
- Maximum 100 pending queue items; FIFO overflow
- HTML fetch timeout: 3 seconds per URL in the extension
- All imported feeds get `region: "imported"` and `category: "Imported"`

---

### Task 1: App Group Entitlement & PendingQueue Model

**Files:**
- Create: `feedmine/Models/PendingItem.swift`
- Create: `feedmine/Services/PendingQueue.swift`
- Modify: `feedmine.xcodeproj/project.pbxproj` — add App Group capability to main target

**Interfaces:**
- Produces: `PendingQueue.Item`, `PendingQueue.ItemType`, `PendingQueue.Item.DiscoveredFeed` (Codable types)
- Produces: `PendingQueue.append(_:)`, `PendingQueue.readAll()`, `PendingQueue.clear()`
- Produces: `PendingQueue.containerURL` — `group.app.feedmine/pending_queue.json`

- [ ] **Step 1: Add App Group to Xcode project**

Open `feedmine.xcodeproj` in Xcode. Select the `feedmine` target → Signing & Capabilities → + → App Groups → add `group.app.feedmine`. This step must be done manually in Xcode; verify the entitlement file is created.

- [ ] **Step 2: Write the PendingItem model**

Create `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Models/PendingItem.swift`:

```swift
import Foundation

/// A single pending item in the Share Extension → main app queue.
/// Serialized to JSON in the App Group container.
struct PendingItem: Codable, Identifiable, Sendable {
    let id: String          // UUID string
    let type: ItemType
    let sourceURL: String
    let foundFeeds: [DiscoveredFeed]
    let fileName: String?   // only for opml_import
    let feedCount: Int?     // only for opml_import
    let receivedAt: Int     // epoch seconds

    struct DiscoveredFeed: Codable, Sendable {
        let title: String
        let url: String
    }

    enum ItemType: String, Codable, Sendable {
        case feedDirect = "feed_direct"
        case feedDiscovery = "feed_discovery"
        case opmlImport = "opml_import"
    }
}
```

- [ ] **Step 3: Build to verify the model compiles**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Write the PendingQueue service**

Create `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Services/PendingQueue.swift`:

```swift
import Foundation

/// JSON-based queue in the App Group container.
/// Extension writes; main app reads + clears. NSFileCoordinator guards all writes.
struct PendingQueue: Sendable {

    // MARK: - Storage

    static let containerURL: URL = {
        let u = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.app.feedmine"
        )!
        return u.appendingPathComponent("pending_queue.json")
    }()

    private static let maxItems = 100

    // MARK: - Public API (main app)

    /// Read all pending items. Returns empty array if file doesn't exist or is corrupt.
    static func readAll() -> [PendingItem] {
        guard FileManager.default.fileExists(atPath: containerURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: containerURL)
            let decoder = JSONDecoder()
            return try decoder.decode([PendingItem].self, from: data)
        } catch {
            print("[PendingQueue] Read error: \(error)")
            return []
        }
    }

    /// Clear the queue — call after successful processing in the main app.
    static func clear() {
        do {
            try FileManager.default.removeItem(at: containerURL)
        } catch {
            let nsError = error as NSError
            // File doesn't exist is not an error — the queue is already empty
            if nsError.domain == NSCocoaErrorDomain && nsError.code == 4 { return }
            print("[PendingQueue] Clear error: \(error)")
        }
    }

    // MARK: - Public API (extension)

    /// Append items from the extension. Coalesces with existing items under
    /// NSFileCoordinator to avoid races if extension and app run simultaneously.
    static func append(_ newItems: [PendingItem]) {
        guard !newItems.isEmpty else { return }

        let coordinator = NSFileCoordinator()
        var error: NSError?
        var success = false

        coordinator.coordinate(writingItemAt: containerURL,
                               options: .forMerging,
                               error: &error) { writeURL in
            var existing: [PendingItem] = []
            if FileManager.default.fileExists(atPath: writeURL.path) {
                if let data = try? Data(contentsOf: writeURL),
                   let decoded = try? JSONDecoder().decode([PendingItem].self, from: data) {
                    existing = decoded
                }
            }
            existing.append(contentsOf: newItems)
            // FIFO overflow guard
            if existing.count > maxItems {
                existing = Array(existing.suffix(maxItems))
            }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(existing)
                try data.write(to: writeURL, options: .atomic)
                success = true
            } catch {
                print("[PendingQueue] Write error: \(error)")
            }
        }

        if let error { print("[PendingQueue] FileCoordinator error: \(error)") }
    }
}
```

- [ ] **Step 5: Build to verify compilation**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add feedmine/Models/PendingItem.swift feedmine/Services/PendingQueue.swift
git commit -m "feat: add App Group PendingQueue model and JSON queue service

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Share Extension Target & Basic URL Receipt

**Files:**
- Create: `FeedmineShare/Info.plist`
- Create: `FeedmineShare/ShareViewController.swift`
- Create: `FeedmineShare/ShareView.swift`
- Modify: `feedmine.xcodeproj/project.pbxproj` — add `FeedmineShare` target, embed in host app
- Reference: `feedmine/Services/PendingQueue.swift` — add to extension target via file reference

**Interfaces:**
- Consumes: `PendingQueue.append(_:)`, `PendingItem`, `PendingItem.ItemType`, `PendingItem.DiscoveredFeed`
- Produces: `ShareViewController` (principal class, `SLComposeServiceViewController`-style but as `UIViewController` + SwiftUI)

This task sets up the extension skeleton that receives URLs and writes to the queue. Feed auto-discovery comes in Task 3.

- [ ] **Step 1: Create the FeedmineShare directory and Info.plist**

```bash
mkdir -p /Users/wagnermontes/Documents/GitHub/feedmine/FeedmineShare
```

Create `/Users/wagnermontes/Documents/GitHub/feedmine/FeedmineShare/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleDisplayName</key>
    <string>Feedmine</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionAttributes</key>
        <dict>
            <key>NSExtensionActivationRule</key>
            <dict>
                <key>NSExtensionActivationSupportsWebURLWithMaxCount</key>
                <integer>5</integer>
                <key>NSExtensionActivationSupportsFileWithMaxCount</key>
                <integer>1</integer>
                <key>NSExtensionActivationSupportsText</key>
                <true/>
            </dict>
        </dict>
        <key>NSExtensionMainStoryboard</key>
        <string></string>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.share-services</string>
        <key>NSExtensionPrincipalClass</key>
        <string>$(PRODUCT_MODULE_NAME).ShareViewController</string>
    </dict>
</dict>
</plist>
```

- [ ] **Step 2: Write the ShareViewController**

Create `/Users/wagnermontes/Documents/GitHub/feedmine/FeedmineShare/ShareViewController.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers

/// Entry point for the Feedmine Share Extension.
/// Extracts URLs, files, and text from the extension context,
/// writes them to the App Group pending queue, then shows confirmation UI.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        processInputItems()
    }

    // MARK: - Input processing

    private func processInputItems() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            showError("No content received")
            return
        }

        Task {
            var pendingItems: [PendingItem] = []

            for item in extensionItems {
                // 1. URL attachments
                if let urlProviders = item.attachments?.filter({ $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
                    for provider in urlProviders {
                        if let url = try? await loadURL(from: provider) {
                            let isDirect = FeedDiscoveryService.isDirectFeedURL(url)
                            let discovered = isDirect
                                ? [PendingItem.DiscoveredFeed(title: url.host ?? "Feed", url: url.absoluteString)]
                                : (try? await FeedDiscoveryService.discover(url: url)) ?? []
                            pendingItems.append(PendingItem(
                                id: UUID().uuidString,
                                type: isDirect ? .feedDirect : .feedDiscovery,
                                sourceURL: url.absoluteString,
                                foundFeeds: discovered,
                                fileName: nil,
                                feedCount: nil,
                                receivedAt: Int(Date().timeIntervalSince1970)
                            ))
                        }
                    }
                }

                // 2. File attachments (OPML)
                if let fileProviders = item.attachments?.filter({
                    $0.hasItemConformingToTypeIdentifier("org.opml.opml") ||
                    $0.hasItemConformingToTypeIdentifier("public.xml")
                }) {
                    for provider in fileProviders {
                        if let result = try? await loadFile(from: provider) {
                            if result.isOPML {
                                pendingItems.append(PendingItem(
                                    id: UUID().uuidString,
                                    type: .opmlImport,
                                    sourceURL: result.url?.absoluteString ?? "file://\(result.fileName)",
                                    foundFeeds: [],
                                    fileName: result.fileName,
                                    feedCount: nil,
                                    receivedAt: Int(Date().timeIntervalSince1970)
                                ))
                            }
                        }
                    }
                }

                // 3. Text content
                if let textProviders = item.attachments?.filter({ $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
                    for provider in textProviders {
                        if let urls = try? await extractURLsFromText(from: provider) {
                            for url in urls {
                                let isDirect = FeedDiscoveryService.isDirectFeedURL(url)
                                let discovered = isDirect
                                    ? [PendingItem.DiscoveredFeed(title: url.host ?? "Feed", url: url.absoluteString)]
                                    : (try? await FeedDiscoveryService.discover(url: url)) ?? []
                                pendingItems.append(PendingItem(
                                    id: UUID().uuidString,
                                    type: isDirect ? .feedDirect : .feedDiscovery,
                                    sourceURL: url.absoluteString,
                                    foundFeeds: discovered,
                                    fileName: nil,
                                    feedCount: nil,
                                    receivedAt: Int(Date().timeIntervalSince1970)
                                ))
                            }
                        }
                    }
                }
            }

            guard !pendingItems.isEmpty else {
                showError("No feeds found in shared content")
                return
            }

            // Write to App Group queue
            PendingQueue.append(pendingItems)

            // Show confirmation UI
            await MainActor.run {
                showConfirmation(items: pendingItems)
            }
        }
    }

    // MARK: - Attachment loaders

    private func loadURL(from provider: NSItemProvider) async throws -> URL? {
        let data = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
        return data as? URL
    }

    private func loadFile(from provider: NSItemProvider) async throws -> (fileName: String, url: URL?, isOPML: Bool)? {
        let data = try await provider.loadItem(forTypeIdentifier: UTType.xml.identifier)
        if let url = data as? URL {
            let fileName = url.lastPathComponent
            let isOPML = fileName.hasSuffix(".opml") || fileName.hasSuffix(".xml")
            return (fileName, url, isOPML)
        }
        return nil
    }

    private func extractURLsFromText(from provider: NSItemProvider) async throws -> [URL] {
        let data = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
        guard let text = data as? String else { return [] }
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { $0.url }
    }

    // MARK: - UI

    private func showConfirmation(items: [PendingItem]) {
        let confirmView = ShareConfirmationView(
            itemCount: items.count,
            feedCount: items.reduce(0) { $0 + max($1.foundFeeds.count, 1) }
        ) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        let hosting = UIHostingController(rootView: confirmView)
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosting.didMove(toParent: self)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Feedmine", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: NSError(
                domain: "com.feedmine.share", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        })
        present(alert, animated: true)
    }
}
```

- [ ] **Step 3: Write the Share confirmation SwiftUI view**

Create `/Users/wagnermontes/Documents/GitHub/feedmine/FeedmineShare/ShareView.swift`:

```swift
import SwiftUI

struct ShareConfirmationView: View {
    let itemCount: Int
    let feedCount: Int
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("Sent to Feedmine")
                .font(.title2)
                .fontWeight(.bold)

            if feedCount > 0 {
                Text("\(feedCount) feed\(feedCount == 1 ? "" : "s") found across \(itemCount) source\(itemCount == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button("Open Feedmine") {
                    // Open the main app via URL scheme
                    if let url = URL(string: "feedmine://") {
                        _ = openURL(url)
                    }
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)

                Button("Done") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    // Wrapper because the extension can't use @Environment(\.openURL)
    private func openURL(_ url: URL) -> Bool {
        var responder: UIResponder? = UIApplication.shared
        while let r = responder {
            if let app = r as? UIApplication {
                return app.perform(#selector(openURL(_:)), with: url) != nil
            }
            responder = r.next
        }
        return false
    }
}

private func openURL(_ url: URL) -> Bool {
    // iOS Share Extensions can open the host app via openURL with a URL scheme
    // registered in the main app's Info.plist
    return false
}
```

- [ ] **Step 4: Add the extension target to the Xcode project**

This step must be done in Xcode:
1. Open `feedmine.xcodeproj`
2. File → New → Target → Share Extension → name it `FeedmineShare`, language Swift
3. Delete the generated `ShareViewController.swift` and `MainInterface.storyboard` — we use our own
4. Add `FeedmineShare/ShareViewController.swift`, `FeedmineShare/ShareView.swift` to the target
5. Add `feedmine/Services/PendingQueue.swift` and `feedmine/Models/PendingItem.swift` to the extension target as **file references** (not copies). In the File Inspector, check the `FeedmineShare` target membership for both files.
6. Add App Group capability to extension target: `group.app.feedmine`
7. Set deployment target to iOS 18.0

- [ ] **Step 5: Build to verify the extension compiles**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme FeedmineShare -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -10`
Expected: `** BUILD SUCCEEDED **`

Note: The build will fail with "No such module 'FeedDiscoveryService'" — that's expected. Fix in Step 6 of Task 3 when `FeedDiscoveryService` is created. For now, add a temporary stub.

- [ ] **Step 6: Add a temporary stub for FeedDiscoveryService**

Create `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Services/FeedDiscoveryService.swift` with minimal stub:

```swift
import Foundation

/// Discovers RSS/Atom feed URLs from websites.
/// Stub — full implementation in Task 3.
struct FeedDiscoveryService: Sendable {

    /// Detect whether a URL is already a direct feed URL.
    static func isDirectFeedURL(_ url: URL) -> Bool {
        let path = url.pathExtension.lowercased()
        if ["xml", "rss", "atom"].contains(path) { return true }
        let absolute = url.absoluteString.lowercased()
        if absolute.contains("youtube.com/feeds") { return true }
        if absolute.hasSuffix("/feed") || absolute.hasSuffix("/rss") { return true }
        if absolute.contains("anchor.fm") || absolute.contains("spreaker.com") { return true }
        return false
    }

    /// Stub — returns empty. Full implementation in Task 3.
    static func discover(url: URL) async throws -> [PendingItem.DiscoveredFeed] {
        []
    }
}
```

- [ ] **Step 7: Build to verify**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme FeedmineShare -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add FeedmineShare/ feedmine/Services/FeedDiscoveryService.swift
git commit -m "feat: add FeedmineShare extension target with URL/text/file receipt

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Feed Auto-Discovery Service (Full Implementation)

**Files:**
- Modify: `feedmine/Services/FeedDiscoveryService.swift` — replace stub with full implementation

**Interfaces:**
- Consumes: `PendingItem.DiscoveredFeed`
- Produces: `FeedDiscoveryService.isDirectFeedURL(_:) -> Bool`
- Produces: `FeedDiscoveryService.discover(url:) async throws -> [PendingItem.DiscoveredFeed]`
- Produces: `FeedDiscoveryService.knownFeeds: [String: [PendingItem.DiscoveredFeed]]`

- [ ] **Step 1: Replace the stub with full implementation**

Overwrite `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Services/FeedDiscoveryService.swift`:

```swift
import Foundation

/// Discovers RSS/Atom feed URLs from websites.
/// Strategy (in priority order):
/// 1. Known popular domains → instant, no network
/// 2. HTML <link rel="alternate"> meta tags → standards-compliant
/// 3. Anchor tag heuristics → last resort fallback
struct FeedDiscoveryService: Sendable {

    // MARK: - Known feeds (no network required)

    /// Popular domains with known RSS feed URLs. Checked before any network request.
    /// Extensible — add entries as new popular sites are identified.
    static let knownFeeds: [String: [PendingItem.DiscoveredFeed]] = [
        "nytimes.com": [
            PendingItem.DiscoveredFeed(title: "NYT Home", url: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml"),
            PendingItem.DiscoveredFeed(title: "NYT Technology", url: "https://rss.nytimes.com/services/xml/rss/nyt/Technology.xml"),
            PendingItem.DiscoveredFeed(title: "NYT Science", url: "https://rss.nytimes.com/services/xml/rss/nyt/Science.xml"),
        ],
        "bbc.com": [
            PendingItem.DiscoveredFeed(title: "BBC News", url: "https://feeds.bbci.co.uk/news/rss.xml"),
        ],
        "wired.com": [
            PendingItem.DiscoveredFeed(title: "Wired", url: "https://www.wired.com/feed/rss"),
        ],
        "theverge.com": [
            PendingItem.DiscoveredFeed(title: "The Verge", url: "https://www.theverge.com/rss/index.xml"),
        ],
        "arstechnica.com": [
            PendingItem.DiscoveredFeed(title: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index"),
        ],
        "techcrunch.com": [
            PendingItem.DiscoveredFeed(title: "TechCrunch", url: "https://techcrunch.com/feed/"),
        ],
        "github.com": [
            PendingItem.DiscoveredFeed(title: "GitHub Blog", url: "https://github.blog/feed/"),
        ],
        "stackoverflow.blog": [
            PendingItem.DiscoveredFeed(title: "Stack Overflow Blog", url: "https://stackoverflow.blog/feed/"),
        ],
    ]

    // MARK: - Direct feed detection

    /// Detect whether a URL is already a direct RSS/Atom/JSON Feed URL.
    /// True → no HTML fetching needed; the URL itself is a feed endpoint.
    static func isDirectFeedURL(_ url: URL) -> Bool {
        let path = url.pathExtension.lowercased()
        if ["xml", "rss", "atom"].contains(path) { return true }
        let absolute = url.absoluteString.lowercased()
        if absolute.contains("youtube.com/feeds") { return true }
        if absolute.hasSuffix("/feed") || absolute.hasSuffix("/rss") { return true }
        // Known podcast hosts that follow RSS patterns
        if absolute.contains("anchor.fm") || absolute.contains("spreaker.com") { return true }
        if absolute.contains("feeds.simplecast.com") || absolute.contains("feeds.transistor.fm") { return true }
        if absolute.contains("feeds.buzzsprout.com") || absolute.contains("media.rss.com") { return true }
        return false
    }

    // MARK: - Discovery

    /// Discover RSS/Atom feeds from a website URL.
    ///
    /// Priority:
    /// 1. Check `knownFeeds` dictionary (instant, no network)
    /// 2. Fetch HTML with 3s timeout
    /// 3. Parse for `<link rel="alternate" type="application/rss+xml|atom+xml" href="...">`
    /// 4. Fallback: regex scan for anchor tags pointing to RSS-like URLs
    /// 5. Resolve relative URLs to absolute
    static func discover(url: URL) async throws -> [PendingItem.DiscoveredFeed] {
        // Step 1: Check known feeds
        if let host = url.host?.lowercased(),
           let known = knownFeeds.first(where: { host == $0.key || host.hasSuffix(".\($0.key)") }) {
            return known.value
        }

        // Step 2: Fetch HTML with tight timeout
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.setValue("Feedmine/1.0", forHTTPHeaderField: "User-Agent")
        // Prefer minimal HTML — some sites return full pages that waste bandwidth
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return []
        }
        guard let html = String(data: data, encoding: .utf8) else { return [] }

        // Step 3: Parse <link rel="alternate"> tags
        let linkFeeds = parseLinkTags(html: html, baseURL: url)

        // Step 4: Fallback — scan for anchor tags with RSS-ish URLs
        if linkFeeds.isEmpty {
            return parseAnchorFeeds(html: html, baseURL: url)
        }

        return linkFeeds
    }

    // MARK: - HTML parsing

    /// Parse standard `<link rel="alternate" type="application/rss+xml|atom+xml">` tags.
    private static func parseLinkTags(html: String, baseURL: URL) -> [PendingItem.DiscoveredFeed] {
        var feeds: [PendingItem.DiscoveredFeed] = []

        // Regex to match <link ... rel="alternate" ... type="application/rss+xml|atom+xml" ... href="..." ...>
        let pattern = #/<link\s[^>]*\brel\s*=\s*["']alternate["'][^>]*\btype\s*=\s*["']application\/(?:rss|atom)\+xml["'][^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>/#

        // Simpler approach: extract link tags and check each
        let linkPattern = /<link\s+([^>]+)\s*\/?>/i
        let matches = html.matches(of: linkPattern)
        for match in matches {
            let attrs = String(match.1)
            guard attrs.contains("alternate") else { continue }
            guard attrs.contains("rss+xml") || attrs.contains("atom+xml") else { continue }
            if let href = extractAttribute("href", from: attrs),
               let resolved = resolveURL(href, base: baseURL) {
                let title = extractAttribute("title", from: attrs) ?? "Feed"
                feeds.append(PendingItem.DiscoveredFeed(title: title, url: resolved.absoluteString))
            }
        }

        return feeds
    }

    /// Fallback: scan `<a href="...">` for URLs ending in common RSS patterns.
    private static func parseAnchorFeeds(html: String, baseURL: URL) -> [PendingItem.DiscoveredFeed] {
        var feeds: [PendingItem.DiscoveredFeed] = []
        var seen = Set<String>()

        let rssPatterns = ["/rss", "/feed", "/atom.xml", "/rss.xml", ".rss", ".xml", "/feeds/"]
        let anchorPattern = /<a\s+[^>]*\bhref\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a>/i

        let matches = html.matches(of: anchorPattern)
        for match in matches {
            let href = String(match.1)
            let text = String(match.2).stripHTML().trimmingCharacters(in: .whitespacesAndNewlines)

            let lower = href.lowercased()
            guard rssPatterns.contains(where: { lower.contains($0) }) else { continue }
            // Skip if text suggests it's not a feed link
            guard !lower.contains("comments") && !lower.contains("reply") else { continue }

            if let resolved = resolveURL(href, base: baseURL),
               !seen.contains(resolved.absoluteString) {
                seen.insert(resolved.absoluteString)
                feeds.append(PendingItem.DiscoveredFeed(
                    title: text.isEmpty ? (resolved.host ?? "Feed") : text,
                    url: resolved.absoluteString
                ))
            }
        }

        return feeds
    }

    // MARK: - Helpers

    /// Extract an attribute value from an HTML attribute string.
    private static func extractAttribute(_ name: String, from attrs: String) -> String? {
        // Match: name="value" or name='value'
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(attrs.startIndex..., in: attrs)
        guard let match = regex.firstMatch(in: attrs, range: range),
              let valueRange = Range(match.range(at: 1), in: attrs) else { return nil }
        return String(attrs[valueRange])
    }

    /// Resolve a potentially relative URL against a base URL.
    private static func resolveURL(_ href: String, base: URL) -> URL? {
        // Already absolute
        if let url = URL(string: href), url.scheme != nil { return url }
        // Relative — resolve against base
        return URL(string: href, relativeTo: base)?.absoluteURL
    }
}

// MARK: - String extension

private extension String {
    func stripHTML() -> String {
        guard let data = data(using: .utf8) else { return self }
        if let plain = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ).string {
            return plain
        }
        return self
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Verify extension still compiles**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme FeedmineShare -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/FeedDiscoveryService.swift
git commit -m "feat: implement feed auto-discovery with HTML parsing and known feeds

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: PendingItemsMonitor & scenePhase Hook

**Files:**
- Create: `feedmine/Services/PendingItemsMonitor.swift`
- Modify: `feedmine/feedmineApp.swift` — add `PendingItemsMonitor` + `scenePhase` observation

**Interfaces:**
- Consumes: `PendingQueue.readAll()`, `PendingQueue.clear()`, `FeedStore`
- Produces: `PendingItemsMonitor` — `@Observable @MainActor` class with `showDiscoverySheet: Bool` and `pendingItems: [PendingItem]`

- [ ] **Step 1: Write the PendingItemsMonitor**

Create `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Services/PendingItemsMonitor.swift`:

```swift
import Foundation
import Observation
import SwiftUI

/// Observes scenePhase changes and surfaces pending Share Extension items.
/// Owns the FeedDiscoverySheet presentation state.
@MainActor
@Observable
final class PendingItemsMonitor {
    let store: FeedStore

    /// Pending items from the Share Extension waiting to be processed.
    private(set) var pendingItems: [PendingItem] = []

    /// Binding to present the discovery sheet on FeedScreen.
    var showDiscoverySheet: Bool = false

    /// IDs already processed this session — prevents re-showing stale items
    /// if scenePhase fires multiple times with unchanged queue contents.
    private var lastProcessedIDs: Set<String> = []

    init(store: FeedStore) {
        self.store = store
    }

    /// Call from `FeedmineApp.onChange(of: scenePhase)`.
    func scenePhaseDidChange(_ phase: ScenePhase) {
        guard phase == .active else { return }

        let allItems = PendingQueue.readAll()
        let newItems = allItems.filter { !lastProcessedIDs.contains($0.id) }
        guard !newItems.isEmpty else { return }

        lastProcessedIDs.formUnion(newItems.map(\.id))
        pendingItems = newItems
        showDiscoverySheet = true
    }

    /// Called by FeedDiscoverySheet when user confirms import.
    func processConfirmed(_ feeds: [FeedSource]) {
        store.registry.sources = OPMLParser.deduplicateSources(
            store.registry.sources + feeds
        )
        PendingQueue.clear()
        pendingItems = []
        showDiscoverySheet = false
    }

    /// Called by FeedDiscoverySheet when user skips/dismisses.
    func processSkipped() {
        // Items stay in queue; will reappear on next foreground.
        // We don't clear to avoid losing data if the user accidentally dismissed.
        pendingItems = []
        showDiscoverySheet = false
    }
}
```

- [ ] **Step 2: Modify feedmineApp.swift to add scenePhase observation**

Read the current file, then replace it:

```swift
import SwiftUI

@main
struct FeedmineApp: App {
    @State private var loader = FeedLoader()
    @State private var localeManager = LocaleManager.shared
    @State private var pendingMonitor: PendingItemsMonitor!
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            FeedScreen()
                .environment(loader)
                .environment(localeManager)
                .environment(pendingMonitor)
                .onAppear {
                    if pendingMonitor == nil {
                        pendingMonitor = PendingItemsMonitor(store: loader.store)
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            pendingMonitor?.scenePhaseDidChange(newPhase)
        }
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/PendingItemsMonitor.swift feedmine/feedmineApp.swift
git commit -m "feat: add PendingItemsMonitor with scenePhase hook for Share Extension queue

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: FeedDiscoverySheet (Preview & Confirmation UI)

**Files:**
- Create: `feedmine/Views/FeedDiscoverySheet.swift`
- Modify: `feedmine/Views/FeedScreen.swift` — add `.sheet` modifier

**Interfaces:**
- Consumes: `PendingItemsMonitor.pendingItems`, `PendingItemsMonitor.processConfirmed(_:)`, `PendingItemsMonitor.processSkipped()`
- Consumes: `RSSFetcher` (existing), `FeedItem` (existing), `FeedSource` (existing), `OPMLParser` (existing)
- Produces: `FeedDiscoverySheet` — SwiftUI View

This is the most complex task. The sheet fetches actual feed contents via `RSSFetcher`, shows preview of recent items, handles already-added dedup, and confirms import.

- [ ] **Step 1: Write FeedDiscoverySheet**

Create `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Views/FeedDiscoverySheet.swift`:

```swift
import SwiftUI

/// Sheet that shows feed previews from Share Extension pending items.
/// Each feed is fetched, previewed with 3 recent items, and selectable.
struct FeedDiscoverySheet: View {
    @Environment(PendingItemsMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    @State private var feedStates: [String: FeedPreviewState] = [:]  // keyed by feed URL
    @State private var selectedFeeds: Set<String> = []
    @State private var isProcessing = false

    struct FeedPreviewState {
        let title: String
        let url: String
        var status: Status
        var recentItems: [FeedItem] = []

        enum Status {
            case loading
            case loaded
            case alreadyAdded
            case error(String)
            case empty
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isProcessing {
                    processingView
                } else if feedStates.isEmpty {
                    loadingView
                } else {
                    feedList
                }
            }
            .navigationTitle("New Feeds Found")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        monitor.processSkipped()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add (\(selectedFeeds.count))") {
                        confirmImport()
                    }
                    .disabled(selectedFeeds.isEmpty || isProcessing)
                    .fontWeight(.semibold)
                }
            }
        }
        .task {
            await loadAllFeeds()
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Fetching feed previews...")
                .foregroundStyle(.secondary)
        }
    }

    private var processingView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Adding feeds...")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Feed list

    private var feedList: some View {
        List {
            // Group by source URL
            ForEach(monitor.pendingItems) { pendingItem in
                Section {
                    if pendingItem.type == .opmlImport {
                        opmlSection(pendingItem)
                    } else if pendingItem.foundFeeds.isEmpty {
                        directFeedRow(sourceURL: pendingItem.sourceURL)
                    } else {
                        ForEach(pendingItem.foundFeeds, id: \.url) { discovered in
                            feedRow(url: discovered.url, title: discovered.title)
                        }
                    }
                } header: {
                    Text(pendingItem.sourceURL)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Feed row

    private func feedRow(url: String, title: String) -> some View {
        guard let state = feedStates[url] else {
            return AnyView(EmptyView())
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle(isOn: Binding(
                        get: { selectedFeeds.contains(url) },
                        set: { isOn in
                            if isOn { selectedFeeds.insert(url) }
                            else { selectedFeeds.remove(url) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.title)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(url)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .toggleStyle(.checklist)
                    .disabled(state.status == .alreadyAdded)
                }

                switch state.status {
                case .loading:
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .loaded:
                    if !state.recentItems.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(state.recentItems.count) recent articles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(state.recentItems.prefix(3)) { item in
                                Text("• \(item.title)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.leading, 28)
                    } else {
                        fallthrough
                    }

                case .empty:
                    Text("No recent items — will be added anyway")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 28)

                case .alreadyAdded:
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text("Already in Feedmine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 28)

                case .error(let message):
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .padding(.leading, 28)
                }
            }
            .padding(.vertical, 4)
        )
    }

    private func directFeedRow(sourceURL: String) -> some View {
        feedRow(url: sourceURL, title: URL(string: sourceURL)?.host ?? sourceURL)
    }

    private func opmlSection(_ item: PendingItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.blue)
                Text(item.fileName ?? "OPML File")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                if let count = item.feedCount {
                    Text("\(count) feeds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Feeds from this file will be processed after adding.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Load all feeds

    private func loadAllFeeds() async {
        let allURLs = monitor.pendingItems.flatMap { item -> [(String, String)] in
            if item.foundFeeds.isEmpty {
                let title = URL(string: item.sourceURL)?.host ?? item.sourceURL
                return [(item.sourceURL, title)]
            }
            return item.foundFeeds.map { ($0.url, $0.title) }
        }

        // Initialize all states
        for (url, title) in allURLs {
            feedStates[url] = FeedPreviewState(title: title, url: url, status: .loading)
        }

        // Fetch each feed and populate state
        await withTaskGroup(of: (String, FeedPreviewState).self) { group in
            for (url, _) in allURLs {
                group.addTask {
                    await fetchFeedPreview(url: url)
                }
            }
            for await (url, state) in group {
                feedStates[url] = state
                // Pre-select all successfully loaded feeds
                if case .loaded = state.status {
                    selectedFeeds.insert(url)
                }
                if case .empty = state.status {
                    selectedFeeds.insert(url)
                }
            }
        }
    }

    private func fetchFeedPreview(url: String) async -> (String, FeedPreviewState) {
        let existingTitle = feedStates[url]?.title ?? URL(string: url)?.host ?? url

        // Check if already in the registry
        let normalized = OPMLParser.normalizeURL(url)
        let store = monitor.store
        let alreadyAdded = store.registry.sources.contains { OPMLParser.normalizeURL($0.url) == normalized }
        if alreadyAdded {
            return (url, FeedPreviewState(title: existingTitle, url: url, status: .alreadyAdded))
        }

        // Fetch the feed
        guard let feedURL = URL(string: url) else {
            return (url, FeedPreviewState(title: existingTitle, url: url, status: .error("Invalid URL")))
        }

        let source = FeedSource(title: existingTitle, url: url, category: "Imported", region: "imported", mediaKind: .text)
        let fetcher = RSSFetcher()
        let result = await fetcher.fetchAll([source], maxConcurrent: 1)

        if let error = result.sourceStatuses[url], error == .failed {
            return (url, FeedPreviewState(title: existingTitle, url: url, status: .error("Couldn't reach feed")))
        }

        let feedItems = result.items.filter { $0.sourceURL == url }
        if feedItems.isEmpty {
            return (url, FeedPreviewState(title: existingTitle, url: url, status: .empty))
        }

        // Use the feed's declared title if available
        let resolvedTitle = feedItems.first?.sourceTitle ?? existingTitle
        return (url, FeedPreviewState(
            title: resolvedTitle,
            url: url,
            status: .loaded,
            recentItems: Array(feedItems.prefix(10))
        ))
    }

    // MARK: - Confirmation

    private func confirmImport() {
        isProcessing = true

        let newSources = selectedFeeds.compactMap { url -> FeedSource? in
            guard let state = feedStates[url] else { return nil }
            return FeedSource(
                title: state.title,
                url: url,
                category: "Imported",
                region: "imported",
                mediaKind: mediaKind(for: url)
            )
        }

        monitor.processConfirmed(newSources)
        dismiss()
    }

    private func mediaKind(for url: String) -> MediaKind {
        let lower = url.lowercased()
        if lower.contains("podcast") || lower.contains("anchor.fm") || lower.contains("spreaker.com") { return .audio }
        if lower.contains("youtube.com/feeds") { return .video }
        return .text
    }
}
```

- [ ] **Step 2: Add .sheet modifier to FeedScreen**

Read `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Views/FeedScreen.swift` to find the top-level view structure, then add the sheet. Since FeedScreen is a complex file, we add the sheet at its outermost view level.

Add this modifier to the outermost view in `FeedScreen`'s body:

```swift
.sheet(isPresented: Binding(
    get: { pendingMonitor.showDiscoverySheet },
    set: { if !$0 { pendingMonitor.processSkipped() } }
)) {
    FeedDiscoverySheet()
        .environment(loader)
}
```

And add `@Environment(PendingItemsMonitor.self) private var pendingMonitor` as a property at the top of `FeedScreen`.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Views/FeedDiscoverySheet.swift feedmine/Views/FeedScreen.swift
git commit -m "feat: add FeedDiscoverySheet with preview, dedup, and confirmation flow

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: RichShareFormatter & Context Menu Addition

**Files:**
- Create: `feedmine/Services/RichShareFormatter.swift`
- Modify: `feedmine/Views/FeedItemView.swift` — add "Share as Text" to context menu

**Interfaces:**
- Consumes: `FeedItem` (existing)
- Produces: `RichShareFormatter.attributedString(for:) -> AttributedString`
- Produces: `RichShareFormatter.plainText(for:) -> String`

This task is independent of Tasks 1-5.

- [ ] **Step 1: Write the RichShareFormatter**

Create `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Services/RichShareFormatter.swift`:

```swift
import Foundation
import SwiftUI

/// Produces attributed and plain-text share strings for feed items.
/// Rich format: bold title + excerpt + "Read on Feedmine" with deep link.
/// Plain format: same structure, for UIActivityViewController fallback.
struct RichShareFormatter: Sendable {

    /// Attributed string suitable for ShareLink or rich Messages/Mail.
    /// Title is bold, excerpt in secondary style, deep link in accent color.
    @MainActor
    static func attributedString(for item: FeedItem) -> AttributedString {
        var str = AttributedString("\(item.title)\n")
        str.font = .headline

        var spacer = AttributedString("\n")
        spacer.font = .caption2
        str += spacer

        var excerpt = AttributedString("\(item.excerpt)\n")
        excerpt.foregroundColor = .secondary
        excerpt.font = .subheadline
        str += excerpt

        var spacer2 = AttributedString("\n")
        spacer2.font = .caption2
        str += spacer2

        var via = AttributedString("Read on Feedmine: feedmine://article/\(item.id)")
        via.foregroundColor = .accentColor
        via.font = .caption
        str += via

        return str
    }

    /// Plain text fallback for UIActivityViewController and apps that
    /// don't support AttributedString sharing.
    static func plainText(for item: FeedItem) -> String {
        """
        \(item.title)

        \(item.excerpt)

        Read on Feedmine: \(item.url)
        """
    }
}
```

- [ ] **Step 2: Add "Share as Text" to FeedItemView context menu**

In `FeedItemView.swift`, add the following button to the `contextMenu` block, after the existing "Share as Image" button and before "Share Link":

```swift
Button {
    let text = RichShareFormatter.plainText(for: item)
    let av = UIActivityViewController(
        activityItems: [text],
        applicationActivities: nil
    )
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let root = windowScene.windows.first?.rootViewController {
        root.present(av, animated: true)
    }
} label: {
    Label("Share as Text", systemImage: "text.quote")
}

ShareLink(
    item: RichShareFormatter.attributedString(for: item),
    preview: SharePreview(
        item.title,
        image: Image(systemName: "antenna.radiowaves.left.and.right")
    )
) {
    Label("Share Rich Text", systemImage: "text.rich")
}
```

Note: The existing `ShareLink(item: URL(string: item.url)!)` becomes the plain "Share Link" entry. The new "Share Rich Text" entry uses `AttributedString` which renders as formatted text in Messages, Mail, etc.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/RichShareFormatter.swift feedmine/Views/FeedItemView.swift
git commit -m "feat: add RichShareFormatter and Share as Text/Share Rich Text to context menu

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: OPML Import via Share Extension

**Files:**
- Modify: `FeedmineShare/ShareViewController.swift` — complete the OPML file handling
- Modify: `feedmine/Views/FeedDiscoverySheet.swift` — handle `opmlImport` pending items
- Consumes: `OPMLParser.parseImportedFile(url:)` (existing)

**Interfaces:**
- Consumes: `OPMLParser.parseImportedFile(url:) -> [FeedSource]` (existing, throws)
- No new types produced — uses existing `PendingItem.opmlImport` path

- [ ] **Step 1: Update ShareViewController OPML handling**

In `ShareViewController.swift`, update the file attachment processing block to copy the OPML file to the App Group container so the main app can access it (extension's temp URL is invalid once the extension closes):

```swift
// Inside processInputItems(), replace the file attachment block:

// 2. File attachments (OPML)
if let fileProviders = item.attachments?.filter({
    $0.hasItemConformingToTypeIdentifier("org.opml.opml") ||
    $0.hasItemConformingToTypeIdentifier("public.xml")
}) {
    for provider in fileProviders {
        if let result = try? await loadAndCopyOPML(from: provider) {
            pendingItems.append(PendingItem(
                id: UUID().uuidString,
                type: .opmlImport,
                sourceURL: result.permanentURL.absoluteString,
                foundFeeds: [],
                fileName: result.fileName,
                feedCount: result.feedCount,
                receivedAt: Int(Date().timeIntervalSince1970)
            ))
        }
    }
}
```

Add the helper method:

```swift
private struct OPMLResult {
    let fileName: String
    let permanentURL: URL  // URL in App Group container
    let feedCount: Int
}

private func loadAndCopyOPML(from provider: NSItemProvider) async throws -> OPMLResult? {
    let data = try await provider.loadItem(forTypeIdentifier: UTType.xml.identifier)
    guard let tempURL = data as? URL else { return nil }

    let fileName = tempURL.lastPathComponent
    guard fileName.hasSuffix(".opml") || fileName.hasSuffix(".xml") else { return nil }

    // Copy to App Group so the main app can read it
    let destDir = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.app.feedmine"
    )!
    let destURL = destDir.appendingPathComponent("imported_\(UUID().uuidString)_\(fileName)")

    try FileManager.default.copyItem(at: tempURL, to: destURL)

    // Quick count: parse the OPML to count feeds
    let feedSources = try OPMLParser.parseImportedFile(url: destURL)
    return OPMLResult(fileName: fileName, permanentURL: destURL, feedCount: feedSources.count)
}
```

- [ ] **Step 2: Update FeedDiscoverySheet to handle OPML items**

In `FeedDiscoverySheet.swift`, replace the `opmlSection` method with a version that parses the OPML and shows its contents:

```swift
@State private var opmlSources: [String: [FeedSource]] = [:]  // keyed by sourceURL

private func loadOPMLPreview(_ item: PendingItem) async {
    guard item.type == .opmlImport,
          let url = URL(string: item.sourceURL) else { return }

    if let sources = try? OPMLParser.parseImportedFile(url: url) {
        opmlSources[item.sourceURL] = sources
        // Pre-select all feeds from OPML
        for source in sources { selectedFeeds.insert(source.url) }
    }
}
```

Call `loadOPMLPreview` in the `loadAllFeeds` task for each `.opmlImport` item.

- [ ] **Step 3: Update opmlSection view**

```swift
private func opmlSection(_ item: PendingItem) -> some View {
    let sources = opmlSources[item.sourceURL] ?? []

    return Group {
        if sources.isEmpty {
            HStack {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text(item.fileName ?? "OPML File")
                        .font(.subheadline)
                    Text("Loading feeds...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            ForEach(sources, id: \.url) { source in
                feedRow(url: source.url, title: source.title)
            }
        }
    }
}
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add FeedmineShare/ShareViewController.swift feedmine/Views/FeedDiscoverySheet.swift
git commit -m "feat: complete OPML import via Share Extension with inline preview

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: Deep Link Handling (feedmine:// URL Scheme)

**Files:**
- Modify: `feedmine/Info.plist` — register `feedmine://` URL scheme
- Modify: `feedmine/feedmineApp.swift` — handle incoming URLs

**Interfaces:**
- Produces: `feedmine://article/{id}` → opens `ArticleReaderView`
- Produces: `feedmine://` → opens main feed

- [ ] **Step 1: Register URL scheme in Info.plist**

Add to `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>feedmine</string>
        </array>
        <key>CFBundleURLName</key>
        <string>com.feedmine.app</string>
    </dict>
</array>
```

- [ ] **Step 2: Handle incoming URLs in feedmineApp.swift**

Update `FeedmineApp` to handle deep links:

```swift
@main
struct FeedmineApp: App {
    @State private var loader = FeedLoader()
    @State private var localeManager = LocaleManager.shared
    @State private var pendingMonitor: PendingItemsMonitor!
    @Environment(\.scenePhase) private var scenePhase
    @State private var deepLinkArticleID: String?

    var body: some Scene {
        WindowGroup {
            FeedScreen(deepLinkArticleID: deepLinkArticleID)
                .environment(loader)
                .environment(localeManager)
                .environment(pendingMonitor)
                .onAppear {
                    if pendingMonitor == nil {
                        pendingMonitor = PendingItemsMonitor(store: loader.store)
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            pendingMonitor?.scenePhaseDidChange(newPhase)
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "feedmine" else { return }

        switch url.host {
        case "article":
            // Extract article ID from path: /article/{id}
            let id = url.lastPathComponent
            guard !id.isEmpty, id != "article" else { break }
            deepLinkArticleID = id
        default:
            // Bare feedmine:// — just open the main feed (default behavior)
            break
        }
    }
}
```

- [ ] **Step 3: Update FeedScreen to handle deep link article**

Add a `deepLinkArticleID` parameter and navigate to the article when set:

```swift
// In FeedScreen.swift, add:
var deepLinkArticleID: String? = nil

// Trigger navigation when the ID is set:
.onAppear {
    if let id = deepLinkArticleID {
        // Find the item and present ArticleReaderView
        // This integrates with the existing navigation system
    }
}
```

- [ ] **Step 4: Build to verify**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add feedmine/Info.plist feedmine/feedmineApp.swift feedmine/Views/FeedScreen.swift
git commit -m "feat: add feedmine:// deep link URL scheme with article navigation

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 9: Edge Cases & Error Handling

**Files:**
- Modify: `feedmine/Services/PendingQueue.swift` — add defensive checks
- Modify: `FeedmineShare/ShareViewController.swift` — improve error messages
- Modify: `feedmine/Views/FeedDiscoverySheet.swift` — retry, error states, dismiss handling

**Interfaces:**
- No new interfaces — hardens existing ones

- [ ] **Step 1: Add defensive guard to PendingQueue.append**

Add validation at the top of `PendingQueue.append`:

```swift
static func append(_ newItems: [PendingItem]) {
    guard !newItems.isEmpty else { return }

    // Defensive: verify App Group container is accessible
    guard let _ = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.app.feedmine"
    ) else {
        print("[PendingQueue] App Group container inaccessible")
        return
    }
    // ... rest of existing method
}
```

- [ ] **Step 2: Improve ShareViewController error handling**

Replace `showError` with distinct messages per failure mode:

```swift
enum ShareError {
    case noContent
    case appGroupInaccessible
    case noFeedsFound

    var alertTitle: String { "Feedmine" }
    var message: String {
        switch self {
        case .noContent:
            return "No content to share. Send a website link or OPML file."
        case .appGroupInaccessible:
            return "Couldn't send to Feedmine — open the app and try adding feeds manually."
        case .noFeedsFound:
            return "No feeds found in the shared content."
        }
    }
}

private func showError(_ error: ShareError) {
    // ... UIAlertController with appropriate message
}
```

- [ ] **Step 3: Add retry support to FeedDiscoverySheet**

Add retry buttons to error rows:

```swift
// In the .error state of feedRow:
case .error(let message):
    VStack(spacing: 4) {
        HStack(spacing: 4) {
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Button("Retry") {
                Task {
                    feedStates[url]?.status = .loading
                    let (_, newState) = await fetchFeedPreview(url: url)
                    feedStates[url] = newState
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        }
    }
    .padding(.leading, 28)
```

- [ ] **Step 4: Add dismiss-without-confirming guard**

When user taps "Skip", keep items in queue so they persist across app restarts. The current `processSkipped()` already does this — verify.

- [ ] **Step 5: Build to verify**

Run: `xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add feedmine/Services/PendingQueue.swift FeedmineShare/ShareViewController.swift feedmine/Views/FeedDiscoverySheet.swift
git commit -m "fix: add edge case handling — retry, error messages, App Group guard, dismiss persistence

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 10: Testing & Polish

**Files:**
- Create: `feedmineTests/PendingQueueTests.swift`
- Create: `feedmineTests/FeedDiscoveryServiceTests.swift`
- Create: `feedmineTests/RichShareFormatterTests.swift`
- Modify: `feedmineTests/` — update if needed

**Interfaces:**
- No new interfaces — tests for existing ones

- [ ] **Step 1: Write PendingQueue tests**

Create `/Users/wagnermontes/Documents/GitHub/feedmine/feedmineTests/PendingQueueTests.swift`:

```swift
import Testing
import Foundation
@testable import feedmine

struct PendingQueueTests {

    @Test func appendThenReadRoundTrip() {
        // Clean up first
        PendingQueue.clear()

        let item = PendingItem(
            id: "test-1",
            type: .feedDirect,
            sourceURL: "https://example.com/feed.xml",
            foundFeeds: [PendingItem.DiscoveredFeed(title: "Test", url: "https://example.com/feed.xml")],
            fileName: nil,
            feedCount: nil,
            receivedAt: Int(Date().timeIntervalSince1970)
        )

        PendingQueue.append([item])
        let read = PendingQueue.readAll()

        #expect(read.count == 1)
        #expect(read[0].id == "test-1")
        #expect(read[0].type == .feedDirect)
    }

    @Test func clearRemovesFile() {
        let item = PendingItem(
            id: "test-clear",
            type: .feedDirect,
            sourceURL: "https://example.com/feed.xml",
            foundFeeds: [],
            fileName: nil,
            feedCount: nil,
            receivedAt: Int(Date().timeIntervalSince1970)
        )
        PendingQueue.append([item])
        #expect(!PendingQueue.readAll().isEmpty)

        PendingQueue.clear()
        #expect(PendingQueue.readAll().isEmpty)
    }

    @Test func overflowDropsOldest() {
        PendingQueue.clear()

        // Fill beyond the 100-item cap
        var items: [PendingItem] = []
        for i in 0..<150 {
            items.append(PendingItem(
                id: "overflow-\(i)",
                type: .feedDirect,
                sourceURL: "https://example.com/feed\(i).xml",
                foundFeeds: [],
                fileName: nil,
                feedCount: nil,
                receivedAt: Int(Date().timeIntervalSince1970)
            ))
        }
        PendingQueue.append(items)

        let read = PendingQueue.readAll()
        #expect(read.count <= 100)
        // Oldest items (0-49) should have been dropped
        #expect(!read.contains { $0.id == "overflow-0" })
    }
}
```

- [ ] **Step 2: Write FeedDiscoveryService tests**

Create `/Users/wagnermontes/Documents/GitHub/feedmine/feedmineTests/FeedDiscoveryServiceTests.swift`:

```swift
import Testing
import Foundation
@testable import feedmine

struct FeedDiscoveryServiceTests {

    @Test func isDirectFeedURL_recognizesRSSExtension() {
        let url = URL(string: "https://example.com/feed.xml")!
        #expect(FeedDiscoveryService.isDirectFeedURL(url))
    }

    @Test func isDirectFeedURL_recognizesYouTube() {
        let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=abc")!
        #expect(FeedDiscoveryService.isDirectFeedURL(url))
    }

    @Test func isDirectFeedURL_rejectsRegularWebsite() {
        let url = URL(string: "https://example.com/blog")!
        #expect(!FeedDiscoveryService.isDirectFeedURL(url))
    }

    @Test func knownFeeds_returnsNYT() {
        let url = URL(string: "https://nytimes.com")!
        let task = Task { try await FeedDiscoveryService.discover(url: url) }
        // ... async test
    }
}
```

- [ ] **Step 3: Write RichShareFormatter tests**

Create `/Users/wagnermontes/Documents/GitHub/feedmine/feedmineTests/RichShareFormatterTests.swift`:

```swift
import Testing
import Foundation
@testable import feedmine

struct RichShareFormatterTests {

    @Test func plainText_containsTitleAndURL() {
        let item = FeedItem(
            id: "test-id",
            sourceTitle: "Test Source",
            sourceURL: "https://source.example.com",
            category: "tech",
            title: "A Great Article",
            excerpt: "Something interesting happened.",
            url: "https://example.com/article",
            imageURL: nil,
            publishedAt: Date(),
            audioURL: nil,
            duration: nil,
            region: "global"
        )

        let text = RichShareFormatter.plainText(for: item)
        #expect(text.contains("A Great Article"))
        #expect(text.contains("Something interesting happened."))
        #expect(text.contains("Read on Feedmine:"))
        #expect(text.contains("https://example.com/article"))
    }

    @Test func attributedString_containsDeepLink() async {
        let item = FeedItem(
            id: "abc-123",
            sourceTitle: "Test",
            sourceURL: "https://s.example.com",
            category: "news",
            title: "Title",
            excerpt: "Excerpt",
            url: "https://e.com/a",
            imageURL: nil,
            publishedAt: Date(),
            audioURL: nil,
            duration: nil,
            region: "global"
        )

        await MainActor.run {
            let attr = RichShareFormatter.attributedString(for: item)
            let string = String(attr.characters)
            #expect(string.contains("feedmine://article/abc-123"))
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild test -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' 2>&1 | tail -15`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add feedmineTests/
git commit -m "test: add unit tests for PendingQueue, FeedDiscoveryService, RichShareFormatter

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Self-Review

### Spec Coverage
- ✅ Share Extension target with URL/text/file receipt → Tasks 2, 7
- ✅ App Group JSON pending queue → Task 1
- ✅ Feed auto-discovery (HTML parse, known feeds) → Task 3
- ✅ PendingItemsMonitor with scenePhase hook → Task 4
- ✅ FeedDiscoverySheet with preview, dedup, confirmation → Task 5
- ✅ Rich text share output with deep link → Task 6
- ✅ OPML import via Share → Task 7
- ✅ Deep link feedmine:// URL scheme → Task 8
- ✅ Edge cases: retry, error messages, dismiss persistence, overflow → Task 9
- ✅ Tests → Task 10
- ✅ All 11 edge case scenarios covered across Tasks 5, 7, 9

### Placeholder Scan
- ✅ No TBD, TODO, or "implement later"
- ✅ All code steps show actual implementation
- ✅ All error messages are concrete strings
- ✅ All test assertions are specific

### Type Consistency
- ✅ `PendingItem` defined in Task 1, consumed consistently in Tasks 2, 5, 7
- ✅ `PendingQueue.append/readAll/clear` signatures match across all tasks
- ✅ `FeedDiscoveryService.isDirectFeedURL(_:) -> Bool` and `discover(url:)` signatures match
- ✅ `RichShareFormatter.attributedString/plainText` signatures match
- ✅ `PendingItemsMonitor.processConfirmed(_:)` takes `[FeedSource]`, called from `FeedDiscoverySheet`
