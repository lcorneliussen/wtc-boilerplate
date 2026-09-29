#!/usr/bin/env bash
# add-repo.sh — bring additional repos into an existing collection.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/add-repo.sh [-b <branch>] [--collection <name>] <repo> [<repo> ...]

The collection is THIS one — the one holding this harness worktree — unless
--collection names another. Every argument is a repo.

Adds worktrees for the named repos (names as in .harness-repos.yml) to a
collection, cloning missing bare owners from GitHub first, then runs
each new repo's init hook. The collection env (.env.collection) already
covers all registry repos' ports, so no re-wiring is needed.

New worktrees are DETACHED AT THE DEVELOPMENT TIP — no branch is created;
`git switch -c <issue-id>-<slug>` at the first commit. A repo added purely for
context (reading a sibling's code) then never grows a branch at all.

  --collection NAME  another collection under the workspace root
  -b <branch>   create/check out this branch instead of detaching at the tip.
                An existing branch of that name is checked out, otherwise it
                is created from the repo's default_ref
  --tip         accepted and ignored — detached at the tip is now the default
EOF
  exit "${1:-1}"
}

original_args=("$@")
branch="" collection=""
while [ $# -gt 0 ]; do
  case "$1" in
    -b) branch="${2:?-b needs a value}"; shift 2 ;;
    --collection) collection="${2:?--collection needs a name}"; shift 2 ;;
    --tip) echo "note: --tip is the default now (detached at the tip); ignoring" >&2; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done
[ $# -ge 1 ] || usage

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
. "$script_dir/lib.sh"
harness_lib_init

[ -n "$collection" ] || collection="$(this_collection)"

# The old signature put the collection first (`add-repo.sh <collection> <repo>`).
# If the first of several positionals is a collection directory, they meant
# that form. A *repo* that happens to share a name with some other collection
# is still a valid repo argument — only the old two-arg shape is rejected.
if [ $# -ge 2 ] && [ -d "$ROOT/$1/harness" ]; then
  echo "error: '$1' is a collection, not a repo. add-repo acts on this" >&2
  echo "       collection; pass --collection $1 to target that one." >&2
  exit 1
fi

dest_root="$ROOT/$collection"
[ -d "$dest_root/harness" ] || { echo "error: $dest_root is not a collection (no harness/)" >&2; exit 1; }

# The target collection owns its pin. Its generated mise.toml may still name
# an older release immediately after a harness upgrade; keep shell bootstrap
# available until both the pin and installed command agree.
native_add_repo_supported() { # v0.1.11 first shipped wtc add-repo
  awk -v version="$1" 'BEGIN {
    if (version !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
    split(version, part, ".")
    exit !((part[1] + 0) > 0 || (part[2] + 0) > 1 ||
           ((part[2] + 0) == 1 && (part[3] + 0) >= 11))
  }'
}
if [ -f "$dest_root/harness/.wtc-cli-version" ]; then
  cli_pin="$(tr -d '[:space:]' < "$dest_root/harness/.wtc-cli-version")"
  cli_version=""
  cli_cmd=()
  if native_add_repo_supported "$cli_pin" && command -v mise >/dev/null 2>&1; then
    cli_version="$(cd "$dest_root" && mise exec -- wtc --version 2>/dev/null)" || cli_version=""
    [ -z "$cli_version" ] || cli_cmd=(mise exec -- wtc)
  fi
  if native_add_repo_supported "$cli_pin" && [ -z "$cli_version" ] && command -v wtc >/dev/null 2>&1; then
    cli_version="$(cd "$dest_root" && wtc --version 2>/dev/null)" || cli_version=""
    [ -z "$cli_version" ] || cli_cmd=(wtc)
  fi
  if [ "$cli_version" = "wtc version $cli_pin" ] &&
      (cd "$dest_root" && "${cli_cmd[@]}" add-repo --help >/dev/null 2>&1); then
    cd "$dest_root"
    exec "${cli_cmd[@]}" add-repo "${original_args[@]}"
  fi
fi

for repo in "$@"; do
  case "$repo" in "$(harness_repo)"|harness) echo "skip: harness is already in every collection"; continue ;; esac
  [ ! -e "$dest_root/$repo" ] || { echo "error: $dest_root/$repo already exists" >&2; exit 1; }
  add_worktree "$repo" "$repo" "$dest_root" "$branch"
done

[ -f "$dest_root/.env.collection" ] || write_collection_env "$dest_root" "$collection"

# Idempotent, and cheap: also picks up skills added since this collection was
# created, for a wtc that predates them (instructions/skills.md).
"$script_dir/link-skills.sh" --collection "$dest_root"

# Likewise for MCP servers — a collection that predates the registry picks
# them up on the next add-repo (instructions/mcp.md).
"$script_dir/link-mcp.sh" --collection "$dest_root"

for repo in "$@"; do
  case "$repo" in "$(harness_repo)"|harness) continue ;; esac
  run_hook "$dest_root/$repo" init
done

# New sibling may pin tools the collection cache did not know about.
if [ -x "$script_dir/agent-env.sh" ]; then
  "$script_dir/agent-env.sh" --write --collection "$dest_root" >/dev/null 2>&1 || true
fi

echo "done: added $* to $dest_root"
