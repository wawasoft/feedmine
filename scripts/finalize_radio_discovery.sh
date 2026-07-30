#!/bin/bash
# Finalize radio podcast discovery: supplemental search + OPML integration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VENV="$PROJECT_DIR/.venv_feeds/bin/python"

echo "=== Step 1: Check main batch results ==="
$VENV -c "
import json
with open('scripts/feed_discovery/data/radio_podcasts_by_country.json') as f:
    data = json.load(f)
print(f'Countries: {data[\"countries_processed\"]}')
print(f'Total candidates: {data[\"total_candidates\"]}')
print(f'Under 5: {data[\"countries_under_5\"]}')
"

echo ""
echo "=== Step 2: Supplemental search for under-5 countries ==="
$VENV scripts/supplemental_radio_search.py --write --under-5

echo ""
echo "=== Step 3: Final stats ==="
$VENV -c "
import json
with open('scripts/feed_discovery/data/radio_podcasts_by_country.json') as f:
    data = json.load(f)
print(f'Countries: {data[\"countries_processed\"]}')
print(f'Total candidates: {data[\"total_candidates\"]}')
print(f'Under 5: {len(data[\"countries_under_5\"])}')
if data['countries_under_5']:
    print(f'  ⚠️  {data[\"countries_under_5\"]}')
else:
    print('  🎉 All countries have 5+ radio podcasts!')
"

echo ""
echo "=== Step 4: Integrate into OPML files ==="
echo "Run: $VENV scripts/integrate_radio_podcasts.py --write"
echo "(Dry-run first: $VENV scripts/integrate_radio_podcasts.py)"
