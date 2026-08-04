#!/usr/bin/env python3
"""Versioned cross-language FeedMine source identity contract.

``canonical_url`` is an identity transform, not a fetch transform.  It is
allowed to remove editorial tracking and ephemeral authorization parameters
so that a refetched signed endpoint keeps the same source ID.

``request_url`` is the fetch transform.  It decodes legacy XML entities and
removes fragments, but deliberately preserves the scheme, path, query spelling
and every authorization/signing parameter supplied by the publisher.

The implementation avoids ``parse_qsl``/``urlencode``.  Those helpers change
the spelling of retained query parameters (``:``/``/``/spaces, bare keys and
``+``), which made Python identities differ from Foundation.URLComponents.
"""

from __future__ import annotations

import hashlib
import math
import re
import urllib.parse


IDENTITY_CONTRACT_VERSION = 2

TRACKING_QUERY_PARAMETERS = frozenset({
    "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
    "ref", "source", "fbclid", "gclid", "mc_cid", "mc_eid", "ref_src",
})

# These values authorize a request but do not identify the feed.  They are
# removed only by canonical_url; request_url always preserves them.
EPHEMERAL_QUERY_PARAMETERS = frozenset({
    "temp_url_sig", "temp_url_expires", "expires", "cfid", "cftoken",
    "jsessionid", "phpsessid",
})

_XML_NAMED_ENTITIES = {
    "amp": "&",
    "lt": "<",
    "gt": ">",
    "quot": '"',
    "apos": "'",
}
_ENTITY_RE = re.compile(
    r"&(?:#(?P<decimal>[0-9]+)|#(?:x|X)(?P<hex>[0-9A-Fa-f]+)|(?P<name>[A-Za-z]+));"
)
_HEX = frozenset("0123456789abcdefABCDEF")
_PATH_SAFE = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    "-._~!$&'()*+,;=/:@"
)
_QUERY_SAFE = _PATH_SAFE | frozenset("?")
_USERINFO_SAFE = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    "-._~!$&'()*+,;=:"
)


def clean_text(value: object) -> str:
    """Return a stripped string without leaking None/NaN as literal text."""
    if value is None:
        return ""
    if isinstance(value, float) and math.isnan(value):
        return ""
    text = str(value).strip()
    return "" if text.casefold() in {"nan", "none", "null"} else text


def _decode_entity(match: re.Match[str]) -> str:
    name = match.group("name")
    if name is not None:
        return _XML_NAMED_ENTITIES.get(name.casefold(), match.group(0))
    try:
        scalar = int(match.group("decimal") or match.group("hex"), 10 if match.group("decimal") else 16)
    except (TypeError, ValueError):
        return match.group(0)
    if scalar > 0x10FFFF or 0xD800 <= scalar <= 0xDFFF:
        return match.group(0)
    return chr(scalar)


def decode_url_entities(raw: object) -> str:
    """Decode XML named/numeric entities, including double escaping.

    OPML is XML, so its portable named-entity set is the five XML entities;
    numeric entities cover all Unicode scalars.  Keeping this exact set on
    both Python and Swift avoids the previous ``html.unescape`` asymmetry.
    """
    value = clean_text(raw)
    for _ in range(3):
        decoded = _ENTITY_RE.sub(_decode_entity, value)
        if decoded == value:
            break
        value = decoded
    return value


def _normalize_percent_encoded(value: str, safe: frozenset[str]) -> str:
    """Encode Unicode/invalid percent signs without rewriting URL delimiters."""
    result: list[str] = []
    index = 0
    while index < len(value):
        character = value[index]
        if (
            character == "%"
            and index + 2 < len(value)
            and value[index + 1] in _HEX
            and value[index + 2] in _HEX
        ):
            result.append("%" + value[index + 1:index + 3].upper())
            index += 3
            continue
        for byte in character.encode("utf-8"):
            ascii_character = chr(byte)
            result.append(ascii_character if byte < 128 and ascii_character in safe else f"%{byte:02X}")
        index += 1
    return "".join(result)


