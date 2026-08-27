#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

REPOSITORY = re.compile(r"^[A-Za-z0-9._-]+$")
BRANCH = re.compile(r"^(?!-)(?!.*\.\.)(?!.*[~^:?*\\\[\s])[A-Za-z0-9._/-]+$")
ACTIVE_SCOPE = "native-build-affected"


def valid_branch(value: object) -> bool:
    if not isinstance(value, str) or not BRANCH.fullmatch(value):
        return False
    if value in {"@", "."} or value.endswith((".", "/")):
        return False
    if "//" in value or "@{" in value:
        return False
    return all(
        segment and not segment.startswith(".") and not segment.endswith(".lock")
        for segment in value.split("/")
    )


def read_allowlist(inventory_path: Path, value: object, errors: list[str]) -> list[str]:
    if (
        not isinstance(value, str)
        or not value
        or value in {".", ".."}
        or "/" in value
        or "\\" in value
    ):
        errors.append("allowlist must be a file next to the inventory")
        return []
    allowlist_path = inventory_path.parent / value
    try:
        names = allowlist_path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        errors.append(f"allowlist could not be read: {error}")
        return []
    if not names:
        errors.append("allowlist must not be empty")
        return []
    for index, name in enumerate(names):
        if not REPOSITORY.fullmatch(name):
            errors.append(f"allowlist[{index}] is invalid")
    if len(names) != len(set(names)):
        errors.append("allowlist names must be unique")
    if names != sorted(names, key=str.casefold):
        errors.append("allowlist names must be sorted")
    return names


def load_and_validate(
    path: Path,
    *,
    expected_count: int | None = None,
    required_scope: str | None = None,
) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"inventory could not be read: {error}") from error

    errors: list[str] = []
    if not isinstance(data, dict):
        raise SystemExit("inventory validation failed:\n- inventory must be an object")
    if data.get("schema") != 1:
        errors.append("schema must be 1")
    if data.get("source_owner") != "ruby":
        errors.append("source_owner must be ruby")
    if data.get("destination_owner") != "ruby-zig":
        errors.append("destination_owner must be ruby-zig")
    if required_scope is not None and data.get("scope") != required_scope:
        errors.append(f"scope must be {required_scope}")

    repositories = data.get("repositories")
    if not isinstance(repositories, list):
        errors.append("repositories must be an array")
        repositories = []
    if data.get("count") != len(repositories):
        errors.append("count does not match repositories")
    if expected_count is not None and len(repositories) != expected_count:
        errors.append(
            f"inventory must contain {expected_count} repositories, found {len(repositories)}"
        )

    active = data.get("scope") == ACTIVE_SCOPE
    allowlist_names: list[str] | None = None
    if active:
        allowlist_names = read_allowlist(path, data.get("allowlist"), errors)

    names: list[str] = []
    identities: list[tuple[str, str]] = []
    for index, repository in enumerate(repositories):
        where = f"repositories[{index}]"
        if not isinstance(repository, dict):
            errors.append(f"{where} must be an object")
            continue
        name = repository.get("name")
        upstream = repository.get("upstream")
        default_branch = repository.get("default_branch")
        if not isinstance(name, str) or not REPOSITORY.fullmatch(name):
            errors.append(f"{where}.name is invalid")
            continue
        names.append(name)
        if upstream != f"ruby/{name}":
            errors.append(f"{where}.upstream must be ruby/{name}")
        if not valid_branch(default_branch):
            errors.append(f"{where}.default_branch is invalid")
        if not isinstance(repository.get("archived"), bool):
            errors.append(f"{where}.archived must be boolean")
        if not isinstance(repository.get("upstream_is_fork"), bool):
            errors.append(f"{where}.upstream_is_fork must be boolean")

        branches = repository.get("branches")
        if branches is None and not active:
            branches = [default_branch]
        if not isinstance(branches, list) or not branches:
            errors.append(f"{where}.branches must be a non-empty array")
            continue
        non_string_branches = [
            branch_index
            for branch_index, branch in enumerate(branches)
            if not isinstance(branch, str)
        ]
        if non_string_branches:
            for branch_index in non_string_branches:
                errors.append(f"{where}.branches[{branch_index}] must be a string")
            continue
        if branches[0] != default_branch:
            errors.append(f"{where}.branches must start with default_branch")
        if len(branches) != len(set(branches)):
            errors.append(f"{where}.branches must be unique")
        for branch_index, branch in enumerate(branches):
            if not valid_branch(branch):
                errors.append(f"{where}.branches[{branch_index}] is invalid")
            else:
                identities.append((name, branch))

    if len(names) != len(set(names)):
        errors.append("repository names must be unique")
    if names != sorted(names, key=str.casefold):
        errors.append("repositories must be sorted by name")
    if len(identities) != len(set(identities)):
        errors.append("repository and branch identities must be unique")
    if allowlist_names is not None and names != allowlist_names:
        errors.append("repositories must exactly match the ordered allowlist")
    if errors:
        raise SystemExit("inventory validation failed:\n- " + "\n- ".join(errors))
    return data


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "inventory", nargs="?", type=Path, default=Path("config/repositories.json")
    )
    parser.add_argument("--expected-count", type=int)
    parser.add_argument("--require-scope")
    args = parser.parse_args()
    data = load_and_validate(
        args.inventory,
        expected_count=args.expected_count,
        required_scope=args.require_scope,
    )
    tracked_refs = sum(
        len(repository.get("branches", [repository["default_branch"]]))
        for repository in data["repositories"]
    )
    print(f"validated {data['count']} repositories and {tracked_refs} tracked refs")


if __name__ == "__main__":
    main()
