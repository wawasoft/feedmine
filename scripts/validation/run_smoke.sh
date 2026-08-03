#!/bin/bash
# FeedMine Validation — Smoke tests
#
# Fast functional gate intended to run on every PR.
# Uses Debug config + simulator + small fixtures.
#
# Usage:
#   ./Scripts/validation/run_smoke.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PROJECT="feedmine.xcodeproj"
SCHEME="feedmine"
SIM_NAME="${FEEDMINE_SIM_NAME:-iPhone 14 Plus}"
DERIVED_DATA="$REPO_ROOT/.build-dd"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULT_BUNDLE="$REPO_ROOT/Artifacts/Validation/Results/Smoke-$TIMESTAMP.xcresult"

echo "🧪 Smoke tests"
echo "   Simulator: $SIM_NAME"

xcodebuild test \
    -project "$REPO_ROOT/$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,name=$SIM_NAME" \
    -derivedDataPath "$DERIVED_DATA" \
    -configuration Debug \
    -testPlan "FeedMine-Smoke" \
    -resultBundlePath "$RESULT_BUNDLE" \
    2>&1 | grep -E "(Test Suite|Test Case.*failed|Executed|Failing|passed|failed)" || true

EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "📊 Result: $( [ $EXIT_CODE -eq 0 ] && echo "PASS" || echo "FAIL" )"
echo "   Bundle: $RESULT_BUNDLE"

exit $EXIT_CODE
