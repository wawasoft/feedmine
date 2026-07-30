#!/usr/bin/env python3
"""
Build influencer OPML sections for each country.

Strategy:
- Tier 1 (~50): Global influencers (shared across all countries)
- Tier 2 (~50): Regional influencers (shared within region)
- Tier 3 (~100): Country-specific local influencers

Output: A new "Influencers & Creators" section inserted into each country's OPML.
"""

import hashlib
import xml.sax.saxutils as saxutils
import json
import os
import sys
from pathlib import Path
from typing import Optional

# ── XML helpers ──────────────────────────────────────────────────

def feedmine_source_id(xml_url: str) -> str:
    return hashlib.sha256(xml_url.encode("utf-8")).hexdigest()

def esc(text: str) -> str:
    return saxutils.escape(text)

def outline_entry(
    *,
    text: str,
    xml_url: str,
    description: str,
    language: str,
    category: str,
    html_url: str,
    topic: str = "Influencers & Creators",
    subcategory: str = "YouTube Creators",
    nature: str = "periodic",
    activity: str = "active",
    quality: int = 75,
    media_kind: str = "video",
    enabled: bool = True,
    articles_fetched: int = 0,
    latest_item_at: Optional[str] = None,
) -> str:
    text_esc = esc(text)
    xml_url_esc = esc(xml_url)
    desc_esc = esc(description)
    lang_esc = esc(language)
    cat_esc = esc(category)
    html_esc = esc(html_url)
    topic_esc = esc(topic)
    subcat_esc = esc(subcategory)
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
        attrs.append(f'feedmineLatestItemAt="{esc(latest_item_at)}"')
    return f'        <outline {" ".join(attrs)} />'

def category_header(text: str, level: int = 1) -> str:
    indent = "    " if level == 1 else "      "
    return f'{indent}<outline text="{esc(text)}" title="{esc(text)}">'

def category_footer(level: int = 1) -> str:
    indent = "    " if level == 1 else "      "
    return f"{indent}</outline>"


# ══════════════════════════════════════════════════════════════════
# TIER 1: GLOBAL INFLUENCERS (consumed worldwide)
# These are added to every country's feed.
# ══════════════════════════════════════════════════════════════════

