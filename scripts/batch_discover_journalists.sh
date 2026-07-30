#!/bin/bash
# Batch journalist blog discovery — runs countries in parallel using background jobs.
# Usage: bash scripts/batch_discover_journalists.sh [MAX_PARALLEL]

set -e

MAX_PARALLEL="${1:-4}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="$REPO_ROOT/scripts/feed_discovery/data/journalist_cache"
LOG_DIR="$CACHE_DIR/logs"
VENV="$REPO_ROOT/.venv_feeds/bin/activate"

mkdir -p "$LOG_DIR"

# Get list of all countries from countries.json
COUNTRIES=$(python3 -c "
import json
with open('$REPO_ROOT/scripts/feed_discovery/data/countries.json') as f:
    data = json.load(f)
for slug in sorted(data.keys()):
    # Skip already-cached countries
    import os
    cache_file = '$CACHE_DIR/' + slug + '_validated.json'
    if not os.path.exists(cache_file):
        print(slug)
")

TOTAL=$(echo "$COUNTRIES" | wc -l | tr -d ' ')
echo "============================================================"
echo "Starting batch discovery for $TOTAL remaining countries"
echo "Max parallel: $MAX_PARALLEL"
echo "Logs: $LOG_DIR"
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
        python3 -u "$REPO_ROOT/scripts/discover_journalist_blogs.py" \
            --country "$slug" --delay 0.7 2>&1
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
BELOW_100=""

for slug in $(echo "$COUNTRIES" | sort); do
    CACHE_FILE="$CACHE_DIR/${slug}_validated.json"
    if [ -f "$CACHE_FILE" ]; then
        COUNT=$(python3 -c "import json; print(len(json.load(open('$CACHE_FILE'))))")
        TOTAL_FEEDS=$((TOTAL_FEEDS + COUNT))
        PROCESSED=$((PROCESSED + 1))
        if [ "$COUNT" -lt 100 ]; then
            BELOW_100="$BELOW_100  $slug: $COUNT\n"
        fi
    fi
done

echo "Processed: $PROCESSED countries"
echo "Total feeds: $TOTAL_FEEDS"
if [ -n "$BELOW_100" ]; then
    echo ""
    echo "Countries below 100 feeds:"
    echo -e "$BELOW_100"
fi
echo "============================================================"
