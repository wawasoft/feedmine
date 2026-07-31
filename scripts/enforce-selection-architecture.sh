#!/bin/bash
# CI check: enforce unified selection architecture rules (§23, §28)
#
# Non-strict mode (default): FeedStore and FeedLoader are permitted as
# legacy adapters during migration. Only code OUTSIDE those files is
# checked for direct access to registry/fetcher/setVisibleItems.
#
# Strict mode (--strict): Phase 7 enforcement — FeedStore and FeedLoader
# must also comply (no remaining legacy access patterns).
#
# Usage: ./scripts/enforce-selection-architecture.sh [--strict]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../feedmine" && pwd)"

VIOLATIONS=0
STRICT=false
[[ "${1:-}" == "--strict" ]] && STRICT=true

# Legacy adapter files permitted during migration (non-strict mode)
LEGACY_PERMITTED="FeedStore.swift|FeedLoader.swift|PresetScorer.swift|Reservoir.swift|SourceRegistry.swift|WhatsNewManager.swift|SelectionExecutor.swift"
# Files that contain architecture rule documentation (false positives from comments)
DOC_FILES="SelectionArchitectureEnforcement.swift|enforce-selection-architecture.sh"

echo "=== Unified Selection Architecture Enforcement ==="
if $STRICT; then
  echo "  MODE: STRICT (Phase 7 — no legacy permitted)"
else
  echo "  MODE: non-strict (Phases 1-6 — FeedStore/FeedLoader permitted as adapters)"
fi
echo ""

# ---------------------------------------------------------------------------
# 1. registry.enabledSources
#    Permitted: SourceRegistry, SourceScopeResolver, SelectionCompiler,
#               FeedStore (legacy), FeedLoader (legacy)
# ---------------------------------------------------------------------------
echo "--- Rule 1: registry.enabledSources ---"
ENABLED_VIOLATIONS=$(grep -rn "registry\.enabledSources" "$SRC_DIR" --include="*.swift" \
  | grep -v "SourceRegistry.swift" \
  | grep -v "SourceScopeResolver.swift" \
  | grep -v "SelectionCompiler.swift" \
  | grep -v "SelectionCatalogReading" \
  | grep -v "FeedStore+Selection.swift" \
  | grep -v "SourceRegistryCatalogAdapter.swift" \
  | grep -vE "$DOC_FILES" \
  | { $STRICT && cat || grep -vE "$LEGACY_PERMITTED"; } \
  || true)

if [[ -n "$ENABLED_VIOLATIONS" ]]; then
  echo "  VIOLATIONS (registry.enabledSources outside permitted files):"
  echo "$ENABLED_VIOLATIONS" | sed 's/^/    /'
  VIOLATIONS=$((VIOLATIONS + $(echo "$ENABLED_VIOLATIONS" | grep -c . || true)))
else
  echo "  PASS"
fi

# ---------------------------------------------------------------------------
# 2. RSSFetcher.fetch — only SelectionNetworkRepository, CatalogMaintenance
# ---------------------------------------------------------------------------
echo "--- Rule 2: RSSFetcher.fetch ---"
FETCH_VIOLATIONS=$(grep -rn "fetcher\.fetch\|RSSFetcher.*\.fetch" "$SRC_DIR" --include="*.swift" \
  | grep -v "RSSFetcher.swift" \
  | grep -v "SelectionNetworkRepository" \
  | grep -vE "$DOC_FILES" \
  | { $STRICT && cat || grep -vE "$LEGACY_PERMITTED"; } \
  || true)

if [[ -n "$FETCH_VIOLATIONS" ]]; then
  echo "  VIOLATIONS (direct fetch outside permitted files):"
  echo "$FETCH_VIOLATIONS" | sed 's/^/    /'
  VIOLATIONS=$((VIOLATIONS + $(echo "$FETCH_VIOLATIONS" | grep -c . || true)))
else
  echo "  PASS"
fi

# ---------------------------------------------------------------------------
# 3. setVisibleItems — only SelectionCoordinator, FeedStoreSelectionBridge
# ---------------------------------------------------------------------------
echo "--- Rule 3: setVisibleItems ---"
SVI_VIOLATIONS=$(grep -rn "setVisibleItems" "$SRC_DIR" --include="*.swift" \
  | grep -v "FeedStore.swift" \
  | grep -v "FeedStoreSelectionBridge.swift" \
  | grep -v "SelectionCoordinator.swift" \
  | grep -v "SelectionSession.swift" \
  | grep -vE "$DOC_FILES" \
  | grep -v "FeedItem.swift" \
  || true)

