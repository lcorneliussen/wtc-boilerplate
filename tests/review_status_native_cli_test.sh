#!/usr/bin/env bash
# The review status shim keeps its plain and JSON contracts with the pinned CLI.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$(dirname "$TESTS_DIR")"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
add_fixture_worktree "$root" widget "$root/main/widget"
mock="$root/mock-bin"
mkdir -p "$mock"
export REVIEW_STATUS_CLI_CALLS="$root/calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${REVIEW_STATUS_CLI_VERSION:-$(cat "$PWD/harness/.wtc-cli-version")}" ;;
  'review status --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$REVIEW_STATUS_CLI_CALLS"; printf 'none\n' ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/review-status.sh"

it 'matching pin routes plain review status through the native command'
assert_eq none "$("$runner" widget 7 --trusted-local)" 'native status output'
assert_contains "$(cat "$REVIEW_STATUS_CLI_CALLS")" \
  "$root/main|review status widget 7 --trusted-local" 'status options forwarded'

it 'older and mismatched pins retain the shell status reader'
: > "$REVIEW_STATUS_CLI_CALLS"
printf '0.1.23\n' > "$root/main/harness/.wtc-cli-version"
"$runner" --help >/dev/null 2>&1
assert_eq 0 "$?" 'older pin shell help'
assert_empty "$(cat "$REVIEW_STATUS_CLI_CALLS")" 'older pin did not dispatch'
printf '0.1.24\n' > "$root/main/harness/.wtc-cli-version"
REVIEW_STATUS_CLI_VERSION=0.1.23 "$runner" --help >/dev/null 2>&1
assert_eq 0 "$?" 'mismatched pin shell help'
assert_empty "$(cat "$REVIEW_STATUS_CLI_CALLS")" 'mismatched CLI did not dispatch'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'the published binary reads review status through the shim'
  assert_eq 'wtc version 0.1.24' "$("$WTC_TEST_RELEASE_BINARY" --version)"
  export REVIEW_TEST_RELEASE_BINARY="$WTC_TEST_RELEASE_BINARY"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
exec "$REVIEW_TEST_RELEASE_BINARY" "$@"
REAL_MISE
  chmod +x "$mock/mise"
  cat > "$mock/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *'--json headRefOid'*) printf '{"headRefOid":"1234567890abcdef1234567890abcdef12345678"}\n' ;;
  *'--json comments'*) printf '{"comments":[{"body":"wtc-review v1 head=1234567890abcdef1234567890abcdef12345678 verdict=pass blockers=0 round=1","createdAt":"2026-01-01T00:00:00Z","url":"https://github.com/example/widget/pull/7#issuecomment-11"}]}\n' ;;
  *) exit 2 ;;
esac
GH
  chmod +x "$mock/gh"
  assert_eq 'current pass 0 1' "$("$runner" widget 7)" 'plain status matches shell contract'
  json="$("$runner" widget 7 --json)"
  assert_status 0 python3 -c 'import json,sys; d=json.loads(sys.argv[1]); head="1234567890abcdef1234567890abcdef12345678"; assert d == {"state":"current","pr":7,"verdict":"pass","blockers":0,"round":1,"review_head":head,"pr_head":head,"comment_url":"https://github.com/example/widget/pull/7#issuecomment-11","comment_id":"11"}, d' "$json"
  assert_contains "$("$runner" widget 7 --trusted-local)" 'untrusted pass 0 1' \
    'trusted-local gate requires a local receipt'
fi
