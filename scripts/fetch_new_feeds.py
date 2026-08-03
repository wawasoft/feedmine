#!/usr/bin/env python3
"""Fetch articles from the 5,779 pending feeds in feeds_corpus_sources.parquet.

Reads the parquet, fetches each pending feed via HTTP, extracts metadata and
articles from the RSS/Atom XML, and updates the parquet row with results.
Resumable — writes progress incrementally.

Usage:
    python3 scripts/fetch_new_feeds.py
    python3 scripts/fetch_new_feeds.py --limit 10    # test with 10
"""

from __future__ import annotations

import argparse, hashlib, locale, os, re, shutil, signal, sys, time
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit
from xml.etree import ElementTree as ET

# ── Date parsing (handles non-English locale dates like French "ven, 31 Juil 2026") ──
_FRENCH_MONTHS = {
    "janv": "Jan", "févr": "Feb", "fév": "Feb", "mars": "Mar",
    "avr": "Apr", "mai": "May", "juin": "Jun",
    "juil": "Jul", "août": "Aug", "aout": "Aug",
    "sept": "Sep", "oct": "Oct", "nov": "Nov", "déc": "Dec", "dec": "Dec",
}
_FRENCH_DAYS = {"lun": "Mon", "mar": "Tue", "mer": "Wed", "jeu": "Thu",
                "ven": "Fri", "sam": "Sat", "dim": "Sun"}

def _normalize_date(raw: str) -> str:
    """Try to normalize a date string from an RSS/Atom feed to ISO 8601."""
    if not raw or not raw.strip():
        return ""
    raw = raw.strip()
    # Try standard RFC 2822 first (handles English locale)
    try:
        return parsedate_to_datetime(raw).isoformat()
    except Exception:
        pass
    # Try French locale
    try:
        cleaned = raw
        for fr, en in _FRENCH_DAYS.items():
            cleaned = re.sub(rf"\b{fr}\b", en, cleaned, flags=re.IGNORECASE)
        for fr, en in _FRENCH_MONTHS.items():
            cleaned = re.sub(rf"\b{fr}\b", en, cleaned, flags=re.IGNORECASE)
        return parsedate_to_datetime(cleaned).isoformat()
    except Exception:
        pass
    # Try ISO 8601 directly
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00")).isoformat()
    except Exception:
        pass
    # Give up — return empty
    return ""

import pyarrow as pa
import pyarrow.parquet as pq
import pandas as pd
from concurrent.futures import ThreadPoolExecutor, as_completed

# ── Config ──
ROOT = Path(__file__).resolve().parent.parent
PARQUET_PATH = ROOT / "feeds_corpus_sources.parquet"
BACKUP_PATH = ROOT / "feeds_corpus_sources.backup.parquet"
PROGRESS_PATH = ROOT / "feeds_new_fetch_progress.json"

TIMEOUT = 30
MAX_ARTICLES = 15
CONCURRENCY = 20
FLUSH_EVERY = 100

# ── Helpers ──

def compute_source_id(url: str) -> str:
    parsed = urlsplit(url)
    canonical = urlunsplit((
        parsed.scheme.lower(),
        parsed.hostname.lower() if parsed.hostname else "",
        parsed.path, parsed.query, ""))
    return hashlib.sha256(canonical.encode()).hexdigest()


