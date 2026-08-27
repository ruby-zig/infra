#!/usr/bin/env bash

set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"

# shellcheck disable=SC2016
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$*" >>"$MOCK_GH_LOG"' \
  'if [[ "$*" == "api repos/ruby-zig/bigdecimal" ]]; then' \
  '  [[ -f "$MOCK_GH_STATE/created" ]] || exit 1' \
  '  printf '\''{"fork":true,"private":false,"default_branch":"master","parent":{"full_name":"ruby/bigdecimal"}}\n'\''' \
  '  exit 0' \
  'fi' \
  'if [[ "$*" == api\ --include\ --method\ POST\ repos/ruby/bigdecimal/forks* ]]; then' \
  '  if [[ "${MOCK_GH_MODE:-success}" == secondary-limit ]]; then' \
  '    printf '\''HTTP/2.0 403 Forbidden\r\nRetry-After: 17\r\n\r\nsecondary rate limit\n'\'' >&2' \
  '    exit 1' \
  '  fi' \
  '  : >"$MOCK_GH_STATE/created"' \
  '  printf '\''HTTP/2.0 202 Accepted\r\n\r\n{}\n'\''' \
  '  exit 0' \
  'fi' \
  'printf "unexpected gh call: %s\\n" "$*" >&2' \
  'exit 1' >"$work/bin/gh"
chmod +x "$work/bin/gh" "$root/scripts/create-forks.sh" "$root/scripts/fork-one.sh"

export GH_TOKEN=test-token
export MOCK_GH_LOG="$work/gh.log"
export MOCK_GH_STATE="$work/state"
export PATH="$work/bin:$PATH"

"$root/scripts/create-forks.sh" --repository bigdecimal
post='api --include --method POST repos/ruby/bigdecimal/forks'
[[ $(grep -Fc "$post" "$MOCK_GH_LOG") == 1 ]] || {
  printf 'fork creation must issue exactly one POST\n' >&2
  exit 1
}

: >"$MOCK_GH_LOG"
"$root/scripts/create-forks.sh" --repository bigdecimal
if grep -F 'api --include --method POST' "$MOCK_GH_LOG" >/dev/null; then
  printf 'existing valid forks must not be recreated\n' >&2
  exit 1
fi

rm -f "$MOCK_GH_STATE/created"
: >"$MOCK_GH_LOG"
export MOCK_GH_MODE=secondary-limit
if "$root/scripts/create-forks.sh" --repository bigdecimal \
  2>"$work/secondary-limit.err"; then
  printf 'a secondary-rate-limit response must fail bootstrap\n' >&2
  exit 1
fi
[[ $(grep -Fc "$post" "$MOCK_GH_LOG") == 1 ]] || {
  printf 'a failed fork request must never be re-POSTed\n' >&2
  exit 1
}
grep -F 'Retry-After: 17' "$work/secondary-limit.err" >/dev/null

if "$root/scripts/create-forks.sh" --repository bigdecimal --workers 5; then
  printf 'more than four bootstrap workers must be refused\n' >&2
  exit 1
fi

printf 'fork bootstrap tests passed\n'
