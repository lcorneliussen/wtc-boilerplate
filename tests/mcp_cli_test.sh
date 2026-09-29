#!/usr/bin/env bash
# link-mcp.sh selects the target collection's matching native CLI.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$(dirname "$TESTS_DIR")"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
TEST_TMPDIRS="$TEST_TMPDIRS $root"
for name in alpha beta; do
  mkdir -p "$root/$name"
  add_fixture_worktree "$root" agent-harness "$root/$name/harness"
done
printf '0.1.14\n' > "$root/main/harness/.wtc-cli-version"
printf '0.1.14\n' > "$root/alpha/harness/.wtc-cli-version"
printf '0.1.13\n' > "$root/beta/harness/.wtc-cli-version"
mock="$root/mock-bin"
mkdir -p "$mock"
export MCP_TEST_CALLS="$root/calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version)
    if [ "${MCP_TEST_WRONG_VERSION:-}" = yes ]; then
      echo 'wtc version 0.1.12'
    else
      printf 'wtc version %s\n' "$(cat "$PWD/harness/.wtc-cli-version")"
    fi ;;
  'mcp render --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$MCP_TEST_CALLS" ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/link-mcp.sh"

it 'matching target pin selects native MCP rendering'
"$runner" --collection "$root/alpha" --dry-run >/dev/null
assert_eq "$root/alpha|mcp render --collection $root/alpha --dry-run" "$(cat "$MCP_TEST_CALLS")" 'target CLI cwd and flags'
assert_no_file "$root/alpha/.mcp.json" 'mock did not write config'

it 'older and mismatched binaries retain the shell renderer'
: > "$MCP_TEST_CALLS"
cat > "$root/beta/harness/.mcp-servers.yml" <<'YML'
schema_version: 1
servers:
  - name: fallback
    command: fallback-server
YML
"$runner" --collection "$root/beta" >/dev/null
assert_empty "$(cat "$MCP_TEST_CALLS")" 'older target did not dispatch'
assert_contains "$(cat "$root/beta/.mcp.json")" 'fallback-server' 'older pin rendered config'
cat > "$root/alpha/harness/.mcp-servers.yml" <<'YML'
schema_version: 1
servers:
  - name: mismatched
    command: mismatched-server
YML
MCP_TEST_WRONG_VERSION=yes "$runner" --collection "$root/alpha" >/dev/null
assert_empty "$(cat "$MCP_TEST_CALLS")" 'mismatched binary did not dispatch'
assert_contains "$(cat "$root/alpha/.mcp.json")" 'mismatched-server' 'mismatched binary used shell renderer'

it '--all uses each collection pin separately'
: > "$MCP_TEST_CALLS"
"$runner" --all --dry-run > "$root/sweep-output"
assert_eq 2 "$(wc -l < "$MCP_TEST_CALLS" | tr -d ' ')" 'two matching targets dispatched'
for name in main alpha; do
  assert_contains "$(cat "$MCP_TEST_CALLS")" \
    "$root/$name|mcp render --collection $root/$name --dry-run --skip-hooks" "$name selected"
done
assert_contains "$(cat "$root/sweep-output")" '=== beta' 'older target included'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'released binary renders registry and runs the native hook'
  real_root="$(make_workspace)"
  TEST_TMPDIRS="$TEST_TMPDIRS $real_root"
  printf '0.1.14\n' > "$real_root/main/harness/.wtc-cli-version"
  cat > "$real_root/main/harness/.mcp-servers.yml" <<'YML'
schema_version: 1
servers:
  - name: fixture
    command: fixture-server
YML
  export MCP_TEST_REAL_CLI="$WTC_TEST_RELEASE_BINARY"
  export MCP_TEST_NATIVE_MARKER="$real_root/native-mcp-ran"
  mkdir -p "$real_root/main/harness/hooks/wtc"
  cat > "$real_root/main/harness/hooks/wtc/mcp.render.pre.sh" <<'HOOK'
#!/bin/sh
printf 'native\n' > "$MCP_TEST_NATIVE_MARKER"
HOOK
  chmod +x "$real_root/main/harness/hooks/wtc/mcp.render.pre.sh"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
exec "$MCP_TEST_REAL_CLI" "$@"
REAL_MISE
  chmod +x "$mock/mise"
  real_out="$("$real_root/main/harness/tools/link-mcp.sh" 2>&1)"
  real_rc=$?
  assert_eq 0 "$real_rc" "released command succeeded: $real_out"
  assert_file "$MCP_TEST_NATIVE_MARKER" 'native MCP hook ran'
  assert_contains "$(cat "$real_root/main/.mcp.json")" 'fixture-server' 'target registry rendered'

  mkdir -p "$real_root/other"
  add_fixture_worktree "$real_root" agent-harness "$real_root/other/harness"
  sweep_out="$(cd "$real_root/main" && "$WTC_TEST_RELEASE_BINARY" mcp render --all --dry-run --json 2>&1)"
  sweep_rc=$?
  assert_eq 0 "$sweep_rc" "released workspace sweep succeeded: $sweep_out"
  assert_contains "$sweep_out" 'swept 2 collection(s), 0 failed' 'published binary swept both targets'
  assert_no_file "$real_root/other/.mcp.json" 'released sweep dry run did not write'

  export MCP_TEST_SWEEP_MARKER="$real_root/other/sweep-hook-ran"
  mkdir -p "$real_root/other/harness/hooks/wtc"
  cat > "$real_root/other/harness/hooks/wtc/mcp.render.pre.sh" <<'HOOK'
#!/bin/sh
printf 'unsafe\n' > "$MCP_TEST_SWEEP_MARKER"
HOOK
  chmod +x "$real_root/other/harness/hooks/wtc/mcp.render.pre.sh"
  rm -f "$MCP_TEST_NATIVE_MARKER"
  sweep_out="$(cd "$real_root/main" && "$WTC_TEST_RELEASE_BINARY" mcp render --all --json 2>&1)"
  sweep_rc=$?
  assert_eq 0 "$sweep_rc" "released workspace write succeeded: $sweep_out"
  assert_file "$real_root/other/.mcp.json" 'released sweep rendered second target'
  assert_no_file "$MCP_TEST_NATIVE_MARKER" 'direct sweep skipped current hooks'
  assert_no_file "$MCP_TEST_SWEEP_MARKER" 'direct sweep skipped other hooks'
  "$real_root/main/harness/tools/link-mcp.sh" --all >/dev/null 2>&1
  assert_no_file "$MCP_TEST_NATIVE_MARKER" 'shell sweep skipped current hooks'
  assert_no_file "$MCP_TEST_SWEEP_MARKER" 'shell sweep skipped other hooks'
fi
