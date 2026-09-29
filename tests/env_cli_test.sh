#!/usr/bin/env bash
# refresh-env keeps target-specific CLI selection and an offline shell path.
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
mock="$root/mock-bin"
mkdir -p "$mock"
export ENV_TEST_CALLS="$root/calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
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
    "$root/$name|env --collection $root/$name --dry-run" "$name selected"
done
assert_contains "$sweep_out" '=== beta' 'older target included in sweep'
assert_not_contains "$(cat "$ENV_TEST_CALLS")" "$root/beta|" 'older target used fallback'
