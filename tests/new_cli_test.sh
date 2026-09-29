#!/usr/bin/env bash
# branch-off selects the creating collection's pinned native command.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
TEST_TMPDIRS="$TEST_TMPDIRS $root"
mock="$root/mock-bin"
mkdir -p "$mock"
export NEW_TEST_CALLS="$root/new-calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${NEW_TEST_VERSION:-0.1.11}" ;;
  'new --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$NEW_TEST_CALLS" ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/branch-off.sh"

it 'the pinned CLI receives the original collection request'
"$runner" --no-open --issue wid-5 demo widget >/dev/null
assert_eq "$root/main|new --no-open --issue wid-5 demo widget" "$(cat "$NEW_TEST_CALLS")"
assert_no_file "$root/wid-5-demo" 'the mock received creation without the shell duplicating it'

it 'a PR review request is passed through before shell-side forge lookup'
"$runner" --pr widget#41 --no-open >/dev/null
assert_contains "$(cat "$NEW_TEST_CALLS")" "$root/main|new --pr widget#41 --no-open"

it 'an older pin retains the shell creation path'
printf '0.1.9\n' > "$root/main/harness/.wtc-cli-version"
"$runner" --no-open old widget >/dev/null 2>&1
assert_file "$root/old/HANDOFF.md" 'shell bootstrap created the collection'
assert_not_contains "$(cat "$NEW_TEST_CALLS")" 'new --no-open old widget' 'old pin did not dispatch'

it 'a mismatched installed CLI retains the shell creation path'
printf '0.1.11\n' > "$root/main/harness/.wtc-cli-version"
NEW_TEST_VERSION=0.1.10 "$runner" --no-open mismatched widget >/dev/null 2>&1
assert_file "$root/mismatched/HANDOFF.md" 'mismatched CLI did not block bootstrap'
assert_not_contains "$(cat "$NEW_TEST_CALLS")" 'new --no-open mismatched widget' 'mismatch did not dispatch'

# Optional release-binary contract. CI remains offline; release verification
# supplies WTC_TEST_RELEASE_BINARY and exercises the actual pinned command.
if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'the released CLI opens a PR at its exact head with a pushable review branch'
  export NEW_TEST_REAL_CLI="$WTC_TEST_RELEASE_BINARY"
  source_repo="$(git --git-dir="$root/.bare/widget.git" remote get-url origin)"
  git -C "$source_repo" checkout -qb review-head
  printf 'review fixture\n' > "$source_repo/review.txt"
  git -C "$source_repo" add review.txt
  git -C "$source_repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm 'review fixture'
  export NEW_TEST_PR_HEAD="$(git -C "$source_repo" rev-parse HEAD)"
  git -C "$source_repo" update-ref refs/pull/41/head "$NEW_TEST_PR_HEAD"
  git -C "$source_repo" checkout -q main
  git --git-dir="$root/.bare/widget.git" fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
  mkdir -p "$root/already"
  git --git-dir="$root/.bare/widget.git" worktree add -q -b review-head "$root/already/widget" origin/review-head
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
case "$1" in
  trust|tasks|bin-paths) exit 0 ;;
  exec)
    [ "$2 $3" = '-- wtc' ] || exit 2
    shift 3
    exec "$NEW_TEST_REAL_CLI" "$@" ;;
esac
exit 2
REAL_MISE
  cat > "$mock/gh" <<'MOCK_GH'
#!/usr/bin/env bash
printf '{"headRefName":"review-head","headRefOid":"%s","title":"Fixture review"}\n' "$NEW_TEST_PR_HEAD"
MOCK_GH
  chmod +x "$mock/mise" "$mock/gh"
  WTC_HARNESS_REPO=agent-harness WTC_CONFIG_ROOT="$root/control" \
    "$runner" --pr widget#41 --no-open >/dev/null 2>&1
  review="$root/widget-pr41"
  assert_eq "$NEW_TEST_PR_HEAD" "$(git -C "$review/widget" rev-parse HEAD)" 'exact PR head'
  assert_eq 'wtc-pr-41-review' "$(git -C "$review/widget" branch --show-current)" 'occupied branch gets a distinct local name'
  assert_contains "$(cat "$review/HANDOFF.md")" "git -C 'widget' push 'origin' 'HEAD:refs/heads/review-head'" 'launch note has push target'
  assert_contains "$(cat "$review/.wtc-prs")" 'widget 41 wtc-pr-41-review' 'PR is enlisted'
fi
