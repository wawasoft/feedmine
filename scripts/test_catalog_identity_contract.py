import ast
import json
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from scripts.catalog_identity import (
    canonical_url, request_url, valid_http_url, compute_source_id
)


ROOT = Path(__file__).resolve().parents[1]


class CatalogIdentityContractTests(unittest.TestCase):
    def test_shared_contract_vectors(self):
        vectors = json.loads(
            (ROOT / "scripts/data/catalog_identity_vectors.json").read_text(encoding="utf-8")
        )
        for vector in vectors:
            with self.subTest(vector["name"]):
                self.assertEqual(canonical_url(vector["raw"]), vector["canonical"])
                self.assertEqual(request_url(vector["raw"]), vector["request"])
                self.assertEqual(valid_http_url(vector["raw"]), vector["valid"])

    def test_catalog_producers_do_not_define_private_source_id_hashes(self):
        violations = []
        for path in sorted((ROOT / "scripts").rglob("*.py")):
            if path.name == "catalog_identity.py" or path.name.startswith("test_"):
                continue
            contents = path.read_text(encoding="utf-8")
            tree = ast.parse(contents, filename=str(path))
            parents = {
                child: parent
                for parent in ast.walk(tree)
                for child in ast.iter_child_nodes(parent)
            }
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
                    continue
                if not (
                    node.func.attr == "sha256"
                    and isinstance(node.func.value, ast.Name)
                    and node.func.value.id == "hashlib"
                ):
                    continue
                source = ast.get_source_segment(contents, node) or ""
                parent = parents.get(node)
                while parent is not None and not isinstance(parent, (ast.Assign, ast.AnnAssign)):
                    parent = parents.get(parent)
                if isinstance(parent, ast.Assign):
                    target_names = {
                        target.id
                        for assignment_target in parent.targets
                        for target in ast.walk(assignment_target)
                        if isinstance(target, ast.Name)
                    }
                elif isinstance(parent, ast.AnnAssign):
                    target_names = {
                        target.id for target in ast.walk(parent.target) if isinstance(target, ast.Name)
                    }
                else:
                    target_names = set()
                # Item/content digests may intentionally include a feed URL.
                # This gate is specifically about source identity producers.
                if target_names and target_names <= {"item_id", "article_id", "content_id"}:
                    continue
                if any(token in source.casefold() for token in ("url", "feed", "canonical", "norm")):
                    violations.append(f"{path.relative_to(ROOT)}:{node.lineno}: {source}")
        self.assertEqual(violations, [], "private URL identity hashes:\n" + "\n".join(violations))


    def test_canonical_url_is_idempotent(self):
        """P1-06: canonical(canonical(x)) == canonical(x) for all vectors."""
        vectors = json.loads(
            (ROOT / "scripts/data/catalog_identity_vectors.json").read_text(encoding="utf-8")
        )
        for vector in vectors:
            with self.subTest(vector["name"]):
                once = canonical_url(vector["raw"])
                twice = canonical_url(once)
                self.assertEqual(
                    once, twice,
                    f"not idempotent: canonical({vector['raw']!r}) = {once!r}, "
                    f"canonical({once!r}) = {twice!r}"
                )

    def test_source_id_stable_after_canonical(self):
        """P1-06: compute_source_id(raw) == compute_source_id(canonical(raw))."""
        vectors = json.loads(
            (ROOT / "scripts/data/catalog_identity_vectors.json").read_text(encoding="utf-8")
        )
        for vector in vectors:
            with self.subTest(vector["name"]):
                id_from_raw = compute_source_id(vector["raw"])
                can = canonical_url(vector["raw"])
                id_from_canonical = compute_source_id(can)
                self.assertEqual(
                    id_from_raw, id_from_canonical,
                    f"id(raw) = {id_from_raw[:12]}..., "
                    f"id(canonical(raw)) = {id_from_canonical[:12]}..."
                )

    def test_percent_encoded_host_delimiters_rejected(self):
        """P1-05: URLs with percent-encoded authority delimiters are invalid."""
        invalid_urls = [
            "https://foo%2Fbar/feed",
            "https://example%3Acom/feed",
            "https://foo%40bar/feed",
            "https://%5B::1%5D/feed",
        ]
        for url in invalid_urls:
            with self.subTest(url):
                self.assertFalse(valid_http_url(url), f"should be invalid: {url!r}")

    def test_valid_bracketed_ipv6_accepted(self):
        """P1-05: Properly bracketed IPv6 is valid."""
        self.assertTrue(valid_http_url("https://[2001:db8::1]/feed"))

    def test_all_opml_source_ids_match_compute_source_id(self):
        """Every feedmineSourceId in every OPML must equal compute_source_id(xmlUrl)."""
        feeds_root = ROOT / "feedmine" / "Resources" / "Feeds"
        if not feeds_root.exists():
            self.skipTest("Feeds directory not available")

        mismatches = []
        for opml_path in sorted(feeds_root.rglob("*.opml")):
            try:
                root_elem = ET.parse(opml_path).getroot()
            except ET.ParseError as e:
                mismatches.append(f"{opml_path}: parse error: {e}")
                continue
            for elem in root_elem.iter():
                url = elem.attrib.get("xmlUrl")
                source_id = elem.attrib.get("feedmineSourceId")
                if url and source_id:
                    expected = compute_source_id(url)
                    if source_id != expected:
                        mismatches.append(
                            f"{opml_path}: {url!r} expected {expected[:16]}..., "
                            f"got {source_id[:16]}..."
                        )

        self.assertEqual(
            mismatches, [],
            f"{len(mismatches)} OPML source_id mismatches found"
        )


if __name__ == "__main__":
    unittest.main()
