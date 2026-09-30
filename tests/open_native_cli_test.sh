#!/usr/bin/env bash
# The selected collections' exact CLI pins govern native workspace opening.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
mock="$root/mock-bin"
mkdir -p "$mock" "$root/other"
cp -R "$root/main/harness" "$root/other/harness"
printf '0.1.21\n' > "$root/main/harness/.wtc-cli-version"
printf '0.1.21\n' > "$root/other/harness/.wtc-cli-version"
export OPEN_CLI_CALLS="$root/calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
[ -z "${OPEN_CLI_MISE_UNAVAILABLE:-}" ] || exit 127
case "$*" in
  --version) printf 'wtc version %s\n' "${OPEN_CLI_VERSION:-$(cat "$PWD/harness/.wtc-cli-version")}" ;;
  'open --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$OPEN_CLI_CALLS" ;;
esac
MOCK
cat > "$mock/wtc" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  --version) [ -n "${OPEN_CLI_STANDALONE_VERSION:-}" ] || exit 127
             printf 'wtc version %s\n' "$OPEN_CLI_STANDALONE_VERSION" ;;
  'open --help') [ -n "${OPEN_CLI_STANDALONE_VERSION:-}" ] ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$OPEN_CLI_CALLS" ;;
esac
MOCK
cat > "$mock/herdr" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' '{"result":{"workspaces":[]}}'
MOCK
chmod +x "$mock/mise" "$mock/wtc" "$mock/herdr"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/wtc-open.sh"

it 'matching target pin dispatches with all options intact'
"$runner" --list --session example other >/dev/null
assert_contains "$(cat "$OPEN_CLI_CALLS")" "$root/other|open --list --session example other"

it 'matching pins dispatch a collection sweep from the selected collection'
: > "$OPEN_CLI_CALLS"
"$runner" --all --list >/dev/null
assert_contains "$(cat "$OPEN_CLI_CALLS")" "$root/main|open --all --list"

it 'older, mixed, and mismatched pins retain the shell opener'
: > "$OPEN_CLI_CALLS"
printf '0.1.20\n' > "$root/other/harness/.wtc-cli-version"
older_out="$("$runner" --list other 2>&1)"; older_rc=$?
assert_eq 0 "$older_rc" 'older target uses a working shell list'
assert_contains "$older_out" 'no workspace' 'older target reported the shell workspace list'
assert_empty "$(cat "$OPEN_CLI_CALLS")" 'older target did not dispatch'
mixed_out="$("$runner" --all --list 2>&1)"; mixed_rc=$?
assert_eq 0 "$mixed_rc" 'mixed sweep uses a working shell list'
assert_contains "$mixed_out" 'no workspace' 'mixed sweep reported the shell workspace list'
assert_empty "$(cat "$OPEN_CLI_CALLS")" 'mixed sweep did not dispatch'
printf '0.1.21\n' > "$root/other/harness/.wtc-cli-version"
mismatch_out="$(OPEN_CLI_VERSION=0.1.20 "$runner" --list other 2>&1)"; mismatch_rc=$?
assert_eq 0 "$mismatch_rc" 'mismatched CLI uses a working shell list'
assert_contains "$mismatch_out" 'no workspace' 'mismatched CLI reported the shell workspace list'
assert_empty "$(cat "$OPEN_CLI_CALLS")" 'mismatched installed version did not dispatch'

it 'matching standalone CLI wins when mise resolves an older version'
OPEN_CLI_VERSION=0.1.20 OPEN_CLI_STANDALONE_VERSION=0.1.21 "$runner" --list other >/dev/null
assert_contains "$(cat "$OPEN_CLI_CALLS")" "$root/other|open --list other"
: > "$OPEN_CLI_CALLS"

it 'missing pins and unavailable binaries keep a working shell listing'
rm "$root/main/harness/.wtc-cli-version"
missing_out="$("$runner" --list 2>&1)"; missing_rc=$?
assert_eq 0 "$missing_rc" 'missing pin uses a working shell list'
assert_contains "$missing_out" 'no workspace' 'missing pin reported the shell workspace list'
assert_empty "$(cat "$OPEN_CLI_CALLS")" 'missing pin did not dispatch'
printf '0.1.21\n' > "$root/main/harness/.wtc-cli-version"
unavailable_out="$(OPEN_CLI_MISE_UNAVAILABLE=1 "$runner" --list 2>&1)"; unavailable_rc=$?
assert_eq 0 "$unavailable_rc" 'unavailable binary uses a working shell list'
assert_contains "$unavailable_out" 'no workspace' 'unavailable binary reported the shell workspace list'
assert_empty "$(cat "$OPEN_CLI_CALLS")" 'unavailable binary did not dispatch'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'the published binary lists through the matching shell entry point'
  release_version="$("$WTC_TEST_RELEASE_BINARY" --version)"
  assert_eq 'wtc version 0.1.21' "$release_version" 'published binary matches the fixture pin'
  export OPEN_TEST_RELEASE_BINARY="$WTC_TEST_RELEASE_BINARY"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
exec "$OPEN_TEST_RELEASE_BINARY" "$@"
REAL_MISE
  chmod +x "$mock/mise"
  output="$("$runner" --list 2>&1)"
  rc=$?
  assert_eq 0 "$rc" "released native open list succeeded: $output"
  assert_contains "$output" '==> main:' 'released CLI handled the workspace list'
fi
