#!/usr/bin/env bash
# catch-up.sh selects the initiating collection's pinned native command.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$(dirname "$TESTS_DIR")"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
TEST_TMPDIRS="$TEST_TMPDIRS $root"
mock="$root/mock-bin"
mkdir -p "$mock"
export CATCH_CLI_CALLS="$root/calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${CATCH_CLI_VERSION:-0.1.15}" ;;
  'catch-up --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$CATCH_CLI_CALLS" ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/catch-up.sh"

it 'matching pin dispatches from the initiating collection'
"$runner" --dry-run --harness-only --json >/dev/null
assert_eq "$root/main|catch-up --dry-run --harness-only --json" "$(cat "$CATCH_CLI_CALLS")"

it 'relative report paths keep the caller directory'
mkdir -p "$root/reports"
(cd "$root" && "$runner" --dry-run --report reports/result.json >/dev/null)
assert_contains "$(cat "$CATCH_CLI_CALLS")" \
  "$root/main|catch-up --dry-run --report $root/reports/result.json" \
  'native command received caller-relative report as an absolute path'
(cd "$root" && "$runner" --dry-run --report=reports/equals.json >/dev/null)
assert_contains "$(cat "$CATCH_CLI_CALLS")" \
  "$root/main|catch-up --dry-run --report=$root/reports/equals.json" \
  'equals-form report path kept the caller directory'
assert_status 2 "$runner" --report=
calls_before="$(wc -l < "$CATCH_CLI_CALLS" | tr -d ' ')"
assert_status 2 "$runner" --report --dry-run
assert_status 2 "$runner" --report ''
assert_eq "$calls_before" "$(wc -l < "$CATCH_CLI_CALLS" | tr -d ' ')" \
  'malformed report arguments never invoke catch-up'

it 'older pin and mismatched installed version use shell catch-up'
: > "$CATCH_CLI_CALLS"
printf '0.1.14\n' > "$root/main/harness/.wtc-cli-version"
"$runner" --dry-run --harness-only --json --no-skills --no-mcp --no-env --no-secrets > "$root/old.json" 2> "$root/old.err"
assert_empty "$(cat "$CATCH_CLI_CALLS")" 'older pin did not dispatch'
assert_contains "$(cat "$root/old.json")" '"dry_run": true' 'shell report returned'
printf '0.1.15\n' > "$root/main/harness/.wtc-cli-version"
CATCH_CLI_VERSION=0.1.14 "$runner" --dry-run --harness-only --json --no-skills --no-mcp --no-env --no-secrets > "$root/mismatch.json" 2> "$root/mismatch.err"
assert_empty "$(cat "$CATCH_CLI_CALLS")" 'mismatched version did not dispatch'
assert_contains "$(cat "$root/mismatch.json")" '"dry_run": true' 'shell report returned'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'released CLI plans catch-up through the shim without changing the fixture'
  export CATCH_TEST_REAL_CLI="$WTC_TEST_RELEASE_BINARY"
  export CATCH_TEST_NATIVE_CALLS="$root/native-calls"
  cat > "$mock/wtc-real" <<'REAL_WRAPPER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CATCH_TEST_NATIVE_CALLS"
exec "$CATCH_TEST_REAL_CLI" "$@"
REAL_WRAPPER
  chmod +x "$mock/wtc-real"
  export CATCH_TEST_REAL_WRAPPER="$mock/wtc-real"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
exec "$CATCH_TEST_REAL_WRAPPER" "$@"
REAL_MISE
  chmod +x "$mock/mise"
  before="$(git -C "$root/main/harness" rev-parse HEAD)"
  "$runner" --dry-run --harness-only --json --no-skills --no-mcp --no-env --no-secrets > "$root/native.json" 2> "$root/native.err"
  native_rc=$?
  assert_eq 0 "$native_rc" "released binary dry-run succeeded: $(cat "$root/native.err")"
  assert_contains "$(cat "$CATCH_TEST_NATIVE_CALLS")" \
    'catch-up --dry-run --harness-only --json --no-skills --no-mcp --no-env --no-secrets' \
    'released binary received the catch-up operation'
  assert_ok python3 - "$root/native.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['dry_run'] and any(r['kind']=='repo' for r in p['outcomes'])
PY
  (cd "$root" && "$runner" --dry-run --harness-only --report=reports/real.json \
    --no-skills --no-mcp --no-env --no-secrets >/dev/null 2> "$root/report.err")
  assert_file "$root/reports/real.json" 'released binary wrote the caller-relative report'
  assert_eq "$before" "$(git -C "$root/main/harness" rev-parse HEAD)" 'dry-run did not move worktree'
fi
