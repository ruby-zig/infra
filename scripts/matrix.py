#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

from validate_inventory import ACTIVE_SCOPE, load_and_validate


@dataclass(frozen=True)
class RefResult:
    sha: str | None
    error: str | None = None


class GitHubClient:
    def __init__(self, token: str, api_url: str = "https://api.github.com") -> None:
        self.token = token
        self.api_url = api_url.rstrip("/")

    def ref(self, owner: str, name: str, branch: str) -> RefResult:
        path = "/repos/{}/{}/git/ref/heads/{}".format(
            urllib.parse.quote(owner, safe=""),
            urllib.parse.quote(name, safe=""),
            urllib.parse.quote(branch, safe=""),
        )
        request = urllib.request.Request(
            self.api_url + path,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self.token}",
                "User-Agent": "ruby-zig-upstream-scan",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        for attempt in range(3):
            try:
                with urllib.request.urlopen(request, timeout=20) as response:
                    payload = json.load(response)
                sha = payload.get("object", {}).get("sha")
                if isinstance(sha, str) and len(sha) in (40, 64):
                    return RefResult(sha=sha)
                return RefResult(None, "invalid-ref-response")
            except urllib.error.HTTPError as error:
                if error.code == 404:
                    return RefResult(None, "missing-ref-or-repository")
                if error.code not in (429, 500, 502, 503, 504) or attempt == 2:
                    return RefResult(None, f"github-http-{error.code}")
            except (OSError, TimeoutError, json.JSONDecodeError) as error:
                if attempt == 2:
                    return RefResult(
                        None, f"github-request-{type(error).__name__.lower()}"
                    )
            time.sleep(1 << attempt)
        return RefResult(None, "github-request-failed")


def make_lane_id(name: str, branch: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", branch).strip("-.") or "ref"
    digest = hashlib.sha256(f"{name}\0{branch}".encode()).hexdigest()[:12]
    return f"{name}--{slug[:80]}-{digest}"


def expand_lanes(data: dict) -> list[dict]:
    lanes = [
        {
            "name": repository["name"],
            "upstream": repository["upstream"],
            "branch": branch,
            "expected_default_branch": repository["default_branch"],
            "destination_owner": data["destination_owner"],
            "lane_id": make_lane_id(repository["name"], branch),
        }
        for repository in data["repositories"]
        for branch in repository["branches"]
    ]
    lane_ids = [lane["lane_id"] for lane in lanes]
    if len(lane_ids) != len(set(lane_ids)):
        raise SystemExit("generated lane IDs are not unique")
    return lanes


def inspect_lane(
    client: GitHubClient, source_owner: str, destination_owner: str, lane: dict
) -> dict:
    upstream = client.ref(source_owner, lane["name"], lane["branch"])
    destination = client.ref(destination_owner, lane["name"], lane["branch"])
    errors = [error for error in (upstream.error, destination.error) if error]
    if errors:
        state = "scan-error:" + ",".join(errors)
    elif upstream.sha == destination.sha:
        state = "current"
    else:
        state = "changed"
    return {"lane": lane, "state": state}


def build_matrix(
    data: dict,
    repository: str,
    branch: str | None,
    client: GitHubClient,
    workers: int = 8,
) -> tuple[dict, dict]:
    branch = branch or None
    if branch is not None and repository == "all":
        raise SystemExit("branch selection requires an exact repository")

    lanes = expand_lanes(data)
    manual_repository = repository != "all"
    if manual_repository:
        lanes = [lane for lane in lanes if lane["name"] == repository]
        if not lanes:
            raise SystemExit(f"repository is not in the inventory: {repository}")
    if branch is not None:
        lanes = [lane for lane in lanes if lane["branch"] == branch]
        if not lanes:
            raise SystemExit(f"branch is not tracked for repository: {repository}@{branch}")

    observations: list[dict] = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [
            pool.submit(
                inspect_lane,
                client,
                data["source_owner"],
                data["destination_owner"],
                lane,
            )
            for lane in lanes
        ]
        for future in as_completed(futures):
            observations.append(future.result())
    observations.sort(
        key=lambda result: (
            result["lane"]["name"].casefold(),
            result["lane"]["branch"].casefold(),
        )
    )

    selected = [
        result
        for result in observations
        if manual_repository or result["state"] != "current"
    ]
    matrix = {
        "include": [
            {**result["lane"], "scan_state": result["state"]}
            for result in selected
        ]
    }
    counts = {
        "scanned": len(observations),
        "current": sum(result["state"] == "current" for result in observations),
        "changed": sum(result["state"] == "changed" for result in observations),
        "errors": sum(
            result["state"].startswith("scan-error:") for result in observations
        ),
        "selected": len(selected),
    }
    return matrix, counts


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", type=Path, default=Path("config/repositories.json"))
    parser.add_argument("--repository", default="all")
    parser.add_argument("--branch", default="")
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()
    if not 1 <= args.workers <= 16:
        raise SystemExit("workers must be between 1 and 16")
    token = os.environ.get("GH_TOKEN")
    if not token:
        raise SystemExit("GH_TOKEN is required")

    data = load_and_validate(args.inventory, required_scope=ACTIVE_SCOPE)
    matrix, counts = build_matrix(
        data,
        args.repository,
        args.branch or None,
        GitHubClient(token, os.environ.get("GITHUB_API_URL", "https://api.github.com")),
        args.workers,
    )
    encoded = json.dumps(matrix, separators=(",", ":"))
    print(
        "scanned {scanned} refs: {current} current, {changed} changed, "
        "{errors} errors; selected {selected}".format(**counts)
    )
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as output:
            output.write(f"matrix={encoded}\n")
            output.write(f"count={counts['selected']}\n")
    else:
        print(encoded)
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as summary:
            summary.write("## Upstream scan\n\n")
            summary.write(
                "Scanned **{scanned}** tracked refs: **{current}** current, "
                "**{changed}** changed, **{errors}** errors. "
                "Queued **{selected}** sync lanes.\n".format(**counts)
            )


if __name__ == "__main__":
    main()
