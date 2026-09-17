#!/bin/bash
# Release gate — journey half.
#
# Runs `PersonaExplorationUITests/testCaptureAllScreens` on the booted iPhone 16 simulator and exits non-zero when the run
# is not a complete pass, so this can be a gate rather than a report:
#   * any of the 17 required surface basenames is missing,
#   * xcodebuild reported `** TEST EXECUTE FAILED **` (e.g. the reader step's XCTFail when the reader never presented or its
#     body never rendered — a missing reader surface is a finding, not a flake),
#   * or xcodebuild itself exited non-zero.
#
# Before this existed the harness printed `ausentes=[…]` and exited 0, which let a blank or unopened reader pass as green.
#
# Serialization: the lane lock covers `simctl` as well as `xcodebuild`, because `simctl uninstall` wipes the app container
# and would invalidate a warm-reopen measurement. The lock is released by removing its `holder` file first — `rmdir` alone
# cannot remove a non-empty directory, which is how earlier versions leaked the lock and blocked later lanes.
#
# Usage: scripts/release-journey.sh [journey-log] [build-log]
#   env: FEEDMINE_SIM_UDID  simulator UDID (required when more than one device matches FEEDMINE_SIM_NAME)
#        FEEDMINE_SIM_NAME  model to use; default `iPhone 16`, the model every recorded measurement used
#   The screenshot directory is NOT configurable here: `PersonaExplorationUITests.screenshotDir` hardcodes
#   /tmp/feedmine-persona-screenshots, and the basename validation below must read exactly what the test wrote.
# No `set -e`: the whole point of this script is to *report* a red run. A bare `xcodebuild` that exits 65 would otherwise
# terminate it before the basename validation, the READER/REOPEN lines and the `JORNADA FALHOU` verdict, which is the
# opposite of a gate that explains itself.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
SIM_NAME="${FEEDMINE_SIM_NAME:-iPhone 16}"
discover_udid() {
  local booted matches count
  booted=$(xcrun simctl list devices booted 2>/dev/null | awk -F'[()]' -v n="$SIM_NAME" '$0 ~ n {gsub(/ /,"",$2); print $2; exit}')
  if [ -n "$booted" ]; then echo "$booted"; return 0; fi
  matches=$(xcrun simctl list devices available 2>/dev/null | awk -F'[()]' -v n="$SIM_NAME" '$0 ~ n {gsub(/ /,"",$2); print $2}')
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  if [ "$count" -gt 1 ]; then
    echo "ABORTADO: $count simulators match '$SIM_NAME' — set FEEDMINE_SIM_UDID to choose:" >&2
    printf '%s\n' "$matches" | sed 's/^/  /' >&2
    return 1
  fi
  printf '%s\n' "$matches" | head -1
}
S="${FEEDMINE_SIM_UDID:-$(discover_udid)}"
if [ -z "$S" ]; then echo "ABORTADO: no simulator matching '$SIM_NAME' — set FEEDMINE_SIM_UDID"; exit 9; fi
# Derived from $S, never configurable — see release-acceptance.sh for why two knobs are a hazard.
DEST="platform=iOS Simulator,id=$S"
echo "simulator: $S | destination: $DEST"
SHOTS=/tmp/feedmine-persona-screenshots
LOG="${1:-/tmp/feedmine-journey.log}"
BUILDLOG="${2:-/tmp/feedmine-journey-build.log}"
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
echo "== journey gate start $(date '+%H:%M:%S') =="
# Boot the target explicitly: `bootstatus` on a shutdown device does not boot it, and both it and `uninstall` can fail
# silently, which would leave the previous run's app container in place — the script's whole premise ("a clean container
# per run") would be gone while its output still read like a cold-start measurement.
xcrun simctl shutdown "$S" 2>/dev/null || true; sleep 3
xcrun simctl boot "$S" 2>/dev/null || true
xcrun simctl bootstatus "$S" -b >/dev/null 2>&1 || true
xcrun simctl uninstall "$S" com.feedmine.app 2>/dev/null || true
if xcrun simctl get_app_container "$S" com.feedmine.app >/dev/null 2>&1; then
  echo "ABORTADO: com.feedmine.app still has a container after uninstall — a warm-start measurement here would be invalid"
  exit 9
fi
rm -rf "$SHOTS"
if xcodebuild build-for-testing -project feedmine.xcodeproj -scheme feedmine \
  -destination "$DEST" > "$BUILDLOG" 2>&1; then BUILD_EXIT=0; else BUILD_EXIT=$?; fi
BE=$(grep -acE 'error:' "$BUILDLOG" || true)
echo "build-erros: $BE (exit=$BUILD_EXIT)"
if [ "$BE" != "0" ] || [ "$BUILD_EXIT" != "0" ]; then
  echo "ABORTADO: o build falhou; nenhuma medicao e valida contra build velho"
  grep -aE 'error:' "$BUILDLOG" | sed 's|.*/feedmine/||' | sort -u | head -12 || true
  exit 8
fi

if xcodebuild test-without-building -project feedmine.xcodeproj -scheme feedmine \
  -destination "$DEST" \
  -only-testing:feedmineUITests/PersonaExplorationUITests/testCaptureAllScreens > "$LOG" 2>&1; then
  JOURNEY_EXIT=0
else
  JOURNEY_EXIT=$?
fi

REQUIRED="01-main-feed 02-main-feed-scrolled 03-article-reader 04-article-scrolled 05-filter-sheet 06-filter-sheet-scrolled 07-search-screen 08-search-results 09-more-menu 10-more-menu-scrolled 11-settings 12-settings-scrolled 13-add-feed 14-browse-topics 15-topics-scrolled 16-context-menu 17-reopen"
MISSING=""; PRESENT=0
for r in $REQUIRED; do
  if [ -f "$SHOTS/$r.png" ]; then PRESENT=$((PRESENT + 1)); else MISSING="$MISSING $r"; fi
done
echo "JORNADA superficies-obrigatorias=$PRESENT/17 ausentes=[$MISSING]"
echo "ficheiros em $SHOTS: $(ls -1 "$SHOTS" 2>/dev/null | wc -l | tr -d ' ')"
grep -a "READY card_after_ms" "$LOG" | tail -1 || true
grep -a "READER" "$LOG" | tail -4 || true
grep -a "REOPEN" "$LOG" || true
grep -aE 'Test Case .*(passed|failed)' "$LOG" | tail -1 | sed 's/^.*PersonaExplorationUITests//' || true

TEST_FAILED=$(grep -ac '\*\* TEST EXECUTE FAILED \*\*' "$LOG" || true)
if [ -n "$MISSING" ] || [ "$TEST_FAILED" != "0" ] || [ "$JOURNEY_EXIT" != "0" ]; then
  echo "JORNADA FALHOU: exit=$JOURNEY_EXIT test_failed=$TEST_FAILED ausentes=[$MISSING] — diagnostics in $LOG and $SHOTS"
  exit 1
fi
echo "JORNADA OK: 17/17 superficies, exit=0"
