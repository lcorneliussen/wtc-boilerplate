#!/usr/bin/env bash
# add-repo selects the target collection's pinned native command.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
TEST_TMPDIRS="$TEST_TMPDIRS $root"
mock="$root/mock-bin"
mkdir -p "$mock"
export ADD_TEST_CALLS="$root/add-calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${ADD_TEST_VERSION:-0.1.12}" ;;
  'add-repo --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$ADD_TEST_CALLS" ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/add-repo.sh"

it 'the matching target pin dispatches before shell checkout'
"$runner" --collection main widget >/dev/null
assert_eq "$root/main|add-repo --collection main widget" "$(cat "$ADD_TEST_CALLS")"
assert_no_file "$root/main/widget" 'the mock received the request without shell checkout'

it 'the current collection is selected when no target is named'
"$runner" widget >/dev/null
assert_contains "$(cat "$ADD_TEST_CALLS")" "$root/main|add-repo widget"

it 'an explicit target uses that collection as the CLI cwd'
mkdir -p "$root/other"
add_fixture_worktree "$root" agent-harness "$root/other/harness"
"$runner" --collection other widget >/dev/null
assert_contains "$(cat "$ADD_TEST_CALLS")" "$root/other|add-repo --collection other widget"
assert_no_file "$root/other/widget" 'the target was passed to the mock'

it 'an older target pin keeps shell bootstrap even when the source is current'
printf '0.1.10\n' > "$root/other/harness/.wtc-cli-version"
calls_before="$(wc -l < "$ADD_TEST_CALLS" | tr -d ' ')"
"$runner" --collection other widget >/dev/null 2>&1
assert_file "$root/other/widget/.git" 'older target was added by shell'
assert_eq "$calls_before" "$(wc -l < "$ADD_TEST_CALLS" | tr -d ' ')" 'source pin did not override target pin'

it 'an older target pin retains shell bootstrap'
printf '0.1.10\n' > "$root/main/harness/.wtc-cli-version"
calls_before="$(wc -l < "$ADD_TEST_CALLS" | tr -d ' ')"
"$runner" --collection main widget >/dev/null 2>&1
assert_file "$root/main/widget/.git" 'shell checkout created the worktree'
assert_eq "$calls_before" "$(wc -l < "$ADD_TEST_CALLS" | tr -d ' ')" 'old pin did not dispatch'

it 'a mismatched installed version retains shell bootstrap'
root_mismatch="$(make_workspace)"
TEST_TMPDIRS="$TEST_TMPDIRS $root_mismatch"
ADD_TEST_VERSION=0.1.10 "$root_mismatch/main/harness/tools/add-repo.sh" --collection main widget >/dev/null 2>&1
assert_file "$root_mismatch/main/widget/.git" 'mismatch did not block checkout'
assert_not_contains "$(cat "$ADD_TEST_CALLS")" "$root_mismatch/main|add-repo --collection main widget" 'mismatch did not dispatch'

# CI remains offline. Release verification sets WTC_TEST_RELEASE_BINARY to the
# checksum-verified archive binary and exercises a real add with init inputs.
if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'the released CLI adds a detached repo with env and secrets ready for init'
  root_real="$(make_workspace)"
  TEST_TMPDIRS="$TEST_TMPDIRS $root_real"
  source_repo="$(git --git-dir="$root_real/.bare/widget.git" remote get-url origin)"
  mkdir -p "$source_repo/.harness" "$root_real/control/widget"
  printf 'secrets.txt\n' > "$source_repo/.gitignore"
  printf 'fixture secret\n' > "$root_real/control/widget/secrets.txt"
  cat > "$source_repo/.harness/init.sh" <<'INIT'
#!/bin/sh
printf '%s|%s|%s' "$WTC_COLLECTION" "$WIDGET_PORT" "$WTC_CONFIG_ROOT" > init-ran
[ -L secrets.txt ] && printf '|secret-present' >> init-ran
INIT
  chmod +x "$source_repo/.harness/init.sh"
  git -C "$source_repo" add -A
  git -C "$source_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm 'prepare init fixture'
  git --git-dir="$root_real/.bare/widget.git" fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
  export ADD_TEST_REAL_CLI="$WTC_TEST_RELEASE_BINARY"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
case "$1" in
  trust|tasks|bin-paths) exit 0 ;;
  exec)
    [ "$2 $3" = '-- wtc' ] || exit 2
    shift 3
    exec "$ADD_TEST_REAL_CLI" "$@" ;;
esac
exit 2
REAL_MISE
  chmod +x "$mock/mise"
  WTC_HARNESS_REPO=agent-harness WTC_CONFIG_ROOT="$root_real/control" \
    "$root_real/main/harness/tools/add-repo.sh" --collection main widget >/dev/null 2>&1
  worktree="$root_real/main/widget"
  assert_eq HEAD "$(git -C "$worktree" rev-parse --abbrev-ref HEAD)" 'worktree is detached'
  assert_contains "$(cat "$worktree/init-ran")" "main|42001|$root_real/control|secret-present" 'init saw env and secret'
  assert_contains "$(cat "$root_real/main/.env.collection")" 'WIDGET_PORT=42001' 'env was generated'
fi
