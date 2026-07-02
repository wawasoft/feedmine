# In-App Article Reader — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- []) syntax for tracking.

**Goal:** Replace ArticlePreviewSheet modal with direct WKWebView article reader, keeping Safari button as fallback.

**Architecture:** Tap card → `.sheet(.large)` → `ArticleReaderView` with WKWebView → swipe down to dismiss. Single Safari button in toolbar for fallback.

**Tech Stack:** SwiftUI, WKWebView (via UIViewRepresentable), existing FeedItem model

## Global Constraints

- iOS 18+ deployment target (iPhone only)
- Swift 6 strict concurrency
- No new external dependencies
- BUILD SUCCEEDED before and after every commit

---

### Task 1: Create ArticleReaderView with WKWebView

**Files:**
- Create: `feedmine/Views/ArticleReaderView.swift`

**Interfaces:**
- Consumes: `FeedItem` (existing model)
- Produces: `ArticleReaderView` — sheet-ready view with WKWebView + Safari button

- [ ] **Step 1: Write ArticleReaderView.swift**

Create `feedmine/Views/ArticleReaderView.swift`:

```swift
import SwiftUI
import WebKit

struct ArticleReaderView: View {
    let item: FeedItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ArticleWebView(url: URL(string: item.url))
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.sourceTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let url = URL(string: item.url) {
                            Link(destination: url) {
                                Image(systemName: "safari")
                                    .font(.title3)
                            }
                        }
                    }
                }
        }
    }
}

// MARK: - WKWebView wrapper

struct ArticleWebView: UIViewRepresentable {
    let url: URL?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic

        if let url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build 2>&1 | grep -E 'error:|BUILD SUCCEEDED'`

Expected: `BUILD SUCCEEDED` (ArticleReaderView compiles but is not yet wired in FeedScreen)

- [ ] **Step 3: Commit**

```bash
git add feedmine/Views/ArticleReaderView.swift
git commit -m "feat: add ArticleReaderView with WKWebView and Safari fallback

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: Wire reader into FeedScreen, remove ArticlePreviewSheet

**Files:**
- Modify: `feedmine/Views/FeedScreen.swift` — replace preview with reader
- Delete: `feedmine/Views/ArticlePreviewSheet.swift`

- [ ] **Step 1: Update FeedScreen to use ArticleReaderView**

In `FeedScreen.swift`, change the tap action from `previewItem` to `articleItem`:
- Replace `@State private var previewItem: FeedItem?` with `@State private var articleItem: FeedItem?`
- Replace `.sheet(item: $previewItem) { item in ArticlePreviewSheet(item: item) }` with `.sheet(item: $articleItem) { item in ArticleReaderView(item: item) }`
- Replace `onOpen: { previewItem = item }` with `onOpen: { articleItem = item }`
- Update all other references from `previewItem` to `articleItem` (Surprise Me, date section card taps)

- [ ] **Step 2: Remove unused code**

- Remove `import SafariServices` from FeedScreen.swift (no longer needed)
- Remove `@State private var selectedArticle: ArticleRoute?` (no longer used)
- Remove `struct ArticleRoute` (no longer used)
- Remove private `struct SafariView` (no longer used)
- Remove `.sheet(item: $selectedArticle) { route in SafariView(url: route.url) }` modifier

- [ ] **Step 3: Delete ArticlePreviewSheet.swift**

```bash
rm feedmine/Views/ArticlePreviewSheet.swift
```

- [ ] **Step 4: Regenerate project and build**

Run: `xcodegen generate --spec project.yml --quiet 2>&1 && xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build 2>&1 | tail -3`

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add feedmine/Views/FeedScreen.swift feedmine.xcodeproj
git rm feedmine/Views/ArticlePreviewSheet.swift
git commit -m "feat: wire ArticleReaderView, remove ArticlePreviewSheet and SafariView

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Build for device and deploy

- [ ] **Step 1: Build for iPhone**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS,id=00008110-00067D861486201E' -allowProvisioningUpdates build
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 2: Install and launch**

```bash
xcrun devicectl device install app --device 00008110-00067D861486201E <app-path>
xcrun devicectl device process launch --device 00008110-00067D861486201E com.feedmine.app
```

- [ ] **Step 3: Manual verification**

1. Tap any card → sheet opens with full article via WKWebView
2. Safari button in top-right → opens system browser
3. X button (top-left) or swipe down → dismisses sheet, returns to feed
4. Scroll through article content smoothly
