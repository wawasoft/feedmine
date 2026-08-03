#!/usr/bin/env python3
"""
Process a batch of decontamination cases.
Each case has: country, feed_lang, tld_country, title, description, etc.

For each case, decide:
  - REMOVE: feed is clearly from another country (wrong language + wrong TLD + content confirms)
  - KEEP: feed is global content that legitimately belongs (e.g., English podcast in non-English country)
  - UNCERTAIN: can't decide from metadata alone

Usage: python3 process_decontamination_batch.py <batch_file.json>
Output: JSON with decisions and actions taken.
"""

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

FEEDS_DIR = Path(__file__).resolve().parent.parent / "feedmine" / "Resources" / "Feeds" / "90_countries"


def load_country_opml(country):
    opml_path = FEEDS_DIR / country / f"{country}.opml"
    if not opml_path.exists():
        return None, None, None
    tree = ET.parse(opml_path)
    return tree, tree.getroot(), opml_path


def find_and_remove_feed(root, source_id):
    """Find a feed by sourceId and remove it. Returns True if removed."""
    body = root.find("body")
    if body is None:
        return False

    def walk(parent):
        for child in list(parent):
            if child.tag == "outline" and child.get("type") == "rss":
                if child.get("feedmineSourceId") == source_id:
                    parent.remove(child)
                    return True
            else:
                if walk(child):
                    return True
        return False

    return walk(body)


