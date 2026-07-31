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


# ---------------------------------------------------------------------------
# Phase 2: Site scraping (fallback)
# ---------------------------------------------------------------------------

CONTACT_PATHS = [
    "/contact", "/about", "/contato", "/contacto", "/kontakt",
    "/contact-us", "/sobre", "/nosotros", "/chi-siamo",
    "/nous-contacter", "/uber-uns", "/impressum",
]

USER_AGENTS = [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
]

PERSON_NAME_RE = re.compile(
    r'(?:[A-Z][a-z]+(?:\s+[A-Z][a-z]+)+)\s*(?:,?\s*(?:Editor|Publisher|Author|Producer|Host|Director|Founder|CEO|Manager|Journalist|Writer|Reporter|Correspondent))?',
)


def robots_allowed(url: str, user_agent: str, cache: dict[str, RobotFileParser]) -> bool:
    """Check robots.txt for a URL. Cache parsers per domain."""
    parsed = urlsplit(url)
    domain = parsed.hostname or ""
    if domain not in cache:
        rp = RobotFileParser()
        rp.set_url(f"{parsed.scheme}://{domain}/robots.txt")
        try:
            rp.read()
        except Exception:
            rp.allow_all = True
        cache[domain] = rp
    return cache[domain].can_fetch(user_agent, url)


def classify_email_type(email: str, page_text: str) -> tuple[str | None, str]:
    """Determine if an email is personal or generic, and extract name if present."""
    local_part = email.split("@")[0].lower().strip()
    for prefix in GENERIC_PREFIXES:
        if local_part == prefix or local_part.startswith(f"{prefix}-") or local_part.startswith(f"{prefix}."):
            return (None, "generic")
    idx = page_text.lower().find(email.lower())
    if idx >= 0:
        context = page_text[max(0, idx - 200):idx + len(email) + 100]
        name_match = PERSON_NAME_RE.search(context)
        if name_match:
            name = name_match.group(0).strip()
            if len(name.split()) >= 2 and not name.isupper():
                return (name, "personal")
    return (None, "generic")


async def scrape_site(
    session: aiohttp.ClientSession,
    source: SourceRecord,
    semaphore: asyncio.Semaphore,
    robots_cache: dict[str, RobotFileParser],
) -> ContactResult:
    """Try to extract contact email from a site's contact/about/homepage."""
    result = ContactResult(source_id=source.source_id, db_id=source.db_id)
    if not source.site_url:
        result.contact_status = "not_found"
        return result

    base_url = source.site_url.rstrip("/")
    user_agent = USER_AGENTS[hash(source.source_id) % len(USER_AGENTS)]
    urls_to_try = [f"{base_url}{p}" for p in CONTACT_PATHS]
    if base_url not in urls_to_try:
        urls_to_try.append(base_url)

    async with semaphore:
        for url in urls_to_try:
            if not robots_allowed(url, user_agent, robots_cache):
                continue
            try:
                await asyncio.sleep(1.0)
                async with session.get(
                    url,
                    headers={"User-Agent": user_agent},
                    timeout=aiohttp.ClientTimeout(total=10),
                    max_redirects=3,
                ) as resp:
                    if resp.status in (403, 429):
                        result.contact_status = "site_blocked"
                        return result
                    if resp.status != 200:
                        continue
                    html = await resp.text(encoding="utf-8", errors="replace")
            except (aiohttp.ClientError, asyncio.TimeoutError):
                continue

            from bs4 import BeautifulSoup
            soup = BeautifulSoup(html, "html.parser")
            for tag in soup(["script", "style", "nav", "footer", "header"]):
                tag.decompose()
            visible_text = soup.get_text(separator=" ", strip=True)
            emails = EMAIL_RE.findall(visible_text)
            if not emails:
                continue
            for email in emails:
                email_lower = email.lower().strip()
                if "noreply" in email_lower or "no-reply" in email_lower:
                    continue
                name, etype = classify_email_type(email_lower, visible_text)
                result.contact_email = email_lower
                result.contact_name = name
                result.contact_source = (
                    "site_contact_page" if "/contact" in url or "/contato" in url or "/contacto" in url
                    else "site_about_page" if "/about" in url or "/sobre" in url
                    else "site_homepage"
                )
                result.contact_type = etype
                result.contact_status = "found"
                return result

    result.contact_status = "not_found"
    return result


async def phase2_site_scraping(
    sources: list[SourceRecord],
    phase1_results: dict[str, ContactResult],
    max_concurrency: int = 20,
) -> dict[str, ContactResult]:
    """Run Phase 2 on sources that didn't get an email from Phase 1."""
    to_scrape = [
        s for s in sources
        if s.site_url and phase1_results.get(s.source_id, ContactResult(s.source_id, s.db_id)).contact_status != "found"
    ]
    print(f"  Phase 2: {len(to_scrape)} sources to scrape (no RSS email found)")

    results: dict[str, ContactResult] = dict(phase1_results)
    semaphore = asyncio.Semaphore(max_concurrency)
    robots_cache: dict[str, RobotFileParser] = {}
    connector = aiohttp.TCPConnector(limit=max_concurrency, limit_per_host=1)

    async with aiohttp.ClientSession(connector=connector) as session:
        tasks = [scrape_site(session, s, semaphore, robots_cache) for s in to_scrape]
        completed = 0
        for coro in asyncio.as_completed(tasks):
            result = await coro
            results[result.source_id] = result
            completed += 1
            if completed % 500 == 0:
                found = sum(1 for r in results.values() if r.contact_status == "found")
                print(f"  Phase 2: {completed}/{len(to_scrape)} processed, {found} total emails found")

    return results
