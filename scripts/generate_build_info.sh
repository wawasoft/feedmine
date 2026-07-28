#!/bin/bash
# generate_build_info.sh — inject git SHA, branch, and build timestamp
# into the app bundle so every binary is traceable to an exact commit.
#
# Usage: Add as an Xcode "Run Script" build phase BEFORE "Copy Bundle Resources":
#   bash "${PROJECT_DIR}/scripts/generate_build_info.sh" "${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"

set -euo pipefail

INFO_PLIST="${1:-}"

GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_EPOCH=$(date -u +%s)
XCODE_VERSION=$(xcodebuild -version 2>/dev/null | head -1 || echo "unknown")

if [ -n "$INFO_PLIST" ] && [ -f "$INFO_PLIST" ]; then
    /usr/libexec/PlistBuddy -c "Add :FeedmineGitSHA string ${GIT_SHA}" "$INFO_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :FeedmineGitSHA ${GIT_SHA}" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Add :FeedmineBuildDate string ${BUILD_DATE}" "$INFO_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :FeedmineBuildDate ${BUILD_DATE}" "$INFO_PLIST"
    echo "→ Build info written to Info.plist: SHA=${GIT_SHA} date=${BUILD_DATE}"
else
    echo "→ Build info: SHA=${GIT_SHA} branch=${GIT_BRANCH} tag=${GIT_TAG:-none} date=${BUILD_DATE}"
    echo "  Xcode: ${XCODE_VERSION}"
fi

# Always write a standalone JSON manifest for CI/release tooling
BUILD_INFO_DIR="${BUILT_PRODUCTS_DIR:-.}/BuildInfo"
mkdir -p "$BUILD_INFO_DIR"
cat > "${BUILD_INFO_DIR}/build.json" <<JSON
{
  "gitSHA": "${GIT_SHA}",
  "gitBranch": "${GIT_BRANCH}",
  "gitTag": "${GIT_TAG}",
  "buildDate": "${BUILD_DATE}",
  "buildEpoch": ${BUILD_EPOCH},
  "xcodeVersion": "${XCODE_VERSION}"
}
JSON
echo "→ Build info written to ${BUILD_INFO_DIR}/build.json"
