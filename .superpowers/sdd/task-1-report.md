# Task 1 Report: Add SourceOrigin to FeedSource

## Summary

Added `SourceOrigin` enum and `origin` property to `FeedSource` as the foundation for distinguishing bundled, imported, and user-added feed sources.

## File Changed

- `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Models/FeedSource.swift`

## Exact Diff

```diff
 enum MediaKind: String, Codable, Sendable {
     case text
     case video
     case audio
 }

+enum SourceOrigin: String, Codable, Sendable {
+    case bundled   // from bundled OPML files
+    case imported  // user imported OPML file
+    case user      // user added via URL / share sheet
+}
+
 struct FeedSource: Codable, Identifiable, Sendable {
     var id: String { url }
     let title: String
     let url: String
     let category: String
     let region: String  // "global" | "countries/brazil"
     let mediaKind: MediaKind
+    let origin: SourceOrigin

     // ... computed properties unchanged ...

-    init(title: String, url: String, category: String, region: String = "global", mediaKind: MediaKind = .text) {
+    init(title: String, url: String, category: String, region: String = "global", mediaKind: MediaKind = .text, origin: SourceOrigin = .bundled) {
         self.title = title
         self.url = url
         self.category = category
         self.region = region
         self.mediaKind = mediaKind
+        self.origin = origin
     }

     enum CodingKeys: String, CodingKey {
-        case title, url, category, region, mediaKind = "media_kind"
+        case title, url, category, region, mediaKind = "media_kind", origin
     }

     init(from decoder: Decoder) throws {
         let c = try decoder.container(keyedBy: CodingKeys.self)
         title = try c.decode(String.self, forKey: .title)
         url = try c.decode(String.self, forKey: .url)
         category = try c.decode(String.self, forKey: .category)
         region = (try? c.decode(String.self, forKey: .region)) ?? "global"
         mediaKind = (try? c.decode(MediaKind.self, forKey: .mediaKind)) ?? .text
+        origin = (try? c.decode(SourceOrigin.self, forKey: .origin)) ?? .bundled
     }
 }
```

## Changes Made

1. **`SourceOrigin` enum** -- Added above `FeedSource` with three `String` cases: `.bundled`, `.imported`, `.user`. Conforms to `Codable` and `Sendable`.

2. **`origin: SourceOrigin` property** -- Added to `FeedSource` struct with `let` immutability.

3. **Memberwise `init`** -- Added `origin: SourceOrigin = .bundled` parameter (backwards-compatible default).

4. **`CodingKeys`** -- Added `origin` so Codable round-trips serialize/deserialize the new field.

5. **`init(from decoder:)`** -- Added fallback decoding with `?? .bundled` for backwards-compatible decoding of existing JSON.

## Build Result

**BUILD SUCCEEDED** -- no warnings or errors.

## Concerns

None. All existing `FeedSource(...)` call sites (e.g., `OPMLParser`) continue to compile without changes because `origin` defaults to `.bundled`, which is the correct origin for OPML-parsed sources.

## Commit

```
e75f355 feat: add SourceOrigin enum to FeedSource
```
