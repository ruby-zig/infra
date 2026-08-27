from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from matrix import RefResult, build_matrix  # noqa: E402


SHA_A = "a" * 40
SHA_B = "b" * 40


class FakeClient:
    def __init__(self, refs):
        self.refs = refs

    def ref(self, owner, name, branch):
        return self.refs[(owner, name, branch)]


def inventory():
    repositories = [
        {"name": name, "upstream": f"ruby/{name}", "default_branch": "main"}
        for name in ("current", "changed", "missing")
    ]
    return {
        "source_owner": "ruby",
        "destination_owner": "ruby-zig",
        "repositories": repositories,
    }


def client():
    refs = {}
    for name in ("current", "changed", "missing"):
        refs[("ruby", name, "main")] = RefResult(SHA_A)
    refs[("ruby-zig", "current", "main")] = RefResult(SHA_A)
    refs[("ruby-zig", "changed", "main")] = RefResult(SHA_B)
    refs[("ruby-zig", "missing", "main")] = RefResult(None, "missing-ref-or-repository")
    return FakeClient(refs)


class MatrixTests(unittest.TestCase):
    def test_all_queues_only_changed_and_errors(self):
        matrix, counts = build_matrix(inventory(), "all", client(), workers=2)

        self.assertEqual([item["name"] for item in matrix["include"]], ["changed", "missing"])
        self.assertEqual(counts, {"scanned": 3, "current": 1, "changed": 1, "errors": 1, "selected": 2})

    def test_manual_single_runs_even_when_current(self):
        matrix, counts = build_matrix(inventory(), "current", client(), workers=2)

        self.assertEqual([item["name"] for item in matrix["include"]], ["current"])
        self.assertEqual(matrix["include"][0]["scan_state"], "current")
        self.assertEqual(counts["selected"], 1)

    def test_unknown_manual_repository_is_refused(self):
        with self.assertRaisesRegex(SystemExit, "not in the inventory"):
            build_matrix(inventory(), "unknown", client(), workers=2)


if __name__ == "__main__":
    unittest.main()
