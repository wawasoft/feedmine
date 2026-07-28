# Release Metadata

> Fill out one copy per App Store / TestFlight submission.
> Archive → attach to the git tag listed below.

## Build Identity

| Field | Value |
|---|---|
| Version | |
| Build | |
| Git SHA | |
| Git Tag | `ios/<version>-build.<build>-<sha>` |
| Archive checksum | `shasum -a 256 .build/feedmine.xcarchive` |
| Xcode | |
| macOS | |
| Catalog revision | |

## Gates

| Gate | Status |
|---|---|
| Unit tests (`make test-sim`) | ⬜ Passed / ⬜ Failed |
| UI tests (`make test-ui-sim`) | ⬜ Passed / ⬜ Failed |
| Static analysis (`make analyze`) | ⬜ Clean / ⬜ Warnings |
| Release build (`make build-release`) | ⬜ Passed / ⬜ Failed |
| Upgrade test (from previous build) | ⬜ Passed / ⬜ Failed |
| Clean install test | ⬜ Passed / ⬜ Failed |
| Slow network / offline test | ⬜ Passed / ⬜ Failed |
| Large OPML import | ⬜ Passed / ⬜ Failed |
| Low storage test | ⬜ Passed / ⬜ Failed |
| Background audio test | ⬜ Passed / ⬜ Failed |
| Instruments: Launch | ⬜ OK / ⬜ Regressed |
| Instruments: Memory | ⬜ OK / ⬜ Regressed |
| Instruments: Hangs | ⬜ OK / ⬜ Regressed |
| Device smoke test | ⬜ Passed / ⬜ Failed |

## Notes

<!-- Freeform: anything unusual about this build, known issues, deferred fixes -->
