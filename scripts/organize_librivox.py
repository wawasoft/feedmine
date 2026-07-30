#!/usr/bin/env python3
"""Organize librivox-pod live OPMLs into the feedmine Feeds/ directory structure.

Maps each source OPML to the appropriate editorial topic directory:
- Audiobooks → 16_Music_&_Audio/
- News/VOA/DW → 01_News_&_Current_Affairs/
- Sports/ESPN → 07_Sports/
- etc.
"""

from __future__ import annotations

import shutil
from pathlib import Path

LIVE_OPML_DIR = Path("/tmp/feedmine-ingest/Feeds")
FEEDS_ROOT = Path(__file__).resolve().parent.parent / "feedmine" / "Resources" / "Feeds"

TOPIC_MAP = {
    # Audiobooks & podcasts
    "librivox-pod.opml": "16_Music_&_Audio",
    "loyalbooks-pod.opml": "16_Music_&_Audio",
    "promodj-pod.opml": "16_Music_&_Audio",
    "radiofrance-pod.opml": "16_Music_&_Audio",
    "bbc-pod.opml": "16_Music_&_Audio",
    "cbc-ca-pod.opml": "16_Music_&_Audio",
    "rtve-pod.opml": "16_Music_&_Audio",
    "rfi-fr-pod.opml": "16_Music_&_Audio",
    "sr-pod.opml": "16_Music_&_Audio",
    "yle-fi-pod.opml": "16_Music_&_Audio",
    "nrk-pod.opml": "16_Music_&_Audio",
    "dr-pod.opml": "16_Music_&_Audio",
    "err-ee-pod.opml": "16_Music_&_Audio",
    "deutschlandfunk-pod.opml": "16_Music_&_Audio",
    "deutschlandfunkkultur-pod.opml": "16_Music_&_Audio",
    "deutschlandfunknova-pod.opml": "16_Music_&_Audio",
    "mdr-pod.opml": "16_Music_&_Audio",
    "ur-pod.opml": "16_Music_&_Audio",
    "radiohelsinki-pod.opml": "16_Music_&_Audio",
    "latvijasradio-pod.opml": "16_Music_&_Audio",
    "aragonradio-es-pod.opml": "16_Music_&_Audio",
    "nova-fr-pod.opml": "16_Music_&_Audio",
    "rthk-pod.opml": "16_Music_&_Audio",
    "sbs-co-kr-pod.opml": "16_Music_&_Audio",
    "rteie-pod.opml": "16_Music_&_Audio",
    "rtl-fr-pod.opml": "16_Music_&_Audio",
    "prx-pod.opml": "16_Music_&_Audio",
    "twit-audio-pod.opml": "16_Music_&_Audio",
    "magnatune-pod.opml": "16_Music_&_Audio",
    "alandsradio-pod.opml": "16_Music_&_Audio",
    "voiceamerica-pod.opml": "16_Music_&_Audio",
    # News
    "voanews-pod.opml": "01_News_&_Current_Affairs",
    "voa-afrique-pod.opml": "01_News_&_Current_Affairs",
    "voa-afaanoromoo-pod.opml": "01_News_&_Current_Affairs",
    "voa-cambodia-pod.opml": "01_News_&_Current_Affairs",
    "voa-cantonese-pod.opml": "01_News_&_Current_Affairs",
    "voa-chinese-pod.opml": "01_News_&_Current_Affairs",
    "voa-hausa-pod.opml": "01_News_&_Current_Affairs",
    "voa-indonesia-pod.opml": "01_News_&_Current_Affairs",
    "voa-korea-pod.opml": "01_News_&_Current_Affairs",
    "voa-noticias-pod.opml": "01_News_&_Current_Affairs",
    "voa-nouvel-pod.opml": "01_News_&_Current_Affairs",
    "voa-portugues-pod.opml": "01_News_&_Current_Affairs",
    "voa-somali-pod.opml": "01_News_&_Current_Affairs",
    "voa-swahili-pod.opml": "01_News_&_Current_Affairs",
    "voa-thai-pod.opml": "01_News_&_Current_Affairs",
    "voa-tibetan-pod.opml": "01_News_&_Current_Affairs",
    "voa-tiengviet-pod.opml": "01_News_&_Current_Affairs",
    "voa-zimbabwe-pod.opml": "01_News_&_Current_Affairs",
    "deutsche-welle-pod.opml": "01_News_&_Current_Affairs",
    "cri-cn-pod.opml": "01_News_&_Current_Affairs",
    "npr-pod.opml": "01_News_&_Current_Affairs",
    # Sports
    "espn-pod.opml": "07_Sports",
}

INCOMING_DIR = FEEDS_ROOT / "_incoming_librivox"


def main() -> int:
    if not LIVE_OPML_DIR.exists():
        print(f"❌ Live OPML dir not found: {LIVE_OPML_DIR}")
        print("   Run ingest_librivox_live.py first.")
        return 1

    # Clean previous incoming
    if INCOMING_DIR.exists():
        shutil.rmtree(INCOMING_DIR)
    INCOMING_DIR.mkdir(parents=True)

    copied = 0
    for opml_path in sorted(LIVE_OPML_DIR.rglob("*.opml")):
        rel = str(opml_path.relative_to(LIVE_OPML_DIR))
        fname = Path(rel).name

        topic = TOPIC_MAP.get(fname)
        if not topic:
            # Auto-classify: files with "pod" in name → audio
            if "pod" in fname.lower():
                topic = "16_Music_&_Audio"
            elif any(kw in fname.lower() for kw in ("voa", "news", "dw-", "cri-")):
                topic = "01_News_&_Current_Affairs"
            else:
                topic = "17_General_Interests"

        dest_dir = INCOMING_DIR / topic
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / fname

        shutil.copy2(str(opml_path), str(dest))
        copied += 1
        print(f"   {topic}/{fname}")

    print(f"\n✅ Copied {copied} OPMLs to {INCOMING_DIR}")
    print(f"   Ready for fetch_all_feeds.py to process")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
