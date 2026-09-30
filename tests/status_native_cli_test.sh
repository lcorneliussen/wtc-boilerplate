#!/usr/bin/env bash
# Status entry points use only the harness's exact released CLI pin.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$(dirname "$TESTS_DIR")"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
mock="$root/mock-bin"
mkdir -p "$mock"
export STATUS_CLI_CALLS="$root/calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${STATUS_CLI_VERSION:-0.1.16}" ;;
  'status --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$STATUS_CLI_CALLS" ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
status="$root/main/harness/tools/wtc-status.sh"
tui="$root/main/harness/tools/wtc-status-tui.sh"

it 'matching pin dispatches one-shot and TUI from the target collection'
"$status" --json --no-fetch >/dev/null
"$status" --repos --tui 120 --no-click >/dev/null
"$tui" --procs --no-watch >/dev/null
assert_contains "$(cat "$STATUS_CLI_CALLS")" "$root/main|status --json --no-fetch"
assert_contains "$(cat "$STATUS_CLI_CALLS")" "$root/main|status --tui --repos --watch 120 --no-click"
assert_contains "$(cat "$STATUS_CLI_CALLS")" "$root/main|status --tui --procs --no-watch"

it 'older or mismatched pins keep the shell entry point'
: > "$STATUS_CLI_CALLS"
printf '0.1.15\n' > "$root/main/harness/.wtc-cli-version"
"$status" --help > "$root/old.help"
assert_empty "$(cat "$STATUS_CLI_CALLS")" 'older pin did not dispatch'
assert_contains "$(cat "$root/old.help")" 'Usage:'
printf '0.1.16\n' > "$root/main/harness/.wtc-cli-version"
STATUS_CLI_VERSION=0.1.15 "$status" --help > "$root/mismatch.help"
assert_empty "$(cat "$STATUS_CLI_CALLS")" 'mismatched version did not dispatch'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'published binary produces a collection snapshot through the shim'
  export STATUS_TEST_REAL_CLI="$WTC_TEST_RELEASE_BINARY"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
exec "$STATUS_TEST_REAL_CLI" "$@"
REAL_MISE
  chmod +x "$mock/mise"
  "$status" --local --json > "$root/native.json" 2> "$root/native.err"
  native_rc=$?
  assert_eq 0 "$native_rc" "released status succeeded: $(cat "$root/native.err")"
  assert_ok python3 - "$root/native.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['schema']==1 and p['collection']=='main'
assert any(row['dir']=='harness' for row in p['repos'])
PY
fi
