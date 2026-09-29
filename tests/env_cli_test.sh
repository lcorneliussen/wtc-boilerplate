#!/usr/bin/env bash
# refresh-env keeps target-specific CLI selection and an offline shell path.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$(dirname "$TESTS_DIR")"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
TEST_TMPDIRS="$TEST_TMPDIRS $root"
for name in alpha beta delta; do
  mkdir -p "$root/$name"
  add_fixture_worktree "$root" agent-harness "$root/$name/harness"
done
printf '0.1.14\n' > "$root/main/harness/.wtc-cli-version"
printf '0.1.14\n' > "$root/alpha/harness/.wtc-cli-version"
printf '0.1.13\n' > "$root/delta/harness/.wtc-cli-version"
mock="$root/mock-bin"
mkdir -p "$mock"
export ENV_TEST_CALLS="$root/calls"
export ENV_TEST_TRUST_CALLS="$root/trust-calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1" != trust ] || { printf '%s\n' "$PWD" >> "$ENV_TEST_TRUST_CALLS"; exit 0; }
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version)
    if [ "${ENV_TEST_WRONG_VERSION:-}" = yes ]; then
      echo 'wtc version 0.1.8'
    else
      printf 'wtc version %s\n' "$(cat "$PWD/harness/.wtc-cli-version")"
    fi ;;
  'env --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$ENV_TEST_CALLS" ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/refresh-env.sh"

it 'the target CLI receives collection and dry-run options'
"$runner" --collection "$root/alpha" --dry-run >/dev/null
assert_eq "$root/alpha|env --collection $root/alpha --dry-run" "$(cat "$ENV_TEST_CALLS")"
assert_no_file "$root/alpha/.env.collection" 'dry run did not write'

it 'an older target retains the shell generator'
printf '0.1.8\n' > "$root/beta/harness/.wtc-cli-version"
fallback_out="$("$runner" --collection "$root/beta" --dry-run)"
assert_contains "$fallback_out" 'would change' 'shell dry run completed'
assert_not_contains "$(cat "$ENV_TEST_CALLS")" "$root/beta|" 'native command not called'
assert_no_file "$root/beta/.env.collection" 'fallback dry run did not write'

it 'a mismatched installed CLI retains the shell generator'
: > "$ENV_TEST_CALLS"
out="$(ENV_TEST_WRONG_VERSION=yes "$runner" --collection "$root/alpha" --dry-run)"
assert_contains "$out" 'would change' 'mismatch shell dry run completed'
assert_empty "$(cat "$ENV_TEST_CALLS")" 'mismatch did not dispatch'

it '--all selects each target pin independently'
: > "$ENV_TEST_CALLS"
sweep_out="$("$runner" --all --dry-run)"
assert_eq 2 "$(wc -l < "$ENV_TEST_CALLS" | tr -d ' ')" 'native command used for supported targets'
for name in main alpha; do
  assert_contains "$(cat "$ENV_TEST_CALLS")" \
    "$root/$name|env --collection $root/$name --dry-run --skip-hooks" "$name selected"
done
assert_contains "$sweep_out" '=== beta' 'older target included in sweep'
assert_not_contains "$(cat "$ENV_TEST_CALLS")" "$root/beta|" 'older target used fallback'
assert_contains "$sweep_out" '=== delta' 'v0.1.13 target included in sweep'
assert_not_contains "$(cat "$ENV_TEST_CALLS")" "$root/delta|" 'v0.1.13 target used safe fallback'

it 'workspace writes do not trust fallback targets'
: > "$ENV_TEST_TRUST_CALLS"
"$runner" --all > "$root/write-sweep-output"
assert_empty "$(cat "$ENV_TEST_TRUST_CALLS")" 'sweep did not trust another target'
assert_file "$root/delta/.env.collection" 'older target shell refresh completed'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'released CLI sweep writes environments without target hooks or trust'
  real_root="$(make_workspace)"
  TEST_TMPDIRS="$TEST_TMPDIRS $real_root"
  mkdir -p "$real_root/other"
  add_fixture_worktree "$real_root" agent-harness "$real_root/other/harness"
  export ENV_TEST_REAL_CLI="$WTC_TEST_RELEASE_BINARY"
  export ENV_TEST_NATIVE_MARKER="$real_root/env-hook-ran"
  export ENV_TEST_REAL_TRUST_MARKER="$real_root/mise-trust-ran"
  for name in main other; do
    mkdir -p "$real_root/$name/harness/hooks/wtc"
    cat > "$real_root/$name/harness/hooks/wtc/env.pre.sh" <<'HOOK'
#!/bin/sh
printf 'unsafe\n' > "$ENV_TEST_NATIVE_MARKER"
HOOK
    chmod +x "$real_root/$name/harness/hooks/wtc/env.pre.sh"
  done
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
if [ "$1" = trust ]; then
  printf 'unsafe\n' > "$ENV_TEST_REAL_TRUST_MARKER"
  exit 0
fi
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
exec "$ENV_TEST_REAL_CLI" "$@"
REAL_MISE
  chmod +x "$mock/mise"
  real_out="$("$real_root/main/harness/tools/refresh-env.sh" --all 2>&1)"
  real_rc=$?
  assert_eq 0 "$real_rc" "released sweep succeeded: $real_out"
  assert_file "$real_root/main/.env.collection" 'current environment written'
  assert_file "$real_root/other/.env.collection" 'other environment written'
  assert_no_file "$ENV_TEST_NATIVE_MARKER" 'released sweep skipped hooks'
  assert_no_file "$ENV_TEST_REAL_TRUST_MARKER" 'released sweep skipped mise trust'
fi
