#!/bin/bash
# Batch writer/author blog discovery — runs countries in parallel using background jobs.
# Usage: bash scripts/batch_discover_writers.sh [MAX_PARALLEL] [TARGET]
#
# Target: 20 writers/authors per country (vs 100 for journalists).

set -e

MAX_PARALLEL="${1:-4}"
TARGET="${2:-20}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="$REPO_ROOT/scripts/feed_discovery/data/writer_cache"
LOG_DIR="$CACHE_DIR/logs"
VENV="$REPO_ROOT/.venv_feeds/bin/activate"

mkdir -p "$LOG_DIR"

# Get list of all countries from countries.json
COUNTRIES=$(python3 -c "
import json
with open('$REPO_ROOT/scripts/feed_discovery/data/countries.json') as f:
    data = json.load(f)
for slug in sorted(data.keys()):
    # Skip already-cached countries that reached target
    import os
    cache_file = '$CACHE_DIR/' + slug + '_validated.json'
    if os.path.exists(cache_file):
        try:
            existing = json.load(open(cache_file))
            if len(existing) >= $TARGET:
                continue
        except:
            pass
    print(slug)
")

TOTAL=$(echo "$COUNTRIES" | wc -l | tr -d ' ')
if [ -z "$COUNTRIES" ]; then
    echo "All countries already at $TARGET+ writer feeds. Nothing to do."
    exit 0
fi

echo "============================================================"
echo "Writer/Author Blog Discovery — Batch Pass 1"
echo "Target: $TARGET feeds per country"
echo "Remaining countries: $TOTAL"
echo "Max parallel: $MAX_PARALLEL"
echo "Logs: $LOG_DIR"
echo "Cache: $CACHE_DIR"
echo "============================================================"

RUNNING=0
COUNTER=0

for slug in $COUNTRIES; do
    # Wait if we've reached max parallel
    while [ $RUNNING -ge $MAX_PARALLEL ]; do
        wait -n 2>/dev/null || true
        RUNNING=$(jobs -r | wc -l | tr -d ' ')
    done

    COUNTER=$((COUNTER + 1))
    LOGFILE="$LOG_DIR/${slug}.log"

    (
        source "$VENV"
        echo "[$(date '+%H:%M:%S')] Starting $slug..."
        python3 -u "$REPO_ROOT/scripts/discover_writer_blogs.py" \
            --country "$slug" --delay 0.7 --target "$TARGET" 2>&1
        echo "[$(date '+%H:%M:%S')] Finished $slug"
    ) > "$LOGFILE" 2>&1 &

    RUNNING=$(jobs -r | wc -l | tr -d ' ')
    echo "  [$COUNTER/$TOTAL] Launched $slug (running: $RUNNING)"

    # Small stagger to avoid all workers hitting DDG at exactly the same time
    sleep 0.5
done

echo ""
echo "All $TOTAL countries launched. Waiting for completion..."
wait

echo ""
echo "============================================================"
echo "Batch complete! Checking results..."

# Summary
TOTAL_FEEDS=0
PROCESSED=0
AT_TARGET=0
BELOW_TARGET=""

for slug in $(echo "$COUNTRIES" | sort); do
    CACHE_FILE="$CACHE_DIR/${slug}_validated.json"
    if [ -f "$CACHE_FILE" ]; then
        COUNT=$(python3 -c "import json; print(len(json.load(open('$CACHE_FILE'))))" 2>/dev/null || echo 0)
        TOTAL_FEEDS=$((TOTAL_FEEDS + COUNT))
        PROCESSED=$((PROCESSED + 1))
        if [ "$COUNT" -ge "$TARGET" ]; then
            AT_TARGET=$((AT_TARGET + 1))
        else
            BELOW_TARGET="$BELOW_TARGET  $slug: $COUNT\n"
        fi
    fi
done

echo "Processed: $PROCESSED countries"
echo "At target ($TARGET+): $AT_TARGET/$PROCESSED"
echo "Total feeds: $TOTAL_FEEDS"
if [ -n "$BELOW_TARGET" ]; then
    echo ""
    echo "Countries below target:"
    echo -e "$BELOW_TARGET"
fi
echo "============================================================"
