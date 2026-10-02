#!/usr/bin/env bash
# branch-off.sh — create a new collection (wtc) from the workspace bare owners.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/branch-off.sh [-b <branch>] [--tip] <slug> [<repo> ...]
  tools/branch-off.sh --issue <issue-id> <slug> [<repo> ...]
  tools/branch-off.sh --tracker <KEY> <slug> [<repo> ...]
  tools/branch-off.sh --pr <repo>#<number> [<repo> ...]

A wtc can start from a plain slug, an issue, a tracker ticket, or a PR (review):

  <slug>            collection <slug>, branch <slug>
  --issue <id>       collection + branch <issue-id>-<slug>; the repo owning the
                    issue's prefix (registry issues_prefix) is included
                    automatically as the primary sibling
  --tracker <KEY>      collection + branch <key>-<slug> (key lowercased); create
                    the linking issue (frontmatter `tracker: <KEY>`) as part of
                    consuming the launch note
  --pr <repo>#<n>   review wtc named <repo>-pr<n>; <repo> is checked out on
                    the PR's head branch (via gh), other repos as usual

Worktrees are created DETACHED AT THE DEVELOPMENT TIP. No branch is created
up front — the branch is created at the first commit, by which point its name
is actually known (wtc-pr §2.1). Detached HEADs also mean every collection can
sit on the tip at once, which branch-per-collection could not.

The names above therefore name the COLLECTION and the branch the work is
expected to get; only --pr checks out a real branch (the PR's head), because
review work pushes to it.

The harness repo is always included as harness/. Missing bare owners are
cloned on demand. After the worktrees exist the tool writes the collection
env (.env.collection + mise.toml), links the wtc-* skills, runs init hooks,
and leaves an ephemeral HANDOFF.md launch note.

  -b <branch>   create/check out this branch instead of detaching at the tip.
                Explicit opt-in; you rarely want it
  --tip         accepted and ignored — detached at the tip is now the default
  --open        open the new wtc as a herdr workspace even if no session is
                running yet (default: join a session that is already up)
  --no-open     never open it; just print the command
EOF
  exit "${1:-1}"
}

original_args=("$@")
branch="" issue="" tracker="" pr="" open_wtc=auto
while [ $# -gt 0 ]; do
  case "$1" in
    -b) branch="${2:?-b needs a value}"; shift 2 ;;
    --tip) echo "note: --tip is the default now (detached at the tip); ignoring" >&2; shift ;;
    --open) open_wtc=yes; shift ;;
    --no-open) open_wtc=no; shift ;;
    --issue) issue="${2:?--issue needs an issue id}"; shift 2 ;;
    --tracker) tracker="${2:?--tracker needs a tracker key}"; shift 2 ;;
    --pr) pr="${2:?--pr needs <repo>#<number>}"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
. "$script_dir/lib.sh"
harness_lib_init

# The creating collection's mise.toml selects the CLI. A newly bumped harness
# can still use this shell implementation until its generated pin catches up.
native_new_supported() { # v0.1.10 first shipped wtc new
  awk -v version="$1" 'BEGIN {
    if (version !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
    split(version, part, ".")
    exit !((part[1] + 0) > 0 || (part[2] + 0) > 1 ||
           ((part[2] + 0) == 1 && (part[3] + 0) >= 10))
  }'
}
source_collection="$(dirname "$HARNESS_DIR")"
if [ -f "$HARNESS_DIR/.wtc-cli-version" ]; then
  cli_pin="$(tr -d '[:space:]' < "$HARNESS_DIR/.wtc-cli-version")"
  cli_version=""
  cli_cmd=()
  if native_new_supported "$cli_pin" && command -v mise >/dev/null 2>&1; then
    cli_version="$(cd "$source_collection" && mise exec -- wtc --version 2>/dev/null)" || cli_version=""
    [ -z "$cli_version" ] || cli_cmd=(mise exec -- wtc)
  fi
  if native_new_supported "$cli_pin" && [ -z "$cli_version" ] && command -v wtc >/dev/null 2>&1; then
    cli_version="$(cd "$source_collection" && wtc --version 2>/dev/null)" || cli_version=""
    [ -z "$cli_version" ] || cli_cmd=(wtc)
  fi
  if [ "$cli_version" = "wtc version $cli_pin" ] &&
      (cd "$source_collection" && "${cli_cmd[@]}" new --help >/dev/null 2>&1); then
    cd "$source_collection"
    exec "${cli_cmd[@]}" new "${original_args[@]}"
  fi
fi

# Resolve the wtc source into: collection, the branch name the work is
# EXPECTED to get (recorded in the launch note, created at the first commit),
# the primary repo, and the source note. `branch` stays empty unless the user
# passed -b or a real branch must be checked out (--pr).
intended_branch="" primary="" primary_branch="" source_note=""
if [ -n "$pr" ]; then
  pr_repo="${pr%%#*}" pr_num="${pr##*#}"
  case "$pr_num" in ''|*[!0-9]*) echo "error: --pr wants <repo>#<number>, got '$pr'" >&2; exit 1 ;; esac
  slug="$(repo_slug_for "$pr_repo")"
  [ -n "$slug" ] || { echo "error: '$pr_repo' not in $REGISTRY" >&2; exit 1; }
  head="$(gh pr view "$pr_num" --repo "$slug" --json headRefName -q .headRefName)"
  [ -n "$head" ] || { echo "error: could not resolve PR #$pr_num on $slug" >&2; exit 1; }
  collection="${pr_repo}-pr${pr_num}"
  intended_branch="$head"
  # The one case that checks out a real branch: review work pushes to the PR's
  # head, so a detached HEAD would have nowhere to go.
  primary="$pr_repo" primary_branch="$head"
  source_note="Review wtc for $slug#$pr_num (head branch \`$head\`)."