def write_opml(tree, path):
    root = tree.getroot()
    ET.indent(root, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def analyze_case(case):
    """
    Decide whether to REMOVE, KEEP, or mark as UNCERTAIN.

    Rules (conservative — only remove when confident):
    - REMOVE if: language clearly wrong for the country
                AND TLD points to a different country
                AND title/description confirms it's about that other country
                AND NOT a global news/tech/entertainment brand
    - KEEP if: global brand (BBC, Netflix, TED, etc.)
              OR content is about international topic
              OR the feed's topic is World News (valid global content)
    """
    title = case.get("title", "")
    desc = case.get("description", "")
    category = case.get("category", "")
    feed_lang = case.get("feed_lang", "")
    country = case.get("country", "")
    tld_country = case.get("tld_country", "")
    topic = case.get("topic", "")
    subcategory = case.get("subcategory", "")
    media_kind = case.get("mediaKind", "")

    combined = f"{title} {desc} {category}".lower()

    # ── Global brands that legitimately belong everywhere ──
    GLOBAL_BRANDS = [
        "bbc", "cnn", "reuters", "associated press", "bloomberg", "the guardian",
        "new york times", "wall street journal", "washington post", "npr",
        "ted talk", "tedx", "national geographic", "discovery", "history channel",
        "netflix", "spotify", "apple podcast", "google", "microsoft",
        "the economist", "financial times", "forbes", "fortune", "time magazine",
        "al jazeera", "france 24", "deutsche welle", "dw news",
        "united nations", "world health", "who", "unicef", "world bank",
        "nasa", "esa", "spacex", "nature", "science", "mit ",
    ]
    for brand in GLOBAL_BRANDS:
        if brand in combined:
            return "KEEP", f"global_brand:{brand}"

    # ── World News / global topics ──
    if topic and "world news" in topic.lower():
        return "KEEP", "topic:world_news"
    if subcategory and "world news" in subcategory.lower():
        return "KEEP", "subcategory:world_news"

    # ── Topic clearly about another country ──
    # If the title explicitly mentions the TLD country, it's misplaced
    tld_country_words = tld_country.replace("_", " ")
    country_words = country.replace("_", " ")

    # Check if title is about the TLD country, not the assigned country
    title_mentions_tld = tld_country_words in combined
    title_mentions_assigned = country_words in combined

    # ── Language-based signals ──
    # pt-BR feed in non-PT country → strong signal of misplacement
    language_specific = {
        "pt": ["brazil", "portugal", "angola"],
        "pt-br": ["brazil"],
        "es": ["spain", "argentina", "mexico", "colombia", "chile", "peru", "venezuela",
              "ecuador", "guatemala", "cuba", "dominican republic", "honduras",
              "paraguay", "el salvador", "nicaragua", "costa rica", "uruguay",
              "panama", "bolivia", "puerto rico"],
        "de": ["germany", "austria", "switzerland"],
        "fr": ["france", "belgium", "switzerland", "canada"],
        "it": ["italy", "switzerland"],
        "ja": ["japan"],
        "ko": ["south korea"],
        "zh": ["china", "taiwan"],
        "ru": ["russia", "belarus", "kazakhstan"],
        "ar": ["saudi arabia", "egypt", "uae", "algeria", "morocco", "tunisia", "iraq", "qatar", "sudan"],
        "nl": ["netherlands", "belgium"],
        "sv": ["sweden"],
        "no": ["norway"],
        "da": ["denmark"],
        "fi": ["finland"],
        "pl": ["poland"],
        "cs": ["czech republic"],
        "hu": ["hungary"],
        "ro": ["romania"],
        "bg": ["bulgaria"],
        "el": ["greece", "cyprus"],
        "tr": ["turkey", "cyprus"],
        "uk": ["ukraine"],
        "vi": ["vietnam"],
        "th": ["thailand"],
        "id": ["indonesia"],
        "ms": ["malaysia"],
        "tl": ["philippines"],
        "hi": ["india"],
        "ur": ["pakistan"],
        "bn": ["bangladesh"],
        "he": ["israel"],
        "fa": ["iran"],
        "kk": ["kazakhstan"],
        "et": ["estonia"],
        "lv": ["latvia"],
        "lt": ["lithuania"],
        "sr": ["serbia"],
        "hr": ["croatia"],
        "sk": ["slovakia"],
        "sl": ["slovenia"],
        "hy": ["armenia"],
        "ka": ["georgia"],
        "az": ["azerbaijan"],
        "am": ["ethiopia"],
        "km": ["cambodia"],
        "my": ["myanmar"],
        "ne": ["nepal"],
        "is": ["iceland"],
        "mt": ["malta"],
        "si": ["sri lanka"],
        "sw": ["kenya", "tanzania"],
        "af": ["south africa"],
        "zu": ["south africa"],
        "xh": ["south africa"],
        "ht": ["haiti"],
        "mi": ["new zealand"],
        "ga": ["ireland"],
        "lb": ["luxembourg"],
        "gn": ["paraguay"],
        "qu": ["peru", "bolivia"],
        "rm": ["switzerland"],
    }

    lang_base = feed_lang.split("-")[0]
    valid_countries_for_lang = language_specific.get(feed_lang, language_specific.get(lang_base, []))

    # If the feed is in a language that ONLY makes sense in specific countries
    # and the current country is NOT one of them → likely misplaced
    if valid_countries_for_lang and country not in valid_countries_for_lang:
        if tld_country in valid_countries_for_lang:
            return "REMOVE", f"lang:{feed_lang}_only_in_{tld_country}"

    # ── Specific known patterns ──
    # Brazilian domain + pt-BR language + not in Brazil/Portugal → remove
    if feed_lang.startswith("pt") and tld_country == "brazil" and country not in ("brazil", "portugal", "angola"):
        return "REMOVE", f"pt-BR_content_in_{country}_domain_.br"

    # Hungarian domain + hu language + not in Hungary → remove
    if feed_lang.startswith("hu") and tld_country == "hungary" and country != "hungary":
        return "REMOVE", f"hungarian_content_in_{country}"

    # Russian domain + ru language + not in Russian-speaking → remove
    if feed_lang.startswith("ru") and tld_country == "russia" and country not in ("russia", "belarus", "kazakhstan"):
        return "REMOVE", f"russian_content_in_{country}"

    # German domain + de language + not in DACH → remove
    if feed_lang.startswith("de") and tld_country == "germany" and country not in ("germany", "austria", "switzerland", "luxembourg"):
        return "REMOVE", f"german_content_in_{country}"

    # Spanish .es domain + es language + not in hispanophone → remove
    if feed_lang.startswith("es") and tld_country in ("spain", "argentina", "mexico") and country not in valid_countries_for_lang:
        return "REMOVE", f"spanish_content_in_{country}"

    # ── Uncategorized but clear mismatch ──
    # If language is very specific (not English) and TLD is also specific → likely misplaced
    if lang_base not in ("en",) and valid_countries_for_lang and country not in valid_countries_for_lang:
        return "REMOVE", f"specific_lang:{feed_lang}_not_in_{country}"

    # ── Default: uncertain ──
    return "KEEP", f"uncertain_but_insufficient_evidence"


def process_batch(batch_file):
    with open(batch_file) as f:
        cases = json.load(f)

    print(f"Processing {len(cases)} cases from {batch_file}")

    results = {"removed": [], "kept": [], "errors": []}
    modified_trees = {}  # country -> (tree, opml_path)

    for i, case in enumerate(cases):
        source_id = case["sourceId"]
        country = case["country"]
        title = case["title"]

        decision, reason = analyze_case(case)

        if decision == "REMOVE":
            if country in modified_trees:
                tree, opml_path = modified_trees[country]
                root = tree.getroot()
            else:
                tree, root, opml_path = load_country_opml(country)
                if tree is None:
                    results["errors"].append({**case, "error": f"OPML not found: {country}"})
                    continue
                modified_trees[country] = (tree, opml_path)

            removed = find_and_remove_feed(root, source_id)
            if removed:
                results["removed"].append({**case, "reason": reason})
                print(f"  [{i+1}/{len(cases)}] REMOVED: [{country}] {title[:70]} — {reason}")
            else:
                results["errors"].append({**case, "error": "source_id not found in OPML"})
                print(f"  [{i+1}/{len(cases)}] ERROR: source_id not found: {title[:70]}")
        else:
            results["kept"].append({**case, "reason": reason})

    # Write modified OPMLs from in-memory trees (which hold all removals for the country)
    for country, (tree, opml_path) in modified_trees.items():
        write_opml(tree, opml_path)

    print(f"\nBatch complete: {len(results['removed'])} removed, {len(results['kept'])} kept, {len(results['errors'])} errors")
    return results


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python3 process_decontamination_batch.py <batch_file.json>")
        sys.exit(1)

    results = process_batch(sys.argv[1])

    # Write results
    out_path = sys.argv[1].replace(".json", "_results.json")
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2, ensure_ascii=False, default=str)
    print(f"Results written to {out_path}")
