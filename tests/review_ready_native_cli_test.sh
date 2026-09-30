#!/usr/bin/env bash
# The ready shim keeps the caller repository and the local-review gate.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$(dirname "$TESTS_DIR")"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
add_fixture_worktree "$root" widget "$root/main/widget"
mock="$root/mock-bin"
mkdir -p "$mock"
export REVIEW_READY_CLI_CALLS="$root/calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${REVIEW_READY_CLI_VERSION:-$(cat "$PWD/harness/.wtc-cli-version")}" ;;
  'review ready --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$REVIEW_READY_CLI_CALLS"; printf 'ok\n' ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/bb-pr-ready.sh"

it 'matching pin sends the caller repository to the native gate'
(cd "$root/main/widget" && "$runner" 7 --user-authorized 'Synthetic authorization' >/dev/null)
assert_contains "$(cat "$REVIEW_READY_CLI_CALLS")" \
  "$root/main|review ready 7 --user-authorized Synthetic authorization --repo widget" \
  'native ready uses widget rather than harness'

it 'older and mismatched pins retain the shell gate'
: > "$REVIEW_READY_CLI_CALLS"
cat > "$mock/wtc" <<'OLD_WTC'
#!/usr/bin/env bash
if [ "$1" = --version ]; then printf 'wtc version 0.1.23\n'; else exit 2; fi
OLD_WTC
cat > "$mock/gh" <<'FALLBACK_GH'
#!/usr/bin/env bash
case "$*" in
  'pr ready 7 --repo example/widget') exit 0 ;;
  *) exit 2 ;;
esac
FALLBACK_GH
chmod +x "$mock/wtc" "$mock/gh"
printf '0.1.23\n' > "$root/main/harness/.wtc-cli-version"
assert_contains "$(cd "$root/main/widget" && "$runner" 7 --user-authorized 'Synthetic authorization' 2>&1)" \
  'gate overridden' 'older pin uses shell gate'
printf '0.1.24\n' > "$root/main/harness/.wtc-cli-version"
assert_contains "$(cd "$root/main/widget" && REVIEW_READY_CLI_VERSION=0.1.23 "$runner" 7 --user-authorized 'Synthetic authorization' 2>&1)" \
  'gate overridden' 'mismatched pin uses shell gate'
assert_empty "$(cat "$REVIEW_READY_CLI_CALLS")" 'fallback did not dispatch'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'the published binary refuses an untrusted review and accepts an explicit override'
  assert_eq 'wtc version 0.1.24' "$("$WTC_TEST_RELEASE_BINARY" --version)"
  export REVIEW_TEST_RELEASE_BINARY="$WTC_TEST_RELEASE_BINARY"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
exec "$REVIEW_TEST_RELEASE_BINARY" "$@"
REAL_MISE
  chmod +x "$mock/mise"
  export REVIEW_READY_GH_CALLS="$root/gh-calls"
  cat > "$mock/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REVIEW_READY_GH_CALLS"
case "$*" in
  *'--json headRefOid'*) printf '{"headRefOid":"1234567890abcdef1234567890abcdef12345678"}\n' ;;
  *'--json comments'*) printf '{"comments":[{"body":"wtc-review v1 head=1234567890abcdef1234567890abcdef12345678 verdict=pass blockers=0 round=1","createdAt":"2026-01-01T00:00:00Z","url":"https://github.com/example/widget/pull/7#issuecomment-11"}]}\n' ;;
  'pr ready 7 --repo example/widget') exit 0 ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 2 ;;
esac
GH
  chmod +x "$mock/gh"
  (cd "$root/main/widget" && "$runner" 7) > "$root/refused.out" 2> "$root/refused.err"
  assert_neq 0 "$?" 'untrusted review closes gate'
  assert_empty "$(rg '^pr ready ' "$REVIEW_READY_GH_CALLS" || true)" 'no forge promotion on closed gate'
  (cd "$root/main/widget" && "$runner" 7 --user-authorized 'Synthetic authorization') > "$root/ready.out" 2> "$root/ready.err"
  assert_eq 0 "$?" "authorized override: $(cat "$root/ready.err")"
  assert_contains "$(cat "$REVIEW_READY_GH_CALLS")" 'pr ready 7 --repo example/widget' \
    'authorized override reached the forge'
fi
