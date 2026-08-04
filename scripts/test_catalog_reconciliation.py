import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from scripts.catalog_identity import canonical_url, compute_source_id, decode_url_entities
from scripts.reconcile_feed_corpus import (
    candidate_from_row,
    choose_title,
    read_opml_memberships,
    reconcile_candidates,
    remap_memberships,
    repair_mojibake,
    semantic_redirect_mismatch,
    title_similarity,
)


def source_row(**overrides):
    row = {
        "source_id": "old",
        "source_title": "Example",
        "xml_url": "https://example.com/feed",
        "canonical_xml_url": "https://example.com/feed",
        "site_url": "https://example.com",
        "feed_title": "Example Feed",
        "feed_description": "Description",
        "feed_reported_language": "en",
        "status": "done",
        "articles_fetched": 10,
        "final_url": "https://example.com/feed",
        "latest_item_at": "2026-08-01T00:00:00+00:00",
        "ai_description": "An analyzed description.",
        "ai_tags": "technology,science",
    }
    row.update(overrides)
    return row


class CatalogIdentityTests(unittest.TestCase):
    def test_identity_decodes_entities_and_collapses_runtime_variants(self):
        variants = {
            "http://www.Example.com/feed/?utm_source=x&amp;hl=pt-BR#top",
            "https://example.com/feed?hl=pt-BR",
        }
        identities = {canonical_url(value) for value in variants}
        self.assertEqual(identities, {"https://example.com/feed?hl=pt-BR"})
        self.assertEqual(len({compute_source_id(value) for value in variants}), 1)
        self.assertEqual(decode_url_entities("?a=1&amp;amp;b=2"), "?a=1&b=2")

    def test_mojibake_and_placeholder_titles_use_observed_feed_title(self):
        self.assertEqual(repair_mojibake("Trechos NotÃ¡veis"), ("Trechos Notáveis", True))
        title, source = choose_title(source_row(source_title="valid", feed_title="Real Publication"))
        self.assertEqual(title, "Real Publication")
        self.assertEqual(source, "feed_title")

    def test_single_character_titles_do_not_bypass_hijack_detection(self):
        self.assertEqual(title_similarity("X", "Y"), 0.0)
        self.assertEqual(title_similarity("X", "X"), 1.0)

    def test_malformed_url_title_fallback_does_not_raise(self):
        title, source = choose_title(source_row(
            source_title="",
            feed_title="",
            xml_url="https://[broken/feed",
        ))
        self.assertEqual((title, source), ("Untitled", "hostname_fallback"))


class ReconciliationTests(unittest.TestCase):
    def test_duplicate_identity_has_one_canonical_source_id(self):
        rows = [
            source_row(source_id="one", xml_url="http://www.example.com/feed/", final_url="https://example.com/feed"),
            source_row(source_id="two", xml_url="https://example.com/feed", articles_fetched=20),
        ]
        resolutions, blocked = reconcile_candidates([
            candidate_from_row(row, index) for index, row in enumerate(rows)
        ])
        self.assertEqual(blocked, [])
        self.assertEqual(len(resolutions), 1)
        self.assertEqual(len(resolutions[0].variants), 2)
        self.assertEqual(resolutions[0].source_id, compute_source_id("https://example.com/feed"))

    def test_done_alias_promotes_group_but_failed_only_group_stays_out(self):
        rows = [
            source_row(source_id="done", status="done"),
            source_row(source_id="failed-alias", status="failed", xml_url="http://www.example.com/feed/"),
            source_row(source_id="failed-only", status="failed", xml_url="https://broken.example/feed", final_url=""),
        ]
        resolutions, blocked = reconcile_candidates([
            candidate_from_row(row, index) for index, row in enumerate(rows)
        ])
        self.assertEqual(len(resolutions), 1)
        self.assertEqual({item.old_source_id for item in resolutions[0].variants}, {"done", "failed-alias"})
        self.assertIn("failed-only", {item.old_source_id for item in blocked})

    def test_entity_corrected_url_requires_refetch(self):
        candidate = candidate_from_row(source_row(
            xml_url="https://news.google.com/rss?gl=BR&amp;hl=pt-BR",
            final_url="https://news.google.com/rss?gl=US&hl=en-US",
        ), 0)
        self.assertEqual(candidate.blocking_reason, "url_entities_decoded_requires_refetch")

    def test_unrelated_low_similarity_redirect_is_quarantined(self):
        self.assertTrue(semantic_redirect_mismatch(
            "https://mofarah.example/feed",
            "https://betting.example/rss",
            "Mo Farah",
            "Best Betting Online",
        ))
        candidate = candidate_from_row(source_row(
            source_title="Mo Farah",
            feed_title="Best Betting Online",
            xml_url="https://mofarah.example/feed",
            final_url="https://betting.example/rss",
        ), 0)
        self.assertEqual(candidate.blocking_reason, "semantic_redirect_mismatch")

    def test_trusted_feed_provider_redirect_is_not_a_semantic_mismatch(self):
        self.assertFalse(semantic_redirect_mismatch(
            "https://publisher.example/podcast",
            "https://feeds.acast.com/public/shows/123",
            "Publisher Politics",
            "Daily Politics Show",
        ))

    def test_opml_memberships_are_remapped_without_losing_order_or_files(self):
        resolution, _ = reconcile_candidates([candidate_from_row(source_row(), 0)])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("one", "two"):
                path = root / name / f"{name}.opml"
                path.parent.mkdir()
                opml = ET.Element("opml", {"version": "2.0"})
                head = ET.SubElement(opml, "head")
                ET.SubElement(head, "title").text = name.title()
                body = ET.SubElement(opml, "body")
                ET.SubElement(body, "outline", {
                    "text": "Example", "xmlUrl": "http://www.example.com/feed/",
                })
                ET.ElementTree(opml).write(path, encoding="utf-8", xml_declaration=True)
            memberships, failures = read_opml_memberships(root)
            remapped, unmatched = remap_memberships(memberships, resolution)
        self.assertEqual(failures, 0)
        self.assertEqual(unmatched, [])
        self.assertEqual(len(remapped), 2)
        self.assertEqual([row["opml_file"] for row in remapped], ["one/one.opml", "two/two.opml"])
        self.assertEqual({row["source_id"] for row in remapped}, {resolution[0].source_id})


if __name__ == "__main__":
    unittest.main()
