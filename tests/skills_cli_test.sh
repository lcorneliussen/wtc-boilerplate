#!/usr/bin/env bash
# The shell entry point must select each target's pin, even in a mixed workspace.
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
export SKILLS_TEST_CALLS="$root/calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
if [ "$1" = --version ]; then
  if [ "${SKILLS_TEST_MISMATCH:-}" = yes ]; then
    echo 'wtc version 0.1.7'
  else
    pin="$(cat "$PWD/harness/.wtc-cli-version")"
    if [ -f "$PWD/mise.toml" ]; then
      generated="$(sed -n 's/.*"github:lcorneliussen\/wtc-cli" = "\([^"]*\)".*/\1/p' "$PWD/mise.toml" | head -n1)"
      [ -z "$generated" ] || pin="$generated"
    fi
    printf 'wtc version %s\n' "$pin"
  fi
elif [ "$1 $2 $3" = 'skills render --help' ]; then
  [ "$(cat "$PWD/harness/.wtc-cli-version")" != 0.1.7 ]
else
  printf '%s|%s\n' "$PWD" "$*" >> "$SKILLS_TEST_CALLS"
fi
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/link-skills.sh"

it 'single collection forwards options and uses the target pin'
"$runner" --collection "$root/alpha" --dry-run --seed-scope >/dev/null
assert_eq "$root/alpha|skills render --collection $root/alpha --dry-run --seed-scope" \
  "$(cat "$SKILLS_TEST_CALLS")"

it 'a version mismatch keeps the shell bootstrap path'
export SKILLS_TEST_MISMATCH=yes
fallback_out="$("$runner" --collection "$root/alpha" --dry-run)"
assert_eq 1 "$(wc -l < "$SKILLS_TEST_CALLS" | tr -d ' ')" 'native renderer not called'
assert_contains "$fallback_out" 'already-current=' 'shell fallback completed'
unset SKILLS_TEST_MISMATCH

it '--all dispatches once per target collection'
: > "$SKILLS_TEST_CALLS"
printf '0.1.7\n' > "$root/beta/harness/.wtc-cli-version"
sweep_out="$("$runner" --all --dry-run)"
assert_eq 2 "$(wc -l < "$SKILLS_TEST_CALLS" | tr -d ' ')" 'native render for supported target pins'
for name in main alpha; do
  assert_contains "$(cat "$SKILLS_TEST_CALLS")" \
    "$root/$name|skills render --collection $root/$name --dry-run" "$name selected"
done
assert_not_contains "$(cat "$SKILLS_TEST_CALLS")" "$root/beta|" 'older target uses shell fallback'
assert_contains "$sweep_out" '=== beta' 'older target included in sweep'
assert_contains "$sweep_out" 'already-current=' 'older target completed shell setup'

it 'catch-up refreshes the target pin before skill setup'
mkdir -p "$root/gamma"
add_fixture_worktree "$root" agent-harness "$root/gamma/harness"
printf '[tools]\n"github:lcorneliussen/wtc-cli" = "0.1.7"\n' > "$root/gamma/mise.toml"
: > "$SKILLS_TEST_CALLS"
"$root/main/harness/tools/catch-up.sh" --harness-only --no-secrets --no-mcp gamma \
  > "$root/catch-up.out" 2> "$root/catch-up.err"
assert_eq 0 "$?" 'catch-up succeeded'
pin="$(cat "$root/gamma/harness/.wtc-cli-version")"
assert_contains "$(cat "$root/gamma/mise.toml")" "\"github:lcorneliussen/wtc-cli\" = \"$pin\"" \
  'generated pin refreshed'
assert_contains "$(cat "$SKILLS_TEST_CALLS")" \
  "$root/gamma|skills render --collection $root/gamma" 'native render used refreshed pin'