def parse_feed(xml_bytes: bytes, xml_url: str) -> dict:
    """Extract metadata and articles from RSS/Atom XML."""
    result = {
        "feed_title": "",
        "feed_description": "",
        "site_url": "",
        "feed_reported_language": "",
        "articles_fetched": 0,
        "latest_item_at": "",
        "error_message": "",
    }

    try:
        text = xml_bytes.decode("utf-8", errors="replace")
    except Exception:
        return result

    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        result["error_message"] = f"XML parse error: {e}"
        return result

    # RSS
    channel = root.find("channel")
    if channel is not None:
        title = channel.findtext("title", "").strip()
        desc = channel.findtext("description", "").strip()
        lang = channel.findtext("language", "").strip()
        link = channel.findtext("link", "").strip()

        result["feed_title"] = title[:300] if title else ""
        result["feed_description"] = desc[:500] if desc else ""
        result["feed_reported_language"] = lang[:20] if lang else ""
        result["site_url"] = link[:500] if link else ""

        # Articles
        items = channel.findall("item")[:MAX_ARTICLES]
        latest = ""
        for item in items:
            pub = item.findtext("pubDate", "")
            pub_iso = _normalize_date(pub)
            if pub_iso and (not latest or pub_iso > latest):
                latest = pub_iso
        result["articles_fetched"] = len(items)
        result["latest_item_at"] = latest
        return result

    # Atom
    ns = {"atom": "http://www.w3.org/2005/Atom"}
    feed = root
    if root.tag.endswith("feed") or root.tag == "feed":
        pass  # root is the feed
    else:
        feed = root.find("atom:feed", ns) or root.find("feed")

    if feed is not None:
        title = feed.findtext("atom:title", "", ns) or feed.findtext("title", "").strip()
        subtitle = feed.findtext("atom:subtitle", "", ns) or ""
        lang_el = feed.get("{http://www.w3.org/XML/1998/namespace}lang", "") or feed.get("lang", "")

        # Find site URL (first link with rel="alternate")
        site = ""
        for link in feed.findall("atom:link", ns) or feed.findall("link"):
            rel = link.get("rel", "alternate")
            href = link.get("href", "")
            if rel == "alternate" and href:
                site = href
                break

        result["feed_title"] = title[:300] if title else ""
        result["feed_description"] = subtitle[:500] if subtitle else ""
        result["feed_reported_language"] = lang_el[:20] if lang_el else ""
        result["site_url"] = site[:500] if site else ""

        # Entries
        entries = feed.findall("atom:entry", ns) or feed.findall("entry")
        entries = entries[:MAX_ARTICLES]
        latest = ""
        for entry in entries:
            updated = entry.findtext("atom:updated", "", ns) or entry.findtext("updated", "")
            published = entry.findtext("atom:published", "", ns) or entry.findtext("published", "")
            ts = _normalize_date(updated or published)
            if ts and (not latest or ts > latest):
                latest = ts
        result["articles_fetched"] = len(entries)
        result["latest_item_at"] = latest
        return result

    # Unknown format
    if not result["feed_title"]:
        result["error_message"] = "Unknown feed format (not RSS/Atom)"
    return result


def fetch_one(url: str) -> dict:
    """Fetch one feed URL and parse it. Returns metadata dict."""
    import urllib.request
    import urllib.error

    result = {
        "feed_title": "",
        "feed_description": "",
        "site_url": "",
        "feed_reported_language": "",
        "articles_fetched": 0,
        "latest_item_at": "",
        "http_status": 0,
        "final_url": url,
        "content_type": "",
        "error_message": "",
    }

    try:
        req = urllib.request.Request(url, headers={
            "User-Agent": "FeedMine/2.0 (feed discovery bot; +https://feedmine.app)",
            "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml, */*",
        })
        resp = urllib.request.urlopen(req, timeout=TIMEOUT)

        result["http_status"] = resp.status
        result["final_url"] = resp.url
        result["content_type"] = resp.headers.get("Content-Type", "")[:100]

        if resp.status != 200:
            result["error_message"] = f"HTTP {resp.status}"
            return result

        # Check content length (avoid huge downloads)
        cl = resp.headers.get("Content-Length", "")
        if cl and int(cl) > 5_000_000:
            result["error_message"] = f"Feed too large: {cl} bytes"
            return result

        body = resp.read(2_000_000)  # max 2MB
        parsed = parse_feed(body, url)
        result.update(parsed)

        if not result.get("error_message") and result["articles_fetched"] == 0:
            result["error_message"] = "No articles found in feed"

    except urllib.error.HTTPError as e:
        result["http_status"] = e.code
        result["error_message"] = f"HTTP {e.code}"
    except urllib.error.URLError as e:
        result["error_message"] = f"URL error: {e.reason}"
    except TimeoutError:
        result["error_message"] = f"Timeout after {TIMEOUT}s"
    except Exception as e:
        result["error_message"] = f"Error: {str(e)[:500]}"

    return result


def save_progress(progress: dict) -> None:
    import json
    tmp = PROGRESS_PATH.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(progress, f)
    tmp.replace(PROGRESS_PATH)


def load_progress() -> dict:
    import json
    if PROGRESS_PATH.exists():
        with open(PROGRESS_PATH) as f:
            return json.load(f)
    return {}


def write_parquet(df) -> None:
    if PARQUET_PATH.exists():
        shutil.copy2(PARQUET_PATH, BACKUP_PATH)
    table = pa.Table.from_pandas(df)
    tmp = PARQUET_PATH.with_suffix(".tmp.parquet")
    pq.write_table(table, tmp, compression="zstd")
    os.replace(str(tmp), str(PARQUET_PATH))


# ── Main ──

