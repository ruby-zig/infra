#!/usr/bin/env bash

set -euo pipefail

name=
upstream=
branch=
destination_owner=
while (($#)); do
  case "$1" in
    --name) name=${2:?}; shift 2 ;;
    --upstream) upstream=${2:?}; shift 2 ;;
    --branch) branch=${2:?}; shift 2 ;;
    --destination-owner) destination_owner=${2:?}; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

: "${GH_TOKEN:?GH_TOKEN is required}"
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { printf 'invalid repository name\n' >&2; exit 64; }
[[ "$upstream" == "ruby/$name" ]] || { printf 'upstream does not match repository\n' >&2; exit 64; }
[[ "$destination_owner" == ruby-zig ]] || { printf 'invalid destination owner\n' >&2; exit 64; }
[[ "$branch" =~ ^[A-Za-z0-9._/-]+$ && "$branch" != -* && "$branch" != *..* ]] || {
  printf 'invalid branch\n' >&2
  exit 64
}

validate_fork() {
  local repository_json=$1
  [[ $(jq -r '.fork' <<<"$repository_json") == true ]] || {
    printf '%s exists but is not a fork\n' "$destination_owner/$name" >&2
    return 1
  }
  [[ $(jq -r '.parent.full_name // ""' <<<"$repository_json") == "$upstream" ]] || {
    printf '%s has the wrong fork parent\n' "$destination_owner/$name" >&2
    return 1
  }
  [[ $(jq -r '.private' <<<"$repository_json") == false ]] || {
    printf '%s is not public\n' "$destination_owner/$name" >&2
    return 1
  }
  [[ $(jq -r '.default_branch' <<<"$repository_json") == "$branch" ]] || {
    printf '%s has the wrong default branch\n' "$destination_owner/$name" >&2
    return 1
  }
}

if repository_json=$(gh api "repos/${destination_owner}/${name}" 2>/dev/null); then
  validate_fork "$repository_json"
  printf '%s already exists and is valid\n' "$destination_owner/$name"
  exit 0
fi

request_output=$(mktemp)
trap 'rm -f "$request_output"' EXIT
if ! gh api --include --method POST "repos/${upstream}/forks" \
  -f organization="$destination_owner" \
  -F default_branch_only=false >"$request_output" 2>&1; then
  if grep -Eiq '(^HTTP/[0-9.]+ 403|HTTP 403)' "$request_output"; then
    retry_after=
    while IFS= read -r header; do
      header=${header%$'\r'}
      if [[ "${header,,}" == retry-after:* ]]; then
        retry_after=${header#*:}
        retry_after=${retry_after#"${retry_after%%[![:space:]]*}"}
        break
      fi
    done <"$request_output"
    if grep -Eiq 'secondary[ -]rate[ -]limit' "$request_output"; then
      reason='GitHub secondary rate limit'
    else
      reason='GitHub rejected fork creation with HTTP 403'
    fi
    if [[ -n "$retry_after" ]]; then
      printf '%s for %s; Retry-After: %s\n' \
        "$reason" "$upstream" "$retry_after" >&2
    else
      printf '%s for %s; no Retry-After header was provided\n' \
        "$reason" "$upstream" >&2
    fi
  else
    printf 'GitHub did not accept the fork request for %s\n' "$upstream" >&2
  fi
  exit 1
fi

for _ in {1..60}; do
  if repository_json=$(gh api "repos/${destination_owner}/${name}" 2>/dev/null); then
    validate_fork "$repository_json"
    printf '%s forked from %s\n' "$destination_owner/$name" "$upstream"
    exit 0
  fi
  sleep 2
done

printf 'timed out waiting for %s to appear\n' "$destination_owner/$name" >&2
exit 1
