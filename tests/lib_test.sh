#!/usr/bin/env bash
# lib_test.sh — the pure lookups in tools/lib.sh: registry parsing, remote
# slugs, port names. No network, no herdr, no git beyond the fixture.
. "$(dirname "$0")/helpers.sh"

ws="$(make_workspace)"
load_lib "$ws"

# --- registry parsing -------------------------------------------------------
# The registry is parsed with awk on a shape that is load-bearing (a block
# starts at `- name:`, every other field is `key: value`). These tests are what
# stops someone "tidying" that file into something awk reads differently.

it "registry_field reads a scalar from the right block"
assert_eq "git@github.com:example/agent-harness.git" "$(registry_field agent-harness remote)"
assert_eq "origin/main" "$(registry_field widget default_ref)"
assert_eq "origin/develop" "$(registry_field gadget default_ref)"

it "registry_field does not leak a field across blocks"
# widget sets port_offset; the blocks either side do not. A scanner that
# forgets to reset on `- name:` answers 1 for all three.
assert_eq "1" "$(registry_field widget port_offset)"
assert_empty "$(registry_field agent-harness port_offset)"
assert_empty "$(registry_field gadget port_offset)"

it "registry_field is empty for an unknown repo or field"
assert_empty "$(registry_field nosuchrepo remote)"
assert_empty "$(registry_field widget nosuchfield)"

it "registry_all_names lists every block, in file order"
assert_eq "agent-harness widget gadget sprocket cog" "$(registry_all_names | tr '\n' ' ' | sed 's/ $//')"

it "registry lookups soft-fail when the registry is gone"
# A wtc-status --watch outlives the harness worktree it was started from
# (retire removes the worktree under a running pane). Losing the file must
# blank the cell, not spray awk errors into the table.
saved="$REGISTRY"; REGISTRY="$ws/definitely-not-here.yml"
assert_ok registry_field widget remote
assert_empty "$(registry_field widget remote 2>&1)"
assert_empty "$(registry_all_names 2>&1)"
REGISTRY="$saved"

# --- repo_slug_for ----------------------------------------------------------
# Both remote forms have to work. An HTTPS remote used to yield
# "//github.com/owner/repo", which gh cannot resolve, so every PR cell in
# wtc-status rendered a GraphQL NOT_FOUND blob.

it "repo_slug_for handles an SSH remote"
assert_eq "example/agent-harness" "$(repo_slug_for agent-harness)"

it "repo_slug_for handles an HTTPS remote"
assert_eq "example/widget" "$(repo_slug_for widget)"

it "repo_slug_for declines a non-GitHub remote rather than guessing"
# gadget is on gitlab. Returning "example/gadget" would send gh looking for a
# GitHub repo that is not there, which reads as "no PRs" rather than "not
# GitHub" — worse than an empty cell.
assert_empty "$(repo_slug_for gadget)"

it "repo_slug_for is empty for an unknown repo"
assert_empty "$(repo_slug_for nosuchrepo)"

# --- issue prefixes and port names -----------------------------------------

it "repo_for_issue_prefix finds the owning repo"
assert_eq "widget" "$(repo_for_issue_prefix wid-)"
assert_empty "$(repo_for_issue_prefix nope-)"

it "port_var_for upper-cases and converts dashes"
assert_eq "WIDGET_PORT" "$(port_var_for widget)"
assert_eq "AGENT_HARNESS_PORT" "$(port_var_for agent-harness)"
assert_eq "LIVE_SUPPORT_PORT" "$(port_var_for live-support)"

# --- alloc_port_base --------------------------------------------------------
# Ports are a contract between repos, so the allocator must never hand out a
# base another collection already holds.

it "alloc_port_base starts at 42000 in an empty workspace"
assert_eq "42000" "$(alloc_port_base)"

it "alloc_port_base skips bases already taken, in steps of 100"
mkdir -p "$ROOT/one" "$ROOT/two"
echo "COLLECTION_PORT_BASE=42000" > "$ROOT/one/.env.collection"
echo "COLLECTION_PORT_BASE=42100" > "$ROOT/two/.env.collection"
assert_eq "42200" "$(alloc_port_base)"

