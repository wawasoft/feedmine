"""Tests for P0-01: typed progress schema in fetch_new_feeds.py."""

import json
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.fetch_new_feeds import (
    classify_fetch_result,
    _serialize_progress_value,
    _deserialize_progress_value,
    PROGRESS_SCHEMA_VERSION,
)


class ClassifyFetchResultTests(unittest.TestCase):
    def test_success_with_articles(self):
        self.assertEqual(
            classify_fetch_result({"http_status": 200, "articles_fetched": 5}), "done"
        )

    def test_success_zero_articles(self):
        """A 200 with zero articles is still a valid feed — just no recent items."""
        self.assertEqual(
            classify_fetch_result({"http_status": 200, "articles_fetched": 0}), "done"
        )

    def test_success_304_not_modified(self):
        self.assertEqual(
            classify_fetch_result({"http_status": 304, "articles_fetched": 0}), "done"
        )

    def test_http_error(self):
        self.assertEqual(
            classify_fetch_result({"http_status": 404, "articles_fetched": 0}), "failed"
        )

    def test_http_500(self):
        self.assertEqual(
            classify_fetch_result({"http_status": 500, "articles_fetched": 0}), "failed"
        )

    def test_error_message_overrides_articles(self):
        """error_message means failed, even if articles were fetched."""
        self.assertEqual(
            classify_fetch_result(
                {"error_message": "timeout", "articles_fetched": 5, "http_status": 200}
            ),
            "failed",
        )

    def test_parse_error(self):
        self.assertEqual(
            classify_fetch_result({"error_message": "not XML", "http_status": 200}), "failed"
        )

    def test_timeout(self):
        self.assertEqual(
            classify_fetch_result({"error_message": "Timeout", "http_status": 0}), "failed"
        )

    def test_articles_without_status(self):
        """Got articles somehow — treat as done."""
        self.assertEqual(
            classify_fetch_result({"articles_fetched": 3, "http_status": 0}), "done"
        )

    def test_no_status_no_articles(self):
        self.assertEqual(
            classify_fetch_result({"http_status": 0, "articles_fetched": 0}), "failed"
        )


class SerializeProgressValueTests(unittest.TestCase):
    def test_preserves_int(self):
        self.assertEqual(_serialize_progress_value(5), 5)
        self.assertIsInstance(_serialize_progress_value(5), int)

    def test_preserves_zero(self):
        self.assertEqual(_serialize_progress_value(0), 0)
        self.assertIsInstance(_serialize_progress_value(0), int)

    def test_preserves_bool_true(self):
        self.assertEqual(_serialize_progress_value(True), True)
        self.assertIsInstance(_serialize_progress_value(True), bool)

    def test_preserves_bool_false(self):
        self.assertEqual(_serialize_progress_value(False), False)

    def test_preserves_none(self):
        self.assertIsNone(_serialize_progress_value(None))

    def test_preserves_string(self):
        self.assertEqual(_serialize_progress_value("hello"), "hello")

    def test_float_to_string(self):
        # Floats are preserved as floats per the typed schema
        self.assertEqual(_serialize_progress_value(3.14), 3.14)


class DeserializeProgressValueTests(unittest.TestCase):
    def test_modern_int_passes_through(self):
        self.assertEqual(_deserialize_progress_value(5, default=0), 5)

    def test_modern_bool_passes_through(self):
        self.assertEqual(_deserialize_progress_value(True), True)

    def test_modern_none_returns_default(self):
        self.assertEqual(_deserialize_progress_value(None, default=0), 0)

    def test_legacy_string_int(self):
        self.assertEqual(_deserialize_progress_value("5", default=0), 5)
        self.assertIsInstance(_deserialize_progress_value("5", default=0), int)

    def test_legacy_empty_string_default_zero(self):
        self.assertEqual(_deserialize_progress_value("", default=0), 0)

    def test_legacy_empty_string_default_empty_str(self):
        self.assertEqual(_deserialize_progress_value("", default=""), "")

    def test_legacy_string_preserved(self):
        self.assertEqual(
            _deserialize_progress_value("Feed Title", default=""), "Feed Title"
        )


class ProgressRoundTripTests(unittest.TestCase):
    def test_typed_round_trip(self):
        original = {
            "schema_version": PROGRESS_SCHEMA_VERSION,
            "status": "done",
            "fields": {
                "articles_fetched": 5,
                "http_status": 200,
                "feed_title": "My Feed",
                "error_message": None,
                "latest_item_at": "2024-01-01T00:00:00",
            },
        }
        serialized = json.dumps(original)
        restored = json.loads(serialized)
        self.assertEqual(restored["fields"]["articles_fetched"], 5)
        self.assertIsInstance(restored["fields"]["articles_fetched"], int)
        self.assertEqual(restored["fields"]["http_status"], 200)
        self.assertIsNone(restored["fields"]["error_message"])

    def test_failed_round_trip(self):
        original = {
            "schema_version": PROGRESS_SCHEMA_VERSION,
            "status": "failed",
            "fields": {
                "articles_fetched": 0,
                "http_status": 0,
                "error_message": "Timeout after 30s",
            },
        }
        serialized = json.dumps(original)
        restored = json.loads(serialized)
        self.assertEqual(restored["status"], "failed")
        self.assertEqual(restored["fields"]["articles_fetched"], 0)
        self.assertIsInstance(restored["fields"]["articles_fetched"], int)


if __name__ == "__main__":
    unittest.main()
