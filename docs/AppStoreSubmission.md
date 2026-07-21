# App Store submission preflight

This document records the release facts and outstanding App Store Connect work
for FeedMine's first public iOS submission. It is a release checklist, not a
privacy policy or legal advice.

## Release facts

| Field | Current value |
|---|---|
| App name | FeedMine |
| Bundle ID | `com.feedmine.app` |
| Version / build | `1.0` / `2` |
| Minimum OS | iOS 18.0 |
| Devices | iPhone |
| Account required | No |
| Advertising / tracking SDK | None identified |
| In-app purchase | None identified |

## Privacy implementation

- `PrivacyInfo.xcprivacy` declares the required-reason APIs used by the app:
  - `UserDefaults` (`CA92.1`) for app-private settings.
  - File timestamps (`C617.1`) for local cache ordering and cleanup.
- The app does not include analytics, advertising, account, or tracking code in
  the current source audit.
- No location APIs or weather service are included in the release build.

## Completed release preparation

- [x] App Store Connect record created for `com.feedmine.app`.
- [x] App Store distribution certificate and provisioning profile created.
- [x] Release archive validated and uploaded to App Store Connect.
- [x] TestFlight build `1.0 (2)` accepted by Apple with status `VALID`.
- [x] Export compliance reported as no non-exempt encryption.
- [x] The release build was tested on a physical iPhone 14 Plus.

## Still required before App Review

- [ ] Publish the privacy-policy URL. The site route exists in source but must
  be deployed before it can be supplied to Apple.
- [ ] Set App Privacy answers to match the executable build.
- [ ] Supply App Store metadata: subtitle, description, keywords, support URL,
  marketing URL, copyright, category, age rating, and review contact.
- [ ] Capture the required iPhone screenshots from the approved release build.
- [ ] Add internal TestFlight testers (or create an external testing group and
  complete its beta review) as appropriate.

## Suggested App Review notes

FeedMine is a local-first RSS, podcast, YouTube, video, and forum reader. It
does not require an account. Users can add their own feeds or choose sources
from the bundled catalog. The app fetches public feed URLs directly and stores
reading state locally. It does not request the device's location.
