#!/bin/bash
# TestFlight delivery with a mandatory build ↔ commit pairing (review P1.5).
#
# The review could not state "TestFlight build 16 = SHA X" for the shipped binary: `scripts/generate_build_info.sh`
# existed but was wired into nothing (the committed project had no shell-script phase), so no build carried its commit.
# That phase now runs on the app target and stamps `FeedmineGitSHA`/`FeedmineBuildDate` into the bundled Info.plist before
# signing. This script is what keeps the pairing honest at delivery time:
#
#   * refuses a dirty working tree — an uploaded binary must be reproducible from a commit;
#   * archives, then **verifies the SHA inside the archive** against HEAD and aborts on a mismatch;
#   * uploads with the App Store Connect API key (the Xcode Apple-ID path fails on this machine);
#   * creates the local annotated tag `ios/<version>-build.<build>-<sha>` and prints the pairing.
#
# It never pushes: `git tag` is local, and pushing needs the user's word.
#
# Usage: scripts/release-testflight.sh [--dry-run]
#   --dry-run  stop after verifying the archived SHA and reporting the pairing (no upload, no tag)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_H3U55Z9WZ7.p8"
KEY_ID="H3U55Z9WZ7"
ISSUER_ID="0e1bd229-1284-4916-91d2-7bf989859bcc"
ARCHIVE=".build/feedmine.xcarchive"
EXPORT_OPTS=".build/ExportOptions.plist"

if [ -n "$(git status --porcelain)" ]; then
  echo "ABORTADO: working tree is dirty — commit first, or the uploaded binary maps to no SHA"
  git status --short | head -10
  exit 9
fi

SHA="$(git rev-parse HEAD)"
SHORT="$(git rev-parse --short HEAD)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' feedmine/Info.plist)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' feedmine/Info.plist)"
TAG="ios/$VERSION-build.$BUILD-$SHORT"

echo "== building $VERSION ($BUILD) from $SHORT =="
rm -rf "$ARCHIVE" .build/tf-export
if xcodebuild archive -project feedmine.xcodeproj -scheme feedmine -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$ARCHIVE" -allowProvisioningUpdates > /tmp/tf-archive.log 2>&1; then
  :
else
  echo "ABORTADO: archive falhou"; grep -aE 'error:' /tmp/tf-archive.log | head -5; exit 8
fi

APP="$ARCHIVE/Products/Applications/feedmine.app"
ARCHIVED_SHA="$(/usr/libexec/PlistBuddy -c 'Print :FeedmineGitSHA' "$APP/Info.plist" 2>/dev/null || echo "absent")"
ARCHIVED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist" 2>/dev/null || echo "?")"
echo "archived: version=$VERSION build=$ARCHIVED_BUILD sha=$ARCHIVED_SHA"
if [ "$ARCHIVED_SHA" != "$SHORT" ]; then
  echo "ABORTADO: the archive carries SHA '$ARCHIVED_SHA' but HEAD is '$SHORT' — the pairing is not proven"
  exit 8
fi
echo "PAIRING OK: TestFlight build $VERSION ($ARCHIVED_BUILD) = $SHA"

if [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN: archive verificado, nada foi enviado e nenhuma tag criada"
  exit 0
fi

if xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTS" \
  -exportPath .build/tf-export -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER_ID" > /tmp/tf-upload.log 2>&1; then
  grep -aE "Upload succeeded" /tmp/tf-upload.log | tail -1
else
  echo "ABORTADO: export/upload falhou"; grep -aE "error:" /tmp/tf-upload.log | head -5; exit 8
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "tag $TAG already exists"
else
  git tag -a "$TAG" -m "TestFlight $VERSION ($BUILD) [$SHORT]" "$SHA" && echo "tag $TAG created (local, not pushed)"
fi
echo "BUILD $VERSION ($BUILD) = $SHA  (tag $TAG)"
