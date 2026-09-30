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
  --version) printf 'wtc version %s\n' "${STATUS_CLI_VERSION:-$(cat "$PWD/harness/.wtc-cli-version")}" ;;
  'status --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$STATUS_CLI_CALLS"
     if [ "${STATUS_CLI_READ_KEY:-}" = yes ]; then
       IFS= read -r key || exit 3
       printf 'key=%s\n' "$key" >> "$STATUS_CLI_CALLS"
     fi
     [ "${STATUS_CLI_HOLD:-}" != yes ] || sleep 5 ;;
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
assert_contains "$(cat "$STATUS_CLI_CALLS")" "$root/main|status --tui --watch 120 --no-click"
assert_contains "$(cat "$STATUS_CLI_CALLS")" "$root/main|status --tui --procs --no-watch"

it 'last repository or process selector wins without hiding enlisted PRs'
"$status" --repos --procs --json >/dev/null
"$status" --procs --repos --json >/dev/null
"$tui" --procs --repos --no-watch >/dev/null
assert_contains "$(cat "$STATUS_CLI_CALLS")" "$root/main|status --procs --json"
assert_contains "$(cat "$STATUS_CLI_CALLS")" "$root/main|status --json"
assert_contains "$(cat "$STATUS_CLI_CALLS")" "$root/main|status --tui --no-watch"
assert_not_contains "$(cat "$STATUS_CLI_CALLS")" '--repos' 'native view keeps the PR section'

it 'the native TUI child receives keyboard input'
printf 'q\n' | STATUS_CLI_READ_KEY=yes "$tui" --no-fetch >/dev/null
assert_contains "$(cat "$STATUS_CLI_CALLS")" 'key=q' 'stdin reached native TUI'

it 'native TUI keeps the status script identifiable for pane lifecycle tools'
STATUS_CLI_HOLD=yes "$tui" --no-fetch >/dev/null 2>&1 &
pane_pid=$!
sleep 1
pane_command="$(ps -p "$pane_pid" -o command= 2>/dev/null)"
assert_contains "$pane_command" 'wtc-status-tui.sh' 'foreground script identity survived native dispatch'
kill "$pane_pid" 2>/dev/null || true
wait "$pane_pid" 2>/dev/null || true

it 'watch through the one-shot entry point keeps the status script identifiable'
STATUS_CLI_HOLD=yes "$status" --watch 30 --no-fetch >/dev/null 2>&1 &
pane_pid=$!
sleep 1
pane_command="$(ps -p "$pane_pid" -o command= 2>/dev/null)"
assert_contains "$pane_command" 'wtc-status.sh' 'watch pane retained script identity'
kill "$pane_pid" 2>/dev/null || true
wait "$pane_pid" 2>/dev/null || true

it 'older or mismatched pins keep the shell entry point'
: > "$STATUS_CLI_CALLS"
printf '0.1.15\n' > "$root/main/harness/.wtc-cli-version"
"$status" --help > "$root/old.help"
assert_empty "$(cat "$STATUS_CLI_CALLS")" 'older pin did not dispatch'
assert_contains "$(cat "$root/old.help")" 'Usage:'
cat "$HARNESS_SRC/.wtc-cli-version" > "$root/main/harness/.wtc-cli-version"
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
  cat > "$root/main/.wtc-status.json" <<'JSON'
{"schema":1,"collection":"main","generated_at":"2026-09-30T00:00:00Z","repos":[],"prs":[{"repo":"widget","number":"7","title":"Synthetic PR","display_title":"Synthetic PR"}],"orphans":[]}
JSON
  WTC_STATUS_REPOS=yes "$tui" --cached > "$root/cached-tui.txt"
  assert_contains "$(cat "$root/cached-tui.txt")" 'Synthetic PR' \
    'released TUI shim kept the enlisted PR section despite repos default'
  WTC_STATUS_REPOS=yes "$status" --cached > "$root/cached-status.txt"
  assert_contains "$(cat "$root/cached-status.txt")" 'Synthetic PR' \
    'released one-shot shim kept the enlisted PR section despite repos default'
fi
