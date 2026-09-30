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
case "$*" in
  --version) printf 'wtc version %s\n' "${OPEN_CLI_VERSION:-$(cat "$PWD/harness/.wtc-cli-version")}" ;;
  'open --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$OPEN_CLI_CALLS" ;;
esac
MOCK
cat > "$mock/herdr" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' '{"result":{"workspaces":[]}}'
MOCK
chmod +x "$mock/mise" "$mock/herdr"
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
"$runner" --list other >/dev/null
assert_empty "$(cat "$OPEN_CLI_CALLS")" 'older target did not dispatch'
"$runner" --all --list >/dev/null
assert_empty "$(cat "$OPEN_CLI_CALLS")" 'mixed sweep did not dispatch'
printf '0.1.21\n' > "$root/other/harness/.wtc-cli-version"
OPEN_CLI_VERSION=0.1.20 "$runner" --list other >/dev/null
assert_empty "$(cat "$OPEN_CLI_CALLS")" 'mismatched installed version did not dispatch'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'the published binary lists through the matching shell entry point'
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
  assert_contains "$output" 'no workspace' 'released CLI read the herdr workspace list'
fi
