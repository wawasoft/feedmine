#!/usr/bin/env python3
"""Shared FeedMine source identity contract.

Every catalog-producing pipeline must import this module instead of defining
its own URL normalizer or source-id formula.  The canonical form mirrors the
runtime identity used by ``OPMLParser.normalizeURL``:

* decode HTML entities before URL parsing;
* force the identity scheme to HTTPS;
* lowercase the host and drop a leading ``www.``;
* remove fragments, one trailing slash, and known tracking parameters;
* retain all other path and query information in its original order.

The request URL is deliberately separate from the identity.  It is cleaned
without forcing HTTPS or removing a meaningful trailing slash, so the crawler
can still request the server-provided endpoint exactly.
"""

from __future__ import annotations

import hashlib
import html
import math
import urllib.parse


TRACKING_QUERY_PARAMETERS = frozenset({
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "ref", "source", "fbclid", "gclid", "mc_cid", "mc_eid", "ref_src",
})


def clean_text(value: object) -> str:
    """Return a stripped string without leaking None/NaN as literal text."""
    if value is None:
        return ""
    if isinstance(value, float) and math.isnan(value):
        return ""
    text = str(value).strip()
    return "" if text.casefold() in {"nan", "none", "null"} else text


def decode_url_entities(raw: object) -> str:
    """Decode single- or double-escaped URL entities with a bounded loop."""
    value = clean_text(raw)
    for _ in range(3):
        decoded = html.unescape(value)
        if decoded == value:
            break
        value = decoded
    return value


def _netloc(parsed: urllib.parse.SplitResult, hostname: str) -> str:
    port = parsed.port
    if port is not None:
        hostname = f"{hostname}:{port}"
    if parsed.username is None:
        return hostname
    userinfo = urllib.parse.quote(urllib.parse.unquote(parsed.username), safe="")
    if parsed.password is not None:
        userinfo += ":" + urllib.parse.quote(urllib.parse.unquote(parsed.password), safe="")
    return f"{userinfo}@{hostname}"


def valid_http_url(raw: object) -> bool:
    try:
        parsed = urllib.parse.urlsplit(decode_url_entities(raw))
        return parsed.scheme.casefold() in {"http", "https"} and bool(parsed.hostname)
    except ValueError:
        return False


def request_url(raw: object) -> str:
    """Clean a URL for fetching while preserving endpoint semantics."""
    value = decode_url_entities(raw)
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError:
        return value
    if not parsed.scheme or not parsed.hostname:
        return value
    hostname = parsed.hostname.lower()
    netloc = _netloc(parsed, hostname)
    return urllib.parse.urlunsplit((
        parsed.scheme.lower(), netloc, parsed.path, parsed.query, "",
    ))


def canonical_url(raw: object) -> str:
    """Return the versioned cross-layer identity for a feed URL."""
    value = decode_url_entities(raw)
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError:
        return value
    if not parsed.scheme or not parsed.hostname:
        return value

    hostname = parsed.hostname.lower()
    if hostname.startswith("www."):
        hostname = hostname[4:]
    netloc = _netloc(parsed, hostname)
    path = parsed.path[:-1] if parsed.path.endswith("/") else parsed.path
    query = urllib.parse.urlencode([
        (name, item)
        for name, item in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        if name.casefold() not in TRACKING_QUERY_PARAMETERS
    ], doseq=True)
    return urllib.parse.urlunsplit(("https", netloc, path, query, ""))


def compute_source_id(raw: object) -> str:
    """Return the only supported public ``feedmineSourceId`` formula."""
    return hashlib.sha256(canonical_url(raw).encode("utf-8")).hexdigest()
