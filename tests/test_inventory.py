from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

import sys

sys.path.insert(0, str(ROOT / "scripts"))

from validate_inventory import load_and_validate  # noqa: E402


class InventoryTests(unittest.TestCase):
    def active_document(self) -> dict:
        return json.loads(
            (ROOT / "config" / "repositories.json").read_text(encoding="utf-8")
        )

    def write_active_fixture(self, directory: str, data: dict) -> Path:
        config = Path(directory) / "config"
        config.mkdir()
        inventory = config / "repositories.json"
        inventory.write_text(json.dumps(data), encoding="utf-8")
        shutil.copyfile(
            ROOT / "config" / "affected-repositories.txt",
            config / "affected-repositories.txt",
        )
        return inventory

    def test_active_inventory_matches_native_scope(self):
        inventory = load_and_validate(ROOT / "config" / "repositories.json")
        affected = (ROOT / "config" / "affected-repositories.txt").read_text(
            encoding="utf-8"
        ).splitlines()

        self.assertEqual(inventory["scope"], "native-build-affected")
        self.assertEqual(inventory["count"], 39)
        self.assertEqual(
            [repository["name"] for repository in inventory["repositories"]],
            affected,
        )

    def test_only_supported_cruby_branches_expand_beyond_default(self):
        inventory = load_and_validate(ROOT / "config" / "repositories.json")
        repositories = {item["name"]: item for item in inventory["repositories"]}

        self.assertEqual(
            repositories["ruby"]["branches"],
            ["master", "ruby_4_0", "ruby_3_4", "ruby_3_3"],
        )
        self.assertNotIn("ruby_3_2", repositories["ruby"]["branches"])
        for name, repository in repositories.items():
            if name != "ruby":
                self.assertEqual(
                    repository["branches"],
                    [repository["default_branch"]],
                )

    def test_discovery_snapshot_is_complete_and_contains_active_scope(self):
        active = load_and_validate(ROOT / "config" / "repositories.json")
        discovery = load_and_validate(
            ROOT / "config" / "discovery-repositories.json",
            expected_count=190,
        )

        active_names = {item["name"] for item in active["repositories"]}
        discovery_names = {item["name"] for item in discovery["repositories"]}
        self.assertEqual(discovery["count"], 190)
        self.assertLessEqual(active_names, discovery_names)

    def test_allowlist_dot_paths_are_rejected_before_file_access(self):
        for value in (".", ".."):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                data = self.active_document()
                data["allowlist"] = value
                inventory = self.write_active_fixture(directory, data)

                with self.assertRaisesRegex(
                    SystemExit, "allowlist must be a file next to the inventory"
                ):
                    load_and_validate(inventory)

    def test_every_non_string_branch_is_rejected_without_set_conversion(self):
        with tempfile.TemporaryDirectory() as directory:
            data = self.active_document()
            repository = data["repositories"][0]
            repository["branches"] = [
                repository["default_branch"],
                7,
                {"invalid": "mapping"},
                ["invalid", "array"],
            ]
            inventory = self.write_active_fixture(directory, data)

            with self.assertRaises(SystemExit) as caught:
                load_and_validate(inventory)
            message = str(caught.exception)
            for branch_index in (1, 2, 3):
                self.assertIn(
                    f"repositories[0].branches[{branch_index}] must be a string",
                    message,
                )


if __name__ == "__main__":
    unittest.main()
