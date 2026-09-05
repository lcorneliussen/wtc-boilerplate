#!/usr/bin/env bash
# wtc-browse.sh — open a collection in one LazyVim, one vim tab per repo.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/wtc-browse.sh [options] [<collection>]

Opens LazyVim on a worktree collection: one vim tab per sibling
(`:tcd` to that repo) so gitsigns / neo-tree / Octo / lazygit see a
real git root. The multi-repo overview stays in wtc-status.sh.

Where it opens depends on who launched it:

  a terminal (including a herdr shell pane)
      this window
  a coding agent inside herdr
      the workspace `browse` pane (never the agent). Also opens a
      sibling herdr tab `pr` with gh-dash when that extension is
      installed.

  <collection>  name under the workspace root (default: this collection)
  --here        force this terminal, even from an agent pane
  --session <n> herdr session

Status-pane clicks talk to this nvim over a listen socket
(/tmp/wtc-browse-<workspace-basename>-<collection>.nvim; long names are
shortened and checksummed to fit the platform socket-path limit).
EOF
  exit "${1:-1}"
}

here=no session=""
while [ $# -gt 0 ]; do
  case "$1" in
    --here) here=yes; shift ;;
    --session) session="${2:?--session needs a name}"; shift 2 ;;
    --no-focus) shift ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
. "$script_dir/lib.sh"
harness_lib_init

if [ $# -gt 0 ]; then
  name="$1"
  collection="$ROOT/$name"
else
  collection="$(cd "$HARNESS_DIR/.." && pwd)"
  name="$(basename "$collection")"
fi
[ -d "$collection/harness" ] || {
  echo "error: $collection is not a collection (no harness/)" >&2
  exit 1
}

lua="$script_dir/wtc-browse.lua"
[ -f "$lua" ] || { echo "error: missing $lua" >&2; exit 1; }

command -v nvim >/dev/null 2>&1 || {
  echo "error: nvim is not on PATH" >&2
  exit 1
}

run_nvim() {
  cd "$collection"
  sock="$(wtc_browse_socket "$name")"
  # Both paths reach Lua as long-bracket strings, which carry spaces and
  # shell-special characters verbatim. `luafile $lua` did not: an Ex command
  # splits its argument on whitespace, so a workspace under a folder with a
  # space in its name never sourced the script.
  set -- -c "lua vim.g.wtc_browse_root = [[$collection]]" \
         -c "lua dofile([[$lua]])"
  if wtc_browse_alive "$name"; then
    # Something answers on the socket, so binding it again can only fail
    # ("address already in use"). The socket is keyed by collection, so that
    # something is this collection's own browse nvim — typically the herdr
    # browse pane, with this call coming from a terminal. A second window is
    # still useful; it just cannot be the one the status pane talks to.
    echo "==> $name: a browse nvim already listens on $sock — opening this window without it" >&2
    exec nvim "$@"
  fi
  rm -f "$sock"   # nothing answers: left over from an nvim that is gone
  exec nvim --listen "$sock" "$@"
}

if [ "$here" = yes ]; then
  run_nvim
fi

if [ "$here" = no ] && herdr_caller_is_agent; then
  [ -n "$session" ] || session="${HERDR_SESSION:-}"
  [ -n "$session" ] || session="$(herdr_session_name)"
  ws="${HERDR_WORKSPACE_ID:-}"
  if [ -n "$ws" ] && herdr_session_running "$session"; then
    pane="$(herdr_ensure_browse_pane "$session" "$ws" "$collection" || true)"
    if [ -n "$pane" ]; then
      fg="$(herdr_pane_fg_name "$session" "$pane")"
      case "$fg" in
        nvim)
          echo "==> $name: nvim already in $pane"
          ;;
        *)
          if ! herdr_pane_idle "$session" "$pane"; then
            echo "==> $name: $pane is busy ($fg) — not replacing it" >&2
            echo "    quit that TUI, or run: ./harness/tools/wtc-browse.sh --here" >&2
            exit 1
          fi
          echo "==> $name: nvim in $pane"
          # Relative to the pane's cwd (the collection root) and with no
          # collection argument — the pane's shell history stays free of this
          # machine's absolute paths.
          herdr --session "$session" pane run "$pane" \
            './harness/tools/wtc-browse.sh --here' >/dev/null
          ;;
      esac
      herdr_ensure_pr_tab "$session" "$ws" "$collection" || true
      exit 0
    fi
    echo "warning: no browse/shell pane in workspace $ws — opening here would" >&2
    echo "         take over the agent. pass --here if you really mean that." >&2
    exit 1
  fi
fi

run_nvim