it "alloc_port_base fills a hole rather than always appending"
rm -f "$ROOT/one/.env.collection"
assert_eq "42000" "$(alloc_port_base)"

# --- default_ref_for --------------------------------------------------------

it "default_ref_for reads the registry, and falls back to origin/main"
assert_eq "origin/develop" "$(default_ref_for gadget)"
assert_eq "origin/main" "$(default_ref_for widget)"
assert_eq "origin/main" "$(default_ref_for nosuchrepo)"

# --- bare_for / owner_of ----------------------------------------------------

it "bare_for resolves a registry repo to its bare owner"
assert_eq "$ROOT/.bare/widget.git" "$(bare_for widget)"

it "owner_of resolves a worktree to its git common dir"
wt="$ROOT/main/harness"
assert_empty "$(owner_of "$ROOT/not-a-worktree" 2>/dev/null)"

# --- file_age_secs ----------------------------------------------------------

it "file_age_secs is small for a fresh file and huge for a missing one"
touch "$ws/fresh"
age="$(file_age_secs "$ws/fresh")"
if [ "$age" -ge 0 ] && [ "$age" -lt 60 ]; then _pass "fresh file age"; else _fail "fresh file age" "got $age"; fi
missing="$(file_age_secs "$ws/nope")"
if [ "$missing" -gt 100000 ]; then _pass "missing file age is huge"; else _fail "missing file age" "got $missing"; fi

# --- forges -----------------------------------------------------------------
# A repo's forge comes from its remote URL, not a global setting: one
# collection can hold a GitHub sibling and a Bitbucket one, and each has to be
# asked with the CLI that speaks its API.

it "forge_of_url recognises both hosts, in both URL forms"
assert_eq "github"    "$(forge_of_url git@github.com:o/r.git)"
assert_eq "github"    "$(forge_of_url https://github.com/o/r.git)"
assert_eq "bitbucket" "$(forge_of_url git@bitbucket.org:o/r.git)"
assert_eq "bitbucket" "$(forge_of_url https://bitbucket.org/o/r.git)"

it "forge_of_url says unknown rather than guessing"
# A gitlab remote answered "github" once and every PR cell rendered a
# NOT_FOUND blob. Unknown is a blank cell; a wrong guess is a lie.
assert_eq "unknown" "$(forge_of_url git@gitlab.com:o/r.git)"
assert_eq "unknown" "$(forge_of_url /a/local/path.git)"
assert_eq "unknown" "$(forge_of_url '')"

it "slug_from_url strips both hosts and both forms"
assert_eq "o/r" "$(slug_from_url git@github.com:o/r.git)"
assert_eq "o/r" "$(slug_from_url https://github.com/o/r.git)"
assert_eq "o/r" "$(slug_from_url git@bitbucket.org:o/r.git)"
assert_eq "o/r" "$(slug_from_url https://bitbucket.org/o/r.git)"
assert_empty    "$(slug_from_url git@gitlab.com:o/r.git)"

it "github_slug_from_url declines a bitbucket URL"
# It exists so a github-only caller cannot be handed a slug it would pass to
# `gh`, which would then ask GitHub about a repo that lives elsewhere.
assert_eq "o/r" "$(github_slug_from_url git@github.com:o/r.git)"
assert_empty    "$(github_slug_from_url git@bitbucket.org:o/r.git)"

it "forge_for_repo reads the registry"
assert_eq "github"    "$(forge_for_repo widget)"
assert_eq "bitbucket" "$(forge_for_repo sprocket)"
assert_eq "bitbucket" "$(forge_for_repo cog)"
assert_eq "unknown"   "$(forge_for_repo gadget)"
assert_eq "unknown"   "$(forge_for_repo nosuchrepo)"

it "repo_slug_for works for bitbucket too, ssh and https"
assert_eq "example/sprocket" "$(repo_slug_for sprocket)"
assert_eq "example/cog"      "$(repo_slug_for cog)"

