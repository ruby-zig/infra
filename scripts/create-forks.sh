#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
inventory="$root/config/repositories.json"
repository=all
workers=1
while (($#)); do
  case "$1" in
    --inventory) inventory=${2:?}; shift 2 ;;
    --repository) repository=${2:?}; shift 2 ;;
    --workers) workers=${2:?}; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

: "${GH_TOKEN:?GH_TOKEN is required}"
if ! [[ "$workers" =~ ^[1-9][0-9]*$ ]] || ((workers > 4)); then
  printf 'workers must be between 1 and 4\n' >&2
  exit 64
fi
[[ "$repository" == all || "$repository" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'invalid repository selection\n' >&2
  exit 64
}

python3 "$root/scripts/validate_inventory.py" "$inventory" \
  --require-scope native-build-affected
destination_owner=$(jq -er '.destination_owner' "$inventory")
entries=$(mktemp)
trap 'rm -f "$entries"' EXIT

jq -r --arg repository "$repository" --arg destination_owner "$destination_owner" '
  .repositories[]
  | select($repository == "all" or .name == $repository)
  | [.name, .upstream, .default_branch, $destination_owner]
  | @tsv
' "$inventory" >"$entries"

if [[ ! -s "$entries" ]]; then
  printf 'repository is not in the inventory: %s\n' "$repository" >&2
  exit 64
fi

export GH_PROMPT_DISABLED=1
# shellcheck disable=SC2016
xargs -r -P "$workers" -n 4 bash -c '
  exec "$1/scripts/fork-one.sh" \
    --name "$2" \
    --upstream "$3" \
    --branch "$4" \
    --destination-owner "$5"
' _ "$root" <"$entries"
