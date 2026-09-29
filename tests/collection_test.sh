#!/usr/bin/env bash
# collection_test.sh — the collection lifecycle end to end:
# branch-off -> add-repo -> retire, against a real workspace on disk.
#
# Everything runs offline. The fixture's .bare/ owners are seeded from local
# repos, so worktrees resolve and fetch without a network, and nothing here
# reaches for gh (the --pr path is the only one that does, and it is not
# exercised).
#
# The unit tests cover the pieces. This one covers the thing the pieces exist
# for, and it is where a change that breaks the *shape* of a collection shows
# up — the generated surfaces are a contract with every agent CLI that opens
# one, and no single tool's tests would notice them going missing.
. "$(dirname "$0")/helpers.sh"

ws="$(make_workspace)"
tools="$ws/main/harness/tools"

# --- branch-off -------------------------------------------------------------

it "branch-off creates a collection with the requested siblings"
out="$("$tools/branch-off.sh" demo widget 2>&1)"
rc=$?
if [ "$rc" != 0 ]; then
  _fail "branch-off exited $rc" "$out"
else
  _pass "branch-off ran"
fi
c="$ws/demo"
assert_file "$c/harness" "harness worktree"
assert_file "$c/widget" "widget worktree"

it "the siblings are real worktrees off the shared bares"
# The whole point of the layout: one clone per repo, many checkouts. A sibling
# that is its own clone would work until two collections wanted the same
# branch.
assert_eq "$ws/.bare/widget.git" "$(git -C "$c/widget" rev-parse --path-format=absolute --git-common-dir)"
assert_eq "$ws/.bare/agent-harness.git" "$(git -C "$c/harness" rev-parse --path-format=absolute --git-common-dir)"

it "product siblings rest detached at the development tip"
# Worktrees rest detached; the branch is created at the first commit, by which
# point its name is known. A collection that starts on a branch pins that
# branch to it and no other collection can check it out.
assert_empty "$(git -C "$c/widget" symbolic-ref -q --short HEAD)"
assert_eq "$(git --git-dir="$ws/.bare/widget.git" rev-parse origin/main)" \
          "$(git -C "$c/widget" rev-parse HEAD)"

it "the collection env is generated with a port for every registry repo"
assert_file "$c/.env.collection"
env_body="$(cat "$c/.env.collection")"
assert_contains "$env_body" "WTC_COLLECTION=demo"
assert_contains "$env_body" "COLLECTION_PORT_BASE=42000"
# widget has port_offset 1, so base+1 — and it is emitted whether or not the
# repo is checked out, so an absent sibling still resolves to a port.
assert_contains "$env_body" "WIDGET_PORT=42001"

it "mise.toml points at the collection env"
assert_file "$c/mise.toml"
assert_contains "$(cat "$c/mise.toml")" ".env.collection"

it "refresh-env retains a harness-pinned CLI release"
assert_contains "$(cat "$c/mise.toml")" '"github:lcorneliussen/wtc-cli" = "0.1.2"'
printf '0.1.3\n' > "$c/harness/.wtc-cli-version"
dry_out="$("$c/harness/tools/refresh-env.sh" --collection "$c" --dry-run)"
assert_contains "$dry_out" '"github:lcorneliussen/wtc-cli" = "0.1.3"'
assert_not_contains "$(cat "$c/mise.toml")" '"github:lcorneliussen/wtc-cli" = "0.1.3"'
"$c/harness/tools/refresh-env.sh" --collection "$c" >/dev/null
assert_contains "$(cat "$c/mise.toml")" '"github:lcorneliussen/wtc-cli" = "0.1.3"'
printf '0.1.2\n' > "$c/harness/.wtc-cli-version"
"$c/harness/tools/refresh-env.sh" --collection "$c" >/dev/null
assert_contains "$(cat "$c/mise.toml")" '"github:lcorneliussen/wtc-cli" = "0.1.2"'

it "the agent entry point and the scope note are seeded"
assert_file "$c/AGENTS.md" "collection AGENTS.md"
assert_file "$c/WTC-SCOPE.md" "seeded scope"
assert_file "$c/HANDOFF.md" "launch note"

it "every agent CLI gets its skills directory"
for d in .claude/skills .agents/skills; do
  assert_file "$c/$d" "$d"
done

it "a second collection gets a different port base"
"$tools/branch-off.sh" other widget >/dev/null 2>&1
assert_contains "$(cat "$ws/other/.env.collection")" "COLLECTION_PORT_BASE=42100"

# --- add-repo ---------------------------------------------------------------

it "add-repo brings another sibling into an existing collection"
# agent-harness is in the registry as a repo in its own right, which makes it
# the one repo the fixture can add without inventing a second product.
out="$("$tools/add-repo.sh" --collection demo agent-harness 2>&1)"
rc=$?
if [ "$rc" != 0 ]; then
  _fail "add-repo exited $rc" "$(printf '%s' "$out" | tail -5)"
else
  _pass "add-repo ran"
fi

it "add-repo refuses a repo that is not in the registry"
assert_fails "$tools/add-repo.sh" --collection demo nosuchrepo

it "add-repo is idempotent for a sibling already checked out"
# Running it twice is what happens when someone is not sure whether they did.
# It must not destroy the existing worktree.
printf 'work in progress\n' > "$c/widget/wip.txt"
"$tools/add-repo.sh" --collection demo widget >/dev/null 2>&1
assert_file "$c/widget/wip.txt" "existing worktree untouched"
rm -f "$c/widget/wip.txt"

# --- retire -----------------------------------------------------------------

it "retire refuses while a sibling holds unsaved work"
printf 'unsaved\n' > "$c/widget/scratch.txt"
git -C "$c/widget" add -A
out="$("$tools/retire.sh" demo 2>&1)"
assert_neq "0" "$?" "refused"
assert_contains "$out" "uncommitted"
assert_file "$c" "collection still there"

it "retire removes the collection once the work is gone"
git -C "$c/widget" reset -q --hard
out="$("$tools/retire.sh" demo 2>&1)"
rc=$?
if [ "$rc" != 0 ]; then
  _fail "retire exited $rc" "$out"
else
  _pass "retire ran"
fi
assert_no_file "$c" "collection folder gone"

it "retire leaves the shared bares and the other collection alone"
# A collection is disposable; the repos it borrowed are not, and neither is
# anybody else's collection.
assert_file "$ws/.bare/widget.git" "widget bare kept"
assert_file "$ws/.bare/agent-harness.git" "harness bare kept"
assert_file "$ws/other/.env.collection" "the other collection kept"

it "retire prunes the worktree registration, not just the folder"
# A stale registration makes the next `worktree add` at that path fail with
# "already registered", which reads as a corrupt workspace.
assert_not_contains "$(git --git-dir="$ws/.bare/widget.git" worktree list)" "/demo/"
