#!/usr/bin/env python3
"""Merge new curated OPMLs into existing curated OPML tree."""
import xml.etree.ElementTree as ET
from pathlib import Path
import shutil

existing = Path('feedmine/Resources/Feeds')
new = Path('build/feed-curation/Feeds')
merged = Path('build/feed-curation/Feeds-merged')

# Remove _incoming_librivox and manifest
for p in [existing / '_incoming_librivox', existing / 'opml_manifest.json']:
    if p.is_dir(): shutil.rmtree(p)
    elif p.is_file(): p.unlink()

# Copy existing to merged
shutil.copytree(existing, merged, dirs_exist_ok=True)

def merge_outline(new_el, parent, existing_urls):
    xml_url = (new_el.get('xmlUrl') or '').strip()
    if xml_url:
        if xml_url not in existing_urls:
            parent.append(new_el)
            existing_urls.add(xml_url)
            return 1
        return 0
    for child in list(new_el):
        merge_outline(child, parent, existing_urls)
    return 0

added_total = 0
for new_path in sorted(new.rglob('*.opml')):
    rel = new_path.relative_to(new)
    merged_path = merged / rel

    if not merged_path.exists():
        merged_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(new_path, merged_path)
        continue

    new_tree = ET.parse(str(new_path))
    existing_tree = ET.parse(str(merged_path))
    new_body = new_tree.getroot().find('body')
    existing_body = existing_tree.getroot().find('body')
    if new_body is None or existing_body is None:
        continue

    existing_urls = {el.get('xmlUrl', '').strip() for el in existing_tree.getroot().iter('outline') if el.get('xmlUrl')}
    added = 0
    for child in list(new_body):
        added += merge_outline(child, existing_body, existing_urls)

    if added > 0:
        ET.indent(existing_tree.getroot(), space='  ')
        existing_tree.write(str(merged_path), encoding='utf-8', xml_declaration=True)
    added_total += added

total_files = len(list(merged.rglob('*.opml')))
total_sources = len({el.get('xmlUrl') for el in ET.parse(str(p)).getroot().iter('outline') if el.get('xmlUrl')} for p in merged.rglob('*.opml'))
print(f'Merge complete: {added_total} new sources added across {total_files} OPML files')
