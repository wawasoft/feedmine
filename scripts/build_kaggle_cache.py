#!/usr/bin/env python3
"""Build name→channel_id cache from Kaggle Youtube-Channels-Dataset.

Scrapes youtube.com/channel/UC... page titles to extract channel names.
Uses concurrent requests for speed (~1 hour for 37K channels).
Output: name_cache.json → {normalized_name: channel_id}
"""

import json
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests

DATA_DIR = Path(__file__).resolve().parent.parent / "scripts/feed_discovery/data"
PICKLE_URL = "https://raw.githubusercontent.com/chen-zhitao/Youtube-Channels-Dataset/master/data/id_2_url.pkl"
OUTPUT_PATH = DATA_DIR / "youtube_channels_kaggle_cache.json"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
}

def normalize(name: str) -> str:
    """Normalize a channel name for matching."""
    return re.sub(r'\s+', '', name.lower().strip())


def fetch_name(channel_id: str) -> tuple[str, str] | None:
    """Scrape youtube.com/channel/UC... for the channel name from <title> tag.
    Returns (normalized_name, channel_id) or None on failure.
    """
    url = f"https://www.youtube.com/channel/{channel_id}"
    try:
        resp = requests.get(url, timeout=10, headers=HEADERS, stream=True)
        # Read only first 8KB — title is in the first few hundred bytes
        chunk = next(resp.iter_content(chunk_size=8192), b"").decode("utf-8", errors="ignore")
        match = re.search(r'<title>([^<]*)</title>', chunk)
        if match:
            title = match.group(1)
            # Strip " - YouTube" suffix
            name = re.sub(r'\s*-\s*YouTube\s*$', '', title).strip()
            if name and name != "YouTube":
                return (normalize(name), channel_id)
    except Exception:
        pass
    return None


def main():
    # Download pickle if needed
    pickle_path = DATA_DIR / "id_2_url.pkl"
    if not pickle_path.exists():
        print("Downloading id_2_url.pkl...", file=sys.stderr)
        import pickle as pkl
        resp = requests.get(PICKLE_URL, timeout=30)
        pickle_path.write_bytes(resp.content)

    import pickle as pkl
    id_to_url = pkl.loads(pickle_path.read_bytes())
    channel_ids = list(id_to_url.keys())
    print(f"Channel IDs loaded: {len(channel_ids)}", file=sys.stderr)

    # Load existing cache
    cache: dict[str, str] = {}
    if OUTPUT_PATH.exists():
        cache = json.loads(OUTPUT_PATH.read_text(encoding="utf-8"))
        print(f"Existing cache: {len(cache)} entries", file=sys.stderr)

    pending = [cid for cid in channel_ids if cid not in cache]
    print(f"Pending: {len(pending)}", file=sys.stderr)

    if not pending:
        print("All channels already cached!", file=sys.stderr)
        return

    # Concurrent fetch
    workers = 8  # Be polite — 8 concurrent connections
    completed = 0
    batch = []
    start = time.time()

    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(fetch_name, cid): cid for cid in pending}

        for future in as_completed(futures):
            result = future.result()
            if result:
                name_key, cid = result
                cache[name_key] = cid
                batch.append(result)

            completed += 1
            if completed % 500 == 0:
                elapsed = time.time() - start
                rate = completed / elapsed if elapsed > 0 else 0
                pct = completed / len(pending) * 100
                print(f"  [{completed}/{len(pending)}] {pct:.0f}% — "
                      f"{len(batch)} new names, {rate:.0f}/s", file=sys.stderr)
                # Save incrementally
                OUTPUT_PATH.write_text(
                    json.dumps(cache, indent=2, ensure_ascii=False),
                    encoding="utf-8",
                )
                batch = []

    # Final save
    OUTPUT_PATH.write_text(
        json.dumps(cache, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    print(f"\n✓ Cache saved: {len(cache)} name→ID mappings → {OUTPUT_PATH}", file=sys.stderr)


if __name__ == "__main__":
    main()
