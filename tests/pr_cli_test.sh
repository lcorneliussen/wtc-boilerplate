#!/usr/bin/env bash
# wtc-pr.sh dispatches to the target collection's matching native PR command.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
TEST_TMPDIRS="$TEST_TMPDIRS $root"
mock="$root/mock-bin"
mkdir -p "$mock"
export PR_TEST_CALLS="$root/pr-calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${PR_TEST_VERSION:-$(cat "$PWD/harness/.wtc-cli-version")}" ;;
  'pr --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$PR_TEST_CALLS" ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/wtc-pr.sh"

it 'matching pin dispatches all four local PR operations'
"$runner" path >/dev/null
"$runner" list >/dev/null
"$runner" enlist widget 17 --branch review --title 'Fixture PR' >/dev/null
"$runner" unlist widget 17 >/dev/null
calls="$(cat "$PR_TEST_CALLS")"
assert_contains "$calls" "$root/main|pr path" 'path dispatched'
assert_contains "$calls" "$root/main|pr list" 'list dispatched'
assert_contains "$calls" "$root/main|pr enlist widget 17 --branch review --title Fixture PR" 'enlist flags dispatched'
assert_contains "$calls" "$root/main|pr unlist widget 17" 'unlist dispatched'
assert_no_file "$root/main/.wtc-prs" 'mock dispatch avoided shell write'

it 'explicit target selects its own pin and CLI cwd'
mkdir -p "$root/other"
add_fixture_worktree "$root" agent-harness "$root/other/harness"
"$runner" path other >/dev/null
assert_contains "$(cat "$PR_TEST_CALLS")" "$root/other|pr path" 'target cwd dispatched'
printf '0.1.2\n' > "$root/other/harness/.wtc-cli-version"
calls_before="$(wc -l < "$PR_TEST_CALLS" | tr -d ' ')"
out="$("$runner" path other)"
assert_eq "$root/other/.wtc-prs" "$out" 'older target used shell path'
assert_eq "$calls_before" "$(wc -l < "$PR_TEST_CALLS" | tr -d ' ')" 'older target did not dispatch'

it 'mismatched installed binary keeps shell bootstrap'
PR_TEST_VERSION=0.1.11 "$runner" enlist widget 18 --branch mismatch >/dev/null
assert_contains "$(cat "$root/main/.wtc-prs")" 'widget 18 mismatch' 'shell recorded PR'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'the released CLI updates enlistment through the shim'
  root_real="$(make_workspace)"
  TEST_TMPDIRS="$TEST_TMPDIRS $root_real"
  export PR_TEST_REAL_CLI="$WTC_TEST_RELEASE_BINARY"
  export PR_TEST_NATIVE_MARKER="$root_real/native-pr-ran"
  mkdir -p "$root_real/main/harness/hooks/wtc"
  cat > "$root_real/main/harness/hooks/wtc/pr.enlist.pre.sh" <<'HOOK'
#!/bin/sh
printf 'native\n' > "$PR_TEST_NATIVE_MARKER"
HOOK
  chmod +x "$root_real/main/harness/hooks/wtc/pr.enlist.pre.sh"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
exec "$PR_TEST_REAL_CLI" "$@"
REAL_MISE
  chmod +x "$mock/mise"
  pr_out="$("$root_real/main/harness/tools/wtc-pr.sh" enlist widget 19 --branch release --title 'Released fixture' 2>&1)"
  pr_rc=$?
  assert_eq 0 "$pr_rc" "released command succeeded: $pr_out"
  assert_file "$PR_TEST_NATIVE_MARKER" 'native PR hook ran'
  assert_contains "$(cat "$root_real/main/.wtc-prs")" 'widget 19 release' 'PR enlisted'
  "$root_real/main/harness/tools/wtc-pr.sh" unlist widget 19 >/dev/null 2>&1
  assert_not_contains "$(cat "$root_real/main/.wtc-prs")" 'widget 19 release' 'PR unlisted'
fi
