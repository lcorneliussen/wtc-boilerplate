#!/usr/bin/env bash
# The review runner shim uses the exact released CLI pin.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
add_fixture_worktree "$root" widget "$root/main/widget"
mock="$root/mock-bin"
mkdir -p "$mock"
export REVIEW_RUN_CLI_CALLS="$root/calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${REVIEW_RUN_CLI_VERSION:-$(cat "$PWD/harness/.wtc-cli-version")}" ;;
  'review run --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$REVIEW_RUN_CLI_CALLS" ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/review-run.sh"

it 'matching pin sends a caller-relative bundle and options to the native runner'
(cd "$root" && "$runner" bundle --only code --parallel 2 >/dev/null)
assert_contains "$(cat "$REVIEW_RUN_CLI_CALLS")" \
  "$root/main|review run $root/bundle --only code --parallel 2" \
  'bundle path remained caller-relative'
(cd "$root" && "$runner" --only code bundle >/dev/null)
assert_contains "$(cat "$REVIEW_RUN_CLI_CALLS")" \
  "$root/main|review run --only code $root/bundle" \
  'bundle path after options remained caller-relative'

it 'older and mismatched pins retain the shell runner'
: > "$REVIEW_RUN_CLI_CALLS"
printf '0.1.23\n' > "$root/main/harness/.wtc-cli-version"
"$runner" --help >/dev/null 2>&1
assert_eq 0 "$?" 'older pin shell help'
assert_empty "$(cat "$REVIEW_RUN_CLI_CALLS")" 'older pin did not dispatch'
printf '0.1.24\n' > "$root/main/harness/.wtc-cli-version"
REVIEW_RUN_CLI_VERSION=0.1.23 "$runner" --help >/dev/null 2>&1
assert_eq 0 "$?" 'mismatched pin shell help'
assert_empty "$(cat "$REVIEW_RUN_CLI_CALLS")" 'mismatched CLI did not dispatch'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'the published binary runs a public bundle through the shim'
  assert_eq 'wtc version 0.1.24' "$("$WTC_TEST_RELEASE_BINARY" --version)"
  export REVIEW_TEST_RELEASE_BINARY="$WTC_TEST_RELEASE_BINARY"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
exec "$REVIEW_TEST_RELEASE_BINARY" "$@"
REAL_MISE
  chmod +x "$mock/mise"
  bundle="$root/native-bundle"
  (cd "$root/main" && "$WTC_TEST_RELEASE_BINARY" review bundle widget --public --no-catch-up --base origin/main --dir "$bundle") > "$root/bundle.out" 2> "$root/bundle.err"
  assert_eq 0 "$?" "published bundle: $(cat "$root/bundle.err")"
  launcher="$root/agent.sh"
  cat > "$launcher" <<'AGENT'
#!/usr/bin/env bash
id="$(basename "$3" .md)"
if [ "$id" = lead ]; then
  printf '**Local review: pass**\n' > "$4/summary.md"
  printf 'pass\n' > "$4/verdict"
else
  printf '{"concern":"%s","status":"ok","findings":[]}\n' "$id" > "$4/findings/$id.json"
fi
printf '{"input_tokens":100,"output_tokens":10,"cache_read_tokens":20,"cost_usd":0.01}\n' > "$WTC_REVIEW_STATS_FILE"
AGENT
  chmod +x "$launcher"
  WTC_REVIEW_AGENT_CMD="$launcher" "$runner" "$bundle" --strong test: --standard test: --fast test: --lead test: > "$root/run.out" 2> "$root/run.err"
  assert_eq 0 "$?" "published runner: $(cat "$root/run.err")"
  assert_contains "$(cat "$bundle/summary.md")" '### Run stats' 'native summary has statistics'
  assert_contains "$(cat "$bundle/summary.md")" '100 / 10 (20)' 'native summary has launcher usage'
  assert_eq pass "$(cat "$bundle/verdict")" 'native runner wrote pass verdict'
fi
