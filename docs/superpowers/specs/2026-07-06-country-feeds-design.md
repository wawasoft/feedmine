# Country Feeds — Design Spec

**Date:** 2026-07-06
**Context:** feedmine iOS app — integrate 97 country OPML files as a dynamic, data-driven global feeds section.

## Overview

Add a "Countries" screen to feedmine where users can browse and toggle country-specific RSS feeds. The system is fully data-driven: adding or modifying a `.opml` file in `Resources/Feeds/countries/` automatically updates the app with zero code changes.

Country feeds are separate from the main topic feeds — their categories do not mix with global categories. Users toggle countries on/off, and when enabled, those feeds contribute articles to the main feed alongside existing content.

## Data Model

### FeedSource — add `region`

```swift
struct FeedSource: Codable, Identifiable, Sendable {
    var id: String { url }
    let title: String
    let url: String
    let category: String
    let region: String  // "global" | "countries/brazil" | "countries/japan" | ...
}
```

- `"global"` — feeds from root-level OPML files (`tech.opml`, `blogs.opml`, etc.)
- `"countries/brazil"` — feeds from `countries/brazil.opml`
- Derived from the OPML file path during parsing

### Country — derived display struct

```swift
struct Country: Identifiable {
    var id: String { region }
    var name: String       // "Brazil"
    var flag: String       // "🇧🇷"
    var feedCount: Int
    var categories: [String]
}
```

- Name and flag derived from filename: `brazil` → `"Brazil"`, `"🇧🇷"`
- Mapping stored as a static dictionary in `CountryStore`; missing countries use the capitalized filename and no flag
- Not persisted — computed from current sources at launch

## FeedLoader Changes

New properties:
- `disabledRegions: Set<String>` — persisted alongside `disabledSourceIDs`
- `availableCountries: [Country]` — computed from `sources`, grouped by region

New methods:
- `func toggleRegion(_ region: String)` — bulk enable/disable all sources in a region
- `func isRegionEnabled(_ region: String) -> Bool`
- `func toggleAllCountries()` — enable all country regions, or disable all if currently enabled
- `func countryFeeds(for region: String) -> [FeedSource]` — grouped by category

Filtering rule: `enabledSources` excludes sources whose region is disabled AND sources individually disabled via `disabledSourceIDs`.

## OPMLParser Changes

`parseFile(url:fallbackCategory:)` now computes `region` from the file URL:
- Files directly in `Feeds/` → region = `"global"`
- Files in `Feeds/countries/` → region = `"countries/<filenameWithoutExtension>"`

## UI

### CountriesListScreen (new)

- NavigationStack with title "Countries"
- Top: "🌐 All Countries" master toggle
- List of `Country` rows, each with flag + name + feed count + enable/disable toggle
- Footer: "N countries · M feeds"
- Tapping a row navigates to CountryDetailScreen
- Access via new row in Settings

### CountryDetailScreen (new)

- Back navigation: "← 🇧🇷 Brazil"
- Header: flag + name + feed count
- Sections grouped by category (News, Sports, Tech, etc.)
- Each section has a header with category name + feed count
- Per-feed row: title + enable/disable toggle
- Sections are collapsible

### SettingsSheetView (modify)

- New "Countries" row under a new "Feeds" section
- Tapping navigates to CountriesListScreen

## Behavior

- **"All Countries" ON**: all country feeds contribute articles to the main feed; per-country toggles still work to exclude specific countries
- **"All Countries" OFF**: no country feeds appear; per-country toggles have no effect
- **Per-feed toggle OFF**: that specific feed is excluded even if its country is enabled
- **Adding a new country**: drop `countries/sweden.opml` into the bundle → appears automatically on next parse
- **Removing a country**: delete the file → feeds and country entry disappear on next parse
- **Modifying a country**: edit feeds in the OPML → changes picked up on next parse

## Persistence

- `disabledRegions` saved in `FeedState` / `PersistenceManager`
- `disabledSourceIDs` continues to work for per-feed toggles, including country feeds
- No migration needed — new field defaults to empty set

## Edge Cases

- Three OPML files have XML parse errors (Ecuador, Romania, Taiwan) — skip gracefully, don't show in country list
- Countries with 0 feeds after validation — still show in list with count 0
- Country filename with hyphens (`costa-rica`, `south-africa`) — handle in name/flag mapping
- Duplicate URLs across countries — already handled by existing dedup logic
- User disables a country while reading its articles — articles stay visible (already loaded), just no new ones appear

## Out of Scope

- Per-country sort/customization
- Country search/filter bar (can add later)
- Country-specific palettes or themes
- iCloud sync of country preferences (uses existing persistence)
