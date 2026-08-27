#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
keep_file="$root/config/affected-repositories.txt"
apply=false
while (($#)); do
  case "$1" in
    --keep) keep_file=${2:?}; shift 2 ;;
    --apply) apply=true; shift ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

: "${GH_TOKEN:?GH_TOKEN is required}"
[[ -f "$keep_file" ]] || { printf 'keep file not found: %s\n' "$keep_file" >&2; exit 66; }

declare -A keep=()
while IFS= read -r name; do
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || {
    printf 'invalid repository in keep file: %s\n' "$name" >&2
    exit 64
  }
  [[ -z ${keep[$name]+x} ]] || { printf 'duplicate keep entry: %s\n' "$name" >&2; exit 64; }
  keep[$name]=1
done <"$keep_file"
(( ${#keep[@]} > 0 )) || { printf 'keep file is empty\n' >&2; exit 64; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
GH_PROMPT_DISABLED=1 gh api --paginate 'orgs/ruby-zig/repos?type=all&per_page=100' \
  --jq '.[] | select(.fork == true) | .name' \
  | LC_ALL=C sort -f >"$work/forks.txt"

delete_count=0
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if [[ -n ${keep[$name]+x} ]]; then
    continue
  fi
  parent=$(GH_PROMPT_DISABLED=1 gh api "repos/ruby-zig/$name" \
    --jq '.parent.full_name // ""')
  [[ "$parent" == "ruby/$name" ]] || {
    printf 'refusing to remove %s: unexpected parent %s\n' "$name" "$parent" >&2
    exit 1
  }
  printf '%s\n' "ruby-zig/$name"
  ((delete_count += 1))
  if [[ "$apply" == true ]]; then
    deleted=false
    for attempt in 1 2 3 4 5; do
      if GH_PROMPT_DISABLED=1 gh repo delete "ruby-zig/$name" --yes; then
        deleted=true
        break
      fi
      sleep $((attempt * attempt))
    done
    [[ "$deleted" == true ]] || {
      printf 'could not remove ruby-zig/%s\n' "$name" >&2
      exit 1
    }
    sleep 1
  fi
done <"$work/forks.txt"

if [[ "$apply" == true ]]; then
  printf 'removed %d unaffected forks\n' "$delete_count"
else
  printf 'dry run: %d unaffected forks would be removed\n' "$delete_count" >&2
fi
