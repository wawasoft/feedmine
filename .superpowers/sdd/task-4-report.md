# Task 4: Restore 16:9 aspect ratio in heroBase

## Changed Files

| File | Line | Change |
|------|------|--------|
| `feedmine/Views/FeedItemCardView.swift` | 67 | Removed `.aspectRatio(16/9, contentMode: .fit)` from the podcast branch in `heroBase` |
| `feedmine/Views/FeedItemCardView.swift` | 81 | Added `.aspectRatio(16/9, contentMode: .fill)` as a common modifier on `heroBase` at the usage site in `portraitCard` |

## Summary

The 16:9 aspect ratio was previously applied only to the podcast branch inside `heroBase` (`@ViewBuilder`). The non-podcast branch used `.aspectRatio(contentMode: .fill)` without a ratio parameter, which relied on asset intrinsic dimensions — causing layout issues.

**Fix:** Removed the aspect ratio from the podcast branch inside `heroBase` and instead applied `.aspectRatio(16/9, contentMode: .fill)` as a common modifier on `heroBase` at the call site in `portraitCard` (line 81). This ensures both podcast and non-podcast heroes render at a consistent 16:9 aspect ratio. The `.fill` content mode is correct because the hero area is subsequently `.clipped()` (line 95), cropping any overflow while filling the 16:9 frame.

Note: The `.aspectRatio` modifier cannot be applied at the declaration level of a `@ViewBuilder` computed property in SwiftUI — it must be applied at the call site or wrapped in a `Group`. The modifier was therefore placed on `heroBase` in the `portraitCard` usage, before the `.overlay` chain.

## Build Verification

```
xcodebuild build -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 14 Plus'
** BUILD SUCCEEDED **
```
