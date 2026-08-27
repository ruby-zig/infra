#!/usr/bin/env bash
set -Eeuo pipefail

name=
upstream=
branch=
destination_owner=
report=
while (($#)); do
  case "$1" in
    --name) name=${2:?}; shift 2 ;;
    --upstream) upstream=${2:?}; shift 2 ;;
    --branch) branch=${2:?}; shift 2 ;;
    --destination-owner) destination_owner=${2:?}; shift 2 ;;
    --report) report=${2:?}; shift 2 ;;
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
[[ -n "$report" ]] || { printf 'report path is required\n' >&2; exit 64; }
mkdir -p "$(dirname "$report")"

before=
upstream_sha=
write_report() {
  local status=$1
  jq -n --arg repository "$name" --arg upstream "$upstream" --arg branch "$branch" \
    --arg status "$status" --arg before "$before" --arg upstream_sha "$upstream_sha" \
    '{repository:$repository,upstream:$upstream,branch:$branch,status:$status,before:$before,upstream_sha:$upstream_sha}' >"$report"
}
fail() {
  write_report "$1"
  printf '::error title=Upstream sync refused::%s: %s\n' "$name" "$2" >&2
  exit 1
}
on_exit() {
  local code=$?
  trap - EXIT
  if ((code != 0)) && [[ ! -s "$report" ]]; then
    write_report internal-error
  fi
  exit "$code"
}
trap on_exit EXIT

if ! repository_json=$(gh api "repos/${destination_owner}/${name}" 2>/dev/null); then
  fail missing-fork "destination fork is missing or inaccessible"
fi
[[ $(jq -r '.fork' <<<"$repository_json") == true ]] || fail not-a-fork "destination is not a fork"
[[ $(jq -r '.parent.full_name // ""' <<<"$repository_json") == "$upstream" ]] || fail parent-mismatch "fork parent does not match $upstream"
[[ $(jq -r '.default_branch' <<<"$repository_json") == "$branch" ]] || fail branch-mismatch "default branch does not match $branch"

if ! upstream_ref=$(git ls-remote --exit-code "https://github.com/${upstream}.git" "refs/heads/${branch}"); then
  fail upstream-unavailable "upstream branch is unavailable"
fi
upstream_sha=${upstream_ref%%[[:space:]]*}
[[ "$upstream_sha" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || fail upstream-invalid "upstream returned an invalid commit"

if ! before=$(gh api "repos/${destination_owner}/${name}/git/ref/heads/${branch}" --jq '.object.sha'); then
  fail missing-branch "destination default branch is missing"
fi
if [[ "$before" == "$upstream_sha" ]]; then
  write_report current
  printf '%s is current at %s\n' "$name" "$before"
  exit 0
fi

if ! comparison=$(gh api "repos/${destination_owner}/${name}/compare/${before}...${upstream_sha}"); then
  fail comparison-failed "commits could not be compared in the fork network"
fi
merge_base=$(jq -r '.merge_base_commit.sha // ""' <<<"$comparison")
behind_by=$(jq -r '.behind_by // -1' <<<"$comparison")
if [[ "$merge_base" != "$before" || "$behind_by" != 0 ]]; then
  fail fork-ahead-or-diverged "destination contains commits that are not in upstream"
fi

if ! updated=$(gh api --method PATCH "repos/${destination_owner}/${name}/git/refs/heads/${branch}" \
  -f sha="$upstream_sha" -F force=false); then
  fail update-rejected "GitHub rejected the non-forced reference update"
fi
[[ $(jq -r '.object.sha // ""' <<<"$updated") == "$upstream_sha" ]] || fail update-unverified "updated reference did not match upstream"
write_report fast-forwarded
printf '%s fast-forwarded %s -> %s\n' "$name" "$before" "$upstream_sha"
