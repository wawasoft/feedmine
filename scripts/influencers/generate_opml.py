#!/usr/bin/env python3
"""Generate OPML outline entries for influencer channels with proper feedmine metadata."""

import hashlib
import xml.sax.saxutils as saxutils
from datetime import datetime
from typing import Optional


def feedmine_source_id(xml_url: str) -> str:
    """SHA-256 hash of the xmlUrl — unique identifier for each feed."""
    return hashlib.sha256(xml_url.encode("utf-8")).hexdigest()


def escape_xml(text: str) -> str:
    """Escape special XML characters."""
    return saxutils.escape(text)


def outline_entry(
    *,
    text: str,
    xml_url: str,
    description: str,
    language: str,
    category: str,
    html_url: str,
    topic: str,
    subcategory: str,
    nature: str = "periodic",
    activity: str = "active",
    quality: int = 75,
    media_kind: str = "video",
    enabled: bool = True,
    articles_fetched: int = 0,
    latest_item_at: Optional[str] = None,
) -> str:
    """Generate a single feedmine <outline> element with all metadata attributes."""

    text_esc = escape_xml(text)
    xml_url_esc = escape_xml(xml_url)
    desc_esc = escape_xml(description)
    lang_esc = escape_xml(language)
    cat_esc = escape_xml(category)
    html_esc = escape_xml(html_url)
    topic_esc = escape_xml(topic)
    subcat_esc = escape_xml(subcategory)
    source_id = feedmine_source_id(xml_url)

    attrs = [
        f'text="{text_esc}"',
        f'title="{text_esc}"',
        'type="rss"',
        f'xmlUrl="{xml_url_esc}"',
        f'description="{desc_esc}"',
        f'language="{lang_esc}"',
        f'category="{cat_esc}"',
        f'feedmineSourceId="{source_id}"',
        f'feedmineTopic="{topic_esc}"',
        f'feedmineSubcategory="{subcat_esc}"',
        f'feedmineNature="{nature}"',
        f'feedmineActivity="{activity}"',
        f'feedmineArticlesFetched="{articles_fetched}"',
        f'feedmineQualityScore="{quality}"',
        f'feedmineDefaultEnabled="{"true" if enabled else "false"}"',
        f'feedmineMediaKind="{media_kind}"',
        f'htmlUrl="{html_esc}"',
    ]

    if latest_item_at:
        attrs.append(f'feedmineLatestItemAt="{escape_xml(latest_item_at)}"')

    return f'        <outline {" ".join(attrs)} />'


def category_header(text: str, level: int = 2) -> str:
    """Generate a category/subcategory opening outline tag."""
    indent = "    " if level == 1 else "      "
    escaped = escape_xml(text)
    return f'{indent}<outline text="{escaped}" title="{escaped}">'


def category_footer(level: int = 2) -> str:
    """Generate a category/subcategory closing outline tag."""
    indent = "    " if level == 1 else "      "
    return f"{indent}</outline>"


def youtube_rss(channel_id_or_handle: str) -> str:
    """Convert a YouTube channel ID or @handle to its RSS feed URL.

    If it starts with 'UC' and is 24 chars, treat as channel ID.
    If it starts with '@', treat as handle.
    Otherwise, treat as channel ID.
    """
    if channel_id_or_handle.startswith("UC") and len(channel_id_or_handle) == 24:
        return f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id_or_handle}"
    elif channel_id_or_handle.startswith("@"):
        # YouTube handles need the channel ID, but RSS only works with channel IDs
        # Return a placeholder — the handle to channel ID mapping requires API
        return f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id_or_handle}"
    else:
        return f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id_or_handle}"


def youtube_html(channel_id_or_handle: str) -> str:
    """Get the YouTube channel HTML URL."""
    if channel_id_or_handle.startswith("UC") and len(channel_id_or_handle) == 24:
        return f"https://www.youtube.com/channel/{channel_id_or_handle}"
    elif channel_id_or_handle.startswith("@"):
        return f"https://www.youtube.com/{channel_id_or_handle}"
    else:
        return f"https://www.youtube.com/channel/{channel_id_or_handle}"


# Example usage
if __name__ == "__main__":
    # Example: Brazilian YouTuber
    entry = outline_entry(
        text="Porta dos Fundos",
        xml_url=youtube_rss("UClIfL8a6NLRXX6GCQpK0IbA"),
        description="Brazilian comedy YouTube channel with sketches and humor.",
        language="pt-BR",
        category="comedy,sketches,brazil,youtube,humor",
        html_url=youtube_html("UClIfL8a6NLRXX6GCQpK0IbA"),
        topic="Influencers & Creators",
        subcategory="YouTube Creators",
        nature="periodic",
        activity="active",
        quality=92,
        media_kind="video",
    )
    print(entry)
