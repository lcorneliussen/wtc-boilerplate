#!/usr/bin/env bash
# bb-pr-ready.sh — guarded `bb pr ready` (undraft) behind the local review gate.
#
# Run from inside the target repo worktree.
# Passes only when tools/review-status.sh reports the PR's newest local review
# as `current` (covers the PR head) with verdict pass or pass-with-notes
# (not changes-requested, pending or error). Anything else needs
#   --user-authorized "<verbatim quote of the user's instruction>"
# Undrafting still happens only when the user asked for it; this adds a
# precondition, not an automatic step. See review/README.md § Gate.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage (from inside the repo worktree):
  ../harness/tools/bb-pr-ready.sh <pr-number> [--user-authorized "…"]

Marks the draft PR ready for review only when the latest local review
(/wtc-local-review) is current for the PR head and its verdict is not
changes-requested, pending or error. Otherwise run /wtc-local-review first, or — when the user
explicitly told you to undraft anyway — pass --user-authorized with a
verbatim quote.

Do not use raw `bb pr ready` / `gh pr ready` (hooks/guard-pr-ready.py refuses them).
EOF
  exit "${1:-2}"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
harness_lib_init

repo_from_cwd() {
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "error: not inside a git worktree" >&2
    exit 1
  }
  # The worktree directory is the collection sibling name (`harness/` for the
  # tooling repo). review-status.sh maps that name onto the registry.
  basename "$top"
}

# Load BB credentials when present (same as skills).
if [ -f "$HARNESS_DIR/.env" ]; then
  # shellcheck disable=SC1090
  set -a
  # shellcheck disable=SC1091
  . "$HARNESS_DIR/.env"
  set +a
fi

user_authorized=""
pr_num=""
bb_args=()
prev=""

for arg in "$@"; do
  if [ "$prev" = "--user-authorized" ]; then
    user_authorized="$arg"
    prev=""
    continue
  fi
  case "$arg" in
    -h|--help) usage 0 ;;
    --user-authorized) prev="$arg"; continue ;;
  esac
  if [ -z "$pr_num" ] && printf '%s' "$arg" | grep -Eq '^[0-9]+$'; then
    pr_num="$arg"
    bb_args+=("$arg")
    continue
  fi
  bb_args+=("$arg")
done
[ -z "$prev" ] || {
  echo "error: --user-authorized requires a value" >&2
  exit 2
}
[ -n "$pr_num" ] || usage

repo="$(repo_from_cwd)"

# state / verdict / blockers / round from the newest review comment on the PR.
status_out=""
if ! status_out="$("$script_dir/review-status.sh" "$repo" "$pr_num" 2>&1)"; then
  status_out="unreadable: $status_out"
fi
state="${status_out%% *}"
verdict="$(printf '%s\n' "$status_out" | awk 'NR==1 { print $2 }')"
echo "bb-pr-ready: repo=$repo pr=#$pr_num review=$status_out" >&2

ok=0
# Positive list: pending / error / changes-requested / anything unknown stays closed.
if [ "$state" = current ]; then
  case "$verdict" in pass|pass-with-notes) ok=1 ;; esac
fi

if [ "$ok" -ne 1 ]; then
  if [ -n "$user_authorized" ]; then
    echo "bb-pr-ready: gate overridden — user-authorized: $user_authorized" >&2
  else
    case "$state" in
      none)    why="PR #$pr_num has no local review comment" ;;
      stale)   why="the local review of PR #$pr_num is stale (the PR head moved after it)" ;;
      current)
        case "$verdict" in
          pending) why="a local review of PR #$pr_num is still running (verdict pending)" ;;
          error)   why="the last local review run of PR #$pr_num failed (verdict error)" ;;
          *)       why="the current local review of PR #$pr_num is $verdict" ;;
        esac ;;
      *)       why="the review state of PR #$pr_num could not be read: $status_out" ;;
    esac
    cat <<EOF >&2
error: refusing to mark PR #$pr_num ready: $why.

Run /wtc-local-review for this PR (bundle → run → post → fix → re-run) until
the review is current and not changes-requested, then retry.
If the user explicitly told you to undraft regardless, pass:
  …/bb-pr-ready.sh $pr_num --user-authorized "<verbatim user quote>"

See review/README.md § Gate.
EOF
    exit 1
  fi
fi

wt="$(git rev-parse --show-toplevel)"
IFS=$'\t' read -r slug forge < <(repo_slug_and_forge "$repo" "$wt") || true
case "$forge" in
  github) exec gh pr ready "${bb_args[@]}" --repo "$slug" ;;
  bitbucket) exec bb pr ready "${bb_args[@]}" ;;
  *) echo "error: cannot determine forge for $repo" >&2; exit 1 ;;
esac
