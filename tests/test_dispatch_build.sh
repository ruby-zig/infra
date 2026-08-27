#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/reports"

export SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export MOCK_GH_LOG="$work/gh.log"
export MOCK_MODE=success

cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_GH_LOG"
[[ "$1" == api ]]
[[ "$2" == --method && "$3" == POST ]]
[[ "$4" == -H && "$5" == 'Accept: application/vnd.github+json' ]]
[[ "$6" == -H && "$7" == 'X-GitHub-Api-Version: 2026-03-10' ]]
[[ "$8" == 'repos/ruby-zig/toolchain/actions/workflows/continuous.yml/dispatches' ]]
[[ "$9" == --input && "${10}" == - ]]
payload=$(cat)
jq -e \
  --arg sha "$SHA_B" '
    keys == ["inputs", "ref"] and
    .ref == "main" and
    (.inputs | keys == ["source-ref-name", "source-repository", "source-sha"]) and
    .inputs["source-repository"] == "ruby-zig/ruby" and
    .inputs["source-ref-name"] == "ruby_3_4" and
    .inputs["source-sha"] == $sha
  ' <<<"$payload" >/dev/null
printf '%s\n' "$payload" >>"$MOCK_GH_LOG"
case "$MOCK_MODE" in
  success)
    printf '%s\n' '{"workflow_run_id":8675309,"run_url":"https://api.github.com/repos/ruby-zig/toolchain/actions/runs/8675309","html_url":"https://github.com/ruby-zig/toolchain/actions/runs/8675309"}'
    ;;
  invalid-response)
    printf '%s\n' '{}'
    ;;
  api-failure)
    exit 1
    ;;
esac
EOF
chmod +x "$work/bin/gh"

export GH_TOKEN=test-token
export GITHUB_REPOSITORY=ruby-zig/infra
export GITHUB_RUN_ID=1234
export GITHUB_RUN_ATTEMPT=2
export PATH="$work/bin:$PATH"

write_sync_report() {
  local status=$1
  local before=$2
  local upstream_sha=$3
  jq -n \
    --arg repository ruby \
    --arg upstream ruby/ruby \
    --arg branch ruby_3_4 \
    --arg status "$status" \
    --arg before "$before" \
    --arg upstream_sha "$upstream_sha" \
    '{repository:$repository,upstream:$upstream,branch:$branch,status:$status,before:$before,upstream_sha:$upstream_sha}' \
    >"$work/sync.json"
}

run_dispatch() {
  bash "$root/scripts/dispatch-build.sh" \
    --sync-report "$work/sync.json" \
    --name ruby \
    --upstream ruby/ruby \
    --branch ruby_3_4 \
    --destination-owner ruby-zig \
    --report "$1"
}

write_sync_report fast-forwarded "$SHA_A" "$SHA_B"
run_dispatch "$work/reports/success.json"
jq -e \
  --arg sha "$SHA_B" '
    .schema == 1 and
    .outcome == "dispatched" and
    .reason == null and
    .source == {
      repository: "ruby-zig/ruby",
      ref_name: "ruby_3_4",
      sha: $sha
    } and
    .sync.status == "fast-forwarded" and
    .controller == {
      repository: "ruby-zig/toolchain",
      workflow: "continuous.yml",
      ref: "main"
    } and
    .api_version == "2026-03-10" and
    .requested_by == {
      repository: "ruby-zig/infra",
      run_id: "1234",
      run_attempt: "2"
    } and
    .workflow_run.id == 8675309
  ' "$work/reports/success.json" >/dev/null
[[ $(wc -l <"$MOCK_GH_LOG") == 2 ]]

: >"$MOCK_GH_LOG"
write_sync_report current "$SHA_B" "$SHA_B"
run_dispatch "$work/reports/current.json"
jq -e '.outcome == "dispatched" and .sync.status == "current"' \
  "$work/reports/current.json" >/dev/null

for invalid_case in failed mismatched-branch invalid-sha; do
  : >"$MOCK_GH_LOG"
  case "$invalid_case" in
    failed) write_sync_report fork-ahead-or-diverged "$SHA_A" "$SHA_B" ;;
    mismatched-branch)
      write_sync_report current "$SHA_B" "$SHA_B"
      jq '.branch = "master"' "$work/sync.json" >"$work/sync.tmp"
      mv "$work/sync.tmp" "$work/sync.json"
      ;;
    invalid-sha) write_sync_report current "$SHA_A" "${SHA_B}bb" ;;
  esac
  if run_dispatch "$work/reports/${invalid_case}.json"; then
    printf '%s sync report must be refused\n' "$invalid_case" >&2
    exit 1
  fi
  jq -e '.outcome == "refused" and .reason == "invalid-sync-report"' \
    "$work/reports/${invalid_case}.json" >/dev/null
  [[ ! -s "$MOCK_GH_LOG" ]] || {
    printf '%s sync report reached GitHub\n' "$invalid_case" >&2
    exit 1
  }
done

for mode in invalid-response api-failure; do
  export MOCK_MODE=$mode
  write_sync_report fast-forwarded "$SHA_A" "$SHA_B"
  if run_dispatch "$work/reports/${mode}.json"; then
    printf '%s must fail the dispatch\n' "$mode" >&2
    exit 1
  fi
done
jq -e '.outcome == "failed" and .reason == "invalid-api-response"' \
  "$work/reports/invalid-response.json" >/dev/null
jq -e '.outcome == "failed" and .reason == "api-rejected"' \
  "$work/reports/api-failure.json" >/dev/null

printf 'dispatch-build tests passed\n'
