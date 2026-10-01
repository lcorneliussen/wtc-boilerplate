#!/usr/bin/env bash
# retire.sh selects the creating collection's pinned native command.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
TEST_TMPDIRS="$TEST_TMPDIRS $root"
mock="$root/mock-bin"
mkdir -p "$mock"
export RETIRE_TEST_CALLS="$root/retire-calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${RETIRE_TEST_VERSION:-$(cat "$PWD/harness/.wtc-cli-version")}" ;;
  'retire --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$RETIRE_TEST_CALLS" ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/retire.sh"
mkdir -p "$root/finished"
add_fixture_worktree "$root" agent-harness "$root/finished/harness"

it 'matching source pin dispatches with collection and flags intact'
"$runner" --force finished >/dev/null
assert_eq "$root/main|retire --force finished" "$(cat "$RETIRE_TEST_CALLS")"
assert_file "$root/finished/harness/.git" 'mock dispatch did not run shell teardown'

it 'older source pin retains shell retirement'
printf '0.1.11\n' > "$root/main/harness/.wtc-cli-version"
calls_before="$(wc -l < "$RETIRE_TEST_CALLS" | tr -d ' ')"
"$runner" finished >/dev/null 2>&1
assert_no_file "$root/finished/harness" 'shell fallback retired the worktree'
assert_eq "$calls_before" "$(wc -l < "$RETIRE_TEST_CALLS" | tr -d ' ')" 'older pin did not dispatch'

it 'mismatched installed version retains shell retirement'
root_mismatch="$(make_workspace)"
TEST_TMPDIRS="$TEST_TMPDIRS $root_mismatch"
mkdir -p "$root_mismatch/finished"
add_fixture_worktree "$root_mismatch" agent-harness "$root_mismatch/finished/harness"
RETIRE_TEST_VERSION=0.1.11 "$root_mismatch/main/harness/tools/retire.sh" finished >/dev/null 2>&1
assert_no_file "$root_mismatch/finished/harness" 'version mismatch used shell fallback'

# CI remains offline. Release verification sets WTC_TEST_RELEASE_BINARY to the
# checksum-verified archive binary and exercises a real retirement.
if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'the released CLI retires a clean fixture without touching remote refs'
  root_real="$(make_workspace)"
  TEST_TMPDIRS="$TEST_TMPDIRS $root_real"
  mkdir -p "$root_real/finished"
  add_fixture_worktree "$root_real" agent-harness "$root_real/finished/harness"
  printf 'generated\n' > "$root_real/finished/.wtc-prs.lock"
  assert_file "$root_real/finished/.wtc-prs.lock" 'native fixture includes the PR registry lock'
  head_before="$(git --git-dir="$root_real/.bare/agent-harness.git" rev-parse refs/remotes/origin/main)"
  export RETIRE_TEST_NATIVE_MARKER="$root_real/native-retire-ran"
  mkdir -p "$root_real/main/harness/hooks/wtc"
  cat > "$root_real/main/harness/hooks/wtc/retire.pre.sh" <<'HOOK'
#!/bin/sh
printf 'native\n' > "$RETIRE_TEST_NATIVE_MARKER"
HOOK
  chmod +x "$root_real/main/harness/hooks/wtc/retire.pre.sh"
  export RETIRE_TEST_REAL_CLI="$WTC_TEST_RELEASE_BINARY"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
case "$1" in
  exec)
    [ "$2 $3" = '-- wtc' ] || exit 2
    shift 3
    exec "$RETIRE_TEST_REAL_CLI" "$@" ;;
esac
exit 2
REAL_MISE
  chmod +x "$mock/mise"
  retire_out="$("$root_real/main/harness/tools/retire.sh" finished 2>&1)"
  retire_rc=$?
  assert_eq 0 "$retire_rc" "released native retirement succeeded: $retire_out"
  assert_file "$RETIRE_TEST_NATIVE_MARKER" 'matching release used native retirement'
  assert_no_file "$root_real/finished/.wtc-prs.lock" 'native retirement removed the PR registry lock'
  assert_no_file "$root_real/finished" 'native command removed the collection'
  assert_eq "$head_before" "$(git --git-dir="$root_real/.bare/agent-harness.git" rev-parse refs/remotes/origin/main)" 'remote ref remains'
fi
