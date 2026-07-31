#!/usr/bin/env python3
"""Extract contact emails for all Feedmine catalog sources.

Phase 1: RSS metadata (managingEditor, webMaster, itunes:owner)
Phase 2: Site scraping (contact/about/homepage pages)
Phase 3: Validation (regex -> DNS MX -> disposable filter -> SMTP RCPT TO)

Usage:
    python3 scripts/extract_contact_emails.py \
      --catalog feedmine/Resources/FeedEngine/catalog.sqlite \
      --output build/feeds_corpus_contacts.parquet \
      --max-sources 0          # 0 = all
      --skip-scraping           # Phase 1 only
      --skip-smtp               # Skip SMTP verification (faster, less accurate)
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import re
import signal
import smtplib
import socket
import sys
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit
from urllib.robotparser import RobotFileParser

import aiohttp
import pyarrow as pa
import pyarrow.parquet as pq
import sqlite3


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class SourceRecord:
    """One row from catalog_source for extraction."""
    source_id: str        # hex digest (feedmineSourceId)
    db_id: int            # catalog_source.id
    title: str
    declared_url: str     # RSS/Atom feed URL
    site_url: str | None  # Website URL
    media_kind: str       # text, audio, video, forum


@dataclass
class ContactResult:
    """Extraction result for one source."""
    source_id: str
    db_id: int
    contact_email: str | None = None
    contact_name: str | None = None
    contact_source: str | None = None
    contact_type: str | None = None      # "personal" | "generic"
    contact_status: str = "pending"       # "found" | "not_found" | "verified" | "unverified" | "invalid"


# Email regex — RFC 5322 simplified, good enough for HTML scraping
EMAIL_RE = re.compile(
    r'[a-zA-Z0-9.!#$%&\'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?'
    r'(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*',
    re.IGNORECASE
)

# Generic email prefixes that indicate a non-personal address
GENERIC_PREFIXES = {
    'info', 'contact', 'admin', 'support', 'hello', 'hi', 'help', 'sales',
    'marketing', 'press', 'media', 'news', 'editor', 'webmaster', 'postmaster',
    'noreply', 'no-reply', 'mail', 'email', 'office', 'team', 'redacao',
    'redacción', 'redaction', 'kontakt', 'contacto', 'contato', 'geral',
    'gerencia', 'direccion', 'direção', 'atendimento', 'faleconosco',
    'comercial', 'vendas', 'imprensa', 'assessoria', 'comunicacao',
}


# ---------------------------------------------------------------------------
# Database reader
# ---------------------------------------------------------------------------

def read_sources(catalog_path: Path) -> list[SourceRecord]:
    """Read all source records from catalog.sqlite."""
    conn = sqlite3.connect(str(catalog_path))
    conn.row_factory = sqlite3.Row
    rows = conn.execute("""
        SELECT id, key, title, declared_url, site_url, media_kind
        FROM catalog_source
        ORDER BY id
    """).fetchall()
    conn.close()

    sources = []
    for r in rows:
        site = r["site_url"]
        if site and not site.startswith("http"):
            site = None
        sources.append(SourceRecord(
            source_id=r["key"],
            db_id=r["id"],
            title=r["title"],
            declared_url=r["declared_url"],
            site_url=site,
            media_kind=r["media_kind"],
        ))
    return sources


# ---------------------------------------------------------------------------
# Checkpoint / resume
# ---------------------------------------------------------------------------

CHECKPOINT_FILE = Path("build/contact_extraction_checkpoint.json")


def load_checkpoint() -> dict[str, dict]:
    """Load existing results so we can resume."""
    if not CHECKPOINT_FILE.exists():
        return {}
    with open(CHECKPOINT_FILE) as f:
        raw = json.load(f)
    return {r["source_id"]: r for r in raw.get("results", [])}


def save_checkpoint(results: dict[str, ContactResult]):
    """Save incremental results. Called every 500 sources."""
    CHECKPOINT_FILE.parent.mkdir(parents=True, exist_ok=True)
    data = {
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "total_processed": len(results),
        "results": [
            {
                "source_id": r.source_id,
                "db_id": r.db_id,
                "contact_email": r.contact_email,
                "contact_name": r.contact_name,
                "contact_source": r.contact_source,
                "contact_type": r.contact_type,
                "contact_status": r.contact_status,
            }
            for r in results.values()
        ],
    }
    tmp = CHECKPOINT_FILE.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, CHECKPOINT_FILE)


# ---------------------------------------------------------------------------
# Phase 1: RSS/Atom feed metadata extraction
# ---------------------------------------------------------------------------

RSS_EMAIL_FIELDS = [
    ("managingEditor", "rss_managing_editor"),
    ("webMaster", "rss_web_master"),
    ("{http://www.w3.org/2005/Atom}author/{http://www.w3.org/2005/Atom}email", "rss_author"),
]

ITUNES_NS = "http://www.itunes.com/dtds/podcast-1.0.dtd"
ITUNES_OWNER_EMAIL = f"{{{ITUNES_NS}}}owner/{{{ITUNES_NS}}}email"


def extract_name_from_email_string(raw: str) -> tuple[str | None, str | None]:
    """Parse 'Name <email>' or 'email (Name)' into (name, email)."""
    bracket_match = re.match(r'^([^<]+)\s*<([^>]+)>$', raw.strip())
    if bracket_match:
        name = bracket_match.group(1).strip()
        email = bracket_match.group(2).strip()
        email_match = EMAIL_RE.search(email)
        return (name if name else None, email_match.group(0) if email_match else None)

    paren_match = re.match(r'^([^(]+)\s*\(([^)]+)\)$', raw.strip())
    if paren_match:
        email_part = paren_match.group(1).strip()
        name = paren_match.group(2).strip()
        email_match = EMAIL_RE.search(email_part)
        return (name if name else None, email_match.group(0) if email_match else None)

    email_match = EMAIL_RE.search(raw)
    return (None, email_match.group(0) if email_match else None)


async def extract_rss_email(
    session: aiohttp.ClientSession,
    source: SourceRecord,
    semaphore: asyncio.Semaphore,
) -> ContactResult:
    """Try to extract contact email from RSS/Atom feed metadata."""
    result = ContactResult(source_id=source.source_id, db_id=source.db_id)

    if not source.declared_url:
        result.contact_status = "not_found"
        return result

    async with semaphore:
        try:
            async with session.get(
                source.declared_url,
                headers={"Range": "bytes=0-65536"},
                timeout=aiohttp.ClientTimeout(total=10),
                max_redirects=3,
            ) as resp:
                if resp.status != 200 and resp.status != 206:
                    result.contact_status = "not_found"
                    return result

                body = await resp.text(encoding="utf-8", errors="replace")

        except (aiohttp.ClientError, asyncio.TimeoutError, UnicodeDecodeError):
            result.contact_status = "not_found"
            return result

    # Parse XML
    try:
        root = ET.fromstring(body)
    except ET.ParseError:
        # Try regex on raw text as fallback for malformed feeds
        emails = EMAIL_RE.findall(body)
        if emails:
            result.contact_email = emails[0].lower()
            result.contact_type = "generic"
            result.contact_source = "rss_raw_text"
            result.contact_status = "found"
        else:
            result.contact_status = "not_found"
        return result

    # Check standard RSS fields
    for field, source_label in RSS_EMAIL_FIELDS:
        el = root.find(f".//{field}")
        if el is not None and el.text:
            name, email = extract_name_from_email_string(el.text)
            if email:
                result.contact_email = email.lower()
                result.contact_name = name
                result.contact_source = source_label
                result.contact_type = "personal" if name else "generic"
                result.contact_status = "found"
                return result

    # Check iTunes owner email (podcasts)
    itunes_el = root.find(f".//{ITUNES_OWNER_EMAIL}")
    if itunes_el is not None and itunes_el.text:
        _, email = extract_name_from_email_string(itunes_el.text)
        if email:
            result.contact_email = email.lower()
            result.contact_source = "itunes_owner"
            result.contact_type = "generic"
            result.contact_status = "found"
            return result

    result.contact_status = "not_found"
    return result


async def phase1_rss_extraction(
    sources: list[SourceRecord],
    max_concurrency: int = 50,
) -> dict[str, ContactResult]:
    """Run Phase 1 across all sources with RSS URLs."""
    results: dict[str, ContactResult] = {}
    semaphore = asyncio.Semaphore(max_concurrency)

    connector = aiohttp.TCPConnector(limit=max_concurrency, limit_per_host=5)
    async with aiohttp.ClientSession(connector=connector) as session:
        tasks = [extract_rss_email(session, s, semaphore) for s in sources if s.declared_url]

        completed = 0
        for coro in asyncio.as_completed(tasks):
            result = await coro
            results[result.source_id] = result
            completed += 1
            if completed % 500 == 0:
                found = sum(1 for r in results.values() if r.contact_status == "found")
                print(f"  Phase 1: {completed}/{len(tasks)} processed, {found} emails found")

    return results
