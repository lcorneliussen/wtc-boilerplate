#!/usr/bin/env bash
# Browse dispatches through the selected collection's exact released CLI pin.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$(dirname "$TESTS_DIR")"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
mock="$root/mock-bin"
mkdir -p "$mock" "$root/other"
cp -R "$root/main/harness" "$root/other/harness"
export BROWSE_CLI_CALLS="$root/calls"
export BROWSE_NVIM_CALLS="$root/nvim-calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${BROWSE_CLI_VERSION:-$(cat "$PWD/harness/.wtc-cli-version")}" ;;
  'browse --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$BROWSE_CLI_CALLS" ;;
esac
MOCK
cat > "$mock/nvim" <<'MOCK'
#!/usr/bin/env bash
[ "$1" != --server ] || exit 1
printf '%s|%s\n' "$PWD" "$*" >> "$BROWSE_NVIM_CALLS"
MOCK
chmod +x "$mock/mise" "$mock/nvim"
export PATH="$mock:$PATH"
browse="$root/main/harness/tools/wtc-browse.sh"

it 'matching pin routes browse and its options from the target collection'
"$browse" --here >/dev/null
printf '0.1.16\n' > "$root/main/harness/.wtc-cli-version"
"$browse" --session test --no-focus other >/dev/null
assert_contains "$(cat "$BROWSE_CLI_CALLS")" "$root/main|browse --here"
assert_contains "$(cat "$BROWSE_CLI_CALLS")" "$root/other|browse --session test --no-focus other"

it 'older or mismatched pins retain the shell browser'
: > "$BROWSE_CLI_CALLS"
"$browse" --here >/dev/null
assert_empty "$(cat "$BROWSE_CLI_CALLS")" 'older pin did not dispatch'
assert_contains "$(cat "$BROWSE_NVIM_CALLS")" "$root/main|" 'shell browser opened Neovim'
printf '0.1.17\n' > "$root/main/harness/.wtc-cli-version"
before_mismatch="$(wc -l < "$BROWSE_NVIM_CALLS" | tr -d '[:space:]')"
BROWSE_CLI_VERSION=0.1.16 "$browse" --here >/dev/null
mismatch_rc=$?
assert_eq 0 "$mismatch_rc" 'mismatched binary fell back successfully'
assert_empty "$(cat "$BROWSE_CLI_CALLS")" 'mismatched binary did not dispatch'
after_mismatch="$(wc -l < "$BROWSE_NVIM_CALLS" | tr -d '[:space:]')"
assert_eq "$((before_mismatch + 1))" "$after_mismatch" 'mismatched binary opened shell browser'
rm "$root/main/harness/.wtc-cli-version"
before_bootstrap="$after_mismatch"
"$browse" --here >/dev/null
bootstrap_rc=$?
assert_eq 0 "$bootstrap_rc" 'missing pin fell back successfully'
assert_empty "$(cat "$BROWSE_CLI_CALLS")" 'missing pin did not dispatch'
after_bootstrap="$(wc -l < "$BROWSE_NVIM_CALLS" | tr -d '[:space:]')"
assert_eq "$((before_bootstrap + 1))" "$after_bootstrap" 'missing pin opened shell browser'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'published CLI opens the bundled browse view through the shell entry point'
  cp "$HARNESS_SRC/.wtc-cli-version" "$root/main/harness/.wtc-cli-version"
  export BROWSE_TEST_RELEASE_BINARY="$WTC_TEST_RELEASE_BINARY"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
exec "$BROWSE_TEST_RELEASE_BINARY" "$@"
REAL_MISE
  chmod +x "$mock/mise"
  : > "$BROWSE_NVIM_CALLS"
  "$browse" --here > "$root/native.out" 2> "$root/native.err"
  native_rc=$?
  assert_eq 0 "$native_rc" "released browse succeeded: $(cat "$root/native.err")"
  assert_contains "$(cat "$BROWSE_NVIM_CALLS")" '--listen' 'released CLI started its listen socket'
  assert_contains "$(cat "$BROWSE_NVIM_CALLS")" 'dofile(' 'released CLI loaded its bundled view'
fi
