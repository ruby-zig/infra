#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/reports"

export SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export SHA_C=cccccccccccccccccccccccccccccccccccccccc
export MOCK_GH_LOG="$work/gh.log"
export MOCK_MODE=success

cat >"$work/bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_GH_LOG"
if [[ "$*" == "ls-remote --exit-code https://github.com/ruby/ruby.git refs/heads/ruby_3_4" ]]; then
  printf '%s\trefs/heads/ruby_3_4\n' "$SHA_B"
  exit 0
fi
printf 'unexpected git call: %s\n' "$*" >&2
exit 1
EOF

cat >"$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_GH_LOG"
case "$*" in
  "api repos/ruby-zig/ruby")
    default_branch=master
    if [[ "$MOCK_MODE" == default-mismatch ]]; then
      default_branch=main
    fi
    printf '{"fork":true,"private":false,"default_branch":"%s","parent":{"full_name":"ruby/ruby"}}\n' "$default_branch"
    ;;
  "api repos/ruby-zig/ruby/git/ref/heads/ruby_3_4 --jq .object.sha")
    [[ "$MOCK_MODE" != missing-branch ]] || exit 1
    printf '%s\n' "$SHA_A"
    ;;
  "api repos/ruby-zig/ruby/compare/${SHA_A}...${SHA_B}")
    merge_base=$SHA_A
    if [[ "$MOCK_MODE" == diverged ]]; then
      merge_base=$SHA_C
    fi
    printf '{"merge_base_commit":{"sha":"%s"},"behind_by":0}\n' "$merge_base"
    ;;
  "api --method PATCH repos/ruby-zig/ruby/git/refs/heads/ruby_3_4 -f sha=${SHA_B} -F force=false")
    printf '{"object":{"sha":"%s"}}\n' "$SHA_B"
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$work/bin/git" "$work/bin/gh"

export GH_TOKEN=test-token
export PATH="$work/bin:$PATH"

run_sync() {
  bash "$root/scripts/sync-one.sh" \
    --name ruby \
    --upstream ruby/ruby \
    --branch ruby_3_4 \
    --destination-owner ruby-zig \
    --report "$1"
}

run_sync "$work/reports/success.json"
jq -e '.repository == "ruby" and .branch == "ruby_3_4" and .status == "fast-forwarded"' \
  "$work/reports/success.json" >/dev/null
grep -F 'force=false' "$MOCK_GH_LOG" >/dev/null

: >"$MOCK_GH_LOG"
if bash "$root/scripts/sync-one.sh" \
  --name ruby \
  --upstream ruby/ruby \
  --branch ruby_3_2 \
  --destination-owner ruby-zig \
  --report "$work/reports/untracked.json"; then
  printf 'untracked branches must be refused\n' >&2
  exit 1
fi
[[ ! -s "$MOCK_GH_LOG" ]] || {
  printf 'untracked input reached GitHub or git\n' >&2
  exit 1
}

for mode in default-mismatch missing-branch diverged; do
  export MOCK_MODE=$mode
  report="$work/reports/$mode.json"
  if run_sync "$report"; then
    printf '%s must be refused\n' "$mode" >&2
    exit 1
  fi
done

jq -e '.status == "default-branch-mismatch"' "$work/reports/default-mismatch.json" >/dev/null
jq -e '.status == "missing-branch"' "$work/reports/missing-branch.json" >/dev/null
jq -e '.status == "fork-ahead-or-diverged"' "$work/reports/diverged.json" >/dev/null

printf 'sync-one tests passed\n'
