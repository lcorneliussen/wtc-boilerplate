#!/usr/bin/env bash
# branch-off selects the creating collection's pinned native command.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
TEST_TMPDIRS="$TEST_TMPDIRS $root"
mock="$root/mock-bin"
mkdir -p "$mock"
export NEW_TEST_CALLS="$root/new-calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${NEW_TEST_VERSION:-0.1.10}" ;;
  'new --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$NEW_TEST_CALLS" ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/branch-off.sh"

it 'the pinned CLI receives the original collection request'
"$runner" --no-open --issue wid-5 demo widget >/dev/null
assert_eq "$root/main|new --no-open --issue wid-5 demo widget" "$(cat "$NEW_TEST_CALLS")"
assert_no_file "$root/wid-5-demo" 'the mock received creation without the shell duplicating it'

it 'a PR review request is passed through before shell-side forge lookup'
"$runner" --pr widget#41 --no-open >/dev/null
assert_contains "$(cat "$NEW_TEST_CALLS")" "$root/main|new --pr widget#41 --no-open"

it 'an older pin retains the shell creation path'
printf '0.1.9\n' > "$root/main/harness/.wtc-cli-version"
"$runner" --no-open old widget >/dev/null 2>&1
assert_file "$root/old/HANDOFF.md" 'shell bootstrap created the collection'
assert_not_contains "$(cat "$NEW_TEST_CALLS")" 'new --no-open old widget' 'old pin did not dispatch'

it 'a mismatched installed CLI retains the shell creation path'
printf '0.1.10\n' > "$root/main/harness/.wtc-cli-version"
NEW_TEST_VERSION=0.1.9 "$runner" --no-open mismatched widget >/dev/null 2>&1
assert_file "$root/mismatched/HANDOFF.md" 'mismatched CLI did not block bootstrap'
assert_not_contains "$(cat "$NEW_TEST_CALLS")" 'new --no-open mismatched widget' 'mismatch did not dispatch'