it "repo_slug_and_forge carries the forge alongside the slug"
assert_eq "example/widget	github"    "$(repo_slug_and_forge widget)"
assert_eq "example/sprocket	bitbucket" "$(repo_slug_and_forge sprocket)"

it "forge_cli maps a forge to its client"
assert_eq "gh" "$(forge_cli github)"
assert_eq "bb" "$(forge_cli bitbucket)"
assert_empty   "$(forge_cli unknown)"

it "pr_url_for is explicit per forge and empty for unknown"
assert_eq "https://github.com/o/r/pull/7"              "$(pr_url_for o/r github 7)"
assert_eq "https://bitbucket.org/o/r/pull-requests/7"  "$(pr_url_for o/r bitbucket 7)"
assert_empty "$(pr_url_for o/r unknown 7)" "no URL rather than a wrong one"

it "forge_for_worktree prefers upstream over origin"
# A fork checkout pushes to origin but opens its PRs against the upstream, so
# the upstream is the host that has to be asked about them.
wtf="$(mktemp_dir forge)"
git -C "$wtf" init -q -b main 2>/dev/null || { mkdir -p "$wtf"; git -C "$wtf" init -q -b main; }
git -C "$wtf" remote add origin   git@github.com:me/fork.git
assert_eq "github" "$(forge_for_worktree "$wtf")"
git -C "$wtf" remote add upstream git@bitbucket.org:them/real.git
assert_eq "bitbucket" "$(forge_for_worktree "$wtf")" "upstream wins"
assert_eq "them/real" "$(upstream_slug_for_worktree "$wtf")"

# --- enrichment dispatch ----------------------------------------------------
# wtc_pr_enrich picks its client from the repo's forge. The rows below are all
# "cannot tell" cases, which matter more than the happy path: catch-up reads
# state to decide whether a branch is finished, so an unreachable forge must
# never be spelled the same as a merged PR.

enrich_field() { # <n> <repo> <number> — one field of the enrich TSV
  wtc_pr_enrich "$2" "$3" "a title" 2>/dev/null | cut -f"$1"
}

it "an unknown forge yields the unknown row, not a guess"
assert_eq ""        "$(enrich_field 2 gadget 5)" "state is empty, not MERGED"
assert_eq "NONE"    "$(enrich_field 3 gadget 5)"
assert_eq "UNKNOWN" "$(enrich_field 4 gadget 5)"
assert_eq "a title" "$(enrich_field 6 gadget 5)" "the fallback title survives"

it "the unknown row keeps its column count"
# Callers read it with `IFS=$'\t' read -r a b c …`; a short row shifts every
# field after the gap and silently mislabels the ones that follow.
assert_eq "8" "$(wtc_pr_enrich gadget 5 'a title' 2>/dev/null | awk -F'\t' '{print NF}')"

it "a forge whose CLI is absent yields the unknown row too"
# Simulated by emptying PATH: neither gh nor bb can be found, so a GitHub repo
# takes the same "cannot tell" path a Bitbucket one would without bb.
out="$(PATH=/nonexistent-for-this-test wtc_pr_enrich widget 5 'a title' 2>/dev/null | cut -f2)"
assert_empty "$out" "state stays empty when no client is installed"

# --- last-refresh snapshot --------------------------------------------------
# A cache, so every reader must work without it — and a shared one, so the
# format has to survive a round trip through both awk and a real YAML parser.

it "the snapshot round-trips every field"
mkdir -p "$ROOT/snap"
wtc_status_cache_begin snap wtc-status-tui.sh
wtc_status_cache_repo widget feat/x abc123 2 0 clean 42 github OPEN SUCCESS CLEAN approved "A title"
wtc_status_cache_commit
assert_file "$(wtc_status_cache_file snap)"
assert_eq "widget	feat/x	abc123	2	0	clean	42	github	OPEN	SUCCESS	CLEAN	approved	A title" \
  "$(wtc_status_cache_rows snap)"