def _canonical_hostname(parsed: urllib.parse.SplitResult) -> tuple[str, bool]:
    hostname = parsed.hostname
    if not hostname:
        raise ValueError("missing hostname")
    try:
        decoded = urllib.parse.unquote_to_bytes(hostname).decode("utf-8")
    except (UnicodeDecodeError, ValueError):
        raise ValueError("invalid encoded hostname") from None
    decoded = decoded.casefold()
    is_ipv6 = ":" in decoded
    if not is_ipv6 and decoded.startswith("www."):
        decoded = decoded[4:]
    if not is_ipv6:
        try:
            decoded = decoded.encode("idna").decode("ascii")
        except UnicodeError:
            raise ValueError("invalid IDN hostname") from None
    return decoded, is_ipv6


def _validated_port(parsed: urllib.parse.SplitResult) -> int | None:
    # urllib deliberately raises ValueError for non-numeric and out-of-range
    # ports.  Centralizing that access prevents a malformed crawl row from
    # crashing reconciliation, curation or publication.
    port = parsed.port
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("port outside 1...65535")
    return port


def _netloc(parsed: urllib.parse.SplitResult, *, strip_www: bool) -> str:
    hostname, is_ipv6 = _canonical_hostname(parsed)
    if not strip_www and not is_ipv6:
        # request_url lowercases/IDNA-normalizes but does not remove www.
        original = urllib.parse.unquote_to_bytes(parsed.hostname or "").decode("utf-8").casefold()
        try:
            hostname = original.encode("idna").decode("ascii")
        except UnicodeError:
            raise ValueError("invalid IDN hostname") from None
    host_text = f"[{hostname}]" if is_ipv6 else hostname
    port = _validated_port(parsed)
    if port is not None:
        host_text = f"{host_text}:{port}"
    if parsed.username is None:
        return host_text
    userinfo = _normalize_percent_encoded(parsed.username, _USERINFO_SAFE)
    if parsed.password is not None:
        userinfo += ":" + _normalize_percent_encoded(parsed.password, _USERINFO_SAFE)
    return f"{userinfo}@{host_text}"


def _split_http_url(raw: object) -> tuple[str, urllib.parse.SplitResult] | None:
    value = decode_url_entities(raw)
    try:
        parsed = urllib.parse.urlsplit(value)
        if parsed.scheme.casefold() not in {"http", "https"} or not parsed.hostname:
            return None
        _validated_port(parsed)
        _canonical_hostname(parsed)
    except (UnicodeError, ValueError):
        return None
    return value, parsed


def valid_http_url(raw: object) -> bool:
    return _split_http_url(raw) is not None


def request_url(raw: object) -> str:
    """Clean a URL for fetching without applying the identity transform."""
    value = decode_url_entities(raw)
    split = _split_http_url(value)
    if split is None:
        return value
    _, parsed = split
    try:
        netloc = _netloc(parsed, strip_www=False)
    except (UnicodeError, ValueError):
        return value
    return urllib.parse.urlunsplit((
        parsed.scheme.casefold(),
        netloc,
        _normalize_percent_encoded(parsed.path, _PATH_SAFE),
        _normalize_percent_encoded(parsed.query, _QUERY_SAFE),
        "",
    ))


def _is_identity_parameter(name: str) -> bool:
    decoded = urllib.parse.unquote_plus(name).casefold()
    return not (
        decoded in TRACKING_QUERY_PARAMETERS
        or decoded in EPHEMERAL_QUERY_PARAMETERS
        or decoded.startswith("x-amz-")
    )


def _canonical_query(raw_query: str) -> str:
    retained: list[str] = []
    for segment in raw_query.split("&"):
        if not segment:
            continue
        name = segment.split("=", 1)[0]
        if _is_identity_parameter(name):
            retained.append(_normalize_percent_encoded(segment, _QUERY_SAFE))
    return "&".join(retained)


def canonical_url(raw: object) -> str:
    """Return the v2 byte-stable identity for a feed URL."""
    value = decode_url_entities(raw)
    split = _split_http_url(value)
    if split is None:
        return value
    _, parsed = split
    try:
        netloc = _netloc(parsed, strip_www=True)
    except (UnicodeError, ValueError):
        return value
    path = _normalize_percent_encoded(parsed.path, _PATH_SAFE)
    if path.endswith("/"):
        path = path[:-1]
    return urllib.parse.urlunsplit((
        "https",
        netloc,
        path,
        _canonical_query(parsed.query),
        "",
    ))


def compute_source_id(raw: object) -> str:
    """Return the only supported public ``feedmineSourceId`` formula."""
    return hashlib.sha256(canonical_url(raw).encode("utf-8")).hexdigest()
