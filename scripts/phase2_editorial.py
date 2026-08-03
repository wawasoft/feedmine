#!/usr/bin/env python3
"""
Phase 2 Editorial Cleanup: "Make Every Country Work"
=====================================================
WS-8: Country tier system
WS-7: Unverified feeds triage (cap at 15%, rest → staging)
WS-9: Quality thresholds (default-disable low quality + unverified)
WS-10: Media mix rebalancing (preliminary)

Run: python3 scripts/phase2_editorial.py [--apply]
"""

import argparse
import copy
import csv
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict, Counter
from pathlib import Path
from datetime import datetime, timezone


# ── Country tier thresholds ────────────────────────────────────────────
# T1 Anchor: >30% fetched, ≤30% YouTube, ≥80% local
# T2 Established: >15% fetched, ≤40% YouTube, ≥60% local
# T3 Underserved: ≤15% fetched or >50% YouTube
# T4 Sparse: <600 total feeds

def classify_tier(total, yt_pct, fetched_pct, local_pct, audio_pct):
    """Classify a country into editorial tier.

    Realistic thresholds based on current corpus (2026-08):
    - T1: established local ecosystem (fetched ≥ 25%, YouTube ≤ 55%)
    - T2: developing (fetched ≥ 12%, YouTube ≤ 75%)
    - T3: underserved (everyone else)
    - T4: rebuild needed (<600 total feeds)
    """
    if total < 600:
        return "T4"
    if fetched_pct >= 25 and yt_pct <= 55 and local_pct >= 30:
        return "T1"
    if fetched_pct >= 12 and yt_pct <= 75 and local_pct >= 15:
        return "T2"
    return "T3"


# ── OPML utilities ─────────────────────────────────────────────────────

def load_opml(path):
    tree = ET.parse(path)
    return tree, tree.getroot()


def write_opml(tree, path):
    root = tree.getroot()
    ET.indent(root, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True, short_empty_elements=True)


def find_all_feeds(root):
    feeds = []
    body = root.find("body")
    if body is None:
        return feeds

    def walk(elem):
        for child in elem:
            if child.tag == "outline" and child.get("type") == "rss":
                feeds.append((child, elem))
            walk(child)
    walk(body)
    return feeds


def compute_country_stats(root):
    """Compute per-country stats from an OPML tree."""
    stats = {"total": 0, "yt": 0, "fetched": 0, "unverified": 0, "audio": 0,
             "disabled": 0, "quality_sum": 0, "local": 0}
    body = root.find("body")
    if body is None:
        return stats

    def walk(elem):
        for child in elem:
            if child.tag == "outline" and child.get("type") == "rss":
                stats["total"] += 1
                url = child.get("xmlUrl", "")
                if "youtube.com" in url:
                    stats["yt"] += 1
                if child.get("feedmineLatestItemAt"):
                    stats["fetched"] += 1
                if child.get("feedmineNature") == "unverified":
                    stats["unverified"] += 1
                if child.get("feedmineMediaKind") == "audio":
                    stats["audio"] += 1
                if child.get("feedmineDefaultEnabled") == "false":
                    stats["disabled"] += 1
                qs = child.get("feedmineQualityScore", "")
                if qs and qs.lstrip("-").isdigit():
                    stats["quality_sum"] += int(qs)
                # "local" = not YouTube + not unverified
                if "youtube.com" not in url and child.get("feedmineNature") != "unverified":
                    stats["local"] += 1
            walk(child)
    walk(body)
    return stats


# ── WS-7: Unverified feeds triage ──────────────────────────────────────

UNVERIFIED_CAP = 0.15  # 15% max


