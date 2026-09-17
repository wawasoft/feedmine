#!/bin/bash
# Release gate — the whole bar: three consecutive unit gates over the committed target, then the journey.
#
# Exits non-zero unless every gate reports `** TEST SUCCEEDED **` and the journey reports 17/17 required surfaces. Each gate
# starts from the same container state (`simctl uninstall` between gates): the unit tests run inside the app's own process
# and write its UserDefaults and page caches, and a gate that inherits the previous gate's container measured a 36.9–37.1 s
# page-publication wait in `FeedLoaderCacheTests.testFilteredDateSectionsPreserveProviderOrderAcrossDates` (normally 0.32 s)
# because the debounced reload is dropped by a generation the test never asked for. Cleaning between gates removed the stall
# and 60–100 s of wall clock per gate.
#
# The journey runs from a clean container too: it measures warm-start behaviour, and a container carrying unit-test junk
# once made it restore a 1-item page slot.
#
# Usage: scripts/release-acceptance.sh
#   env: FEEDMINE_SIM_UDID (default: the iPhone 16 used by the release lane)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
S="${FEEDMINE_SIM_UDID:-2F70B5E4-DF56-428C-A7B9-0A769B6CAC3D}"
SHOTS=/tmp/feedmine-persona-screenshots
LANE=/tmp/feedmine-lane.lock

release_lane() { rm -f "$LANE/holder" 2>/dev/null || true; rmdir "$LANE" 2>/dev/null || true; }
acquire() {
  for _ in $(seq 1 120); do
    if mkdir "$LANE" 2>/dev/null; then
      echo "$$ $(date +%s)" > "$LANE/holder"
      trap 'release_lane' EXIT
      return 0
    fi
    H=$(awk '{print $1}' "$LANE/holder" 2>/dev/null || true)
    AGE=$(( $(date +%s) - $(awk '{print $2}' "$LANE/holder" 2>/dev/null || echo "$(date +%s)") ))
    reclaim() { echo "RECLAIM: $1"; rm -f "$LANE/holder" 2>/dev/null || true; rmdir "$LANE" 2>/dev/null || rm -rf "$LANE"; }
    if [ -n "$H" ] && ! kill -0 "$H" 2>/dev/null; then reclaim "holder pid $H is gone"; continue; fi
    if [ "$AGE" -gt 900 ] 2>/dev/null && ! pgrep -f "xcodebuild|simctl" >/dev/null; then reclaim "lock age ${AGE}s idle"; continue; fi
    sleep 10
  done
  echo "ABORTADO: lane lock held by pid ${H:-?}"; exit 9
}

acquire
echo "== acceptance bar start $(date '+%H:%M:%S') at $(git rev-parse --short HEAD) =="
xcrun simctl shutdown "$S" 2>/dev/null || true; sleep 3
xcrun simctl boot "$S" 2>/dev/null || true
xcrun simctl bootstatus "$S" -b >/dev/null 2>&1 || true
xcrun simctl uninstall "$S" com.feedmine.app 2>/dev/null || true
rm -rf "$SHOTS"
xcodebuild build-for-testing -project feedmine.xcodeproj -scheme feedmine \
  -destination "platform=iOS Simulator,name=iPhone 16" > /tmp/feedmine-acceptance-build.log 2>&1
BE=$(grep -acE 'error:' /tmp/feedmine-acceptance-build.log || true)
echo "build-erros: $BE"
if [ "$BE" != "0" ]; then
  echo "ABORTADO: o build falhou; nenhuma medicao e valida contra build velho"
  grep -aE 'error:' /tmp/feedmine-acceptance-build.log | sed 's|.*/feedmine/||' | sort -u | head -12
  exit 8
fi

FAILED=0
for g in 1 2 3; do
  xcrun simctl uninstall "$S" com.feedmine.app 2>/dev/null || true
  xcodebuild test-without-building -project feedmine.xcodeproj -scheme feedmine \
    -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:feedmineTests > "/tmp/feedmine-gate-$g.log" 2>&1
  GEXIT=$?
  RESUMO=$(grep -aE 'Executed [0-9]+ tests, with' "/tmp/feedmine-gate-$g.log" | tail -1 | tr -s ' ')
  VEREDITO=$(grep -aoE '\*\* TEST (SUCCEEDED|FAILED) \*\*' "/tmp/feedmine-gate-$g.log" | tail -1)
  echo "gate $g [green under 30s deadline tolerance, finding 10 (injected clock / suspension points) STILL OPEN]: $RESUMO | $VEREDITO"
  grep -aE 'Test Case .*failed \(' "/tmp/feedmine-gate-$g.log" | sed 's/^/  FALHA: /' | sort -u | head -3 || true
  if [ "$GEXIT" != "0" ] || [ "$VEREDITO" != "** TEST SUCCEEDED **" ]; then FAILED=1; echo "  gate $g FALHOU (exit=$GEXIT)"; fi
done

xcrun simctl uninstall "$S" com.feedmine.app 2>/dev/null || true; rm -rf "$SHOTS"
xcodebuild test-without-building -project feedmine.xcodeproj -scheme feedmine \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  -only-testing:feedmineUITests/PersonaExplorationUITests/testCaptureAllScreens > /tmp/feedmine-journey.log 2>&1
JEXIT=$?
REQUIRED="01-main-feed 02-main-feed-scrolled 03-article-reader 04-article-scrolled 05-filter-sheet 06-filter-sheet-scrolled 07-search-screen 08-search-results 09-more-menu 10-more-menu-scrolled 11-settings 12-settings-scrolled 13-add-feed 14-browse-topics 15-topics-scrolled 16-context-menu 17-reopen"
MISSING=""; PRESENT=0
for r in $REQUIRED; do
  if [ -f "$SHOTS/$r.png" ]; then PRESENT=$((PRESENT + 1)); else MISSING="$MISSING $r"; fi
done
echo "JORNADA superficies-obrigatorias=$PRESENT/17 ausentes=[$MISSING]"
grep -a "READY card_after_ms" /tmp/feedmine-journey.log | tail -1 || true
grep -a "READER" /tmp/feedmine-journey.log | tail -4 || true
grep -a "REOPEN" /tmp/feedmine-journey.log || true
grep -aE 'Test Case .*(passed|failed)' /tmp/feedmine-journey.log | tail -1 | sed 's/^.*PersonaExplorationUITests//' || true
if [ -n "$MISSING" ] || [ "$JEXIT" != "0" ] || [ "$(grep -ac '\*\* TEST EXECUTE FAILED \*\*' /tmp/feedmine-journey.log || true)" != "0" ]; then
  FAILED=1; echo "JORNADA FALHOU: exit=$JEXIT ausentes=[$MISSING]"
fi

if [ "$FAILED" != "0" ]; then echo "== BAR FALHOU $(date '+%H:%M:%S') =="; exit 1; fi
echo "== BAR OK $(date '+%H:%M:%S') =="