it "values that look like YAML structure survive"
# A PR title is arbitrary text from someone else's repo: a leading dash makes
# it a list item, a colon makes it a mapping, and either would change the
# shape of the document rather than the value.
wtc_status_cache_begin snap wtc-status.sh
wtc_status_cache_repo r b h 0 0 clean "" unknown "" "" "" "" "A title: with a colon"
wtc_status_cache_repo r2 b h 0 0 clean "" unknown "" "" "" "" "- leading dash"
wtc_status_cache_commit
assert_eq "A title: with a colon" "$(wtc_status_cache_rows snap | head -n1 | cut -f13)"
assert_eq "- leading dash"        "$(wtc_status_cache_rows snap | tail -n1 | cut -f13)"

it "an empty field is '-', not nothing, and the row keeps 13 columns"
# `IFS=$'\t' read` treats tab as IFS whitespace, so consecutive tabs collapse
# into one delimiter and every field after an empty one shifts left. A repo
# with no PR rendered its forge in the PR column before this. "-" is the
# codebase's existing placeholder for "intentionally blank".
assert_eq "13" "$(wtc_status_cache_rows snap | head -n1 | awk -F'\t' '{print NF}')"
assert_eq "-"  "$(wtc_status_cache_rows snap | head -n1 | cut -f7)" "empty pr is -"

it "an empty field survives a shell read without shifting the row"
# The failure this guards is silent: the columns still line up, they just hold
# the wrong values.
IFS=$'\t' read -r r_repo r_branch r_head r_ahead r_behind r_tree r_pr r_forge _rest <<ROW
$(wtc_status_cache_rows snap | head -n1)
ROW
assert_eq "r"       "$r_repo"
assert_eq "-"       "$r_pr"     "pr field did not swallow the next column"
assert_eq "unknown" "$r_forge"  "forge is still in the forge field"

it "a missing snapshot is not an error"
# Every reader has to work without it: the collection may never have rendered.
assert_ok wtc_status_cache_rows never-rendered
assert_empty "$(wtc_status_cache_rows never-rendered)"

it "a half-written snapshot is never visible"
# begin+repo without commit leaves the previous file in place, because the
# rows go to a temp file that is moved only at the end.
before="$(wtc_status_cache_rows snap)"
wtc_status_cache_begin snap wtc-status.sh
wtc_status_cache_repo interrupted b h 0 0 clean "" unknown "" "" "" "" ""
assert_eq "$before" "$(wtc_status_cache_rows snap)" "still the last good snapshot"
wtc_status_cache_commit
assert_contains "$(wtc_status_cache_rows snap)" "interrupted" "and the new one lands on commit"

# --- wtc_browse_socket ------------------------------------------------------
# The socket used to be /tmp/wtc-browse-<collection>.nvim. Every workspace on
# a machine tends to have a `main`, so the second workspace's browse nvim
# failed to --listen on a socket the first one's held, and status clicks from
# it landed in the other workspace's editor.

it "wtc_browse_socket is keyed by workspace root as well as collection"
assert_eq "/tmp/wtc-browse-$(basename "$ws")-main.nvim" "$(wtc_browse_socket main)"

it "the same collection name in another workspace gets its own socket"
here="$(wtc_browse_socket main)"
saved="$ROOT"; ROOT="$(dirname "$ws")/another-workspace"
assert_neq "$here" "$(wtc_browse_socket main)"
assert_eq "/tmp/wtc-browse-another-workspace-main.nvim" "$(wtc_browse_socket main)"
ROOT="$saved"

it "a workspace and collection too long for a socket path are cut to fit"
# sun_path is 104 bytes on macOS, NUL included; past it nvim --listen fails
# outright. The cut name keeps a checksum of the full pair so it stays unique.
long="$(printf '%090d' 0 | tr 0 c)"
sock="$(wtc_browse_socket "$long")"
assert_eq "yes" "$([ "$(printf '%s' "$sock" | wc -c | tr -d ' ')" -le 100 ] && echo yes || echo no)" "fits a socket path"
assert_contains "$sock" "/tmp/wtc-browse-$(basename "$ws")-" "still says which workspace"
assert_eq "$sock" "$(wtc_browse_socket "$long")" "stable across calls"
assert_neq "$sock" "$(wtc_browse_socket "${long}d")" "a name differing past the cut still gets its own socket"