def triage_unverified_feeds(root, country, tier, staging_dir, report):
    """
    Cap unverified feeds at 15% of country total.
    Excess unverified feeds → moved to staging OPML.
    Priority for removal: YouTube > no language > low quality
    Priority for keeping: non-YouTube > language matches > fetched
    """
    feeds = find_all_feeds(root)
    unverified_feeds = [(f, p) for f, p in feeds
                        if f.get("feedmineNature") == "unverified"]

    total = len(feeds)
    unverified_count = len(unverified_feeds)
    max_unverified = int(total * UNVERIFIED_CAP)
    excess = unverified_count - max_unverified

    if excess <= 0:
        report["unverified_ok"].append(country)
        return 0

    # Sort unverified: YouTube first (least valuable), then no language, then low articles
    def sort_key(item):
        f, _ = item
        url = f.get("xmlUrl", "")
        is_yt = 1 if "youtube.com" in url else 0
        has_lang = 0 if f.get("language", "").strip() else 1
        fetched_count = int(f.get("feedmineArticlesFetched", "0") or "0")
        return (is_yt, has_lang, -fetched_count)  # YouTube + no-lang first (least valuable)

    unverified_feeds.sort(key=sort_key)

    # Remove excess unverified feeds
    removed = 0
    for feed_elem, parent_elem in unverified_feeds[:excess]:
        # Save to staging
        staging_feed = copy.deepcopy(feed_elem)
        staging_feed.set("feedmineDisposition", "unverified_triage")
        staging_feed.set("feedmineOriginalCountry", country)
        staging_feed.set("feedmineTriageDate", datetime.now(timezone.utc).strftime("%Y-%m-%d"))
        staging_dir.append(staging_feed)

        parent_elem.remove(feed_elem)
        removed += 1
        report["unverified_moved"].append({
            "country": country,
            "title": feed_elem.get("text", ""),
            "url": feed_elem.get("xmlUrl", ""),
        })

    return removed


# ── WS-9: Quality thresholds ───────────────────────────────────────────

def apply_quality_thresholds(root, country, report):
    """
    Default-disable feeds that meet ALL of:
    - qualityScore < 40
    - articlesFetched == 0 or 1
    - NOT evergreen (evergreen content is timeless)

    Exception: feeds that are already disabled (unverified) stay as-is.
    """
    feeds = find_all_feeds(root)
    disabled_count = 0

    for feed_elem, parent_elem in feeds:
        # Skip already disabled
        if feed_elem.get("feedmineDefaultEnabled") == "false":
            continue

        nature = feed_elem.get("feedmineNature", "")
        if nature == "evergreen":
            continue  # Evergreen content stays enabled regardless

        qs_str = feed_elem.get("feedmineQualityScore", "")
        if not qs_str or not qs_str.lstrip("-").isdigit():
            continue
        qs = int(qs_str)

        fetched = feed_elem.get("feedmineArticlesFetched", "0")
        try:
            fetched_count = int(fetched) if fetched else 0
        except (ValueError, TypeError):
            fetched_count = 0

        if qs < 40 and fetched_count <= 1 and nature != "unverified":
            feed_elem.set("feedmineDefaultEnabled", "false")
            disabled_count += 1
            report["quality_disabled"].append({
                "country": country,
                "title": feed_elem.get("text", ""),
                "quality": qs,
                "fetched": fetched_count,
                "nature": nature,
            })

    return disabled_count


# ── WS-10: Media mix balancing (preliminary) ────────────────────────────

def check_media_balance(root, country):
    """Compute audio/YouTube percentages for reporting."""
    feeds = find_all_feeds(root)
    total = len(feeds)
    if total == 0:
        return 0, 0

    audio = sum(1 for f, _ in feeds if f.get("feedmineMediaKind") == "audio")
    yt = sum(1 for f, _ in feeds if "youtube.com" in f.get("xmlUrl", ""))
    return audio / total * 100, yt / total * 100


# ── Main Phase 2 pipeline ───────────────────────────────────────────────

