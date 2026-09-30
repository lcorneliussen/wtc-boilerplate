#!/usr/bin/env bash
# The review bundle shim uses the collection's exact released CLI pin.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$(dirname "$TESTS_DIR")"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
add_fixture_worktree "$root" widget "$root/main/widget"
mock="$root/mock-bin"
mkdir -p "$mock"
export REVIEW_CLI_CALLS="$root/calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${REVIEW_CLI_VERSION:-$(cat "$PWD/harness/.wtc-cli-version")}" ;;
  'review bundle --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$REVIEW_CLI_CALLS" ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/review-bundle.sh"

it 'matching pin sends review bundle options to the native command'
(cd "$root" && "$runner" widget --public --no-catch-up --dir output >/dev/null)
assert_contains "$(cat "$REVIEW_CLI_CALLS")" \
  "$root/main|review bundle widget --public --no-catch-up --dir $root/output" \
  'caller-relative bundle directory remained absolute'
(cd "$root" && "$runner" widget --dir=equals-output >/dev/null)
assert_contains "$(cat "$REVIEW_CLI_CALLS")" \
  "$root/main|review bundle widget --dir=$root/equals-output" \
  'equals-form bundle directory remained caller-relative'

it 'an older or mismatched pin retains the shell bundle'
: > "$REVIEW_CLI_CALLS"
printf '0.1.21\n' > "$root/main/harness/.wtc-cli-version"
old="$root/old-bundle"
"$runner" widget --public --no-catch-up --base origin/main --dir "$old" >/dev/null 2> "$root/old.err"
assert_eq 0 "$?" "older pin shell bundle: $(cat "$root/old.err")"
assert_empty "$(cat "$REVIEW_CLI_CALLS")" 'older pin did not dispatch'
assert_file "$old/manifest.env"
printf '0.1.22\n' > "$root/main/harness/.wtc-cli-version"
mismatch="$root/mismatch-bundle"
REVIEW_CLI_VERSION=0.1.21 "$runner" widget --public --no-catch-up --base origin/main --dir "$mismatch" >/dev/null 2> "$root/mismatch.err"
assert_eq 0 "$?" "mismatched CLI shell bundle: $(cat "$root/mismatch.err")"
assert_empty "$(cat "$REVIEW_CLI_CALLS")" 'mismatched CLI did not dispatch'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'the published binary builds a public bundle through the shim'
  assert_eq 'wtc version 0.1.22' "$("$WTC_TEST_RELEASE_BINARY" --version)"
  export REVIEW_TEST_RELEASE_BINARY="$WTC_TEST_RELEASE_BINARY"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
exec "$REVIEW_TEST_RELEASE_BINARY" "$@"
REAL_MISE
  chmod +x "$mock/mise"
  native="$root/native-bundle"
  "$runner" widget --public --no-catch-up --base origin/main --dir "$native" > "$root/native.out" 2> "$root/native.err"
  assert_eq 0 "$?" "published CLI bundle: $(cat "$root/native.err")"
  assert_eq "$native" "$(cat "$root/native.out")" 'native bundle directory printed'
  assert_contains "$(cat "$native/manifest.json")" '"public": true' 'public manifest retained'
  assert_file "$native/diff.patch"
  assert_status 1 test -e "$native/downstream"
fi
