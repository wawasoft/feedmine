#!/usr/bin/env python3
"""Reconcile FeedMine's source corpus before catalog publication.

This is the mandatory boundary between crawl evidence and production.  It
does not modify its inputs.  It writes:

* one canonical ``done`` row per publishable feed;
* memberships remapped from the current OPML tree to canonical source IDs;
* old-ID/URL aliases for migration and joins;
* quarantine and unmatched-membership queues;
* a machine-readable reconciliation summary.

The subsequent ``curate_opml_catalog.py`` and ``build_catalog.py`` steps consume
the canonical Parquets and remain deterministic.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import unicodedata
import urllib.parse
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from dataclasses import dataclass
from difflib import SequenceMatcher
from pathlib import Path
from typing import Iterable, Mapping, Sequence

try:
    from scripts.catalog_identity import (
        canonical_url,
        clean_text,
        compute_source_id,
        decode_url_entities,
        request_url,
        valid_http_url,
    )
except ModuleNotFoundError:  # Direct ``python scripts/...`` execution.
    from catalog_identity import (
        canonical_url,
        clean_text,
        compute_source_id,
        decode_url_entities,
        request_url,
        valid_http_url,
    )

try:
    from scripts.catalog_collections import is_country_collection
except ModuleNotFoundError:
    from catalog_collections import is_country_collection


SCHEMA_VERSION = 1
PLACEHOLDER_TITLES = frozenset({
    "", "valid", "untitled", "unknown", "none", "null", "nan", "rss",
    "rss feed", "feed", "home", "homepage",
})
MOJIBAKE_MARKERS = ("Ã", "Â", "â€", "â€™", "â€œ", "â€�", "ðŸ", "Ð", "Ñ")
TITLE_STOPWORDS = frozenset({
    "a", "an", "and", "at", "by", "da", "de", "do", "dos", "e", "feed",
    "for", "from", "in", "la", "le", "of", "official", "on", "rss", "the",
    "to", "with",
})
TRUSTED_FEED_PROVIDER_SUFFIXES = (
    "acast.com", "anchor.fm", "art19.com", "buzzsprout.com", "feedburner.com",
    "feedsportal.com", "libsyn.com", "megaphone.fm", "omnycontent.com",
    "podbean.com", "simplecast.com", "spotify.com", "substack.com",
    "transistor.fm", "youtube.com",
)


@dataclass(frozen=True)
class Candidate:
    row_index: int
    row: Mapping[str, object]
    old_source_id: str
    intended_title: str
    observed_title: str
    declared_url: str
    declared_identity: str
    final_url: str
    destination_identity: str
    status: str
    articles_fetched: int
    blocking_reason: str | None


@dataclass(frozen=True)
class Resolution:
    source_id: str
    identity: str
    request_url: str
    title: str
    representative: Candidate
    variants: tuple[Candidate, ...]


def _fold(value: str) -> str:
    return unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii").casefold()


def _title_tokens(value: str) -> set[str]:
    return {
        token for token in re.findall(r"[^\W_]+", _fold(value), flags=re.UNICODE)
        if len(token) > 1 and token not in TITLE_STOPWORDS
    }


def title_similarity(left: str, right: str) -> float:
    left_folded = " ".join(sorted(_title_tokens(left)))
    right_folded = " ".join(sorted(_title_tokens(right)))
    if not left_folded or not right_folded:
        left_fallback = _fold(left).strip()
        right_fallback = _fold(right).strip()
        return 1.0 if left_fallback and left_fallback == right_fallback else 0.0
    left_tokens = set(left_folded.split())
    right_tokens = set(right_folded.split())
    jaccard = len(left_tokens & right_tokens) / len(left_tokens | right_tokens)
    sequence = SequenceMatcher(None, left_folded, right_folded).ratio()
    return max(jaccard, sequence)


def is_placeholder_title(value: object) -> bool:
    title = re.sub(r"\s+", " ", clean_text(value)).strip(" .:-").casefold()
    return title in PLACEHOLDER_TITLES or not any(character.isalnum() for character in title)


def _marker_count(value: str) -> int:
    return sum(value.count(marker) for marker in MOJIBAKE_MARKERS)


def repair_mojibake(value: object) -> tuple[str, bool]:
    original = clean_text(value)
    if not original:
        return "", False
    candidates = [original]
    for encoding in ("latin1", "cp1252"):
        try:
            candidates.append(original.encode(encoding).decode("utf-8"))
        except (UnicodeEncodeError, UnicodeDecodeError):
            pass
    repaired = min(candidates, key=lambda item: (_marker_count(item), "�" in item, len(item)))
    return repaired, repaired != original and _marker_count(repaired) < _marker_count(original)


def choose_title(row: Mapping[str, object]) -> tuple[str, str]:
    feed_title, feed_repaired = repair_mojibake(row.get("feed_title"))
    source_title, source_repaired = repair_mojibake(row.get("source_title"))
    if not is_placeholder_title(feed_title):
        return feed_title[:300], "feed_title_repaired" if feed_repaired else "feed_title"
    if not is_placeholder_title(source_title):
        return source_title[:300], "source_title_repaired" if source_repaired else "source_title"
    host = _host(clean_text(row.get("xml_url"))) or "Untitled"
    return host[:300], "hostname_fallback"


def _host(raw: str) -> str:
    try:
        return (urllib.parse.urlsplit(raw).hostname or "").casefold().removeprefix("www.")
    except ValueError:
        return ""


def _related_hosts(left: str, right: str) -> bool:
    return left == right or left.endswith(f".{right}") or right.endswith(f".{left}")


def _trusted_provider(host: str) -> bool:
    return any(host == suffix or host.endswith(f".{suffix}") for suffix in TRUSTED_FEED_PROVIDER_SUFFIXES)


def semantic_redirect_mismatch(
    declared_url: str,
    final_url: str,
    intended_title: str,
    observed_title: str,
) -> bool:
    if not final_url or not valid_http_url(final_url):
        return False
    declared_host, final_host = _host(declared_url), _host(final_url)
    if not declared_host or not final_host or _related_hosts(declared_host, final_host):
        return False
    if _trusted_provider(declared_host) or _trusted_provider(final_host):
        return False
    if is_placeholder_title(intended_title) or is_placeholder_title(observed_title):
        return False
    return title_similarity(intended_title, observed_title) < 0.18


def _integer(value: object) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def candidate_from_row(row: Mapping[str, object], row_index: int) -> Candidate:
    declared_raw = clean_text(row.get("xml_url")) or clean_text(row.get("canonical_xml_url"))
    decoded_declared = decode_url_entities(declared_raw)
    final = request_url(row.get("final_url")) if valid_http_url(row.get("final_url")) else ""
    intended = clean_text(row.get("source_title"))
    observed = clean_text(row.get("feed_title"))
    status = clean_text(row.get("status")).casefold() or "unknown"
    reason: str | None = None
    if not valid_http_url(decoded_declared):
        reason = "invalid_url"
    elif decoded_declared != declared_raw:
        # The successful crawl describes the wrongly escaped request.  The
        # corrected endpoint must be fetched again before it can be trusted.
        reason = "url_entities_decoded_requires_refetch"
    elif semantic_redirect_mismatch(decoded_declared, final, intended, observed):
        reason = "semantic_redirect_mismatch"
    destination = canonical_url(final or decoded_declared)
    return Candidate(
        row_index=row_index,
        row=row,
        old_source_id=clean_text(row.get("source_id")),
        intended_title=intended,
        observed_title=observed,
        declared_url=request_url(decoded_declared),
        declared_identity=canonical_url(decoded_declared),
        final_url=final,
        destination_identity=destination,
        status=status,
        articles_fetched=_integer(row.get("articles_fetched")),
        blocking_reason=reason,
    )


def _representative_rank(candidate: Candidate) -> tuple[object, ...]:
    title, _ = choose_title(candidate.row)
    latest = clean_text(candidate.row.get("latest_item_at"))
    return (
        candidate.status == "done",
        candidate.articles_fetched,
        bool(latest),
        not is_placeholder_title(title),
        bool(candidate.final_url),
        candidate.declared_url.casefold().startswith("https://"),
        candidate.old_source_id,
    )


def reconcile_candidates(candidates: Sequence[Candidate]) -> tuple[list[Resolution], list[Candidate]]:
    blocked = [candidate for candidate in candidates if candidate.blocking_reason]
    accepted = [candidate for candidate in candidates if not candidate.blocking_reason]
    grouped: dict[str, list[Candidate]] = defaultdict(list)
    for candidate in accepted:
        if candidate.destination_identity:
            grouped[candidate.destination_identity].append(candidate)

    resolutions: list[Resolution] = []
    for identity, variants in sorted(grouped.items()):
        done = [candidate for candidate in variants if candidate.status == "done"]
        if not done:
            blocked.extend(variants)
            continue
        representative = max(done, key=_representative_rank)
        title, _ = choose_title(representative.row)
        resolved_request = request_url(representative.final_url or representative.declared_url)
        resolutions.append(Resolution(
            source_id=compute_source_id(identity),
            identity=identity,
            request_url=resolved_request,
            title=title,
            representative=representative,
            variants=tuple(sorted(variants, key=lambda item: item.row_index)),
        ))
    return resolutions, blocked


def _clean_row(resolution: Resolution) -> dict[str, object]:
    row = dict(resolution.representative.row)
    title, _ = choose_title(row)
    for field in ("feed_description", "ai_description"):
        repaired, changed = repair_mojibake(row.get(field))
        if changed:
            row[field] = repaired
    row.update({
        "source_id": resolution.source_id,
        "source_title": title,
        "feed_title": title,
        "xml_url": resolution.request_url,
        "canonical_xml_url": resolution.identity,
        "final_url": resolution.request_url,
        "status": "done",
        "error_message": None,
    })
    language = clean_text(row.get("feed_reported_language"))
    row["feed_reported_language"] = language or None
    row["site_url"] = clean_text(row.get("site_url")) or None
    return row


def _stable_id(namespace: str, value: str) -> str:
    return hashlib.sha256(f"{namespace}:{value}".encode("utf-8")).hexdigest()


def _walk_memberships(
    element: ET.Element,
    *,
    parent_chain: tuple[str, ...],
    file_metadata: Mapping[str, str | None],
) -> Iterable[dict[str, str | None]]:
    for child in element.findall("outline"):
        label = clean_text(child.get("title") or child.get("text"))
        url = clean_text(child.get("xmlUrl"))
        language = clean_text(child.get("language")) or file_metadata["language"]
        if url:
            yield {
                "xml_url": url,
                "collection": file_metadata["collection"],
                "topic": file_metadata["topic"],
                "subcategory": " / ".join(parent_chain) or None,
                "claimed_language": language or None,
                "region": "global",
                "claimed_country": file_metadata["country"],
                "opml_file": file_metadata["opml_file"],
                "opml_title": file_metadata["opml_title"],
                "claimed_media_kind": clean_text(
                    child.get("feedmineMediaKind") or child.get("mediaKind")
                ) or None,
            }
        next_chain = parent_chain + ((label,) if label and not url else ())
        yield from _walk_memberships(
            child,
            parent_chain=next_chain,
            file_metadata={**file_metadata, "language": language or None},
        )


def read_opml_memberships(feeds_root: Path) -> tuple[list[dict[str, str | None]], int]:
    result: list[dict[str, str | None]] = []
    parse_failures = 0
    for path in sorted(feeds_root.rglob("*.opml")):
        relative = path.relative_to(feeds_root).as_posix()
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError:
            parse_failures += 1
            continue
        head = root.find("head")
        body = root.find("body")
        if body is None:
            continue
        parts = Path(relative).parts
        collection = parts[0] if parts else "unknown"
        metadata = {
            "collection": collection,
            "topic": Path(relative).stem,
            "country": parts[1] if is_country_collection(collection) and len(parts) > 1 else None,
            "opml_file": relative,
            "opml_title": clean_text(head.findtext("title")) if head is not None else None,
            "language": clean_text(head.findtext("language")) if head is not None else None,
        }
        result.extend(_walk_memberships(body, parent_chain=(), file_metadata=metadata))
    return result, parse_failures


def remap_memberships(
    memberships: Sequence[Mapping[str, str | None]],
    resolutions: Sequence[Resolution],
) -> tuple[list[dict[str, str | None]], list[dict[str, str | None]]]:
    by_declared: dict[str, set[str]] = defaultdict(set)
    by_source_id = {resolution.source_id: resolution for resolution in resolutions}
    for resolution in resolutions:
        for variant in resolution.variants:
            by_declared[variant.declared_identity].add(resolution.source_id)

    remapped: list[dict[str, str | None]] = []
    unmatched: list[dict[str, str | None]] = []
    seen: set[str] = set()
    for occurrence in memberships:
        identity = canonical_url(occurrence["xml_url"] or "")
        target_ids = by_declared.get(identity, set())
        if len(target_ids) != 1:
            unmatched.append({
                **occurrence,
                "normalized_identity": identity,
                "reason": "not_publishable" if not target_ids else "ambiguous_identity",
            })
            continue
        source_id = next(iter(target_ids))
        resolution = by_source_id[source_id]
        values = (
            occurrence["collection"], occurrence["topic"], occurrence["subcategory"],
            occurrence["claimed_language"], occurrence["region"], occurrence["claimed_country"],
            occurrence["opml_file"], occurrence["opml_title"], occurrence["claimed_media_kind"],
        )
        identity_text = "|".join(clean_text(value) for value in values)
        membership_id = _stable_id("membership", f"{source_id}|{identity_text}")
        if membership_id in seen:
            continue
        seen.add(membership_id)
        remapped.append({
            "membership_id": membership_id,
            "source_id": source_id,
            "collection": occurrence["collection"],
            "topic": occurrence["topic"],
            "subcategory": occurrence["subcategory"],
            "claimed_language": occurrence["claimed_language"],
            "region": occurrence["region"],
            "claimed_country": occurrence["claimed_country"],
            "opml_file": occurrence["opml_file"],
            "opml_title": occurrence["opml_title"],
            "claimed_media_kind": occurrence["claimed_media_kind"],
            "canonical_xml_url": resolution.identity,
        })
    return remapped, unmatched


def _write_csv(path: Path, rows: Sequence[Mapping[str, object]], fields: Sequence[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=fields,
            extrasaction="ignore",
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(rows)


def run(args: argparse.Namespace) -> dict[str, object]:
    import pandas as pd
    import pyarrow as pa
    import pyarrow.parquet as pq

    table = pq.read_table(args.sources)
    raw_rows = table.to_pylist()
    candidates = [candidate_from_row(row, index) for index, row in enumerate(raw_rows)]
    resolutions, blocked = reconcile_candidates(candidates)

    raw_memberships, parse_failures = read_opml_memberships(args.feeds_root)
    memberships, unmatched = remap_memberships(raw_memberships, resolutions)
    membership_ids = {clean_text(row["source_id"]) for row in memberships}
    published_resolutions = [
        resolution for resolution in resolutions if resolution.source_id in membership_ids
    ]

    # A successful crawl without an editorial membership is evidence, not a
    # publication decision.  Keep it in the orphan queue and out of the clean
    # production Parquet until a membership is assigned explicitly.
    clean_rows = [_clean_row(resolution) for resolution in published_resolutions]
    clean_frame = pd.DataFrame(clean_rows, columns=table.schema.names)
    clean_table = pa.Table.from_pandas(clean_frame, schema=table.schema, preserve_index=False)
    args.output_sources.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(clean_table, args.output_sources, compression="zstd")

    # Pending injections are not publishable evidence yet, but they must remain
    # a first-class queue for the next crawl instead of disappearing from the
    # canonical run outputs.
    pending_candidates = [
        candidate for candidate in blocked
        if candidate.status == "pending" and candidate.blocking_reason is None
    ]
    pending_rows = [dict(candidate.row) for candidate in pending_candidates]
    if pending_rows:
        pending_table = pa.Table.from_pylist(pending_rows, schema=table.schema)
    else:
        pending_frame = pd.DataFrame([], columns=table.schema.names)
        pending_table = pa.Table.from_pandas(
            pending_frame, schema=table.schema, preserve_index=False
        )
    args.pending_output.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(pending_table, args.pending_output, compression="zstd")

    membership_columns = [
        "membership_id", "source_id", "collection", "topic", "subcategory",
        "claimed_language", "region", "claimed_country", "opml_file", "opml_title",
        "claimed_media_kind", "canonical_xml_url",
    ]
    membership_frame = pd.DataFrame(memberships, columns=membership_columns)
    pq.write_table(pa.Table.from_pandas(membership_frame, preserve_index=False), args.output_memberships, compression="zstd")

    aliases: list[dict[str, object]] = []
    for resolution in resolutions:
        for variant in resolution.variants:
            aliases.append({
                "old_source_id": variant.old_source_id,
                "old_xml_url": variant.declared_url,
                "old_identity": variant.declared_identity,
                "canonical_source_id": resolution.source_id,
                "canonical_xml_url": resolution.identity,
                "publication_url": resolution.request_url,
                "old_status": variant.status,
                "representative": variant.row_index == resolution.representative.row_index,
                "published": resolution.source_id in membership_ids,
            })
    _write_csv(args.report_dir / "source-aliases.csv", aliases, [
        "old_source_id", "old_xml_url", "old_identity", "canonical_source_id",
        "canonical_xml_url", "publication_url", "old_status", "representative", "published",
    ])

    quarantine_rows: list[dict[str, object]] = []
    for candidate in blocked:
        reason = candidate.blocking_reason or f"status_{candidate.status}"
        title, title_source = choose_title(candidate.row)
        quarantine_rows.append({
            "row_index": candidate.row_index,
            "old_source_id": candidate.old_source_id,
            "source_title": candidate.intended_title,
            "feed_title": candidate.observed_title,
            "repaired_title": title,
            "title_source": title_source,
            "xml_url": candidate.declared_url,
            "final_url": candidate.final_url,
            "status": candidate.status,
            "reason": reason,
        })
    _write_csv(args.report_dir / "quarantine.csv", quarantine_rows, [
        "row_index", "old_source_id", "source_title", "feed_title", "repaired_title",
        "title_source", "xml_url", "final_url", "status", "reason",
    ])
    _write_csv(args.report_dir / "unmatched-memberships.csv", unmatched, [
        "opml_file", "xml_url", "normalized_identity", "reason", "collection",
        "topic", "subcategory", "claimed_country", "claimed_language", "region",
        "opml_title", "claimed_media_kind",
    ])

    eligible_ids = {resolution.source_id for resolution in resolutions}
    published_ids = {resolution.source_id for resolution in published_resolutions}
    orphaned = [
        {
            "source_id": resolution.source_id,
            "title": resolution.title,
            "xml_url": resolution.request_url,
            "canonical_xml_url": resolution.identity,
        }
        for resolution in resolutions if resolution.source_id not in membership_ids
    ]
    _write_csv(args.report_dir / "publishable-without-membership.csv", orphaned, [
        "source_id", "title", "xml_url", "canonical_xml_url",
    ])

    input_identity_count = len({candidate.declared_identity for candidate in candidates if candidate.declared_identity})
    title_sources = Counter(choose_title(resolution.representative.row)[1] for resolution in resolutions)
    summary: dict[str, object] = {
        "schema_version": SCHEMA_VERSION,
        "inputs": {
            "source_rows": len(candidates),
            "declared_identities": input_identity_count,
            "opml_occurrences": len(raw_memberships),
            "opml_parse_failures": parse_failures,
        },
        "outputs": {
            "eligible_canonical_sources": len(resolutions),
            "canonical_sources": len(published_resolutions),
            "canonical_memberships": len(memberships),
            "source_alias_rows": len(aliases),
            "declared_identity_duplicate_rows": len(candidates) - input_identity_count,
            "accepted_alias_collapse_count": len(aliases) - len(resolutions),
            "rows_withheld_from_canonical_output": len(blocked),
            "publishable_without_membership": len(eligible_ids - membership_ids),
            "unmatched_memberships": len(unmatched),
            "pending_sources_preserved": len(pending_candidates),
        },
        "quarantine": dict(sorted(Counter(
            candidate.blocking_reason or f"status_{candidate.status}" for candidate in blocked
        ).items())),
        "title_sources": dict(sorted(title_sources.items())),
        "artifacts": {
            "sources": str(args.output_sources),
            "memberships": str(args.output_memberships),
            "aliases": str(args.report_dir / "source-aliases.csv"),
            "pending_sources": str(args.pending_output),
            "quarantine": str(args.report_dir / "quarantine.csv"),
            "unmatched_memberships": str(args.report_dir / "unmatched-memberships.csv"),
        },
    }
    args.report_dir.mkdir(parents=True, exist_ok=True)
    (args.report_dir / "reconciliation-summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return summary


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, required=True, help="original source Parquet")
    parser.add_argument("--feeds-root", type=Path, default=Path("feedmine/Resources/Feeds"))
    parser.add_argument("--output-sources", type=Path, default=Path("build/catalog-reconciliation/feeds_corpus_sources.parquet"))
    parser.add_argument("--output-memberships", type=Path, default=Path("build/catalog-reconciliation/feeds_corpus_source_memberships.parquet"))
    parser.add_argument("--pending-output", type=Path, default=Path("build/catalog-reconciliation/pending-source-queue.parquet"))
    parser.add_argument("--report-dir", type=Path, default=Path("build/catalog-reconciliation"))
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    for path in (args.sources, args.feeds_root):
        if not path.exists():
            raise SystemExit(f"input not found: {path}")
    summary = run(args)
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(
            f"Reconciled {summary['inputs']['source_rows']:,} rows into "
            f"{summary['outputs']['canonical_sources']:,} canonical sources; "
            f"quarantined {sum(summary['quarantine'].values()):,} rows."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
