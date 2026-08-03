#!/bin/bash
# FeedMine Validation — Summarize .xcresult bundles into Markdown
#
# Usage:
#   ./Scripts/validation/summarize_results.sh Artifacts/Validation/Results/*.xcresult
set -euo pipefail

echo "# FeedMine Test Results"
echo ""
echo "**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "**Commit:** $(git rev-parse --short HEAD)"
echo "**Branch:** $(git branch --show-current)"
echo ""

for BUNDLE in "$@"; do
    if [ ! -d "$BUNDLE" ]; then
        echo "⚠️  Skipping missing bundle: $BUNDLE"
        continue
    fi

    BUNDLE_NAME="$(basename "$BUNDLE" .xcresult)"
    echo "## $BUNDLE_NAME"
    echo ""

    # Extract test summary using xcresulttool
    if xcrun xcresulttool get --path "$BUNDLE" --format json 2>/dev/null | \
        python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # Navigate to test summary
    issues = data.get('issues', {})
    test_failures = issues.get('testFailureSummaries', [])
    if not test_failures:
        tests = data.get('metrics', {}).get('testsCount', {})
        print(f\"  Tests: {tests.get('value', '?')}\")
        print(f\"  Failures: {tests.get('value', 0) and 0 or '?'}\")
        print('')
        print('✅ All tests passed')
    else:
        print(f'  ❌ {len(test_failures)} failure(s):')
        for f in test_failures[:10]:
            name = f.get('testCaseName', '?')
            msg = f.get('message', '')
            print(f'  - {name}: {msg[:120]}')
        print('')
except Exception as e:
    print(f'_Unable to parse xcresult: {e}_')
    print('_Run `xcrun xcresulttool get --path <bundle> --format json` manually_')
    print('')
" 2>/dev/null; then
        :
    else
        echo "_xcresulttool parsing failed — see raw bundle_"
    fi
done

echo ""
echo "---"
echo ""
echo "## Environment"
echo ""
echo "- **Xcode:** $(xcodebuild -version | head -1)"
echo "- **macOS:** $(sw_vers -productVersion)"
echo "- **Arch:** $(uname -m)"
echo "- **Host:** $(hostname)"
