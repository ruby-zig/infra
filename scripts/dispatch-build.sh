#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
inventory="$root/config/repositories.json"
sync_report=
name=
upstream=
branch=
destination_owner=
report=
while (($#)); do
  case "$1" in
    --inventory) inventory=${2:?}; shift 2 ;;
    --sync-report) sync_report=${2:?}; shift 2 ;;
    --name) name=${2:?}; shift 2 ;;
    --upstream) upstream=${2:?}; shift 2 ;;
    --branch) branch=${2:?}; shift 2 ;;
    --destination-owner) destination_owner=${2:?}; shift 2 ;;
    --report) report=${2:?}; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

: "${GH_TOKEN:?GH_TOKEN is required}"
[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || {
  printf 'invalid repository name\n' >&2
  exit 64
}
[[ "$upstream" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
  printf 'invalid upstream repository\n' >&2
  exit 64
}
[[ "$destination_owner" =~ ^[A-Za-z0-9_-]+$ ]] || {
  printf 'invalid destination owner\n' >&2
  exit 64
}
[[ "$branch" =~ ^[A-Za-z0-9._/-]+$ && "$branch" != -* && "$branch" != *..* ]] || {
  printf 'invalid branch\n' >&2
  exit 64
}
[[ -n "$sync_report" ]] || { printf 'sync report path is required\n' >&2; exit 64; }
[[ -n "$report" ]] || { printf 'dispatch report path is required\n' >&2; exit 64; }
mkdir -p "$(dirname "$report")"

controller_repository=ruby-zig/toolchain
controller_workflow=continuous.yml
controller_ref=main
api_version=2026-03-10
source_repository="${destination_owner}/${name}"
source_sha=
sync_status=
before=
workflow_run_id=
workflow_run_api_url=
workflow_run_html_url=

write_report() {
  local outcome=$1
  local reason=$2
  jq -n \
    --arg outcome "$outcome" \
    --arg reason "$reason" \
    --arg source_repository "$source_repository" \
    --arg source_ref_name "$branch" \
    --arg source_sha "$source_sha" \
    --arg sync_status "$sync_status" \
    --arg sync_before "$before" \
    --arg sync_upstream "$upstream" \
    --arg controller_repository "$controller_repository" \
    --arg controller_workflow "$controller_workflow" \
    --arg controller_ref "$controller_ref" \
    --arg api_version "$api_version" \
    --arg requested_by_repository "${GITHUB_REPOSITORY:-}" \
    --arg requested_by_run_id "${GITHUB_RUN_ID:-}" \
    --arg requested_by_run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
    --arg workflow_run_id "$workflow_run_id" \
    --arg workflow_run_api_url "$workflow_run_api_url" \
    --arg workflow_run_html_url "$workflow_run_html_url" \
    '{
      schema: 1,
      outcome: $outcome,
      reason: (if $reason == "" then null else $reason end),
      source: {
        repository: $source_repository,
        ref_name: $source_ref_name,
        sha: $source_sha
      },
      sync: {
        status: $sync_status,
        before: $sync_before,
        upstream: $sync_upstream
      },
      controller: {
        repository: $controller_repository,
        workflow: $controller_workflow,
        ref: $controller_ref
      },
      api_version: $api_version,
      requested_by: {
        repository: $requested_by_repository,
        run_id: $requested_by_run_id,
        run_attempt: $requested_by_run_attempt
      },
      workflow_run: (
        if $workflow_run_id == "" then null
        else {
          id: ($workflow_run_id | tonumber),
          api_url: $workflow_run_api_url,
          html_url: $workflow_run_html_url
        }
        end
      )
    }' >"$report"
}
fail() {
  write_report "$1" "$2"
  printf '::error title=Build dispatch refused::%s@%s: %s\n' \
    "$name" "$branch" "$2" >&2
  exit 1
}
on_exit() {
  local code=$?
  trap - EXIT
  if ((code != 0)) && [[ ! -s "$report" ]]; then
    write_report failed internal-error
  fi
  exit "$code"
}
trap on_exit EXIT

if ! python3 "$root/scripts/validate_inventory.py" "$inventory" \
  --require-scope native-build-affected >/dev/null; then
  fail refused invalid-inventory
fi
if ! entry=$(jq -ce --arg name "$name" \
  '.repositories[] | select(.name == $name)' "$inventory"); then
  fail refused untracked-repository
fi
expected_upstream=$(jq -r '.upstream' <<<"$entry")
expected_destination_owner=$(jq -r '.destination_owner' "$inventory")
[[ "$upstream" == "$expected_upstream" ]] || fail refused upstream-mismatch
[[ "$destination_owner" == "$expected_destination_owner" ]] || {
  fail refused destination-owner-mismatch
}
if ! jq -e --arg branch "$branch" '.branches | index($branch) != null' \
  <<<"$entry" >/dev/null; then
  fail refused untracked-branch
fi

if ! sync=$(jq -ce \
  --arg repository "$name" \
  --arg upstream "$upstream" \
  --arg branch "$branch" '
    select(
      type == "object" and
      keys == ["before", "branch", "repository", "status", "upstream", "upstream_sha"] and
      .repository == $repository and
      .upstream == $upstream and
      .branch == $branch and
      (.status == "current" or .status == "fast-forwarded") and
      (.before | type == "string" and test("^[0-9a-f]{40}$")) and
      (.upstream_sha | type == "string" and test("^[0-9a-f]{40}$")) and
      (
        (.status == "current" and .before == .upstream_sha) or
        (.status == "fast-forwarded" and .before != .upstream_sha)
      )
    )
  ' "$sync_report" 2>/dev/null); then
  fail refused invalid-sync-report
fi

sync_status=$(jq -r '.status' <<<"$sync")
before=$(jq -r '.before' <<<"$sync")
source_sha=$(jq -r '.upstream_sha' <<<"$sync")

payload=$(jq -nc \
  --arg ref "$controller_ref" \
  --arg source_repository "$source_repository" \
  --arg source_ref_name "$branch" \
  --arg source_sha "$source_sha" \
  '{
    ref: $ref,
    inputs: {
      "source-repository": $source_repository,
      "source-ref-name": $source_ref_name,
      "source-sha": $source_sha
    }
  }')

if ! response=$(gh api --method POST \
  -H 'Accept: application/vnd.github+json' \
  -H "X-GitHub-Api-Version: ${api_version}" \
  "repos/${controller_repository}/actions/workflows/${controller_workflow}/dispatches" \
  --input - <<<"$payload"); then
  fail failed api-rejected
fi
if ! run=$(jq -ce '
  select(
    (.workflow_run_id | type == "number" and . > 0 and floor == .) and
    (.run_url | type == "string" and length > 0) and
    (.html_url | type == "string" and length > 0)
  )
' <<<"$response" 2>/dev/null); then
  fail failed invalid-api-response
fi

workflow_run_id=$(jq -r '.workflow_run_id' <<<"$run")
workflow_run_api_url=$(jq -r '.run_url' <<<"$run")
workflow_run_html_url=$(jq -r '.html_url' <<<"$run")
write_report dispatched ''
printf '%s@%s dispatched at %s to %s\n' \
  "$source_repository" "$branch" "$source_sha" "$workflow_run_html_url"
