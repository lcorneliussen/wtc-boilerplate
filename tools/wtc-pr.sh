#!/usr/bin/env bash
# wtc-pr.sh — local PR enlistment for a collection (not a forge label).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/wtc-pr.sh list [collection]
  tools/wtc-pr.sh enlist <repo> <number> [--branch B] [--url U] [--title T] [collection]
  tools/wtc-pr.sh unlist <repo> <number> [collection]
  tools/wtc-pr.sh path [collection]

Local mapping of PRs ↔ this wtc lives in <collection>/.wtc-prs. GitHub is
only used later to enrich status (state/title), never to discover which PRs
belong here.

  enlist   add/update a row after you open a PR (draft or ready)
  unlist   drop a row (closed, wrong enlistment — not needed after merge;
           catch-up keeps MERGED rows so status can archive them)
  list     show enlisted rows
  path     print the .wtc-prs path

Default collection: the one holding this harness worktree.
EOF
  exit "${1:-1}"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
harness_lib_init

cmd="${1:-}"; shift || true
[ -n "$cmd" ] || usage

default_coll="$(this_collection)"

native_pr_supported() { # v0.1.3 first shipped wtc pr
  awk -v version="$1" 'BEGIN {
    if (version !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
    split(version, part, ".")
    exit !((part[1] + 0) > 0 || (part[2] + 0) > 1 ||
           ((part[2] + 0) == 1 && (part[3] + 0) >= 3))
  }'
}
run_native_pr() { # collection, then native pr arguments; falls through on bootstrap
  local coll="$1" target pin version
  shift
  target="$ROOT/$coll"
  [ -f "$target/harness/.wtc-cli-version" ] || return 1
  pin="$(tr -d '[:space:]' < "$target/harness/.wtc-cli-version")"
  native_pr_supported "$pin" || return 1
  local -a cli_cmd=()
  version=""
  if command -v mise >/dev/null 2>&1; then
    version="$(cd "$target" && mise exec -- wtc --version 2>/dev/null)" || version=""
    [ -z "$version" ] || cli_cmd=(mise exec -- wtc)
  fi
  if [ -z "$version" ] && command -v wtc >/dev/null 2>&1; then
    version="$(cd "$target" && wtc --version 2>/dev/null)" || version=""
    [ -z "$version" ] || cli_cmd=(wtc)
  fi
  [ "$version" = "wtc version $pin" ] || return 1
  (cd "$target" && "${cli_cmd[@]}" pr --help >/dev/null 2>&1) || return 1
  cd "$target"
  exec "${cli_cmd[@]}" pr "$@"
}

case "$cmd" in
  path)
    coll="${1:-$default_coll}"
    run_native_pr "$coll" path || :
    wtc_prs_file "$coll"
    ;;
  list)
    coll="${1:-$default_coll}"
    run_native_pr "$coll" list || :
    f="$(wtc_prs_file "$coll")"
    if [ ! -f "$f" ]; then
      echo "(no enlistment yet: $f)"
      echo "add with: tools/wtc-pr.sh enlist <repo> <number> --branch <branch>"
      exit 0
    fi
    echo "file: $f"
    wtc_pr_enlist_rows "$coll" | awk -F'\t' '{
      printf "%-18s #%-6s %-28s %s\n", $1, $2, $3, $5
    }'
    ;;
  enlist)
    repo="${1:-}"; num="${2:-}"; shift 2 || true
    branch="" url="" title="" coll="$default_coll"
    while [ $# -gt 0 ]; do
      case "$1" in
        --branch) branch="${2:?--branch needs a value}"; shift 2 ;;
        --url) url="${2:?--url needs a value}"; shift 2 ;;
        --title) title="${2:?--title needs a value}"; shift 2 ;;
        -*) echo "unknown: $1" >&2; usage ;;
        *) coll="$1"; shift ;;
      esac
    done
    [ -n "$repo" ] && [ -n "$num" ] || usage
    native_args=(enlist "$repo" "$num")
    [ -z "$branch" ] || native_args+=(--branch "$branch")
    [ -z "$url" ] || native_args+=(--url "$url")
    [ -z "$title" ] || native_args+=(--title "$title")
    run_native_pr "$coll" "${native_args[@]}" || :
    # If branch omitted, try the worktree's current branch.
    if [ -z "$branch" ]; then
      wt="$(wtc_repo_worktree "$coll" "$repo")"
      [ -d "$wt" ] && branch="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || true)"
    fi
    if [ -z "$url" ] && [ -n "$num" ]; then
      IFS=$'\t' read -r slug forge <<EOF
$(repo_slug_and_forge "$repo" "$(wtc_repo_worktree "$coll" "$repo")")
EOF
      url="$(pr_url_for "$slug" "$forge" "$num")"
    fi
    wtc_pr_enlist "$coll" "$repo" "$num" "$branch" "$url" "$title"
    ;;
  unlist)
    repo="${1:-}"; num="${2:-}"; coll="${3:-$default_coll}"
    [ -n "$repo" ] && [ -n "$num" ] || usage
    run_native_pr "$coll" unlist "$repo" "$num" || :
    wtc_pr_unlist "$coll" "$repo" "$num"
    ;;
  -h|--help|help) usage 0 ;;
  *) echo "unknown command: $cmd" >&2; usage ;;
esac
