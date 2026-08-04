import ast
import json
import unittest
from pathlib import Path

from scripts.catalog_identity import canonical_url, request_url, valid_http_url


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


if __name__ == "__main__":
    unittest.main()
