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
    printf 'wtc version %s\n' "$(cat "$PWD/harness/.wtc-cli-version")"
  fi
elif [ "$1 $2 $3" = 'skills render --help' ]; then
  exit 0
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
"$runner" --collection "$root/alpha" --dry-run >/dev/null
assert_eq 1 "$(wc -l < "$SKILLS_TEST_CALLS" | tr -d ' ')" 'native renderer not called'
unset SKILLS_TEST_MISMATCH

it '--all dispatches once per target collection'
: > "$SKILLS_TEST_CALLS"
"$runner" --all --dry-run >/dev/null
assert_eq 3 "$(wc -l < "$SKILLS_TEST_CALLS" | tr -d ' ')" 'one CLI render per collection'
for name in main alpha beta; do
  assert_contains "$(cat "$SKILLS_TEST_CALLS")" \
    "$root/$name|skills render --collection $root/$name --dry-run" "$name selected"
done