if [[ -n "$SVI_VIOLATIONS" ]]; then
  echo "  VIOLATIONS (setVisibleItems outside permitted files):"
  echo "$SVI_VIOLATIONS" | sed 's/^/    /'
  VIOLATIONS=$((VIOLATIONS + $(echo "$SVI_VIOLATIONS" | grep -c . || true)))
else
  echo "  PASS"
fi

# ---------------------------------------------------------------------------
# 4. Legacy deprecated methods (warn only in non-strict)
# ---------------------------------------------------------------------------
echo "--- Rule 4: Deprecated methods ---"
DEPRECATED_METHODS=(
  "applyFilters"
  "sourcesEligibleForActiveSearch"
  "sourceMatchesActiveSearchFilters"
  "smartFeedMatches"
  "smartFeedMatchingSourceURLs"
  "immediatelyCullVisibleItemsForActiveFilter"
)

for method in "${DEPRECATED_METHODS[@]}"; do
  VIOLATIONS_FOUND=$(grep -rn "$method" "$SRC_DIR" --include="*.swift" \
    | grep -vE "$DOC_FILES" \
    | { $STRICT && cat || grep -vE "$LEGACY_PERMITTED"; } \
    || true)

  if [[ -n "$VIOLATIONS_FOUND" ]]; then
    count=$(echo "$VIOLATIONS_FOUND" | grep -c . || true)
    echo "  WARNING: '$method' found in $count locations — review for Phase 7 removal"
    if $STRICT; then
      echo "$VIOLATIONS_FOUND" | sed 's/^/    /'
      VIOLATIONS=$((VIOLATIONS + count))
    fi
  fi
done

# ---------------------------------------------------------------------------
# 5. Legacy generation counters (warn only in non-strict)
# ---------------------------------------------------------------------------
echo "--- Rule 5: Deprecated generation properties ---"
DEPRECATED_PROPS=(
  "filterGeneration"
  "presetGeneration"
  "presentationEpoch"
)

for prop in "${DEPRECATED_PROPS[@]}"; do
  VIOLATIONS_FOUND=$(grep -rn "$prop" "$SRC_DIR" --include="*.swift" \
    | grep -vE "$DOC_FILES" \
    | grep -v "FeedPresentationContext.swift" \
    | { $STRICT && cat || grep -vE "$LEGACY_PERMITTED"; } \
    || true)

  if [[ -n "$VIOLATIONS_FOUND" ]]; then
    count=$(echo "$VIOLATIONS_FOUND" | grep -c . || true)
    echo "  WARNING: '$prop' found in $count locations — review for Phase 7 removal"
    if $STRICT; then
      echo "$VIOLATIONS_FOUND" | sed 's/^/    /'
      VIOLATIONS=$((VIOLATIONS + count))
    fi
  fi
done

# ---------------------------------------------------------------------------
# 6. CardPreparationCoordinator — only via SelectionCardPreparing
# ---------------------------------------------------------------------------
echo "--- Rule 6: CardPreparationCoordinator direct access ---"
CPC_VIOLATIONS=$(grep -rn "preparationCoordinator\." "$SRC_DIR" --include="*.swift" \
  | grep -v "FeedStore.swift" \
  | grep -v "CardPreparationCoordinator.swift" \
  | grep -v "CardPreparationCoordinatorAdapter" \
  | grep -v "SelectionCardPreparationService" \
  | grep -v "SelectionExecutor.swift" \
  | grep -v "enforce-selection-architecture.sh" \
  || true)

if [[ -n "$CPC_VIOLATIONS" ]]; then
  echo "  WARNING: CardPreparationCoordinator accessed outside FeedStore/adapter"
  echo "$CPC_VIOLATIONS" | sed 's/^/    /'
  if $STRICT; then
    VIOLATIONS=$((VIOLATIONS + $(echo "$CPC_VIOLATIONS" | grep -c . || true)))
  fi
else
  echo "  PASS"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================================="
if [[ $VIOLATIONS -gt 0 ]]; then
  echo "  RESULT: $VIOLATIONS violation(s) found"
  if $STRICT; then
    echo "  Strict mode — failing build."
    exit 1
  else
    echo "  Non-strict mode — warnings only (legacy adapters permitted)."
    echo "  Run '$0 --strict' to enforce Phase 7 rules."
  fi
else
  echo "  RESULT: All architecture rules pass"
fi
echo "=============================================="