elif [ -n "$issue" ]; then
  [ $# -ge 1 ] || usage
  wtc_slug="$1"; shift
  collection="$issue-$wtc_slug"
  intended_branch="$collection"
  prefix="${issue%%-*}-"
  primary="$(repo_for_issue_prefix "$prefix")"
  [ -n "$primary" ] || { echo "error: no repo owns issues prefix '$prefix' in $REGISTRY" >&2; exit 1; }
  primary_branch="$branch"
  source_note="Issue wtc for \`$issue\` (repo: $primary)."
elif [ -n "$tracker" ]; then
  [ $# -ge 1 ] || usage
  wtc_slug="$1"; shift
  key_lc="$(printf '%s' "$tracker" | tr '[:upper:]' '[:lower:]')"
  collection="$key_lc-$wtc_slug"
  intended_branch="$collection"
  source_note="Tracker wtc for $tracker — create the linking issue (frontmatter \`tracker: $tracker\`) when consuming this note."
else
  [ $# -ge 1 ] || usage
  collection="$1"; shift
  intended_branch="$collection"
fi
# -b is an explicit override: it applies to every sibling.
[ -z "$branch" ] || intended_branch="$branch"

dest_root="$ROOT/$collection"
[ ! -e "$dest_root" ] || { echo "error: $dest_root already exists" >&2; exit 1; }
mkdir -p "$dest_root"

add_worktree "$(harness_repo)" harness "$dest_root" "$branch"
if [ -n "$primary" ]; then
  add_worktree "$primary" "$primary" "$dest_root" "$primary_branch"
fi
hr="$(harness_repo)"
for repo in "$@"; do
  case "$repo" in "$hr"|harness) continue ;; esac
  [ "$repo" = "$primary" ] && continue
  add_worktree "$repo" "$repo" "$dest_root" "$branch"
done

write_collection_env "$dest_root" "$collection"

# Expose the wtc-* skills under the directory names the agent CLIs read
# (instructions/skills.md). Before the init hooks: a hook may well want them.
"$script_dir/link-skills.sh" --collection "$dest_root" --seed-scope

# Same idea for MCP servers (instructions/mcp.md): rendered before the init
# hooks so a hook that starts an agent finds them already configured.
"$script_dir/link-mcp.sh" --collection "$dest_root"

for wt in "$dest_root"/*/; do
  wt="${wt%/}"
  [ -e "$wt/.git" ] && run_hook "$wt" init
done

# Init hooks install the pinned tools; refresh the PATH cache so a just-created
# collection's agent shells see them without a later catch-up. Pass
# --collection: this script lives in the *creating* harness, not dest_root's.
if [ -x "$script_dir/agent-env.sh" ]; then
  "$script_dir/agent-env.sh" --write --collection "$dest_root" >/dev/null 2>&1 || true
fi

if [ -n "$pr" ]; then
  branch_note="The primary sibling is already on the PR head branch \`$intended_branch\` — push review work there. Do not \`git switch -c\` a new branch on top of it. Other siblings start detached at the tip."
else
  branch_note="Worktrees start **detached at the development tip** — no branch exists yet.
Create one at your first commit:

    git switch -c $intended_branch

(that is the expected name; adjust it if the work turns out to be something
else)."
fi

cat > "$dest_root/HANDOFF.md" <<EOF
# wtc: $collection — launch note (EPHEMERAL)

**Goal:** ${source_note:-"(fill in — what this wtc exists for)"}

First agent on this wtc: read this, turn anything durable into issues /
commits / PRs, then **delete this file as your very first action**
(harness/AGENTS.md → "State lives in git").

$branch_note Collection env: \`.env.collection\` (inherited via \`mise.toml\`).
From this collection's Herdr workspace, retire with \`wtc retire .\`.
From elsewhere, use \`wtc retire $collection\`.
EOF

echo "done: $dest_root"

# A running session is where the other wtcs live — join it without being asked.
if [ "$open_wtc" = auto ] && herdr_present && herdr_session_running "$(herdr_session_name)"; then
  open_wtc=yes
fi
if [ "$open_wtc" = yes ]; then
  # Interactive from inside herdr: land in the new wtc. From an agent's
  # (non-TTY) shell: open it in the background, never yank the user's focus.
  if [ "${HERDR_ENV:-}" = 1 ] && [ -t 1 ]; then
    "$script_dir/wtc-open.sh" --focus "$collection"
  else
    "$script_dir/wtc-open.sh" "$collection"
  fi
elif herdr_present; then
  echo "open it:  $script_dir/wtc-open.sh $collection"
fi