def main():
    parser = argparse.ArgumentParser(description="Fetch pending feeds from parquet")
    parser.add_argument("--limit", type=int, default=0, help="Only fetch N feeds (0=all)")
    parser.add_argument("--reset", action="store_true", help="Clear progress and restart")
    args = parser.parse_args()

    # ── 1. Read parquet ──
    print(f"Reading {PARQUET_PATH}...")
    table = pq.read_table(PARQUET_PATH)
    df = table.to_pandas()
    total = len(df)
    print(f"  {total} total rows")

    # ── 2. Find pending ──
    pending_mask = df["status"] == "pending"
    pending_idx = df[pending_mask].index.tolist()

    # Load progress
    progress = {} if args.reset else load_progress()

    # Filter already-processed
    remaining = []
    for idx in pending_idx:
        pid = str(df.at[idx, "source_id"])
        if pid in progress:
            # Apply cached results
            p = progress[pid]
            for col in ["feed_title", "feed_description", "site_url", "feed_reported_language",
                         "articles_fetched", "latest_item_at", "http_status", "final_url",
                         "content_type", "error_message"]:
                if col in p and p[col]:
                    df.at[idx, col] = p[col]
            df.at[idx, "status"] = "done" if p.get("articles_fetched", 0) > 0 else "done"
        else:
            remaining.append(idx)

    print(f"  {len(pending_idx)} pending total")
    print(f"  {len(pending_idx) - len(remaining)} already processed (cached)")
    print(f"  {len(remaining)} remaining to fetch")

    if args.limit and args.limit > 0:
        remaining = remaining[:args.limit]
        print(f"  --limit {args.limit}: processing {len(remaining)}")

    if not remaining:
        print("  Nothing to do!")
        write_parquet(df)
        return

    # ── 3. Fetch in parallel ──
    processed = 0
    failed = 0
    start_time = time.time()

    # Prepare work items
    work = [(idx, str(df.at[idx, "xml_url"])) for idx in remaining]

    print(f"\n  Fetching {len(work)} feeds ({CONCURRENCY} concurrent, timeout={TIMEOUT}s)")
    print(f"  Flush every {FLUSH_EVERY} feeds\n")

    # Signal handler for clean shutdown
    shutdown = False
    def on_interrupt(signum, frame):
        nonlocal shutdown
        shutdown = True
        print("\n[interrupt] Finishing current batch before saving...")
    original_sigint = signal.signal(signal.SIGINT, on_interrupt)

    try:
        with ThreadPoolExecutor(max_workers=CONCURRENCY) as executor:
            futures = {executor.submit(fetch_one, url): (idx, url) for idx, url in work}

            for i, future in enumerate(as_completed(futures)):
                idx, url = futures[future]
                pid = str(df.at[idx, "source_id"])

                try:
                    result = future.result()
                except Exception as e:
                    result = {"error_message": f"Thread error: {e}", "articles_fetched": 0}

                # Update dataframe
                for col, val in result.items():
                    if val:  # only update non-empty
                        df.at[idx, col] = val

                new_status = "done" if result.get("articles_fetched", 0) > 0 else "failed"
                if result.get("error_message"):
                    new_status = "failed"
                df.at[idx, "status"] = new_status

                # Cache in progress
                progress[pid] = {k: str(v) if v else "" for k, v in result.items()}

                if new_status == "done":
                    processed += 1
                else:
                    failed += 1

                # Progress display
                elapsed = time.time() - start_time
                rate = (processed + failed) / elapsed if elapsed > 0 else 0
                remaining_count = len(work) - (processed + failed)
                eta = remaining_count / rate if rate > 0 else 0

                title = str(df.at[idx, "feed_title"])[:50] or str(df.at[idx, "source_title"])[:50]
                print(f"  [{processed + failed}/{len(work)}] {new_status:6s} "
                      f"({processed}ok/{failed}fail) {rate:.1f}/s ETA {eta/60:.0f}m "
                      f"| {title}")

                # Flush periodically
                if (processed + failed) % FLUSH_EVERY == 0:
                    print(f"  --- flushing to parquet ---")
                    write_parquet(df)
                    progress = {}
                    save_progress(progress)

                if shutdown:
                    print("  Shutting down early...")
                    break

    finally:
        signal.signal(signal.SIGINT, original_sigint)

    # ── 4. Final save ──
    print(f"\n{'='*60}")
    print(f"Results: {processed} done, {failed} failed")
    write_parquet(df)
    save_progress(progress)

    # Stats
    final = pq.read_table(PARQUET_PATH).to_pandas()
    statuses = final["status"].value_counts().to_dict()
    print(f"Parquet status: {statuses}")
    print(f"Done!")


if __name__ == "__main__":
    main()