def run_phase2(base_path, apply_changes=False):
    report = {
        "unverified_ok": [],
        "unverified_moved": [],
        "quality_disabled": [],
        "tiers": {},
        "media_balance": {},
    }

    base = Path(base_path)
    feeds_dir = base / "feedmine" / "Resources" / "Feeds"
    countries_dir = feeds_dir / "90_countries"
    staging_dir_path = base / "editorial" / "feed-curation" / "staging"
    staging_feeds = []  # collected for staging OPML

    print("=" * 70)
    print("PHASE 2: Editorial Cleanup — 'Make Every Country Work'")
    print("=" * 70)

    # ── Load all country OPMLs ────────────────────────────────────────
    print("\n[1/5] Loading and classifying countries...")
    country_data = {}
    for country_dir in sorted(countries_dir.iterdir()):
        if not country_dir.is_dir() or country_dir.name.startswith("."):
            continue
        country = country_dir.name
        opml_path = country_dir / f"{country}.opml"
        if not opml_path.exists():
            continue
        tree, root = load_opml(opml_path)
        stats = compute_country_stats(root)
        if stats["total"] == 0:
            continue

        yt_pct = stats["yt"] / stats["total"] * 100
        fetched_pct = stats["fetched"] / stats["total"] * 100
        local_pct = stats["local"] / stats["total"] * 100
        audio_pct = stats["audio"] / stats["total"] * 100
        avg_q = stats["quality_sum"] / stats["total"]
        disabled_pct = stats["disabled"] / stats["total"] * 100

        tier = classify_tier(stats["total"], yt_pct, fetched_pct, local_pct, audio_pct)

        country_data[country] = {
            "tree": tree, "root": root, "opml_path": opml_path,
            "tier": tier, "total": stats["total"],
            "yt_pct": yt_pct, "fetched_pct": fetched_pct,
            "local_pct": local_pct, "audio_pct": audio_pct,
            "unverified": stats["unverified"], "disabled_pct": disabled_pct,
            "avg_q": avg_q,
        }
        report["tiers"][country] = tier

    # Print tier distribution
    tier_counts = Counter(d["tier"] for d in country_data.values())
    print(f"  Tier distribution: {dict(sorted(tier_counts.items()))}")

    # Print T1 countries
    t1_countries = [c for c, d in country_data.items() if d["tier"] == "T1"]
    print(f"  T1 (Anchor): {', '.join(sorted(t1_countries))}")
    t4_countries = [c for c, d in country_data.items() if d["tier"] == "T4"]
    if t4_countries:
        print(f"  T4 (Rebuild needed): {', '.join(sorted(t4_countries))}")
    t3_countries = [c for c, d in country_data.items() if d["tier"] == "T3"]
    print(f"  T3: {len(t3_countries)} countries | T2: {tier_counts.get('T2', 0)} countries")

    # ── WS-7: Unverified feeds triage ──────────────────────────────────
    print("\n[2/5] WS-7: Triaging unverified feeds (cap at 15%)...")
    total_moved = 0
    for country, data in sorted(country_data.items()):
        removed = triage_unverified_feeds(
            data["root"], country, data["tier"],
            staging_feeds, report
        )
        if removed > 0:
            total_moved += removed
    print(f"  Unverified feeds moved to staging: {total_moved}")
    print(f"  Countries within cap: {len(report['unverified_ok'])}")

    # ── WS-9: Quality thresholds ───────────────────────────────────────
    print("\n[3/5] WS-9: Applying quality thresholds...")
    total_disabled = 0
    for country, data in sorted(country_data.items()):
        disabled = apply_quality_thresholds(data["root"], country, report)
        if disabled > 0:
            total_disabled += disabled
    print(f"  Feeds default-disabled by quality: {total_disabled}")

    # ── WS-10: Media balance check ─────────────────────────────────────
    print("\n[4/5] WS-10: Media balance report...")
    low_audio = []
    high_yt = []
    for country, data in sorted(country_data.items()):
        audio_pct, yt_pct = check_media_balance(data["root"], country)
        report["media_balance"][country] = {"audio_pct": round(audio_pct, 1),
                                             "yt_pct": round(yt_pct, 1)}
        if audio_pct < 8:
            low_audio.append((country, audio_pct))
        if yt_pct > 80:
            high_yt.append((country, yt_pct))

    print(f"  Countries with <8% audio: {len(low_audio)}")
    for c, pct in sorted(low_audio, key=lambda x: x[1])[:10]:
        print(f"    {c}: {pct:.1f}% audio")
    print(f"  Countries with >80% YouTube: {len(high_yt)}")
    for c, pct in sorted(high_yt, key=lambda x: x[1], reverse=True)[:10]:
        print(f"    {c}: {pct:.1f}% YouTube")

    # ── Final stats ────────────────────────────────────────────────────
    print("\n[5/5] Computing final state...")
    final_count = 0
    for country, data in country_data.items():
        feeds = find_all_feeds(data["root"])
        final_count += len(feeds)

    # ── Write ──────────────────────────────────────────────────────────
    if apply_changes:
        print("\n" + "=" * 70)
        print("APPLYING CHANGES...")
        print("=" * 70)

        # Write country OPMLs
        for country, data in country_data.items():
            write_opml(data["tree"], data["opml_path"])
        print(f"  Written {len(country_data)} country OPMLs")

        # Write staging OPML for triaged unverified feeds
        if staging_feeds:
            staging_opml = staging_dir_path / "unverified_triage.opml"
            staging_root = ET.Element("opml", {"version": "2.0"})
            head = ET.SubElement(staging_root, "head")
            ET.SubElement(head, "title").text = "Feedmine Unverified Triage"
            ET.SubElement(head, "dateCreated").text = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
            body = ET.SubElement(staging_root, "body")

            # Group by original country
            by_country = defaultdict(list)
            for f in staging_feeds:
                by_country[f.get("feedmineOriginalCountry", "unknown")].append(f)

            for country in sorted(by_country):
                group = ET.SubElement(body, "outline", {
                    "text": f"From {country}",
                    "feedmineDisposition": "unverified_triage"
                })
                for f in by_country[country]:
                    group.append(f)

            staging_tree = ET.ElementTree(staging_root)
            write_opml(staging_tree, staging_opml)
            print(f"  Written {len(staging_feeds)} feeds to {staging_opml}")

        # Write tier report
        tier_report_path = base / "scripts" / "phase2_tiers.json"
        with open(tier_report_path, "w") as f:
            json.dump({
                "generated": datetime.now(timezone.utc).isoformat(),
                "tiers": report["tiers"],
                "tier_counts": dict(tier_counts),
            }, f, indent=2)
        print(f"  Tier report: {tier_report_path}")

        # Write CSV report
        csv_path = base / "scripts" / "phase2_cleanup_report.csv"
        with open(csv_path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["workstream", "detail", "count"])
            writer.writerow(["WS-7_unverified", "moved_to_staging", total_moved])
            writer.writerow(["WS-7_unverified", "countries_ok", len(report["unverified_ok"])])
            writer.writerow(["WS-9_quality", "disabled", total_disabled])
            writer.writerow(["WS-10_low_audio", "countries", len(low_audio)])
            writer.writerow(["WS-10_high_yt", "countries", len(high_yt)])
        print(f"  Report: {csv_path}")

        print(f"\n  Before: {sum(d['total'] for d in country_data.values())} feeds")
        print(f"  After:  {final_count} feeds")
        print(f"  Delta:  {final_count - sum(d['total'] for d in country_data.values())}")
    else:
        print("\n" + "=" * 70)
        print("DRY RUN — no changes applied. Use --apply to execute.")
        print("=" * 70)
        print(f"\n  Would move to staging: {total_moved} unverified feeds")
        print(f"  Would default-disable: {total_disabled} low-quality feeds")
        print(f"  Countries with <8% audio: {len(low_audio)}")
        print(f"  Countries with >80% YouTube: {len(high_yt)}")

    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Feedmine Phase 2 Editorial Cleanup")
    parser.add_argument("--apply", action="store_true", help="Apply changes")
    parser.add_argument("--worktree", type=str, default=None)
    args = parser.parse_args()

    base_path = args.worktree or Path(__file__).resolve().parent.parent
    run_phase2(base_path, apply_changes=args.apply)
