# Task 1 Report: Download Models

**Status:** DONE

**Branch:** offline-features

## Commits Made

- `d72f8f8f` — `feat: add download models (enums, GRDB records, notification payload)`

## Files Created

- `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Models/DownloadModels.swift`

## Models Produced

- `DownloadStatus` — enum with states: queued, downloadingAudio, downloadingPage, completed, failedAudio, failedPage
- `DownloadMode` — enum: wifi, cellular
- `AutoDeletePolicy` — enum: afterRead, after7Days, manual
- `DownloadContentType` — enum: podcast, article
- `StorageGate` — equatable enum with allowed / insufficientFree / wouldExceedUserLimit / criticallyLow cases
- `DownloadNotification` — struct with nested `DownloadNotificationEvent` for toast system
- `DownloadRuleRecord` — GRDB record (`download_rule` table)
- `DownloadRecord` — GRDB record (`download` table)

## Build Verification

`xcodebuild` completed with zero errors.

## Concerns

None. Models are straightforward value types with no dependencies on other modules.

## Fix: DownloadModels review findings

**Commit:** `b08398e2`

**File:** `/Users/wagnermontes/Documents/GitHub/feedmine/feedmine/Models/DownloadModels.swift`

### Fix 1 (Medium) - Sendable conformance
Added `Sendable` to all public types:
- `DownloadStatus`, `DownloadMode`, `AutoDeletePolicy`, `DownloadContentType` - added `Sendable` to conformance list
- `StorageGate` - added `Sendable` alongside `Equatable`
- `DownloadNotification`, `DownloadNotification.DownloadNotificationEvent` - added `Sendable`
- `DownloadRuleRecord`, `DownloadRecord` - added `Sendable` to conformance

### Fix 2 (Medium) - Default values matching SQL column defaults
- `DownloadRuleRecord`: `maxItems: Int = 3`, `mode: String = "wifi"`, `enabled: Bool = true`
- `DownloadRecord`: `contentType: String = "podcast"`, `audioBytes: Int = 0`, `audioDownloaded: Int = 0`, `pageBytes: Int = 0`, `pageDownloaded: Int = 0`, `status: String = "queued"`

### Fix 3 (Low) - String raw type
Added `String` raw type to `DownloadNotificationEvent` enum.

### Build result
Build succeeded with zero errors on iOS Simulator (iPhone 14 Plus).
