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
  it 'published status keeps JSON output clean'
  "$status" --local --silent --json > "$root/silent-native.json" 2> "$root/silent-native.err"
  assert_empty "$(cat "$root/silent-native.err")" 'released status wrote diagnostics in silent JSON mode'
  assert_contains "$("$WTC_TEST_RELEASE_BINARY" status --help)" '--silent' 'released status lacks --silent'
  assert_ok python3 - "$root/silent-native.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['schema'] == 1
PY
  it 'published status logs interactive progress unless silent'
  assert_ok python3 - "$status" <<'PY'
import errno, os, pty, select, subprocess, sys, time

def run(*flags):
    master, slave = pty.openpty()
    proc = subprocess.Popen([sys.argv[1], '--local', *flags],
                            stdin=subprocess.DEVNULL, stdout=slave, stderr=slave)
    os.close(slave)
    chunks = []
    deadline = time.monotonic() + 30
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([master], [], [], remaining)[0]:
                proc.kill()
                proc.wait()
                raise AssertionError('released status timed out')
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        os.close(master)
    assert proc.wait(timeout=5) == 0
    return b''.join(chunks)

normal = run()
silent = run('--silent')
assert b'Reading worktrees' in normal, normal.decode(errors='replace')
assert b'Reading worktrees' not in silent, silent.decode(errors='replace')
PY
  it 'published table keeps build columns without build facts'
  cat > "$root/main/.wtc-status.json" <<'JSON'
{"schema":1,"collection":"main","generated_at":"2026-09-30T00:00:00Z","repos":[{"dir":"widget","repo":"widget","branch_display":"main","tree":"clean"}],"prs":[],"orphans":[]}
JSON
  "$status" --cached --ansi > "$root/no-build-table.txt"
  assert_contains "$(cat "$root/no-build-table.txt")" 'TEST' 'released table kept a test column without build facts'
  assert_contains "$(cat "$root/no-build-table.txt")" 'PROD' 'released table kept a production column without build facts'
  cat > "$root/main/.wtc-status.json" <<'JSON'
{"schema":1,"collection":"main","generated_at":"2026-09-30T00:00:00Z","repos":[{"dir":"widget","repo":"widget","slug":"example/widget","forge":"github.com","branch":"main","branch_display":"main","tree":"clean","ahead":2,"behind":3,"tip":{"checks":"SUCCESS","build":"42","url":"https://github.com/example/widget/actions/runs/42"},"prod":{"checks":"SUCCESS","build":"41","url":"https://github.com/example/widget/actions/runs/41"}}],"prs":[{"repo":"widget","number":"7","state":"UNKNOWN","title":"Synthetic PR","display_title":"Synthetic PR","url":"https://github.com/example/widget/pull/7"}],"orphans":[]}
JSON
  WTC_STATUS_REPOS=yes "$tui" --cached > "$root/cached-tui.txt"
  assert_contains "$(cat "$root/cached-tui.txt")" 'Synthetic PR' \
    'released TUI shim kept the enlisted PR section despite repos default'
  WTC_STATUS_REPOS=yes "$status" --cached > "$root/cached-status.txt"
  assert_contains "$(cat "$root/cached-status.txt")" 'Synthetic PR' \
    'released one-shot shim kept the enlisted PR section despite repos default'
  assert_ok python3 - "$status" "$root/cached-table.txt" <<'PY'
import errno, fcntl, os, pty, select, struct, subprocess, sys, termios, time

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
proc = subprocess.Popen([sys.argv[1], '--cached'], stdin=subprocess.DEVNULL,
                        stdout=slave, stderr=slave, env={**os.environ, 'TERM': 'xterm-256color'})
os.close(slave)
chunks = []
deadline = time.monotonic() + 5
try:
    while time.monotonic() < deadline:
        if not select.select([master], [], [], 0.1)[0]:
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not chunk:
            break
        chunks.append(chunk)
    else:
        raise AssertionError('released cached status timed out')
    assert proc.wait(timeout=1) == 0
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    os.close(master)
open(sys.argv[2], 'wb').write(b''.join(chunks))
PY
  assert_contains "$(cat "$root/cached-table.txt")" 'unknown' 'released table did not claim an unavailable PR was open'
  it 'published TUI shows linked cached facts and a refresh log'
  assert_ok python3 - "$tui" <<'PY'
import errno, fcntl, os, pty, re, select, struct, subprocess, sys, termios, time

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
proc = subprocess.Popen([sys.argv[1], '--no-fetch'], stdin=slave,
                        stdout=slave, stderr=slave,
                        env={**os.environ, 'TERM': 'xterm-256color', 'NO_COLOR': ''})
os.close(slave)
chunks = []
started = time.monotonic()
sent_log = sent_quit = False
log_start = 0
try:
    while time.monotonic() - started < 15:
        elapsed = time.monotonic() - started
        if not sent_log and elapsed > 0.6:
            log_start = sum(map(len, chunks))
            os.write(master, b'l')
            sent_log = True
        log_output = b''.join(chunks)[log_start:]
        # The terminal redraw may retain the initial R from the prior header.
        log_heading = log_output.find(b'fresh log') if sent_log else -1
        if log_heading >= 0 and not sent_quit and \
                b'Reading worktrees 1/1' in log_output[log_heading:] and \
                b'Writing status snapshot' in log_output[log_heading:]:
            os.write(master, b'q')
            sent_quit = True
        if select.select([master], [], [], 0.1)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            chunks.append(chunk)
        if sent_quit and proc.poll() is not None:
            break
    assert proc.wait(timeout=3) == 0
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    os.close(master)
output = b''.join(chunks)
log_output = output[log_start:]
log_heading = log_output.find(b'fresh log')
assert log_heading >= 0, 'refresh log view did not open'
log_output = log_output[log_heading:]
for url in (b'https://github.com/example/widget',
            b'https://github.com/example/widget/tree/main',
            b'https://github.com/example/widget/actions/runs/42',
            b'https://github.com/example/widget/actions/runs/41',
            b'https://github.com/example/widget/pull/7'):
    assert b'\x1b]8;;' + url + b'\x07' in output, f'missing terminal link: {url!r}'
assert b'Reading worktrees 1/1' in log_output, 'refresh log did not show the completed worktree count'
assert b'Writing status snapshot' in log_output, 'refresh log did not report snapshot publication'
for url, tone, bold in ((b'https://github.com/example/widget', b'38;5;252', True),
                        (b'https://github.com/example/widget/tree/main', b'38;5;252', False),
                        (b'https://github.com/example/widget/pull/7', b'38;5;81', False),
                        (b'https://github.com/example/widget/actions/runs/42', b'38;5;114', False),
                        (b'https://github.com/example/widget/actions/runs/41', b'38;5;114', False)):
    marker = b'\x1b]8;;' + url + b'\x07'
    at = output.find(marker)
    style = re.search(rb'\x1b\[([0-9;]+)m$', output[max(0, at-40):at])
    assert at >= 0 and style and tone in style.group(1) and (b'1' in style.group(1).split(b';')) == bold, \
        f'wrong link tone: {url!r}'
assert all(b'4' not in sgr.split(b';') for sgr in re.findall(rb'\x1b\[([0-9;]+)m', output)), 'permanent underline appeared'
PY
fi
