from __future__ import annotations

import unittest
from pathlib import Path


WORKFLOW = (
    Path(__file__).resolve().parents[1]
    / ".github"
    / "workflows"
    / "sync-upstreams.yml"
)


def step(text: str, name: str, next_name: str) -> str:
    start = text.index(f"      - name: {name}")
    end = text.index(f"      - name: {next_name}", start)
    return text[start:end]


class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")

    def test_dispatch_token_is_separate_and_repository_scoped(self):
        block = step(
            self.text,
            "Mint toolchain dispatch App token",
            "Dispatch exact synchronized SHA",
        )

        self.assertIn("if: steps.sync.outcome == 'success'", block)
        self.assertIn("RUBY_ZIG_DISPATCH_APP_ID", block)
        self.assertIn("RUBY_ZIG_DISPATCH_APP_PRIVATE_KEY", block)
        self.assertIn("owner: ruby-zig", block)
        self.assertIn("repositories: toolchain", block)
        self.assertIn("permission-actions: write", block)
        self.assertNotIn("permission-contents:", block)
        self.assertNotIn("permission-workflows:", block)

    def test_dispatch_receives_only_the_lane_identity_and_reports(self):
        block = step(
            self.text,
            "Dispatch exact synchronized SHA",
            "Publish lane summary",
        )

        self.assertIn("GH_TOKEN: ${{ steps.dispatch-token.outputs.token }}", block)
        self.assertIn('--sync-report "$SYNC_REPORT"', block)
        self.assertIn("--name '${{ matrix.name }}'", block)
        self.assertIn("--upstream '${{ matrix.upstream }}'", block)
        self.assertIn("--branch '${{ matrix.branch }}'", block)
        self.assertIn(
            "--destination-owner '${{ matrix.destination_owner }}'", block
        )
        self.assertIn('--report "$DISPATCH_REPORT"', block)


if __name__ == "__main__":
    unittest.main()
