import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from scripts.catalog_identity import compute_source_id
from scripts.migrate_catalog_identity import migrate, migrate_document, parse_document


class CatalogIdentityMigrationTests(unittest.TestCase):
    def test_real_xml_parser_preserves_comments_attributes_and_signed_request_url(self):
        raw = b'''<?xml version="1.0" encoding="utf-8"?>
<opml version="2.0"><body>
  <!-- <outline xmlUrl="https://comment.example/not-a-feed" /> -->
  <outline text="A &gt; B" title="still-here"
    xmlUrl="https://example.com/feed?q=a&gt;b&amp;X-Amz-Signature=secret&amp;X-Amz-Expires=60"
    feedmineSourceId="old" />
</body></opml>'''

        migrated, changes, errors = migrate_document(raw, Path("fixture.opml"))

        self.assertEqual(errors, [])
        self.assertEqual(changes, 2)
        tree = parse_document(migrated)
        outlines = [element for element in tree.getroot().iter() if element.tag == "outline"]
        self.assertEqual(len(outlines), 1)
        outline = outlines[0]
        self.assertEqual(outline.attrib["text"], "A > B")
        self.assertEqual(outline.attrib["title"], "still-here")
        self.assertEqual(
            outline.attrib["xmlUrl"],
            "https://example.com/feed?q=a%3Eb&X-Amz-Signature=secret&X-Amz-Expires=60",
        )
        self.assertEqual(outline.attrib["feedmineSourceId"], compute_source_id(outline.attrib["xmlUrl"]))
        self.assertIn(b"comment.example/not-a-feed", migrated)
        self.assertNotIn(b"feedmineSourceId", migrated.split(b"-->", 1)[0])

    def test_write_has_committed_journal_and_recovery_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "Feeds"
            root.mkdir()
            path = root / "one.opml"
            original = (
                b'<opml><body><outline xmlUrl="https://example.com/feed?utm_source=x" '
                b'feedmineSourceId="old" /></body></opml>'
            )
            path.write_bytes(original)
            journal = Path(temporary) / "journal.json"

            summary = migrate(root, write=True, journal_path=journal)

            self.assertEqual(summary["files_changed"], 1)
            self.assertEqual(json.loads(journal.read_text(encoding="utf-8"))["status"], "committed")
            recovery = Path(summary["recovery_root"])
            self.assertEqual((recovery / "one.opml").read_bytes(), original)
            ET.parse(path)


if __name__ == "__main__":
    unittest.main()
