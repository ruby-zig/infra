#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

REPOSITORY = re.compile(r"^[A-Za-z0-9._-]+$")
BRANCH = re.compile(r"^(?!-)(?!.*\.\.)(?!.*[~^:?*\\\[\s])[A-Za-z0-9._/-]+$")


def load_and_validate(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    errors: list[str] = []
    if data.get("schema") != 1:
        errors.append("schema must be 1")
    if data.get("source_owner") != "ruby":
        errors.append("source_owner must be ruby")
    if data.get("destination_owner") != "ruby-zig":
        errors.append("destination_owner must be ruby-zig")
    repositories = data.get("repositories")
    if not isinstance(repositories, list):
        errors.append("repositories must be an array")
        repositories = []
    if data.get("count") != len(repositories):
        errors.append("count does not match repositories")
    if len(repositories) != 190:
        errors.append(f"inventory must contain 190 repositories, found {len(repositories)}")

    names: list[str] = []
    for index, repository in enumerate(repositories):
        where = f"repositories[{index}]"
        if not isinstance(repository, dict):
            errors.append(f"{where} must be an object")
            continue
        name = repository.get("name")
        upstream = repository.get("upstream")
        branch = repository.get("default_branch")
        if not isinstance(name, str) or not REPOSITORY.fullmatch(name):
            errors.append(f"{where}.name is invalid")
            continue
        names.append(name)
        if upstream != f"ruby/{name}":
            errors.append(f"{where}.upstream must be ruby/{name}")
        if not isinstance(branch, str) or not BRANCH.fullmatch(branch):
            errors.append(f"{where}.default_branch is invalid")
        if not isinstance(repository.get("archived"), bool):
            errors.append(f"{where}.archived must be boolean")
        if not isinstance(repository.get("upstream_is_fork"), bool):
            errors.append(f"{where}.upstream_is_fork must be boolean")

    if len(names) != len(set(names)):
        errors.append("repository names must be unique")
    if names != sorted(names, key=str.casefold):
        errors.append("repositories must be sorted by name")
    if errors:
        raise SystemExit("inventory validation failed:\n- " + "\n- ".join(errors))
    return data


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("inventory", nargs="?", type=Path, default=Path("config/repositories.json"))
    args = parser.parse_args()
    data = load_and_validate(args.inventory)
    print(f"validated {data['count']} repositories")


if __name__ == "__main__":
    main()
