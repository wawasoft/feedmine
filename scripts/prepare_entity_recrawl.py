#!/usr/bin/env python3
"""Turn entity-decoding quarantine rows into an explicit pending recrawl.

The source Parquet is never modified.  The output can be passed to
``fetch_new_feeds.py --parquet ...`` and then back to reconciliation after the
corrected endpoint has real crawl evidence.
"""

from __future__ import annotations

import argparse
import csv
import os
from pathlib import Path

try:
    from scripts.catalog_identity import canonical_url, compute_source_id, request_url
except ModuleNotFoundError:
    from catalog_identity import canonical_url, compute_source_id, request_url


def prepare(sources: Path, quarantine: Path, output: Path) -> int:
    import pyarrow as pa
    import pyarrow.parquet as pq

    table = pq.read_table(sources)
    rows = table.to_pylist()
    queued: dict[int, str] = {}
    with quarantine.open(newline="", encoding="utf-8") as handle:
        for item in csv.DictReader(handle):
            if item.get("reason") != "url_entities_decoded_requires_refetch":
                continue
            queued[int(item["row_index"])] = request_url(item.get("xml_url", ""))

    for index, fetch_url in queued.items():
        if index < 0 or index >= len(rows):
            raise ValueError(f"quarantine row_index outside source parquet: {index}")
        row = rows[index]
        row["source_id"] = compute_source_id(fetch_url)
        row["xml_url"] = fetch_url
        row["canonical_xml_url"] = canonical_url(fetch_url)
        row["status"] = "pending"
        row["error_message"] = None
        row["final_url"] = None
        row["attempt_count"] = 0

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    pq.write_table(pa.Table.from_pylist(rows, schema=table.schema), temporary, compression="zstd")
    os.replace(temporary, output)
    return len(queued)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, default=Path("feeds_corpus_sources.parquet"))
    parser.add_argument(
        "--quarantine", type=Path,
        default=Path("build/catalog-reconciliation/quarantine.csv"),
    )
    parser.add_argument(
        "--output", type=Path,
        default=Path("build/catalog-reconciliation/entity-recrawl-input.parquet"),
    )
    return parser.parse_args()


if __name__ == "__main__":
    arguments = parse_args()
    count = prepare(arguments.sources, arguments.quarantine, arguments.output)
    print(f"prepared {count} entity-corrected source rows for recrawl: {arguments.output}")
