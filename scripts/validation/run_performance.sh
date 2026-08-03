#!/bin/bash
# FeedMine Validation — Performance tests
#
# Performance gate using Release config, serial execution, and local fixtures.
# For official baselines, target a physical device (FEEDMINE_DEVICE_ID).
# Without a device, runs on simulator with INCONCLUSIVE status for physical gates.
#
# Usage:
#   # Simulator (informative only):
#   ./Scripts/validation/run_performance.sh
#
#   # Physical device (official baseline):
#   FEEDMINE_DEVICE_ID=00008110-00067D861486201E ./Scripts/validation/run_performance.sh device
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PROJECT="feedmine.xcodeproj"
SCHEME="feedmine"
PLATFORM="${1:-simulator}"

if [ "$PLATFORM" = "device" ]; then
    DEVICE_ID="${FEEDMINE_DEVICE_ID:-}"
    if [ -z "$DEVICE_ID" ]; then
        echo "❌ FEEDMINE_DEVICE_ID is required for physical device testing"
        echo "   Example: FEEDMINE_DEVICE_ID=00008110-00067D861486201E $0 device"
        exit 1
    fi
    DESTINATION="platform=iOS,id=$DEVICE_ID"
    DERIVED_DATA="$REPO_ROOT/.build-device"
    CONFIG="Release"
else
    SIM_NAME="${FEEDMINE_SIM_NAME:-iPhone 14 Plus}"
    DESTINATION="platform=iOS Simulator,name=$SIM_NAME"
    DERIVED_DATA="$REPO_ROOT/.build-dd"
    CONFIG="Release"
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_BUNDLE="$REPO_ROOT/Artifacts/Validation/Results/Performance-$TIMESTAMP.xcresult"

echo "⚡ Performance tests"
echo "   Config:      $CONFIG"
echo "   Platform:    $PLATFORM"
echo "   Destination: $DESTINATION"

# Step 1: Build for testing
echo ""
echo "🔨 Building for testing..."
xcodebuild build-for-testing \
    -project "$REPO_ROOT/$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    2>&1 | tail -3

# Step 2: Test without building (serial execution)
echo ""
echo "⚡ Running performance tests..."
xcodebuild test-without-building \
    -project "$REPO_ROOT/$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -testPlan "FeedMine-Performance" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$RESULT_BUNDLE" \
    2>&1 | grep -E "(Test Suite|Test Case.*failed|Executed|Failing|passed|failed)" || true

EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "📊 Result: $( [ $EXIT_CODE -eq 0 ] && echo "PASS" || echo "FAIL" )"
if [ "$PLATFORM" != "device" ]; then
    echo "⚠️  Simulator results are INFORMATIVE only — physical device gate is INCONCLUSIVE"
fi
echo "   Bundle: $RESULT_BUNDLE"

exit $EXIT_CODE
