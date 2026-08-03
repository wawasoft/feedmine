#!/bin/bash
# FeedMine Validation — Build-for-testing
#
# Builds the app once so subsequent test runs can use test-without-building.
# This reduces interference and ensures the same binary is measured.
#
# Usage:
#   ./Scripts/validation/build_for_validation.sh [debug|release] [simulator|device]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG="${1:-debug}"
PLATFORM="${2:-simulator}"

PROJECT="feedmine.xcodeproj"
SCHEME="feedmine"

# Resolve destination
if [ "$PLATFORM" = "device" ]; then
    DEVICE_ID="${FEEDMINE_DEVICE_ID:-00008110-00067D861486201E}"
    DESTINATION="platform=iOS,id=$DEVICE_ID"
    DERIVED_DATA="$REPO_ROOT/.build-device"
else
    SIM_NAME="${FEEDMINE_SIM_NAME:-iPhone 14 Plus}"
    DESTINATION="platform=iOS Simulator,name=$SIM_NAME"
    DERIVED_DATA="$REPO_ROOT/.build-dd"
fi

RESULT_BUNDLE="$REPO_ROOT/Artifacts/Validation/Results/Build-$(date +%Y%m%d-%H%M%S).xcresult"

echo "🔨 Build for testing"
echo "   Config:      $CONFIG"
echo "   Platform:    $PLATFORM"
echo "   Destination: $DESTINATION"
echo "   DerivedData: $DERIVED_DATA"

xcodebuild build-for-testing \
    -project "$REPO_ROOT/$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    2>&1 | tail -10

echo "✅ Build complete"
echo "   Result bundle: $RESULT_BUNDLE"