GLOBAL_INFLUENCERS = [
    # ── YouTube Creators (global) ──
    {
        "text": "MrBeast",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCX6OQ3DkcsbYNE6H8uQQuVA",
        "description": "Jimmy Donaldson — the world's most-subscribed YouTuber, known for extreme challenges, philanthropy, and viral stunts.",
        "language": "en", "html_url": "https://www.youtube.com/@MrBeast",
        "category": "challenges,philanthropy,entertainment,viral,global",
        "subcategory": "YouTube Creators", "quality": 98, "media_kind": "video",
    },
    {
        "text": "PewDiePie",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UC-lHJZR3Gqxm24_Vd_AJ5Yw",
        "description": "Felix Kjellberg — iconic gaming, commentary, and meme-review YouTuber from Sweden with global reach.",
        "language": "en", "html_url": "https://www.youtube.com/@PewDiePie",
        "category": "gaming,commentary,memes,entertainment,global",
        "subcategory": "YouTube Creators", "quality": 95, "media_kind": "video",
    },
    {
        "text": "Mark Rober",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCY1kMZp36IQSyNx_9h4mpCg",
        "description": "Former NASA engineer creating viral science and engineering videos, including glitter bombs and squirrel obstacle courses.",
        "language": "en", "html_url": "https://www.youtube.com/@MarkRober",
        "category": "science,engineering,DIY,education,entertainment,global",
        "subcategory": "YouTube Creators", "quality": 96, "media_kind": "video",
    },
    {
        "text": "Dude Perfect",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCRijo3ddMTht_IHyNSNXpNQ",
        "description": "Five guys from Texas doing trick shots, records, battles, and family-friendly sports entertainment.",
        "language": "en", "html_url": "https://www.youtube.com/@DudePerfect",
        "category": "sports,trick shots,entertainment,family,global",
        "subcategory": "YouTube Creators", "quality": 93, "media_kind": "video",
    },
    {
        "text": "Marques Brownlee (MKBHD)",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCBJycsmduvYEL83R_U4JriQ",
        "description": "Marques Brownlee — leading tech reviewer covering smartphones, laptops, EVs, and gadgets with in-depth analysis.",
        "language": "en", "html_url": "https://www.youtube.com/@mkbhd",
        "category": "technology,reviews,gadgets,smartphones,EVs,global",
        "subcategory": "YouTube Creators", "quality": 96, "media_kind": "video",
    },
    {
        "text": "Kurzgesagt – In a Nutshell",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCsXVk37bltHxD1rDPwtNM8Q",
        "description": "Beautifully animated science explainer videos covering space, biology, philosophy, and technology.",
        "language": "en", "html_url": "https://www.youtube.com/@kurzgesagt",
        "category": "science,animation,education,philosophy,space,global",
        "subcategory": "YouTube Creators", "quality": 97, "media_kind": "video",
    },
    {
        "text": "Veritasium",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCHnyfMqiRRG1u-2MsSQLbXA",
        "description": "Derek Muller explores the science behind everyday phenomena with experiments and expert interviews.",
        "language": "en", "html_url": "https://www.youtube.com/@veritasium",
        "category": "science,education,experiments,physics,global",
        "subcategory": "YouTube Creators", "quality": 96, "media_kind": "video",
    },
    {
        "text": "Vsauce",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UC6nSFpj9HTCZ5t-N3Rm3-HA",
        "description": "Michael Stevens explores mind-bending science, math, and philosophy questions through deep dives.",
        "language": "en", "html_url": "https://www.youtube.com/@Vsauce",
        "category": "science,philosophy,education,mind-bending,global",
        "subcategory": "YouTube Creators", "quality": 95, "media_kind": "video",
    },
    {
        "text": "CrashCourse",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCX6b17PVsYBQ0ip5gyeme-Q",
        "description": "John and Hank Green's educational series covering history, science, literature, and more with engaging animation.",
        "language": "en", "html_url": "https://www.youtube.com/@crashcourse",
        "category": "education,history,science,literature,global",
        "subcategory": "YouTube Creators", "quality": 94, "media_kind": "video",
    },
    {
        "text": "Tom Scott",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCBa659QWEk1AI4Tg--mrJ2A",
        "description": "British educator exploring amazing places, linguistics, technology, and interesting facts in short-form videos.",
        "language": "en", "html_url": "https://www.youtube.com/@TomScottGo",
        "category": "education,travel,linguistics,technology,facts,global",
        "subcategory": "YouTube Creators", "quality": 94, "media_kind": "video",
    },
    {
        "text": "Linus Tech Tips",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCXuqSBlHAE6Xw-yeJA0Tunw",
        "description": "Linus Sebastian — PC hardware reviews, tech news, build guides, and ambitious tech experiments.",
        "language": "en", "html_url": "https://www.youtube.com/@LinusTechTips",
        "category": "technology,PC hardware,reviews,builds,tech news,global",
        "subcategory": "YouTube Creators", "quality": 93, "media_kind": "video",
    },
    {
        "text": "Kallmekris",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCz0clEIp7B1P2wJSB6EF5EA",
        "description": "Kris Collins — Canadian TikTok and YouTube personality creating comedy sketches, characters, and relatable humor.",
        "language": "en", "html_url": "https://www.youtube.com/@kallmekris",
        "category": "comedy,sketches,characters,humor,global",
        "subcategory": "YouTube Creators", "quality": 90, "media_kind": "video",
    },
    {
        "text": "Ryan Trahan",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UC9hVJX3-hOdpYBS_4c6SWTA",
        "description": "American YouTuber known for creative challenge videos, survival series, and entrepreneurial storytelling.",
        "language": "en", "html_url": "https://www.youtube.com/@RyanTrahan",
        "category": "challenges,storytelling,entertainment,global",
        "subcategory": "YouTube Creators", "quality": 91, "media_kind": "video",
    },
    {
        "text": "Yes Theory",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCvKRFNawVcuzMg1b9kJAXIw",
        "description": "A group of friends seeking discomfort through travel, challenges, and human connection stories around the world.",
        "language": "en", "html_url": "https://www.youtube.com/@YesTheory",
        "category": "travel,challenges,human connection,lifestyle,global",
        "subcategory": "YouTube Creators", "quality": 92, "media_kind": "video",
    },
    {
        "text": "NikkieTutorials",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCU2Xh2-1Q4g1GQ4D4_wDgQg",
        "description": "Nikkie de Jager — Dutch makeup artist and beauty influencer known for transformative makeup tutorials.",
        "language": "en", "html_url": "https://www.youtube.com/@NikkieTutorials",
        "category": "beauty,makeup,tutorials,fashion,global",
        "subcategory": "YouTube Creators", "quality": 92, "media_kind": "video",
    },
    {
        "text": "Nas Daily",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCJsDIsE3I3_tGKS2V1LzNnQ",
        "description": "Nuseir Yassin — 1-minute daily videos from around the world covering culture, technology, and human stories.",
        "language": "en", "html_url": "https://www.youtube.com/@NasDaily",
        "category": "travel,culture,stories,global,daily",
        "subcategory": "YouTube Creators", "quality": 90, "media_kind": "video",
    },
    {
        "text": "Vox",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCLXo7UDZvByw2ixzpQCufnA",
        "description": "Explanatory journalism through video essays on politics, culture, science, and current events.",
        "language": "en", "html_url": "https://www.youtube.com/@Vox",
        "category": "journalism,explainers,politics,culture,science,global",
        "subcategory": "YouTube Creators", "quality": 94, "media_kind": "video",
    },
    {
        "text": "Johnny Harris",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCmGSJVG3mCRXVOP4yZrU1Dw",
        "description": "Former Vox journalist making long-form video essays on geopolitics, history, and international affairs.",
        "language": "en", "html_url": "https://www.youtube.com/@johnnyharris",
        "category": "geopolitics,history,journalism,video essays,global",
        "subcategory": "YouTube Creators", "quality": 93, "media_kind": "video",
    },
    {
        "text": "Cleo Abram",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UChBqklxViF7prYoKJ6BhbAA",
        "description": "Making optimistic tech explainers about futuristic technologies, science, and engineering breakthroughs.",
        "language": "en", "html_url": "https://www.youtube.com/@CleoAbram",
        "category": "technology,science,futurism,optimism,global",
        "subcategory": "YouTube Creators", "quality": 91, "media_kind": "video",
    },
    {
        "text": "Ali Abdaal",
        "xml_url": "https://www.youtube.com/feeds/videos.xml?channel_id=UCoOae5nYA7VqaXzerajD0lg",
        "description": "Doctor-turned-entrepreneur sharing practical productivity tips, book summaries, and creator-economy insights.",
        "language": "en", "html_url": "https://www.youtube.com/@aliabdaal",
        "category": "productivity,books,entrepreneurship,creator economy,global",
        "subcategory": "YouTube Creators", "quality": 92, "media_kind": "video",
    },
    # ── Podcasters (global) ──
    {
        "text": "The Joe Rogan Experience",
        "xml_url": "https://feeds.simplecast.com/qVU9Y0IK",
        "description": "Joe Rogan's long-form conversations with comedians, scientists, authors, and thought leaders — the world's most popular podcast.",
        "language": "en", "html_url": "https://open.spotify.com/show/4rOoJ6Egrf8K2IrywzwOMk",
        "category": "comedy,interviews,science,culture,podcast,global",
        "subcategory": "Podcasters", "quality": 98, "media_kind": "audio",
    },
    {
        "text": "Huberman Lab",
        "xml_url": "https://feeds.transistor.fm/huberman-lab",
        "description": "Dr. Andrew Huberman discusses neuroscience, health optimization, and science-based tools for everyday life.",
        "language": "en", "html_url": "https://www.hubermanlab.com/",
        "category": "neuroscience,health,science,optimization,podcast,global",
        "subcategory": "Podcasters", "quality": 96, "media_kind": "audio",
    },
    {
        "text": "Lex Fridman Podcast",
        "xml_url": "https://lexfridman.com/feed/podcast/",
        "description": "Long-form conversations with the greatest minds in AI, science, philosophy, and technology.",
        "language": "en", "html_url": "https://lexfridman.com/podcast/",
        "category": "AI,science,philosophy,technology,interviews,global",
        "subcategory": "Podcasters", "quality": 95, "media_kind": "audio",
    },
    {
        "text": "The Diary of a CEO",
        "xml_url": "https://feeds.megaphone.fm/ADL9846637102",
        "description": "Steven Bartlett interviews world-class entrepreneurs, thinkers, and performers about their life stories and lessons.",
        "language": "en", "html_url": "https://stevenbartlett.com/the-diary-of-a-ceo/",
        "category": "entrepreneurship,interviews,business,life lessons,global",
        "subcategory": "Podcasters", "quality": 93, "media_kind": "audio",
    },
    {
        "text": "SmartLess",
        "xml_url": "https://rss.art19.com/smartless",
        "description": "Jason Bateman, Sean Hayes, and Will Arnett surprise each other with mystery celebrity guests in this comedy interview show.",
        "language": "en", "html_url": "https://www.smartless.com/",
        "category": "comedy,interviews,celebrities,entertainment,global",
        "subcategory": "Podcasters", "quality": 93, "media_kind": "audio",
    },
    {
        "text": "Call Her Daddy",
        "xml_url": "https://feeds.megaphone.fm/call-her-daddy",
        "description": "Alex Cooper's unfiltered conversations about relationships, mental health, and modern womanhood.",
        "language": "en", "html_url": "https://open.spotify.com/show/7gYbvY5bhxrXkjzPj7vDwb",
        "category": "relationships,mental health,women,lifestyle,global",
        "subcategory": "Podcasters", "quality": 92, "media_kind": "audio",
    },
    {
        "text": "TED Talks Daily",
        "xml_url": "https://feeds.megaphone.fm/TPG6175046888",
        "description": "Daily TED talks featuring thought-provoking ideas and inspiring speakers from every discipline.",
        "language": "en", "html_url": "https://www.ted.com/podcasts/ted-talks-daily",
        "category": "ideas,education,inspiration,science,technology,global",
        "subcategory": "Podcasters", "quality": 95, "media_kind": "audio",
    },
    {
        "text": "The Tim Ferriss Show",
        "xml_url": "https://rss.art19.com/tim-ferriss-show",
        "description": "Tim Ferriss deconstructs world-class performers to extract actionable tools, tactics, and routines.",
        "language": "en", "html_url": "https://tim.blog/podcast/",
        "category": "productivity,interviews,business,health,self-improvement,global",
        "subcategory": "Podcasters", "quality": 94, "media_kind": "audio",
    },
    {
        "text": "Stuff You Should Know",
        "xml_url": "https://feeds.simplecast.com/vXFJbGBI",
        "description": "Josh Clark and Chuck Bryant explore a wide range of topics, from science to history to pop culture.",
        "language": "en", "html_url": "https://www.iheart.com/podcast/105-stuff-you-should-know-26940277/",
        "category": "education,science,history,pop culture,curiosity,global",
        "subcategory": "Podcasters", "quality": 93, "media_kind": "audio",
    },
    {
        "text": "My First Million",
        "xml_url": "https://feeds.megaphone.fm/HS4419457859",
        "description": "Sam Parr and Shaan Puri brainstorm business ideas, analyze market trends, and share entrepreneurial stories.",
        "language": "en", "html_url": "https://www.mfmpod.com/",
        "category": "entrepreneurship,business ideas,startups,trends,global",
        "subcategory": "Podcasters", "quality": 91, "media_kind": "audio",
    },
    {
        "text": "Acquired",
        "xml_url": "https://acquired.libsyn.com/rss",
        "description": "Ben Gilbert and David Rosenthal tell the stories behind the world's greatest companies and acquisitions.",
        "language": "en", "html_url": "https://www.acquired.fm/",
        "category": "business,tech history,companies,M&A,strategy,global",
        "subcategory": "Podcasters", "quality": 94, "media_kind": "audio",
    },
    {
        "text": "How I Built This",
        "xml_url": "https://rss.art19.com/how-i-built-this",
        "description": "Guy Raz interviews the founders behind the world's biggest companies about their entrepreneurial journeys.",
        "language": "en", "html_url": "https://www.npr.org/podcasts/510313/how-i-built-this",
        "category": "entrepreneurship,founders,business,startups,interviews,global",
        "subcategory": "Podcasters", "quality": 94, "media_kind": "audio",
    },
    # ── Bloggers & Writers (global) ──
    {
        "text": "Wait But Why",
        "xml_url": "https://waitbutwhy.com/feed",
        "description": "Tim Urban's long-form illustrated blog posts exploring psychology, technology, and the future with stick-figure drawings.",
        "language": "en", "html_url": "https://waitbutwhy.com/",
        "category": "psychology,technology,futurism,long-form,illustrated,global",
        "subcategory": "Bloggers & Writers", "quality": 95, "media_kind": "text",
    },
    {
        "text": "Seth Godin's Blog",
        "xml_url": "https://seths.blog/feed/",
        "description": "Daily bite-sized wisdom on marketing, leadership, creativity, and the creator economy from bestselling author Seth Godin.",
        "language": "en", "html_url": "https://seths.blog/",
        "category": "marketing,leadership,creativity,business,wisdom,global",
        "subcategory": "Bloggers & Writers", "quality": 94, "media_kind": "text",
    },
    {
        "text": "James Clear",
        "xml_url": "https://jamesclear.com/feed",
        "description": "Author of Atomic Habits sharing science-based insights on habits, decision-making, and continuous improvement.",
        "language": "en", "html_url": "https://jamesclear.com/articles",
        "category": "habits,productivity,self-improvement,psychology,global",
        "subcategory": "Bloggers & Writers", "quality": 95, "media_kind": "text",
    },
    {
        "text": "Maria Popova — The Marginalian",
        "xml_url": "https://www.themarginalian.org/feed/",
        "description": "Formerly Brain Pickings — Maria Popova's thoughtful essays on art, science, poetry, and what it means to live a meaningful life.",
        "language": "en", "html_url": "https://www.themarginalian.org/",
        "category": "literature,philosophy,art,science,meaning,global",
        "subcategory": "Bloggers & Writers", "quality": 96, "media_kind": "text",
    },
    {
        "text": "Mark Manson",
        "xml_url": "https://markmanson.net/feed",
        "description": "Author of The Subtle Art of Not Giving a F*ck sharing life advice, personal development, and cultural commentary.",
        "language": "en", "html_url": "https://markmanson.net/",
        "category": "self-improvement,life advice,culture,psychology,global",
        "subcategory": "Bloggers & Writers", "quality": 92, "media_kind": "text",
    },
    {
        "text": "Farnam Street (Shane Parrish)",
        "xml_url": "https://fs.blog/feed/",
        "description": "Mental models, decision-making frameworks, and timeless wisdom for business and life.",
        "language": "en", "html_url": "https://fs.blog/",
        "category": "mental models,decision-making,wisdom,business,global",
        "subcategory": "Bloggers & Writers", "quality": 93, "media_kind": "text",
    },
    {
        "text": "Paul Graham",
        "xml_url": "https://paulgraham.com/feed.xml",
        "description": "Essays on startups, programming, design, and life from the co-founder of Y Combinator.",
        "language": "en", "html_url": "https://paulgraham.com/articles.html",
        "category": "startups,programming,essays,technology,global",
        "subcategory": "Bloggers & Writers", "quality": 95, "media_kind": "text",
    },
    {
        "text": "Zen Habits (Leo Babauta)",
        "xml_url": "https://zenhabits.net/feed/",
        "description": "Minimalist blog on simplicity, mindfulness, habits, and finding focus in a distracted world.",
        "language": "en", "html_url": "https://zenhabits.net/",
        "category": "minimalism,mindfulness,habits,simplicity,wellness,global",
        "subcategory": "Bloggers & Writers", "quality": 91, "media_kind": "text",
    },
    {
        "text": "Derek Sivers",
        "xml_url": "https://sivers.org/en.atom",
        "description": "Short, punchy posts on entrepreneurship, creativity, music, and unconventional life philosophy.",
        "language": "en", "html_url": "https://sivers.org/",
        "category": "entrepreneurship,creativity,music,philosophy,global",
        "subcategory": "Bloggers & Writers", "quality": 92, "media_kind": "text",
    },
    {
        "text": "Scott H Young",
        "xml_url": "https://www.scotthyoung.com/blog/feed/",
        "description": "Author of Ultralearning sharing evidence-based strategies for learning faster and mastering difficult skills.",
        "language": "en", "html_url": "https://www.scotthyoung.com/blog/",
        "category": "learning,productivity,self-improvement,education,global",
        "subcategory": "Bloggers & Writers", "quality": 90, "media_kind": "text",
    },
    {
        "text": "Stratechery (Ben Thompson)",
        "xml_url": "https://stratechery.com/feed/",
        "description": "Analysis of the strategy and business of technology, media, and the Internet — daily updates with sharp insight.",
        "language": "en", "html_url": "https://stratechery.com/",
        "category": "technology,strategy,media,business,analysis,global",
        "subcategory": "Bloggers & Writers", "quality": 96, "media_kind": "text",
    },
]

print(f"Global influencers count: {len(GLOBAL_INFLUENCERS)}")

if __name__ == "__main__":
    for entry in GLOBAL_INFLUENCERS:
        print(outline_entry(**entry))
