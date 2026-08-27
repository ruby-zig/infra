from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

from matrix import RefResult, build_matrix  # noqa: E402


SHA_A = "a" * 40
SHA_B = "b" * 40


class SameRefClient:
    def ref(self, owner, name, branch):
        return RefResult(SHA_A)


class ChangedRefClient:
    def ref(self, owner, name, branch):
        return RefResult(SHA_A if owner == "ruby" else SHA_B)


def active_inventory():
    import json

    path = Path(__file__).resolve().parents[1] / "config" / "repositories.json"
    return json.loads(path.read_text(encoding="utf-8"))


class BranchMatrixTests(unittest.TestCase):
    def test_active_inventory_expands_to_42_tracked_refs(self):
        matrix, counts = build_matrix(
            active_inventory(), "all", None, SameRefClient(), workers=2
        )

        self.assertEqual(matrix, {"include": []})
        self.assertEqual(counts["scanned"], 42)
        self.assertEqual(counts["current"], 42)

    def test_manual_repository_queues_all_of_its_tracked_refs(self):
        matrix, counts = build_matrix(
            active_inventory(), "ruby", None, SameRefClient(), workers=2
        )

        self.assertEqual(
            [item["branch"] for item in matrix["include"]],
            ["master", "ruby_3_3", "ruby_3_4", "ruby_4_0"],
        )
        self.assertEqual(counts["selected"], 4)

    def test_manual_exact_branch_queues_only_that_ref(self):
        matrix, counts = build_matrix(
            active_inventory(), "ruby", "ruby_3_4", SameRefClient(), workers=2
        )

        self.assertEqual(len(matrix["include"]), 1)
        self.assertEqual(matrix["include"][0]["branch"], "ruby_3_4")
        self.assertEqual(counts["selected"], 1)

    def test_branch_requires_exact_repository_and_tracked_value(self):
        with self.assertRaisesRegex(SystemExit, "requires an exact repository"):
            build_matrix(
                active_inventory(), "all", "ruby_3_4", SameRefClient(), workers=2
            )
        with self.assertRaisesRegex(SystemExit, "branch is not tracked"):
            build_matrix(
                active_inventory(), "ruby", "ruby_3_2", SameRefClient(), workers=2
            )

    def test_lane_ids_are_slash_safe_and_collision_resistant(self):
        inventory = {
            "source_owner": "ruby",
            "destination_owner": "ruby-zig",
            "repositories": [
                {
                    "name": "ruby",
                    "upstream": "ruby/ruby",
                    "default_branch": "master",
                    "branches": ["release/a-b", "release-a-b"],
                }
            ],
        }
        matrix, _ = build_matrix(
            inventory, "all", None, ChangedRefClient(), workers=2
        )
        lane_ids = [item["lane_id"] for item in matrix["include"]]

        self.assertEqual(len(lane_ids), 2)
        self.assertEqual(len(set(lane_ids)), 2)
        self.assertTrue(all("/" not in lane_id for lane_id in lane_ids))


if __name__ == "__main__":
    unittest.main()
