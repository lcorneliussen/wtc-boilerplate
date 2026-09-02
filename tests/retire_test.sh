#!/usr/bin/env bash
# retire_test.sh — tools/retire.sh, the one tool whose job is deletion.
#
# Two properties matter and they pull against each other: a collection with
# only generated content must actually disappear, and anything that is not
# generated must survive. Getting the first one wrong leaves dead folders
# around; getting the second wrong destroys the only copy of someone's file.
#
# Both halves are asserted here because the cleanup list is hand-maintained,
# and the list going stale is a real bug that has happened twice.
. "$(dirname "$0")/helpers.sh"

ws="$(make_workspace)"
retire="$ws/main/harness/tools/retire.sh"

# Build a collection the way the tools do, without needing branch-off: a
# harness dir (retire refuses anything without one) plus the generated
# surfaces link-skills.sh and write-stack.sh leave behind.
make_collection() { # <name> -> path
  _c="$ws/$1"
  mkdir -p "$_c/harness" "$_c/.claude/skills" "$_c/.agents/skills" \
           "$_c/.cursor" "$_c/.codex" "$_c/.grok/hooks"
  # retire skips directories with no .git, which is what makes a harness dir
  # with no worktree in it safe to use as a fixture.
  for f in HANDOFF.md .env.collection .env.collection.local mise.toml \
           AGENTS.md WTC-SCOPE.md .mcp.json .envrc .env.toolchain \
           .wtc-prs .last-wtc-status.yml; do
    printf 'generated\n' > "$_c/$f"
  done
  printf 'generated\n' > "$_c/.claude/settings.json"
  printf 'generated\n' > "$_c/.cursor/hooks.json"
  printf 'generated\n' > "$_c/.grok/hooks/wtc-agent-env.json"
  printf '%s\n' "$_c"
}

# --- a clean collection disappears -----------------------------------------

it "retire removes every generated collection-root path"
c="$(make_collection tidy)"
out="$("$retire" tidy 2>&1)"
rc=$?
for p in .claude .agents .cursor .codex .grok .envrc .env.toolchain \
         .env.collection .env.collection.local mise.toml AGENTS.md \
         WTC-SCOPE.md HANDOFF.md .mcp.json .wtc-prs .last-wtc-status.yml; do
  assert_no_file "$c/$p" "removed: $p"
done

it "retire reports what it could not remove"
# The harness dir is left because the fixture's is not a real worktree. That
# is the honest outcome and the report has to name it, or a half-retired
# collection looks like a successful one.
assert_contains "$out" "left in place"
assert_contains "$out" "harness"

# --- a collection with something of its own does not -----------------------

it "a hand-authored file survives, with its content"
c="$(make_collection precious)"
mkdir -p "$c/docs"
printf 'my own notes\n' > "$c/docs/architecture.md"
printf 'a screenshot someone dropped\n' > "$c/screenshot.png"
out="$("$retire" precious 2>&1)"
assert_file "$c/docs/architecture.md" "authored file kept"
assert_eq "my own notes" "$(cat "$c/docs/architecture.md")"
assert_file "$c/screenshot.png" "stray file kept"
assert_contains "$out" "left in place"

it "the generated files around it still go"
assert_no_file "$c/.envrc"
assert_no_file "$c/.env.toolchain"
assert_no_file "$c/.grok"

# --- .harness-backups is not a generated leftover ---------------------------

it "retire never removes .harness-backups"
# link-secrets.sh moves displaced real files there, so it holds the only copy
# of whatever was in the way. It looks exactly like the same class of
# generated leftover and is the opposite of one — a collection holding one
# should refuse to disappear quietly.
c="$(make_collection with-backups)"
mkdir -p "$c/.harness-backups"
printf 'the file that was in the way\n' > "$c/.harness-backups/id_rsa"
"$retire" with-backups >/dev/null 2>&1
assert_file "$c/.harness-backups/id_rsa" "displaced secret kept"
assert_eq "the file that was in the way" "$(cat "$c/.harness-backups/id_rsa")"

# --- refusals ---------------------------------------------------------------

it "retire refuses a directory that is not a collection"
mkdir -p "$ws/not-a-collection"
assert_fails "$retire" not-a-collection

it "retire refuses to remove the collection it is running from"
# Deleting the harness mid-run leaves the tool reading files that are gone.
assert_fails "$retire" main

it "retire refuses a collection with uncommitted work, without --force"
c="$(make_collection dirty)"
add_fixture_worktree "$ws" widget "$c/widget"
printf 'unsaved\n' > "$c/widget/scratch.txt"
git -C "$c/widget" add -A 2>/dev/null
out="$("$retire" dirty 2>&1)"
rc=$?
assert_neq "0" "$rc" "refused a dirty collection"
assert_contains "$out" "uncommitted"
assert_file "$c/widget/scratch.txt" "the unsaved file is still there"

it "--force retires it anyway"
assert_ok "$retire" --force dirty
assert_no_file "$c/widget" "worktree removed under --force"
