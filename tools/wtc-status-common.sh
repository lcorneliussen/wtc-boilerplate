#!/usr/bin/env bash
# wtc-status-common.sh — shared load/draw/format for wtc-status.sh and
# wtc-status-tui.sh. Source this; do not execute directly.
#
# Ported from the Steep reference implementation
# (harness/tools/steep-status-common.sh, port/status-from-steep) for
# side-by-side testing. The boilerplate-native predecessor is preserved as
# wtc-status-legacy.sh / wtc-status-legacy-tui.sh, unwired from wtc-open.sh
# and retire.sh. Differences from the reference are called out inline —
# forge/pipeline stubs (lib.sh), tip/prod columns hidden by default
# (WTC_STATUS_PIPE), and a .last-wtc-status.yml write alongside the
# .wtc-status.json/.md snapshot (write_last_status_yml).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "error: source wtc-status-common.sh from wtc-status.sh or wtc-status-tui.sh" >&2
  exit 1
fi
set -euo pipefail

wtc_status_usage() {
  # Asking for help is success (exit 0); unknown options and other call sites
  # pass nothing and get exit 1. See tests/cli_contract_test.sh.
  local rc="${1:-1}"
  case "${WTC_STATUS_UI:-}" in
    oneshot)
      cat <<'EOF'
Usage: tools/wtc-status.sh [--repos|--procs] [--json|--md|--ansi] [--all | <collection>]

One-shot status for agents and scripts — always loads fresh, prints once, exits.
Writes <collection>/.wtc-status.json and .wtc-status.md when scoped to one collection.

  tools/wtc-status.sh              # this collection → markdown if piped, else ANSI table
  tools/wtc-status.sh --json       # canonical JSON on stdout
  tools/wtc-status.sh --md         # agent markdown on stdout
  tools/wtc-status.sh --all        # every collection (table only; no snapshot files)
  tools/wtc-status.sh --tui        # the live pane, same as wtc-status-tui.sh
  tools/wtc-status.sh --cached     # render the last snapshot; no git, no forge

For the live herdr status pane (watch, click, background refresh), use
tools/wtc-status-tui.sh — wtc-open.sh starts that automatically.

  --repos / --procs / --all / --no-fetch / --fetch-age — see wtc-status-tui.sh --help
  --cached reads <collection>/.wtc-status.json (falls back to the plainer
  .last-wtc-status.yml when that is missing); one collection only.
EOF
      ;;
    *)
      cat <<'EOF'
Usage: tools/wtc-status-tui.sh [--repos|--procs] [--watch [seconds]] [--no-click]

Interactive status pane: stale-while-revalidate from .wtc-status.json on start,
background refresh, clickable ANSI table, age/countdown footer.

  tools/wtc-status-tui.sh                 # this collection (what wtc-open runs)
  tools/wtc-status-tui.sh --procs --watch 5

One-shot output for agents: tools/wtc-status.sh (--json / --md / --ansi).

  --watch / --no-click default from $WTC_CONFIG_ROOT/wtc.env
  r refresh · a archived · ? help · q quit · click opens T/P pipelines
EOF
      ;;
  esac
  exit "$rc"
}

# Prefer BASH_SOURCE so a sourced common.sh still resolves *this* tools/
# directory (wrappers live beside us). $0 alone would also work today because
# the wrappers source us, but BASH_SOURCE is the durable form.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# HARNESS_DIR is the worktree that carries .harness-repos.yml. Normally that
# is dirname(tools/). When this checkout is an unmanaged ext.* sibling inside
# someone else's collection (Steep's harness-dev layout), borrow that
# collection's harness/ so status can still resolve the registry — and infer
# WTC_HARNESS_REPO from the harness_repo_bare_owner reason line when unset.
if [ -z "${HARNESS_DIR:-}" ] || [ ! -f "${HARNESS_DIR}/.harness-repos.yml" ]; then
  if [ -f "$(dirname "$script_dir")/.harness-repos.yml" ]; then
    HARNESS_DIR="$(dirname "$script_dir")"
  else
    _coll_harness="$(cd "$(dirname "$script_dir")/.." && pwd)/harness"
    if [ -f "$_coll_harness/.harness-repos.yml" ]; then
      HARNESS_DIR="$_coll_harness"
      if [ -z "${WTC_HARNESS_REPO:-}" ]; then
        WTC_HARNESS_REPO="$(awk '
          $1 == "-" && $2 == "name:" { n = $3 }
          $1 == "reason:" && $2 == "harness_repo_bare_owner" { print n; exit }
        ' "$HARNESS_DIR/.harness-repos.yml" 2>/dev/null || true)"
      fi
    else
      HARNESS_DIR="$(dirname "$script_dir")"
    fi
  fi
fi
. "$script_dir/lib.sh"
harness_lib_init
# Machine defaults first, flags on top: a changed default lives in the control
# root, not in every command line (instructions/secrets.md).
load_wtc_config

# WTC_STATUS_* is the boilerplate spelling (wtc.env); HARNESS_STATUS_* is the
# Steep-side one (herdr.env) — read as a fallback so a control root written
# for one side still sets defaults on the other during the reconcile.
want=both
case "${WTC_STATUS_REPOS:-${HARNESS_STATUS_REPOS:-no}}" in yes|1|true|TRUE) want=repos ;; esac
interval="${WTC_STATUS_WATCH:-${HARNESS_STATUS_WATCH:-60}}"
case "$interval" in ''|*[!0-9]*) interval=60 ;; esac
# Watching needs a terminal that can be redrawn and quit. Piped or captured,
# one pass is the only useful answer — see the note in usage.
watch=no
if [ "${WTC_STATUS_UI:-}" != oneshot ] && [ "$interval" != 0 ] && [ -t 1 ]; then
  watch=yes
fi
click=auto
case "${WTC_STATUS_NO_CLICK:-${HARNESS_STATUS_NO_CLICK:-no}}" in yes|1|true|TRUE) click=no ;; esac
# Pipelines (TIP/PROD columns) are a Bitbucket-only concept upstream; core
# boilerplate has no forge_for_slug result other than github/unknown, so the
# columns default hidden here rather than always-empty-dot. WTC_STATUS_PIPE=yes
# opts back in for a fork that does wire a second forge.
pipe_enabled=no
case "${WTC_STATUS_PIPE:-no}" in yes|1|true|TRUE) pipe_enabled=yes ;; esac
fetch=yes fetch_max_age=300 all=no only="" format=auto load_only=no cached=no

while [ $# -gt 0 ]; do
  case "$1" in
    --repos) want=repos; shift ;;
    --procs) want=procs; shift ;;
    --all) all=yes; shift ;;
    --watch) watch=yes; shift; case "${1:-}" in [0-9]*) interval="$1"; shift ;; esac ;;
    --no-watch) watch=no; [ "$click" = yes ] || click=no; shift ;;
    --load-only) load_only=yes; shift ;;
    --cached) cached=yes; shift ;;
    --json) format=json; shift ;;
    --md) format=md; shift ;;
    --ansi) format=ansi; shift ;;
    --click) click=yes; shift ;;
    --no-click) click=no; shift ;;
    --no-fetch) fetch=no; shift ;;
    --fetch-age) fetch_max_age="${2:?--fetch-age needs seconds}"; shift 2 ;;
    -h|--help) wtc_status_usage 0 ;;
    -*) echo "unknown option: $1" >&2; wtc_status_usage ;;
    *) only="$1"; shift ;;
  esac
done

# One numeric truth for the interval, before anything decides on it. `--watch`
# accepts anything starting with a digit and wtc.env accepts whatever is in it,
# so `00`, `007` and `0abc` all reach here — and `sleep` returns immediately for
# the first two and fails for the third, both inside a `while :` loop. Env vars
# that are wholly non-numeric were already replaced with the default above; a
# flag value that still has non-digits is refused. 10# keeps a leading zero from
# being read as octal.
case "$interval" in
  ''|*[!0-9]*)
    echo "error: --watch / WTC_STATUS_WATCH wants a whole number of seconds: $interval" >&2
    exit 1
    ;;
esac
interval=$((10#$interval))

case "$format" in
  auto)
    if [ -t 1 ] && [ "$want" != procs ]; then format=ansi
    elif [ "$want" = procs ]; then format=ansi
    else format=md
    fi
    ;;
  json|md|ansi) ;;
  *) echo "error: unknown output format: $format" >&2; exit 1 ;;
esac
[ "$format" = ansi ] || { click=no; watch=no; }

if [ "${WTC_STATUS_UI:-}" = oneshot ]; then
  watch=no
  click=no
fi

# --cached is repo-table only: a bare `--cached` must not fall through to the
# live process table (the default `both` view). Select repos instead.
if [ "$cached" = yes ] && [ "$want" = both ]; then
  want=repos
fi

# Collection-local by default; widening the view is always something you typed
# (instructions/collection-context.md).
if [ "$all" = yes ]; then
  [ -z "$only" ] || { echo "error: --all and a collection name are exclusive" >&2; exit 1; }
else
  [ -n "$only" ] || only="$(this_collection)"
  [ -d "$ROOT/$only/harness" ] \
    || { echo "error: $ROOT/$only is not a collection (no harness/)" >&2; exit 1; }
fi

# Clicking needs the collection table and a terminal on both ends (TUI only).
if [ "${WTC_STATUS_UI:-}" != oneshot ]; then
  if [ "$click" = auto ]; then
    click=no
    if [ "$want" != procs ] && [ -t 0 ] && [ -t 1 ]; then click=yes; fi
  fi
  [ "$click" = yes ] && watch=yes
fi

# Zero interval means print once — wins over click re-enabling watch (legacy
# --no-watch / --watch 0 / WTC_STATUS_WATCH=0). A sleep-0 loop would re-fetch
# every bare as fast as the machine allows.
if [ "$interval" = 0 ]; then watch=no; click=no; fi

# Column widths are character counts, and the rollup glyphs (✓ ✗ ● — ↑ ±) are
# one column but several bytes — so the table needs a UTF-8 ctype to measure.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*) ;;
  *) export LC_CTYPE=en_US.UTF-8 ;;
esac

# One source of truth for the columns: the widths and the click map must not
# drift apart. Wide panes use one line per repo; narrow panes wrap each repo
# to two lines (identity, then PR / dirty / ahead / behind / builds).
c_coll=22 c_repo=16 c_pr=12 c_local=8 c_ahead=3 c_behind=3 c_tip=2 c_prod=2 c_branch=34
col_repo=0 col_pr=0 col_local=0 col_ahead=0 col_behind=0 col_tip=0 col_prod=0
show_ahead=yes show_behind=yes
show_tip=$pipe_enabled show_prod=$pipe_enabled
_row_end=0   # last column the table actually writes to, separators included
row_compact=no
c_branch_vis=0
_detail_indent=0   # columns the connector glyph occupies on a compact subline
_timing_w=16   # fixed HUD width — top-right clock never shifts the layout

# Column-width hysteresis: a TUI process redraws from a fresh measurement
# every time, so a repo/branch/PR name a character shorter than the widest
# one seen so far would otherwise shrink its column mid-session — a table
# that jitters under an unchanged terminal width. Each floor only ever rises
# (bumped in _apply_column_floors, called from layout() after measuring);
# oneshot has no session to remember across, so it never touches them.
_floor_repo=0 _floor_pr=0 _floor_branch=0 _floor_local=0 _floor_ahead=0 _floor_behind=0

_apply_column_floors() {
  [ "${WTC_STATUS_UI:-}" = oneshot ] && return 0
  if [ "$c_repo" -gt "$_floor_repo" ]; then _floor_repo=$c_repo; else c_repo=$_floor_repo; fi
  if [ "$c_pr" -gt "$_floor_pr" ]; then _floor_pr=$c_pr; else c_pr=$_floor_pr; fi
  if [ "$c_branch" -gt "$_floor_branch" ]; then _floor_branch=$c_branch; else c_branch=$_floor_branch; fi
  if [ "$c_local" -gt "$_floor_local" ]; then _floor_local=$c_local; else c_local=$_floor_local; fi
  if [ "$c_ahead" -gt "$_floor_ahead" ]; then _floor_ahead=$c_ahead; else c_ahead=$_floor_ahead; fi
  if [ "$c_behind" -gt "$_floor_behind" ]; then _floor_behind=$c_behind; else c_behind=$_floor_behind; fi
}
# Scoped to one collection, the COLLECTION column is a constant — spend those
# columns on branch names instead and name the collection above the table.
show_coll=yes; [ -n "$only" ] && show_coll=no
show_help=no   # ? toggles the key/icon reference; the footer stays one line
show_archived=no  # a toggles merged PRs past 48 weekday-hours

_layout_detail_cols() { # shared tail: PR, dirty, ahead, behind, builds
  col_pr=$x; x=$((x + c_pr + 1))
  col_local=$x; x=$((x + c_local + 1))
  if [ "$show_ahead" = yes ]; then col_ahead=$x; x=$((x + c_ahead + 1)); else col_ahead=0; fi
  if [ "$show_behind" = yes ]; then col_behind=$x; x=$((x + c_behind + 1)); else col_behind=0; fi
  if [ "$show_tip" = yes ]; then col_tip=$x; x=$((x + c_tip + 1)); else col_tip=0; fi
  if [ "$show_prod" = yes ]; then col_prod=$x; x=$((x + c_prod + 1)); else col_prod=0; fi
  _row_end=$((x - 2))   # x carries a trailing separator the row never prints
}

_layout_set_cols() {
  col_repo=1
  if [ "$show_coll" = yes ]; then col_repo=$((c_coll + 2)); fi
  x=$col_repo
  x=$((x + c_repo + 1)); col_branch=$x
  x=$((x + c_branch + 1))
  _layout_detail_cols
}

# Compact rows have two independent column maps: line 1 is repo + branch, and
# line 2 starts fresh after the connector glyph, so the detail columns are not
# boxed in by how much width the repo names need.
_layout_set_cols_compact() {
  col_repo=1
  col_branch=$((col_repo + c_repo + 1))
  x=$((_detail_indent + 1))
  _layout_detail_cols
}

# The snapshot is already loaded when we lay out, so the columns whose content
# has a knowable width get measured rather than guessed. A cell narrower than
# its own text does not truncate — it pushes the rest of the row off the edge.
_repo_name_width() {
  local w=6 n
  for n in ${CR_DIR[@]+"${CR_DIR[@]}"}; do
    n="${n#${WTC_REPO_PREFIX:-}}"
    [ "${#n}" -gt "$w" ] && w=${#n}
  done
  printf '%s' "$w"
}

_pr_cell_width() { # "#<num> <3 glyphs>" — floor fits # + 2 digits
  # Layout: '#' + digits + ' ' + checks + merge + review = 5 + len(num).
  # Floor 7 covers the usual two-digit PR numbers.
  local w=7 n
  for n in ${CR_PR_NUM[@]+"${CR_PR_NUM[@]}"}; do
    [ -n "$n" ] || continue
    [ $((5 + ${#n})) -gt "$w" ] && w=$((5 + ${#n}))
  done
  printf '%s' "$w"
}

# PRS "#NN" field: '#' + digits + trailing space, min two digits, grows.
_prs_num_width() {
  local w=4 n  # "#28 " — one space after the number before the repo
  for n in ${CR_PR_NUM[@]+"${CR_PR_NUM[@]}"}; do
    [ -n "$n" ] || continue
    [ $((2 + ${#n})) -gt "$w" ] && w=$((2 + ${#n}))
  done
  for n in ${PR_ROW_NUM[@]+"${PR_ROW_NUM[@]}"}; do
    [ -n "$n" ] || continue
    [ $((2 + ${#n})) -gt "$w" ] && w=$((2 + ${#n}))
  done
  printf '%s' "$w"
}

_branch_width() {
  local w=0 n
  for n in ${CR_BRANCH[@]+"${CR_BRANCH[@]}"}; do
    [ "${#n}" -gt "$w" ] && w=${#n}
  done
  printf '%s' "$w"
}

# Dirty tree only (±N). Ahead and behind have their own columns.
_local_cell_width() {
  local w=0 i=0 t
  while [ "$i" -lt "${#CR_TREE[@]}" ]; do
    t="${CR_TREE[$i]:-clean}"
    case "$t" in
      clean|'') ;;
      *) [ "${#t}" -gt "$w" ] && w=${#t} ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$w"
}

# Ahead/behind cells are bare counts under ↑/↓ headers (no repeated arrow).
# Floor is one digit + one trailing space (width 2); grow when a count needs more.
_count_cell_width() { # scans CR_AHEAD or CR_BEHIND via name prefix
  local which="$1" w=2 i=0 n
  while [ "$i" -lt "${#CR_WT[@]}" ]; do
    case "$which" in
      ahead) n="${CR_AHEAD[$i]:-0}" ;;
      behind) n="${CR_BEHIND[$i]:-0}" ;;
      *) n=0 ;;
    esac
    if [ -n "$n" ] && [ "$n" != 0 ] && [ "${#n}" -gt "$w" ]; then
      w=${#n}
    fi
    i=$((i + 1))
  done
  printf '%s' "$w"
}

_ahead_cell_width() { _count_cell_width ahead; }
_behind_cell_width() { _count_cell_width behind; }

layout() { # recompute the columns for the terminal as it is now
  # stty asks the terminal itself; tput would believe an inherited $COLUMNS.
  cols="$(stty size 2>/dev/null | awk '{print $2}' || true)"
  [ -n "$cols" ] || cols="${COLUMNS:-}"
  [ -n "$cols" ] || cols="$(tput cols 2>/dev/null || true)"
  case "$cols" in ''|*[!0-9]*) cols=100 ;; esac
  [ "$cols" -lt 24 ] && cols=24

  row_compact=no
  show_ahead=yes show_behind=yes
  show_tip=$pipe_enabled show_prod=$pipe_enabled
  if [ "$show_coll" = yes ]; then c_coll=18; else c_coll=0; fi
  c_repo="$(_repo_name_width)"; [ "$c_repo" -lt 4 ] && c_repo=4
  c_pr="$(_pr_cell_width)"
  c_local="$(_local_cell_width)"; [ "$c_local" -lt 1 ] && c_local=1
  c_ahead="$(_ahead_cell_width)"
  c_behind="$(_behind_cell_width)"
  c_branch="$(_branch_width)"; [ "$c_branch" -lt 6 ] && c_branch=6
  c_tip=2 c_prod=2
  prs_w_num="$(_prs_num_width)"
  _apply_column_floors

  # Narrow panes / live status pane: two lines per repo (identity, then columns).
  # No header row here — a header would have to align with one of the two lines
  # and cramp the other, so each detail cell carries its own glyph instead.
  if [ "$cols" -lt 56 ] || { [ "$watch" = yes ] && [ "$cols" -lt 64 ]; }; then
    row_compact=yes
    _detail_indent=2
    c_repo="$(_repo_name_width)"
    c_pr="$(_pr_cell_width)"; [ "$c_pr" -lt 1 ] && c_pr=1
    c_local="$(_local_cell_width)"; [ "$c_local" -lt 1 ] && c_local=1
    c_ahead="$(_ahead_cell_width)"
    c_behind="$(_behind_cell_width)"
    c_tip=2 c_prod=2
    prs_w_num="$(_prs_num_width)"
    _apply_column_floors
    # Every compact column is already at its content width, so a pane too narrow
    # for all of them drops whole columns rather than clipping the row.
    while :; do
      _layout_set_cols_compact
      if [ "$_row_end" -le "$cols" ]; then
        break
      fi
      changed=no
      if [ "$show_behind" = yes ]; then show_behind=no; changed=yes
      elif [ "$show_ahead" = yes ]; then show_ahead=no; changed=yes
      elif [ "$show_tip" = yes ] && [ "$show_prod" = yes ]; then
        show_tip=no; show_prod=no; changed=yes
      elif [ "$c_pr" -gt 5 ]; then c_pr=$((c_pr - 1)); changed=yes
      else break
      fi
      [ "$changed" = yes ] || break
    done
    # Line 1 is only repo + branch, so the repo column can have the width its
    # names actually need — but never so much that the branch has no room.
    if [ "$c_repo" -gt $((cols - 12)) ]; then
      c_repo=$((cols - 12))
      [ "$c_repo" -lt 6 ] && c_repo=6
    fi
    _layout_set_cols_compact
    # Branch: fixed start (col_branch), takes what is left bar the final column
    # (a row that reaches the right edge wraps into a stray blank line).
    c_branch_vis=$((cols - col_branch))
    [ "$c_branch_vis" -lt 4 ] && c_branch_vis=4
    return 0
  fi

  # Single-line table must fit in display columns (glyphs only, no OSC-8 in cells).
  while :; do
    _layout_set_cols
    [ "$_row_end" -le "$cols" ] && break
    changed=no
    if [ "$c_branch" -gt 8 ]; then c_branch=$((c_branch - 1)); changed=yes
    elif [ "$c_repo" -gt 7 ]; then c_repo=$((c_repo - 1)); changed=yes
    elif [ "$c_coll" -gt 8 ]; then c_coll=$((c_coll - 1)); changed=yes
    elif [ "$c_pr" -gt 7 ]; then c_pr=$((c_pr - 1)); changed=yes
    elif [ "$show_behind" = yes ]; then show_behind=no; changed=yes
    elif [ "$show_ahead" = yes ]; then show_ahead=no; changed=yes
    elif [ "$show_tip" = yes ] && [ "$show_prod" = yes ]; then
      show_tip=no; show_prod=no; changed=yes
    elif [ "$c_branch" -gt 4 ]; then c_branch=$((c_branch - 1)); changed=yes
    elif [ "$c_repo" -gt 5 ]; then c_repo=$((c_repo - 1)); changed=yes
    elif [ "$c_pr" -gt 5 ]; then c_pr=$((c_pr - 1)); changed=yes
    else
      row_compact=yes
      break
    fi
    [ "$changed" = yes ] || break
  done

  if [ "$row_compact" != yes ] && [ "$_row_end" -gt "$cols" ]; then
    row_compact=yes
  fi
  # Every column sits at the width its content needs, so a pane wider than the
  # table just ends early — stretching BRANCH to pin the rest to the right edge
  # only put a canyon between a repo and its own status.
  [ "$c_branch" -lt 4 ] && c_branch=4
  _layout_set_cols
}

FORMAT_PY="$script_dir/wtc-status-format.py"
ANSI_PY="$script_dir/wtc-status-ansi.py"
_snapshot_ndjson=""
snapshot_loaded=no
_snapshot_stale=0
_snapshot_prs_empty=no

_snapshot_epoch=0
_tick=0
_refresh_pending=no
_refresh_active=no
_refresh_dir=""
_refresh_pid=""
_redraw_only=no
_frame=""
_frame_buf=no
_procs_cached=""

ROWS=("")   # ROWS[<screen line>] = "<worktree>|<slug>|<branch>|<pr>"
# Compact rows split one repo over two lines with independent column maps, so a
# click needs to know which of the two it landed on: `id` (repo + branch) or
# `detail` (PR / sync / builds / tree).
ROWKIND=("")
TERMX=("")  # TERMX[<screen line>] = screen column of that row's ▣ (terminal PR)
TIPURL=("") # TIPURL[<screen line>] = pipeline url for TIP glyph click
PRODURL=("")  # PRODURL[<screen line>] = pipeline url for PROD glyph click
PROWS=("")  # PROWS[<screen line>] = "<slug>|<pr number>" for the PRS section
line=0      # lines printed so far, i.e. the screen line of the last one
# The PRS section is a fixed layout, so its two click zones are constants.
prs_x_num=3 prs_w_num=6 prs_x_term=0


# Cached repo rows — populated by load_snapshot, consumed by draw_repos_tty.
CR_COLL=(); CR_DIR=(); CR_WT=(); CR_SLUG=(); CR_LABEL=()
CR_BRANCH=(); CR_AHEAD=(); CR_BEHIND=(); CR_TREE=()
CR_PR_NUM=(); CR_PR_CHECKS=(); CR_PR_MERGE=(); CR_PR_REVIEW=(); CR_PR_DRAFT=()
CR_TIP_CHECKS=(); CR_TIP_URL=(); CR_PROD_CHECKS=(); CR_PROD_URL=()
# Cached PR section rows — title includes any MERGED follow-through prefix.
PR_ROW_REPO=(); PR_ROW_NUM=(); PR_ROW_CHECKS=(); PR_ROW_MERGE=()
PR_ROW_REVIEW=(); PR_ROW_TITLE=(); PR_ROW_SLUG=(); PR_ROW_ARCHIVED=(); PR_ROW_DRAFT=()
PR_ROW_ON_BRANCH=()  # yes = merged/closed but worktree still on the PR branch

out() {
  local s="$1"
  if [ -n "${cols:-}" ] && { [ "$watch" = yes ] || [ "$format" = ansi ]; }; then
    s="$(python3 "$ANSI_PY" fit "$cols" <<< "$s")"
  fi
  if [ "$_frame_buf" = yes ]; then
    _frame="${_frame}${s}"$'\n'
  else
    printf '%s\n' "$s"
  fi
  line=$((line + 1))
}

ansi_vislen() { # <text> -> $_vlen display columns (CSI only)
  _vlen="$(python3 "$ANSI_PY" len 0 <<< "$1")"
}

flush_frame() {
  [ "$_frame_buf" = yes ] || return 0
  [ -n "$_frame" ] || return 0
  if [ "$watch" = yes ]; then
    printf '\033[H\033[2J%s' "$_frame"
  else
    printf '%s' "$_frame"
  fi
  _frame=""
}

show_refreshing() { :; }  # refresh runs in the background; table stays visible

status_age_label() {
  [ "$_snapshot_epoch" -gt 0 ] || { printf '…'; return 0; }
  now="$(date +%s)"
  age=$((now - _snapshot_epoch))
  if [ "$age" -lt 60 ]; then printf '%ss' "$age"
  elif [ "$age" -lt 3600 ]; then printf '%sm' $((age / 60))
  else printf '%sh' $((age / 3600))
  fi
}

# The child reports units done out of a total it fixed before starting, so this
# is one bar that fills once — a refresh that takes seconds needs to show
# movement, which a countdown never did.
status_progress_bar() { # <done> <total> <repos> -> "[####------]"
  local pdone="${1:-0}" ptotal="${2:-1}" nrepo="${3:-0}" w wmax filled i bar=""
  case "$ptotal" in ''|*[!0-9]*) ptotal=1 ;; esac
  case "$pdone" in ''|*[!0-9]*) pdone=0 ;; esac
  case "$nrepo" in ''|*[!0-9]*) nrepo=0 ;; esac
  [ "$ptotal" -gt 0 ] || ptotal=1
  [ "$pdone" -gt "$ptotal" ] && pdone="$ptotal"
  # Two cells per repo where they fit, one where they do not, so a repo landing
  # is a visible step rather than a fraction of a character.
  wmax=$((_timing_w - 2))
  if [ "$nrepo" -gt 0 ] && [ $((nrepo * 2)) -le "$wmax" ]; then w=$((nrepo * 2))
  elif [ "$nrepo" -gt 0 ] && [ "$nrepo" -le "$wmax" ]; then w="$nrepo"
  else w="$wmax"
  fi
  [ "$w" -lt 4 ] && w=4
  filled=$((pdone * w / ptotal))
  i=0
  while [ "$i" -lt "$w" ]; do
    if [ "$i" -lt "$filled" ]; then bar="$bar#"; else bar="$bar-"; fi
    i=$((i + 1))
  done
  printf '[%s]' "$bar"
}

status_progress_hud() {
  local f pdone="" ptotal="" nrepo=""
  if [ -n "${_refresh_dir:-}" ] && [ -f "${_refresh_dir}/progress" ]; then
    f="${_refresh_dir}/progress"
    IFS=$'\t' read -r pdone ptotal nrepo < "$f" 2>/dev/null || true
  fi
  # Before the child's first report, the cached table already knows how many
  # repos there are — so the empty bar is the right size from the first frame.
  [ -n "$nrepo" ] || nrepo="${#CR_WT[@]}"
  status_progress_bar "${pdone:-0}" "${ptotal:-1}" "$nrepo"
}

# Fixed-width HUD for the top-right corner (does not affect footer layout).
# ASCII only: an ambiguous-width glyph here renders two columns wide in some
# terminals, overflows the title bar and wraps its last character onto row 2.
status_timing_hud() {
  local hud=""
  if [ "$_refresh_active" = yes ]; then
    hud="$(status_progress_hud)"
  elif [ "$_snapshot_epoch" -gt 0 ]; then
    printf -v hud '%s old' "$(status_age_label)"
  else
    hud="no data"
  fi
  printf '%*s' "$_timing_w" "$hud"
}

status_keys_footer() {
  printf '? · a · r · q'
}


draw_title_bar() {
  # Collection name stays top-left in the live pane; timing HUD is top-right only.
  local title pad timing
  if [ "$watch" != yes ]; then
    [ -n "$only" ] && [ "$show_coll" = no ] && out $'\033[1m'"$only"$'\033[0m'
    return 0
  fi
  if [ -n "$only" ]; then title="$only"
  elif [ "$all" = yes ]; then title="all collections"
  else title="status"
  fi
  timing="$(status_timing_hud)"
  # The HUD stops one short of the right edge: filling the last column wraps.
  if [ $(( ${#title} + _timing_w + 2 )) -gt "$cols" ]; then
    fit "$title" $((cols - _timing_w - 2))
    title="$_fit"
  fi
  pad=$((cols - 1 - ${#title} - _timing_w))
  [ "$pad" -lt 1 ] && pad=1
  printf -v _titlebar '%s%*s\033[2m%s\033[0m' \
    $'\033[1m'"$title"$'\033[0m' "$pad" '' "$timing"
  out "$_titlebar"
}

update_status_clock() {
  [ "$watch" = yes ] || return 0
  [ "$format" = ansi ] || return 0
  layout
  local col hud
  hud="$(status_timing_hud)"
  col=$((cols - _timing_w))
  [ "$col" -lt 1 ] && col=1
  # Clear from the cursor rightwards, not the whole row: the collection name
  # lives on the left of this same line and a tick must not erase it.
  printf '\033[1;%dH\033[K\033[2m%s\033[0m' "$col" "$hud"
}

apply_snapshot_from_json() {
  json_path="${1:-}"
  if [ -z "$json_path" ]; then
    if [ -n "${_refresh_dir:-}" ] && [ -f "${_refresh_dir}/snapshot.json" ]; then
      json_path="${_refresh_dir}/snapshot.json"
    elif [ -n "$only" ] && [ -f "$ROOT/$only/.wtc-status.json" ]; then
      json_path="$ROOT/$only/.wtc-status.json"
    fi
  fi
  [ -n "$json_path" ] && [ -f "$json_path" ] || return 1
  eval "$(python3 "$FORMAT_PY" --bash-state < "$json_path")"
  [ "$_snapshot_epoch" -gt 0 ] || _snapshot_epoch="$(date +%s)"
  snapshot_loaded=yes
  return 0
}

refresh_bg_args() {
  REFRESH_ARGS=( --load-only )
  [ "$fetch" = no ] && REFRESH_ARGS+=( --no-fetch )
  [ "$fetch_max_age" != 300 ] && REFRESH_ARGS+=( --fetch-age "$fetch_max_age" )
  [ "$all" = yes ] && REFRESH_ARGS+=( --all )
  [ -n "$only" ] && REFRESH_ARGS+=( "$only" )
  case "$want" in
    repos) REFRESH_ARGS+=( --repos ) ;;
    procs) REFRESH_ARGS+=( --procs ) ;;
  esac
}

start_refresh_bg() {
  [ "$_refresh_active" = yes ] && return 0
  [ "$snapshot_loaded" = yes ] || return 1
  _refresh_dir="$(mktemp -d "${TMPDIR:-/tmp}/wtc-refresh.XXXXXX")"
  _refresh_active=yes
  refresh_bg_args
  (
    WTC_STATUS_PROGRESS="${_refresh_dir}/progress" \
    "$script_dir/wtc-status.sh" "${REFRESH_ARGS[@]}" \
      > "${_refresh_dir}/snapshot.json" 2>/dev/null || true
    printf '%s\n' $? > "${_refresh_dir}/exit"
    touch "${_refresh_dir}/done"
  ) &
  _refresh_pid=$!
  update_status_clock
}

poll_refresh_complete() {
  [ "$_refresh_active" = yes ] || return 1
  [ -f "${_refresh_dir}/done" ] || return 1
  wait "$_refresh_pid" 2>/dev/null || true
  _refresh_active=no
  _refresh_pid=""
  if apply_snapshot_from_json; then
    if [ "$want" = both ]; then cache_procs; else _procs_cached=""; fi
    _tick=0
    rm -rf "${_refresh_dir}"
    _refresh_dir=""
    if [ "$_refresh_pending" = yes ]; then
      _refresh_pending=no
      start_refresh_bg
      return 1
    fi
    return 0
  fi
  rm -rf "${_refresh_dir}"
  _refresh_dir=""
  return 1
}

do_refresh_sync() {
  snapshot_loaded=no
  load_snapshot
  if [ "$want" = both ]; then cache_procs; else _procs_cached=""; fi
  _refresh_pending=no
  _tick=0
}

# A refresh costs seconds of git and forge round trips, so a live pane needs to
# show it is working, not just that it started. The loader runs as a child
# process, so it reports through a file the pane polls; with no file named
# (agents, one-shot runs) every call below is a no-op.
_prog_file="${WTC_STATUS_PROGRESS:-}"
_prog_n=0       # worktrees in scope — one phase segment each
_prog_total=0   # units for the whole refresh, fixed before any work starts
_prog_units=0   # units done; never allowed to go backwards
_prog_jobs=0

# One bar for the whole refresh: the total is known up front and every phase
# fills its own slice of it, so the bar only ever moves forward.
progress_units() { # <units done overall>
  [ -n "$_prog_file" ] || return 0
  local u="$1"
  [ "$u" -lt "$_prog_units" ] && u="$_prog_units"
  [ "$u" -gt "$_prog_total" ] && u="$_prog_total"
  _prog_units="$u"
  # The repo count travels with the counts so the pane can size the bar to the
  # work: a couple of cells per repo, rather than an arbitrary fixed width.
  printf '%s\t%s\t%s\n' "$_prog_units" "$_prog_total" "$_prog_n" \
    > "$_prog_file.tmp" 2>/dev/null || return 0
  mv -f "$_prog_file.tmp" "$_prog_file" 2>/dev/null || true
}

_scope_worktree_count() {
  local n=0 c wt
  for c in "$ROOT"/*/; do
    c="${c%/}"
    [ -d "$c/harness" ] || continue
    if [ -n "$only" ] && [ "$(basename "$c")" != "$only" ]; then continue; fi
    for wt in "$c"/*/; do
      wt="${wt%/}"
      [ -e "$wt/.git" ] || continue
      n=$((n + 1))
    done
  done
  printf '%s' "$n"
}

_json_str() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }

snapshot_open() {
  _snapshot_ndjson="$(mktemp "${TMPDIR:-/tmp}/wtc-status-snap.XXXXXX")"
  : > "$_snapshot_ndjson"
}

snapshot_close() {
  [ -n "${_snapshot_ndjson:-}" ] && rm -f "$_snapshot_ndjson"
  _snapshot_ndjson=""
}

ndjson_line() {
  python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$1" \
    >> "$_snapshot_ndjson"
}

write_snapshot_files() {
  [ -n "$only" ] || return 0
  [ "$want" = procs ] && return 0
  [ -f "$_snapshot_ndjson" ] || return 0
  coll_root="$ROOT/$only"
  python3 "$FORMAT_PY" --json < "$_snapshot_ndjson" > "$coll_root/.wtc-status.json"
  python3 "$FORMAT_PY" --md < "$_snapshot_ndjson" > "$coll_root/.wtc-status.md"
  write_last_status_yml
}

# The same facts, once more, in the boilerplate's own cache format
# (<collection>/.last-wtc-status.yml) via wtc_status_cache_begin/_repo/_commit
# in lib.sh — kept alongside .wtc-status.json/.md rather than instead of them,
# so a --cached reader on either side of the steep/boilerplate port sees the
# same render. Cast from the CR_* arrays load_snapshot already built; nothing
# here re-walks a worktree or re-asks a forge, beyond one local `rev-parse`
# per repo for the short head SHA the cache format wants and the snapshot
# JSON does not carry.
write_last_status_yml() {
  wtc_status_cache_begin "$only" "$(basename "$0")$([ "$watch" = yes ] && printf ' --tui')"
  local i=0 dir wt slug branch ahead behind tree pr forge state checks merge review head
  i=0
  while [ "$i" -lt "${#CR_WT[@]}" ]; do
    dir="${CR_DIR[$i]:-}"
    wt="${CR_WT[$i]:-}"
    slug="${CR_SLUG[$i]:-}"
    branch="${CR_BRANCH[$i]:-}"
    ahead="${CR_AHEAD[$i]:-0}"
    behind="${CR_BEHIND[$i]:-0}"
    tree="${CR_TREE[$i]:-clean}"
    pr="${CR_PR_NUM[$i]:-}"
    checks="${CR_PR_CHECKS[$i]:-}"
    merge="${CR_PR_MERGE[$i]:-}"
    review="${CR_PR_REVIEW[$i]:-}"
    head="$(git -C "$wt" rev-parse --short HEAD 2>/dev/null || true)"
    forge="unknown"; [ -n "$slug" ] && forge="$(forge_for_slug "$slug")"
    state=""
    if [ -n "$pr" ]; then
      if [ "${CR_PR_DRAFT[$i]:-no}" = yes ]; then state=DRAFT; else state=OPEN; fi
    fi
    wtc_status_cache_repo "$dir" "$branch" "$head" "$ahead" "$behind" "$tree" \
      "$pr" "$forge" "$state" "$checks" "$merge" "$review" ""
    i=$((i + 1))
  done
  wtc_status_cache_commit
}

emit_snapshot_output() {
  [ -f "$_snapshot_ndjson" ] || return 0
  case "$format" in
    json) python3 "$FORMAT_PY" --json < "$_snapshot_ndjson" ;;
    md)   python3 "$FORMAT_PY" --md < "$_snapshot_ndjson" ;;
  esac
}

build_glyph_cell() { # <checks> <url> -> $_bgcell (glyph only; url is for click maps)
  case "${1:-}" in
    SUCCESS|FAILURE|ERROR|PENDING|EXPECTED) _bgcell="$(glyph_checks "$1")" ;;
    *) _bgcell=""; return 0 ;;
  esac
}

# --- PR facts: one round trip each, run in parallel, cached -----------------
# GitHub: one GraphQL query. Bitbucket: bb pr list (match source branch) +
# bb pr checks. Same TSV cache shape either way:
#   number \t state \t checks \t merge \t review \t title
PR_CACHE="${TMPDIR:-/tmp}/wtc-status-$(id -u)"
pr_cache_age="${WTC_PR_CACHE_AGE:-90}"

PR_QUERY='
query($owner:String!,$name:String!,$branch:String!){
  repository(owner:$owner,name:$name){
    pullRequests(headRefName:$branch,first:1,
                 orderBy:{field:CREATED_AT,direction:DESC}){
      nodes{
        number state isDraft mergeStateStatus reviewDecision
        reviewThreads(first:100){nodes{isResolved isOutdated}}
        commits(last:1){nodes{commit{statusCheckRollup{state}}}}
      }}}}'

PR_SHAPE='.data.repository.pullRequests.nodes[0] // empty | [
    (.number|tostring),
    .state,
    ((.commits.nodes[0].commit.statusCheckRollup.state // "NONE") as $c
      | if .isDraft and ($c == "NONE") then "draft" else $c end),
    (.mergeStateStatus // "UNKNOWN"),
    (([.reviewThreads.nodes[] | select((.isResolved|not) and (.isOutdated|not))] | length) as $open
      | if $open > 0 then ($open|tostring)
        elif .reviewDecision == "APPROVED" then "approved"
        elif .reviewDecision == "CHANGES_REQUESTED" then "changes"
        else "none" end),
    (.title // "")
  ] | @tsv'

pr_cache_file() { # <slug> <branch>
  printf '%s/%s\n' "$PR_CACHE" "$(printf '%s@%s' "$1" "$2" | tr -c 'A-Za-z0-9._@-' '_')"
}

pr_cache_fresh() { # <file> — 0 while it may still be believed
  [ -f "$1" ] || return 1
  [ "$(file_age_secs "$1")" -lt "$pr_cache_age" ]
}

# Bitbucket → same TSV as PR_SHAPE (+ empty merged_on). Prefer wtc-pr-facts when
# the list hit has enough data; otherwise fall back to comment_count heuristics.
pr_fetch_bb() { # <slug> <branch> <cache-file>
  owner="${1%%/*}"; nm="${1#*/}"; branch="$2"; f="$3"
  command -v bb >/dev/null 2>&1 || { : > "$f.$$"; mv -f "$f.$$" "$f"; return 0; }
  _facts_py="$(wtc_pr_facts_py 2>/dev/null || true)"
  bb pr list -w "$owner" -r "$nm" --state OPEN --limit 50 --json 2>/dev/null \
    | python3 -c '
import json, sys, subprocess, os
branch, out = sys.argv[1], sys.argv[2]
owner, nm = sys.argv[3], sys.argv[4]
facts_py = sys.argv[5] if len(sys.argv) > 5 else ""
d = json.load(sys.stdin)
match = None
for p in d.get("pullRequests") or []:
    src = ((p.get("source") or {}).get("branch") or {}).get("name") or ""
    if src == branch:
        match = p
        break
if not match:
    open(out, "w").write("")
    sys.exit(0)
pid = match.get("id")
# List payloads omit participants — view for review / draft accuracy.
try:
    raw = subprocess.check_output(
        ["bb", "--json", "pr", "view", str(pid), "-w", owner, "-r", nm],
        stderr=subprocess.DEVNULL, text=True)
    checks_raw = ""
    try:
        checks_raw = subprocess.check_output(
            ["bb", "--json", "pr", "checks", str(pid), "-w", owner, "-r", nm],
            stderr=subprocess.DEVNULL, text=True)
    except Exception:
        pass
    if facts_py and os.path.isfile(facts_py):
        import subprocess as sp
        line = sp.check_output(
            ["python3", facts_py, "bb-from-json", "--num", str(pid),
             "--checks-json", checks_raw],
            input=raw, text=True).rstrip("\n")
        # Drop trailing merged_on for the 6-field branch cache used by pr_facts.
        parts = line.split("\t")
        while len(parts) < 6:
            parts.append("")
        open(out, "w").write("\t".join(parts[:6]) + "\n")
        sys.exit(0)
except Exception:
    pass
state = match.get("state") or "OPEN"
draft = bool(match.get("draft"))
if draft and state == "OPEN":
    state = "DRAFT"
title = (match.get("title") or "").replace("\t", " ").replace("\n", " ")
# D in the checks slot means CI was skipped because of draft — not "is draft".
checks = "draft" if draft else "NONE"
review = "none"
open(out, "w").write("\t".join([str(pid), state, checks, "UNKNOWN", review, title]) + "\n")
' "$branch" "$f.$$" "$owner" "$nm" "${_facts_py:-}" 2>/dev/null || : > "$f.$$"
  mv -f "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$"
}

pr_fetch_gh() { # <slug> <branch> <cache-file>
  owner="${1%%/*}"; nm="${1#*/}"; f="$3"
  command -v gh >/dev/null 2>&1 || { : > "$f.$$"; mv -f "$f.$$" "$f"; return 0; }
  gh api graphql -F owner="$owner" -F name="$nm" -F branch="$2" \
    -f query="$PR_QUERY" --jq "$PR_SHAPE" > "$f.$$" 2>/dev/null || : > "$f.$$"
  mv -f "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$"
}

pr_fetch_bg() { # <slug> <branch> — refresh one cache entry, in the background
  f="$(pr_cache_file "$1" "$2")"
  pr_cache_fresh "$f" && return 0
  (
    case "$(forge_for_slug "$1")" in
      bitbucket) pr_fetch_bb "$1" "$2" "$f" ;;
      github)    pr_fetch_gh "$1" "$2" "$f" ;;
      *)
        if command -v bb >/dev/null 2>&1; then
          pr_fetch_bb "$1" "$2" "$f"
        elif command -v gh >/dev/null 2>&1; then
          pr_fetch_gh "$1" "$2" "$f"
        else
          : > "$f"
        fi
        ;;
    esac
  ) &
}

pr_facts() { # <slug> <branch> -> the cached TSV line, or empty
  f="$(pr_cache_file "$1" "$2")"
  [ -f "$f" ] && cat "$f" || true
}

# --- glyphs -----------------------------------------------------------------
# Each slot only speaks when it has something to say: a PR with green checks,
# no conflict and no comments is just "#225 ✓". Silence is the common case,
# and a row of icons that are always present is a row you stop reading.
G_OK=$'\033[32m✓\033[0m'
G_BAD=$'\033[31m✗\033[0m'
G_RUN=$'\033[33m●\033[0m'
G_NONE=$'\033[2m·\033[0m'

glyph_checks() { # <state> -> one column
  case "$1" in
    SUCCESS)                      printf '%s' "$G_OK" ;;
    FAILURE|ERROR)                printf '%s' "$G_BAD" ;;
    PENDING|EXPECTED)             printf '%s' "$G_RUN" ;;
    draft)                        printf '\033[33mD\033[0m' ;;  # CI skipped because draft
    *)                            printf '%s' "$G_NONE" ;;
  esac
}

# OSC-8 hyperlink (iTerm2 / herdr / most modern terminals). Visible width is
# still just the text — the escapes are zero-width for layout purposes.
osc8_link() { # <url> <text> -> $_osc8
  if [ -n "$1" ]; then
    printf -v _osc8 '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$2"
  else
    _osc8="$2"
  fi
}

# Underlined "#N" linking to the forge PR (Bitbucket or GitHub). Visible width
# stays 1+${#num}; OSC-8 gives hover/⌘-click in iTerm2/herdr, and on_click
# opens the same URL on a plain click when mouse reporting is on.
pr_num_link() { # <slug> <num> -> $_prlink
  local slug="${1:-}" num="${2:-}" forge="" url="" label=""
  [ -n "$num" ] || { _prlink=""; return 0; }
  label=$'\033[4m'"#$num"$'\033[24m'
  if [ -n "$slug" ]; then
    forge="$(forge_for_slug "$slug")"
    url="$(pr_url_for "$slug" "$forge" "$num")"
  fi
  if [ -n "$url" ]; then
    osc8_link "$url" "$label"
    _prlink="$_osc8"
  else
    _prlink="$label"
  fi
}

open_pr_web() { # <slug> <pr number> — browser; Bitbucket or GitHub
  local slug="${1:-}" num="${2:-}" forge="" url=""
  [ -n "$slug" ] && [ -n "$num" ] || return 0
  forge="$(forge_for_slug "$slug")"
  url="$(pr_url_for "$slug" "$forge" "$num")"
  [ -n "$url" ] || return 0
  (open "$url" >/dev/null 2>&1 || xdg-open "$url" >/dev/null 2>&1 || true) &
}

# Glyph + optional #build hyperlink to the Bitbucket pipeline. Failures are
# underlined so they read as the thing to open.
pipe_build_cell() { # <checks> <build> <url> -> $_pcell
  g="$(glyph_checks "${1:-NONE}")"
  if [ -z "${2:-}" ]; then
    _pcell="$g"
    return 0
  fi
  label="#$2"
  case "$1" in
    FAILURE|ERROR) label=$'\033[4m'"#$2"$'\033[24m' ;;
  esac
  if [ -n "${3:-}" ]; then
    osc8_link "$3" "$label"
    _pcell="$g $_osc8"
  else
    _pcell="$g $label"
  fi
}

glyph_merge() { # <mergeStateStatus|FOLLOW|MERGED> -> one column, blank when nothing to flag
  case "$1" in
    BEHIND)          printf '\033[33m↓\033[0m' ;;
    DIRTY)           printf '\033[31m⚠\033[0m' ;;
    BLOCKED)         printf '\033[33m⊘\033[0m' ;;
    FOLLOW)          printf '\033[36m→\033[0m' ;;  # riding tip→prod after merge
    MERGED)          printf '\033[2m·\033[0m' ;;  # merged, follow cleared — fade
    *)               printf ' ' ;;
  esac
}

glyph_review() { # <approved|changes|waiting|commented|noreviewers|merged|none|N> -> one column
  case "$1" in
    approved)     printf '\033[32m✓\033[0m' ;;
    changes)      printf '\033[31m!\033[0m' ;;
    waiting)      printf '\033[33m…\033[0m' ;;          # reviewers assigned, silent
    commented)    printf '\033[33m✎\033[0m' ;;          # reviewer participated, not approved
    # Dim red ◌ rather than the bold ⚠ merge conflicts use — a PR simply
    # missing reviewers is not the same emergency as one that cannot merge,
    # and sharing the glyph made the eye stop at the wrong column first.
    noreviewers)  printf '\033[2;31m◌\033[0m' ;;       # ready-for-review with nobody assigned
    merged)       printf '\033[2m·\033[0m' ;;
    none|'')      printf ' ' ;;
    *)            printf '\033[33m%s\033[0m' "$1" ;;   # unresolved comment count (GH)
  esac
}

# Dim yellow "◇ draft" for the PRS row — draft *state*, separate from the
# checks-slot D (which means CI was not triggered because of that draft).
# Fixed-width field in draw_prs_tty so glyphs share a column with/without it.
draft_tag() { # -> prints the PRS-section draft badge
  printf '\033[2;33m◇ draft\033[0m'
}
prs_w_draft=8


# Both write to a variable rather than stdout: cells end in padding, and
# command substitution would eat it.

fit() { # <text> <width> -> $_fit, exactly <width> columns (%-*s counts bytes)
  _fit="${1:0:$2}"
  if [ "${#_fit}" -lt "$2" ]; then
    printf -v _fit '%s%*s' "$_fit" $(( $2 - ${#_fit} )) ''
  fi
}

fit_ellipsis() { # <text> <width> -> $_fit; truncates with …, never wraps
  local text="$1" width="$2"
  if [ "$width" -le 0 ]; then _fit=""; return 0; fi
  if [ "${#text}" -le "$width" ]; then fit "$text" "$width"; return 0; fi
  if [ "$width" -eq 1 ]; then _fit="…"; return 0; fi
  fit "${text:0:$((width - 1))}…" "$width"
}

# There is no rule and no header to carry the eye across a row, so an empty cell
# holds a dim placeholder instead of whitespace: the columns are only legible as
# columns if every one of them puts something on every line.
dot_cell() { # <width> -> $_cell
  if [ "$1" -lt 1 ]; then _cell=""; return 0; fi
  printf -v _cell '%s%*s' $'\033[2m·\033[0m' $(( $1 - 1 )) ''
}

# Dirty tree only (±N). Clean worktree is the same dim · as empty cells.
# Ahead/behind are separate columns — unpushed commits are not "local dirt".
local_cell() { # <tree state> -> $_cell
  case "${1:-}" in
    clean|'') dot_cell $c_local ;;
    *) cell "$1" $c_local ;;
  esac
}

# Bare count, left-aligned with the ↑/↓ header and empty · cells. Width floors
# at one digit + one space and grows for larger counts.
count_cell() { # <count-or-empty> <width> -> $_cell
  local n="${1:-}" w="$2"
  if [ -n "$n" ] && [ "$n" != 0 ]; then
    printf -v _cell '%-*s' "$w" "$n"
    return 0
  fi
  dot_cell "$w"
}

ahead_cell() { # <ahead or ""> -> $_cell
  count_cell "${1:-}" "$c_ahead"
}

# PR / sync / builds / tree — shared by one-line and compact second line.
draw_detail_cells() {
  local pr_num="$1" pr_checks="$2" pr_merge="$3" pr_review="$4"
  local a_disp="$5" b_disp="$6" tip_checks="$7" tip_url="$8"
  local prod_checks="$9" prod_url="${10}" tree="${11}"
  local pr_draft="${12:-no}" pr_slug="${13:-}"
  local row="" term_x=0 checks_g

  if [ -n "$pr_num" ]; then
    # D only when forge said CI was skipped for draft — never force it just
    # because the PR is a draft (drafts can still run checks).
    checks_g="$(glyph_checks "$pr_checks")"
    pr_num_link "$pr_slug" "$pr_num"
    printf -v _cell '%s %s%s%s' "$_prlink" \
      "$checks_g" "$(glyph_merge "$pr_merge")" \
      "$(glyph_review "$pr_review")"
    pad=$((c_pr - (1 + ${#pr_num} + 1 + 3)))
    [ "$pad" -gt 0 ] && printf -v _cell '%s%*s' "$_cell" "$pad" ''
  else
    dot_cell $c_pr
  fi
  row="$_cell "
  # Without a header row the cells have to say what they are, so compact mode
  # keeps T/P markers inline; ↑/↓ counts stay bare (column position is enough).
  local lbl_tip="" lbl_prod=""
  if [ "$row_compact" = yes ]; then
    lbl_tip="T" lbl_prod="P"
  fi
  local_cell "$tree"; row="$row$_cell "
  if [ "$show_ahead" = yes ]; then
    ahead_cell "$a_disp"
    row="$row$_cell "
  fi
  if [ "$show_behind" = yes ]; then
    count_cell "$b_disp" "$c_behind"
    row="$row$_cell "
  fi
  build_glyph_cell "$tip_checks" "$tip_url"
  if [ "$show_tip" = yes ]; then
    if [ -n "$_bgcell" ]; then
      pad=$((c_tip - 1 - ${#lbl_tip})); [ "$pad" -lt 0 ] && pad=0
      printf -v _tipcell '%s%s%*s' $'\033[2m'"$lbl_tip"$'\033[0m' "$_bgcell" "$pad" ''
    else
      dot_cell $c_tip; _tipcell="$_cell"
    fi
    row="$row$_tipcell "
  fi
  build_glyph_cell "$prod_checks" "$prod_url"
  if [ "$show_prod" = yes ]; then
    if [ -n "$_bgcell" ]; then
      pad=$((c_prod - 1 - ${#lbl_prod})); [ "$pad" -lt 0 ] && pad=0
      printf -v _prodcell '%s%s%*s' $'\033[2m'"$lbl_prod"$'\033[0m' "$_bgcell" "$pad" ''
    else
      dot_cell $c_prod; _prodcell="$_cell"
    fi
    row="$row$_prodcell "
  fi
  _detail_row="${row% }"
  _detail_term_x=$term_x
}

cell() { # <text> <width> -> $_cell: <width> columns
  s="${1:0:$2}"
  pad=$(( $2 - ${#s} ))
  if [ "$pad" -gt 0 ]; then
    printf -v s '%s%*s' "$s" "$pad" ''
  fi
  _cell="$s"
}


load_snapshot() {
  snapshot_open
  layout
  ROWS=("")
  ROWKIND=("")
  TERMX=("")
  TIPURL=("")
  PRODURL=("")
  PROWS=("")
  CR_COLL=(); CR_DIR=(); CR_WT=(); CR_SLUG=(); CR_LABEL=()
  CR_BRANCH=(); CR_AHEAD=(); CR_BEHIND=(); CR_TREE=()
  CR_PR_NUM=(); CR_PR_CHECKS=(); CR_PR_MERGE=(); CR_PR_REVIEW=(); CR_PR_DRAFT=()
  CR_TIP_CHECKS=(); CR_TIP_URL=(); CR_PROD_CHECKS=(); CR_PROD_URL=()
  PR_ROW_REPO=(); PR_ROW_NUM=(); PR_ROW_CHECKS=(); PR_ROW_MERGE=()
  PR_ROW_REVIEW=(); PR_ROW_TITLE=(); PR_ROW_SLUG=(); PR_ROW_ARCHIVED=(); PR_ROW_DRAFT=()
  PR_ROW_ON_BRANCH=()
  _snapshot_stale=0
  _snapshot_prs_empty=no
  # Segments: fetch, forge round trips, row scan, then the PR section.
  _prog_n="$(_scope_worktree_count)"
  [ "$_prog_n" -gt 0 ] || _prog_n=1
  _prog_total=$((3 * _prog_n + 1))
  _prog_units=0
  progress_units 0

  if [ "$fetch" = yes ]; then
    _prog_i=0
    for c in "$ROOT"/*/; do
      c="${c%/}"
      [ -d "$c/harness" ] || continue
      if [ -n "$only" ] && [ "$(basename "$c")" != "$only" ]; then continue; fi
      for wt in "$c"/*/; do
        wt="${wt%/}"
        [ -e "$wt/.git" ] || continue
        fetch_if_stale "$(owner_of "$wt")" "$fetch_max_age" || true
        _prog_i=$((_prog_i + 1))
        progress_units "$_prog_i"
      done
    done
  fi
  progress_units "$_prog_n"

  mkdir -p "$PR_CACHE" "$PIPE_CACHE" 2>/dev/null || true
  _prog_jobs=0
  for c in "$ROOT"/*/; do
    c="${c%/}"
    [ -d "$c/harness" ] || continue
    cname="$(basename "$c")"
    if [ -n "$only" ] && [ "$cname" != "$only" ]; then continue; fi
    for wt in "$c"/*/; do
      wt="${wt%/}"
      [ -e "$wt/.git" ] || continue
      wrepo="$(basename "$wt")"; [ "$wrepo" = harness ] && wrepo="$(harness_repo)"
      wbranch="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || true)"
      wslug="$(slug_for_worktree "$wt" "$wrepo")"
      if [ -n "$wbranch" ] && [ -n "$wslug" ]; then
        if command -v bb >/dev/null 2>&1 || command -v gh >/dev/null 2>&1; then
          pr_fetch_bg "$wslug" "$wbranch"
          _prog_jobs=$((_prog_jobs + 1))
        fi
      fi
      if [ -n "$wslug" ] && [ "$(forge_for_slug "$wslug")" = bitbucket ]; then
        tip_br="$(default_ref_for "$wrepo")"; tip_br="${tip_br#origin/}"
        prod_br="$(production_ref_for "$wrepo")"; prod_br="${prod_br#origin/}"
        pipe_fetch_bg "$wslug" "$tip_br"
        _prog_jobs=$((_prog_jobs + 1))
        if [ "$prod_br" != "$tip_br" ]; then
          pipe_fetch_bg "$wslug" "$prod_br"
          _prog_jobs=$((_prog_jobs + 1))
        fi
      fi
    done
  done
  # The forge round trips run in parallel and dominate the wait, so count them
  # down as they land instead of blocking on a bare `wait` with a frozen bar.
  # They fill the segment between the fetch and the scan, however many there are.
  if [ -n "$_prog_file" ] && [ "$_prog_jobs" -gt 0 ]; then
    while :; do
      _prog_left="$(jobs -pr 2>/dev/null | wc -l | tr -d ' ')"
      case "$_prog_left" in ''|*[!0-9]*) _prog_left=0 ;; esac
      progress_units $(( _prog_n + (_prog_jobs - _prog_left) * _prog_n / _prog_jobs ))
      [ "$_prog_left" -gt 0 ] || break
      sleep 0.2
    done
  fi
  wait 2>/dev/null || true
  _prog_i=0
  progress_units $((2 * _prog_n))

  for c in "$ROOT"/*/; do
    c="${c%/}"
    [ -d "$c/harness" ] || continue
    cname="$(basename "$c")"
    if [ -n "$only" ] && [ "$cname" != "$only" ]; then continue; fi
    for wt in "$c"/*/; do
      wt="${wt%/}"
      [ -e "$wt/.git" ] || continue
      dir="$(basename "$wt")"
      repo="$dir"; [ "$dir" = harness ] && repo="$(harness_repo)"
      slug="$(slug_for_worktree "$wt" "$repo")"
      state="$(wt_head_state "$wt" "$repo")"
      kind="$(printf '%s' "$state" | awk '{print $1}')"
      label="$(printf '%s' "$state" | awk '{print $2}')"
      ahead="$(printf '%s' "$state" | awk '{print $3}')"
      behind="$(printf '%s' "$state" | awk '{print $4}')"
      changed="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
      branch_disp="$label"
      [ "$kind" = detached ] && branch_disp="⌂ $label"
      tree="clean"
      [ "$changed" != 0 ] && tree="±$changed"
      [ "$behind" != 0 ] && _snapshot_stale=$((_snapshot_stale + 1))

      pr_num=""; pr_checks=""; pr_merge=""; pr_review=""; pr_draft=no
      if [ "$kind" = branch ]; then
        enlisted="$(wtc_pr_enlisted_for "$cname" "$repo" "$label" | head -n1)"
        if [ -n "$enlisted" ]; then
          pr_num="${enlisted%%$'\t'*}"
          ent_title="${enlisted#*$'\t'}"
          tsv_from_cmd _n pr_state pr_checks pr_merge pr_review _ _ -- \
            wtc_pr_enrich "$repo" "$pr_num" "$ent_title" "$wt"
          case "$pr_state" in OPEN|DRAFT) ;; *) pr_num="" ;; esac
          [ "$pr_state" = DRAFT ] && pr_draft=yes
        else
          tsv_from_cmd pr_num pr_state pr_checks pr_merge pr_review _ -- \
            pr_facts "$slug" "$label"
          case "$pr_state" in OPEN|DRAFT) ;; *) pr_num="" ;; esac
          [ "$pr_state" = DRAFT ] && pr_draft=yes
        fi
      fi

      tip_br=""; tip_checks=""; tip_build=""; tip_url=""
      prod_br=""; prod_checks=""; prod_build=""; prod_url=""
      if [ -n "$slug" ] && [ "$(forge_for_slug "$slug")" = bitbucket ]; then
        tip_ref="$(default_ref_for "$repo")"
        tip_br="${tip_ref#origin/}"
        prod_ref="$(production_ref_for "$repo")"
        prod_br="${prod_ref#origin/}"
        tsv_from_cmd tip_build tip_checks _ tip_url -- pipe_facts "$slug" "$tip_br"
        if [ "$prod_br" != "$tip_br" ]; then
          tsv_from_cmd prod_build prod_checks _ prod_url -- pipe_facts "$slug" "$prod_br"
        else
          prod_br=""
        fi
      fi

      python3 - >> "$_snapshot_ndjson" <<PY
import json
print(json.dumps({
  "kind": "repo",
  "collection": $(_json_str "$cname"),
  "dir": $(_json_str "$dir"),
  "repo": $(_json_str "$repo"),
  "worktree": $(_json_str "$wt"),
  "slug": $(_json_str "$slug"),
  "branch_kind": $(_json_str "$kind"),
  "branch": $(_json_str "$label"),
  "branch_display": $(_json_str "$branch_disp"),
  "ahead": int(${ahead:-0}),
  "behind": int(${behind:-0}),
  "tree": $(_json_str "$tree"),
  "changed": int(${changed:-0}),
  "pr_number": $(_json_str "$pr_num"),
  "pr_checks": $(_json_str "$pr_checks"),
  "pr_merge": $(_json_str "$pr_merge"),
  "pr_review": $(_json_str "$pr_review"),
  "pr_draft": $( [ "$pr_draft" = yes ] && echo True || echo False ),
  "tip_branch": $(_json_str "$tip_br"),
  "tip_checks": $(_json_str "$tip_checks"),
  "tip_build": $(_json_str "$tip_build"),
  "tip_url": $(_json_str "$tip_url"),
  "prod_branch": $(_json_str "$prod_br"),
  "prod_checks": $(_json_str "$prod_checks"),
  "prod_build": $(_json_str "$prod_build"),
  "prod_url": $(_json_str "$prod_url"),
}))
PY
      CR_COLL+=("$cname")
      CR_DIR+=("$dir")
      CR_WT+=("$wt")
      CR_SLUG+=("$slug")
      CR_LABEL+=("$label")
      CR_BRANCH+=("$branch_disp")
      CR_AHEAD+=("$ahead")
      CR_BEHIND+=("$behind")
      CR_TREE+=("$tree")
      CR_PR_NUM+=("$pr_num")
      CR_PR_CHECKS+=("$pr_checks")
      CR_PR_MERGE+=("$pr_merge")
      CR_PR_REVIEW+=("$pr_review")
      CR_PR_DRAFT+=("$pr_draft")
      CR_TIP_CHECKS+=("$tip_checks")
      CR_TIP_URL+=("$tip_url")
      CR_PROD_CHECKS+=("$prod_checks")
      CR_PROD_URL+=("$prod_url")
      _prog_i=$((_prog_i + 1))
      progress_units $((2 * _prog_n + _prog_i))
    done
  done

  if [ -n "$only" ]; then
    progress_units $((3 * _prog_n))
    rows="$(wtc_pr_list "$only" 2>/dev/null || true)"
    orphans=""
    open_keys=""
    orphan_covered=""  # " repo|branch " covered by a listed merged PR still on-branch
    while IFS=$'\t' read -r repo num checks merge review title archived merged_on draft; do
      [ -n "$num" ] || continue
      case "$merge" in FOLLOW|MERGED) continue ;; esac
      br=""
      while IFS=$'\t' read -r r n b url t; do
        [ "$r" = "$repo" ] && [ "$n" = "$num" ] && br="$b"
      done <<EOF
$(wtc_pr_enlist_rows "$only")
EOF
      [ -n "$br" ] && open_keys="$open_keys $repo|$br "
    done <<EOF
$rows
EOF

    if [ -n "$rows" ]; then
      while IFS=$'\t' read -r repo num checks merge review title archived merged_on draft; do
        [ -n "$num" ] || continue
        IFS=$'\t' read -r slug forge <<EOF
$(repo_slug_and_forge "$repo" "$(wtc_repo_worktree "$only" "$repo")")
EOF
        owner="${slug%%/*}"; nm="${slug#*/}"
        pr_url="$(pr_url_for "$slug" "$forge" "$num")"
        follow_tip=""; follow_prod=""
        on_branch=no
        enlist_br=""
        while IFS=$'\t' read -r r n b url t; do
          [ "$r" = "$repo" ] && [ "$n" = "$num" ] && enlist_br="$b"
        done <<EOF
$(wtc_pr_enlist_rows "$only")
EOF
        wt="$(wtc_repo_worktree "$only" "$repo")"
        if [ -n "$enlist_br" ] && [ -d "$wt" ]; then
          cur="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || true)"
          if [ "$cur" = "$enlist_br" ]; then
            case "$merge" in
              FOLLOW|MERGED)
                on_branch=yes
                archived=no  # catch-up needed — keep out of the quiet archive
                orphan_covered="$orphan_covered $(basename "$wt")|$enlist_br "
                ;;
            esac
          fi
        fi
        if [ "$merge" = FOLLOW ]; then
          tip_b="$(default_ref_for "$repo")"; tip_b="${tip_b#origin/}"
          prod_b="$(production_ref_for "$repo")"; prod_b="${prod_b#origin/}"
          tsv_from_cmd tb tc _ tu -- pipe_facts "$slug" "$tip_b"
          follow_tip="#${tb:-?}"
          case "$tc" in FAILURE|ERROR) follow_tip="#${tb:-?}" ;; esac
          if [ "$prod_b" != "$tip_b" ]; then
            tsv_from_cmd pb pc _ pu -- pipe_facts "$slug" "$prod_b"
            follow_prod="#${pb:-?}"
          fi
        fi
        disp_title="$title"
        if [ "$on_branch" = yes ]; then
          disp_title="MERGED — still on $enlist_br; catch-up  ${title}"
        elif [ "$merge" = FOLLOW ]; then
          # Plain tip/prod labels only — OSC-8 in PRS titles was byte-truncated and
          # left open hyperlinks that ate the next rows and the footer.
          tip_b="$(default_ref_for "$repo")"; tip_b="${tip_b#origin/}"
          prod_b="$(production_ref_for "$repo")"; prod_b="${prod_b#origin/}"
          tsv_from_cmd tb tc _ tu -- pipe_facts "$slug" "$tip_b"
          tip_plain="tip:#${tb:-?}"
          if [ "$prod_b" = "$tip_b" ]; then
            disp_title="${tip_plain}  ${title}"
          else
            tsv_from_cmd pb pc _ pu -- pipe_facts "$slug" "$prod_b"
            disp_title="${tip_plain} prod:#${pb:-?}  ${title}"
          fi
        fi
        if [ "$draft" = yes ] || [ "$checks" = draft ]; then draft=yes; fi
        python3 - >> "$_snapshot_ndjson" <<PY
import json
print(json.dumps({
  "kind": "pr",
  "repo": $(_json_str "$repo"),
  "number": $(_json_str "$num"),
  "checks": $(_json_str "$checks"),
  "merge": $(_json_str "$merge"),
  "review": $(_json_str "$review"),
  "title": $(_json_str "$title"),
  "display_title": $(_json_str "$disp_title"),
  "slug": $(_json_str "$slug"),
  "url": $(_json_str "$pr_url"),
  "follow_tip_build": $(_json_str "$follow_tip"),
  "follow_prod_build": $(_json_str "$follow_prod"),
  "archived": $( [ "$archived" = yes ] && echo True || echo False ),
  "merged_on": $(_json_str "$merged_on"),
  "draft": $( [ "$draft" = yes ] && echo True || echo False ),
  "on_branch": $( [ "$on_branch" = yes ] && echo True || echo False ),
}))
PY
        PR_ROW_REPO+=("$repo")
        PR_ROW_NUM+=("$num")
        PR_ROW_CHECKS+=("$checks")
        PR_ROW_MERGE+=("$merge")
        PR_ROW_REVIEW+=("$review")
        PR_ROW_TITLE+=("$disp_title")
        PR_ROW_SLUG+=("$slug")
        PR_ROW_ARCHIVED+=("$archived")
        PR_ROW_DRAFT+=("$draft")
        PR_ROW_ON_BRANCH+=("$on_branch")
      done <<EOF
$rows
EOF
    fi

    # Orphans after PR rows so on-branch merged PRs can suppress the duplicate.
    while IFS=$'\t' read -r repo num branch url title; do
      [ -n "$num" ] || continue
      [ -n "$branch" ] || continue
      case " $open_keys " in *" $repo|$branch "*) continue ;; esac
      wt="$ROOT/$only/$repo"
      [ "$repo" = "$(harness_repo)" ] && wt="$ROOT/$only/harness"
      [ "$repo" = harness ] && wt="$ROOT/$only/harness"
      [ -d "$wt" ] || continue
      cur="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || true)"
      [ "$cur" = "$branch" ] || continue
      case " $orphan_covered " in
        *" $(basename "$wt")|$branch "*) continue ;;
      esac
      tsv_from_cmd _prnum ostate _checks _merge _review _title _mc -- \
        wtc_pr_enrich "$repo" "$num" "$title" "$wt"
      case "$ostate" in
        MERGED|CLOSED|DECLINED|SUPERSEDED)
          orphans="$orphans$(basename "$wt")	$branch	$ostate
"
          python3 - >> "$_snapshot_ndjson" <<PY
import json
print(json.dumps({
  "kind": "orphan",
  "repo": $(_json_str "$(basename "$wt")"),
  "branch": $(_json_str "$branch"),
  "state": $(_json_str "$ostate"),
}))
PY
          ;;
      esac
    done <<EOF
$(wtc_pr_enlist_rows "$only")
EOF

    if [ -z "$rows" ] && [ -z "$orphans" ]; then
      f="$(wtc_prs_file "$only")"
      [ -f "$f" ] || _snapshot_prs_empty=yes
    fi
    SNAPSHOT_PRS_ROWS="$rows"
    SNAPSHOT_PRS_ORPHANS="$orphans"
  fi

  meta_coll="${only:-}"
  [ "$all" = yes ] && meta_coll=""
  python3 - >> "$_snapshot_ndjson" <<PY
import json
print(json.dumps({
  "kind": "meta",
  "collection": $(_json_str "$meta_coll"),
  "show_collection_column": $( [ "$show_coll" = yes ] && echo True || echo False ),
  "stale_count": $_snapshot_stale,
  "prs_empty_hint": $( [ "$_snapshot_prs_empty" = yes ] && echo True || echo False ),
}))
PY

  write_snapshot_files
  _snapshot_epoch="$(date +%s)"
  snapshot_loaded=yes
  progress_units "$_prog_total"
  return 0
}

cache_procs() {
  saved_frame="$_frame"
  saved_buf="$_frame_buf"
  saved_line=$line
  _frame=""
  _frame_buf=yes
  line=0
  procs_table
  _procs_cached="$_frame"
  _frame="$saved_frame"
  _frame_buf="$saved_buf"
  line=$saved_line
}


draw_repo_row_compact() {
  local repo_name="$1" branch="$2" wt="$3" slug="$4" label="$5"
  local pr_num="$6" pr_checks="$7" pr_merge="$8" pr_review="$9"
  local ahead="${10}" behind="${11}" tree="${12}"
  local tip_checks="${13}" tip_url="${14}" prod_checks="${15}" prod_url="${16}"
  local a_disp="" b_disp="" pad="" row=""

  [ "$ahead" != 0 ] && a_disp="$ahead"
  [ "$behind" != 0 ] && b_disp="$behind"

  # Line 1: repo (fixed width) then branch — same start every row, ellipsis to EOL.
  cell "$repo_name" $c_repo
  row="$_cell "
  fit_ellipsis "$branch" "$c_branch_vis"
  out "${row}${_fit}"
  ROWS[$line]="$wt|$slug|$label|$pr_num"
  ROWKIND[$line]=id
  TERMX[$line]=0
  TIPURL[$line]=""
  PRODURL[$line]=""

  # Line 2: a dim corner ties the subline to the repo above it, then the detail
  # columns at fixed positions so they line up down the whole table.
  draw_detail_cells "$pr_num" "$pr_checks" "$pr_merge" "$pr_review" \
    "$a_disp" "$b_disp" "$tip_checks" "$tip_url" "$prod_checks" "$prod_url" "$tree" \
    "${17:-no}" "$slug"
  printf -v row '%s%*s%s' $'\033[2m└\033[0m' $((_detail_indent - 1)) '' "$_detail_row"
  out "$row"
  ROWS[$line]="$wt|$slug|$label|$pr_num"
  ROWKIND[$line]=detail
  TERMX[$line]=$_detail_term_x
  TIPURL[$line]="${tip_url:-}"
  PRODURL[$line]="${prod_url:-}"
}

draw_repos_tty() {
  layout
  # Compact rows label themselves, so they skip the header entirely.
  if [ "$row_compact" != yes ]; then
    hdr=""
    if [ "$show_coll" = yes ]; then
      fit COLLECTION $c_coll; hdr="$_fit "
    fi
    fit REPO $c_repo;       hdr="$hdr$_fit "
    fit BRANCH $c_branch;   hdr="$hdr$_fit "
    fit PR $c_pr;           hdr="$hdr$_fit "
    fit "±" $c_local;       hdr="$hdr$_fit "
    if [ "$show_ahead" = yes ]; then fit "↑" $c_ahead; hdr="$hdr$_fit "; fi
    if [ "$show_behind" = yes ]; then fit "↓" $c_behind; hdr="$hdr$_fit "; fi
    if [ "$show_tip" = yes ]; then fit "T" $c_tip; hdr="$hdr$_fit "; fi
    if [ "$show_prod" = yes ]; then fit "P" $c_prod; hdr="$hdr$_fit "; fi
    out $'\033[1m'"${hdr% }"$'\033[0m'
  fi

  i=0
  while [ "$i" -lt "${#CR_WT[@]}" ]; do
    name="${CR_COLL[$i]:-}"
    dir="${CR_DIR[$i]:-}"
    wt="${CR_WT[$i]:-}"
    slug="${CR_SLUG[$i]:-}"
    label="${CR_LABEL[$i]:-}"
    branch="${CR_BRANCH[$i]:-}"
    ahead="${CR_AHEAD[$i]:-0}"
    behind="${CR_BEHIND[$i]:-0}"
    tree="${CR_TREE[$i]:-clean}"
    pr_num="${CR_PR_NUM[$i]:-}"
    pr_checks="${CR_PR_CHECKS[$i]:-}"
    pr_merge="${CR_PR_MERGE[$i]:-}"
    pr_review="${CR_PR_REVIEW[$i]:-}"
    pr_draft="${CR_PR_DRAFT[$i]:-no}"
    tip_checks="${CR_TIP_CHECKS[$i]:-}"
    tip_url="${CR_TIP_URL[$i]:-}"
    prod_checks="${CR_PROD_CHECKS[$i]:-}"
    prod_url="${CR_PROD_URL[$i]:-}"
    repo_name="${dir#${WTC_REPO_PREFIX:-}}"

    if [ "$row_compact" = yes ]; then
      draw_repo_row_compact "$repo_name" "$branch" "$wt" "$slug" "$label" \
        "$pr_num" "$pr_checks" "$pr_merge" "$pr_review" \
        "$ahead" "$behind" "$tree" \
        "$tip_checks" "$tip_url" "$prod_checks" "$prod_url" "$pr_draft"
      i=$((i + 1))
      continue
    fi

    a_disp=""; [ "$ahead" != 0 ] && a_disp="$ahead"
    b_disp=""; [ "$behind" != 0 ] && b_disp="$behind"

    row=""
    if [ "$show_coll" = yes ]; then fit "$name" $c_coll; row="$_fit "; fi
    cell "$repo_name" $c_repo; row="$row$_cell "
    fit_ellipsis "$branch" $c_branch; row="$row$_fit "
    draw_detail_cells "$pr_num" "$pr_checks" "$pr_merge" "$pr_review" \
      "$a_disp" "$b_disp" "$tip_checks" "$tip_url" "$prod_checks" "$prod_url" "$tree" \
      "$pr_draft" "$slug"
    row="${row}${_detail_row}"
    out "$row"
    ROWS[$line]="$wt|$slug|$label|$pr_num"
    ROWKIND[$line]=wide
    TERMX[$line]=$_detail_term_x
    TIPURL[$line]="${tip_url:-}"
    PRODURL[$line]="${prod_url:-}"
    i=$((i + 1))
  done
  return 0
}

draw_prs_tty() {
  [ -n "$only" ] || return 0
  orphans="${SNAPSHOT_PRS_ORPHANS:-}"
  pr_count="${#PR_ROW_NUM[@]}"

  [ "$pr_count" -gt 0 ] || [ -n "$orphans" ] || return 0

  # Split active vs archived (merged past 48 weekday-hours).
  local active_n=0 archived_n=0 i
  i=0
  while [ "$i" -lt "$pr_count" ]; do
    if [ "${PR_ROW_ARCHIVED[$i]:-no}" = yes ]; then
      archived_n=$((archived_n + 1))
    else
      active_n=$((active_n + 1))
    fi
    i=$((i + 1))
  done

  out ""
  if [ "$active_n" -gt 0 ] || [ "$archived_n" -gt 0 ]; then
    out $'\033[1m'"PRS"$'\033[0m'
  fi

  _draw_pr_row() { # <index> [archived]
    local idx="$1" as_archived="${2:-no}"
    local repo num checks merge review title slug draft on_branch faded prow room tag show
    repo="${PR_ROW_REPO[$idx]:-}"
    num="${PR_ROW_NUM[$idx]:-}"
    checks="${PR_ROW_CHECKS[$idx]:-}"
    merge="${PR_ROW_MERGE[$idx]:-}"
    review="${PR_ROW_REVIEW[$idx]:-}"
    title="${PR_ROW_TITLE[$idx]:-}"
    slug="${PR_ROW_SLUG[$idx]:-}"
    draft="${PR_ROW_DRAFT[$idx]:-no}"
    on_branch="${PR_ROW_ON_BRANCH[$idx]:-no}"
    [ -n "$num" ] || return 0
    fit "$repo" $c_repo
    room=$((cols - prs_x_num - prs_w_num - c_repo - 16))
    [ "$room" -ge 10 ] || room=10
    # Visible-width truncate (CSI/OSC-safe). Never bash-slice a title that might
    # still contain escapes — that left open OSC-8 links and glued the footer in.
    show="$(python3 "$ANSI_PY" fit "$room" <<< "$title")"
    if [ "$on_branch" = yes ]; then
      # Same amber as the orphan warning — merged but still checked out.
      printf -v prow '  ⚠ #%s%*s%s  %s' \
        "$num" $((prs_w_num - 1 - ${#num})) '' "$_fit" "$show"
      out $'\033[33m'"$prow"$'\033[0m'
    elif [ "$as_archived" = yes ]; then
      printf -v prow '  #%s%*s%s  %s' \
        "$num" $((prs_w_num - 1 - ${#num})) '' "$_fit" "$show"
      out $'\033[2m'"$prow"$'\033[0m'
    else
      case "$merge" in
        FOLLOW|MERGED) faded=yes ;;
        *) faded=no ;;
      esac
      if [ "$faded" = yes ]; then
        # Soft dim — quiet vs open PRs, still readable (was 238 near-invisible).
        printf -v prow '  #%s%*s%s  %s' \
          "$num" $((prs_w_num - 1 - ${#num})) '' "$_fit" "$show"
        out $'\033[2m'"$prow"$'\033[0m'
      else
        # Fixed-width draft field so checks/merge/review line up across rows.
        # Badge = draft state; D in checks = CI skipped because of draft.
        # When both would say the same thing, keep the badge and use · for
        # the checks slot so the row is not DRAFT + D.
        tag="$(printf '%*s' "$prs_w_draft" '')"
        checks_for_glyph="$checks"
        if [ "$draft" = yes ] || [ "$checks" = draft ]; then
          _dt="$(draft_tag)"
          ansi_vislen "$_dt"
          _pad=$((prs_w_draft - _vlen))
          [ "$_pad" -lt 0 ] && _pad=0
          printf -v tag '%s%*s' "$_dt" "$_pad" ''
          [ "$checks" = draft ] && checks_for_glyph=NONE
        fi
        pr_num_link "$slug" "$num"
        printf -v prow '  %s%*s%s %s%s%s%s  %s' \
          "$_prlink" $((prs_w_num - 1 - ${#num})) '' "$_fit" \
          "$tag" \
          "$(glyph_checks "$checks_for_glyph")" "$(glyph_merge "$merge")" "$(glyph_review "$review")" \
          "$show"
        out "$prow"
      fi
    fi
    PROWS[$line]="$slug|$num"
  }

  i=0
  while [ "$i" -lt "$pr_count" ]; do
    [ "${PR_ROW_ARCHIVED[$i]:-no}" = yes ] || _draw_pr_row "$i"
    i=$((i + 1))
  done

  if [ "$archived_n" -gt 0 ]; then
    if [ "$show_archived" = yes ]; then
      out $'\033[2m'"ARCHIVED"$'\033[0m'
      i=0
      while [ "$i" -lt "$pr_count" ]; do
        if [ "${PR_ROW_ARCHIVED[$i]:-no}" = yes ]; then
          _draw_pr_row "$i" yes
        fi
        i=$((i + 1))
      done
      out $'\033[2m'"▸ archived · a to hide"$'\033[0m'
    else
      out $'\033[2m'"▸ archived ($archived_n) · a to show"$'\033[0m'
    fi
  fi

  if [ -n "$orphans" ]; then
    while IFS=$'\t' read -r repo branch state; do
      [ -n "$repo" ] || continue
      fit "  ⚠ $repo on $branch — PR $state; catch-up returns it to the tip" "$cols"
      out $'\033[33m'"$_fit"$'\033[0m'
    done <<EOF
$orphans
EOF
  fi
  return 0
}

# A legend you have read is clutter, so the permanent footer is one short
# line and the reference is a keypress away. Cramming both a click map and
# three icon scales into two dim lines made the table end in a wall of text
# nobody reads twice.
legend() {
  local hint="" foot
  if [ "$_snapshot_stale" -gt 0 ] && [ "$row_compact" = yes ]; then
    hint="↓$_snapshot_stale · "
  fi
  foot="$(status_keys_footer)"
  out $'\033[2m'"${hint}${foot}"$'\033[0m'
}

_on_winch() { _redraw_only=yes; }

watch_setup() {
  _last_cols=0
  trap _on_winch WINCH
}

# Resize (or any WINCH): full redraw on the next watch_loop turn.

help_block() {
  d=$'\033[2m'; z=$'\033[0m'; k=$'\033[1m'
  out ""
  out "${k}KEYS${z}    ${d}?${z} this list   ${d}a${z} archived   ${d}r${z} refresh   ${d}q${z} quit"
  out "${k}CLICK${z}   ${d}#n${z} forge PR (⌘-click / OSC-8)   ${d}T / P${z} pipeline (when shown)"
  out "${k}DRAG${z}    ${d}select text as usual${z} — a click that moves is a selection, not a click"
  out ""
  out "${k}±${z}       ${d}±N${z} files not committed   $(printf '\033[2m·\033[0m') clean worktree"
  out "${k}AHEAD${z}   ${d}N${z} under ↑ — commits on this branch not pushed"
  out "${k}BEHIND${z}  ${d}N${z} under ↓ — commits on remote not in this worktree — catch-up territory"
  out "${k}CHECKS${z}  $(glyph_checks SUCCESS) passing   $(glyph_checks FAILURE) failing   $(glyph_checks PENDING) running   $(glyph_checks draft) CI skipped (draft)   $(glyph_checks NONE) none"
  out "${k}MERGE${z}   $(glyph_merge BEHIND) behind base   $(glyph_merge DIRTY) conflict   $(glyph_merge BLOCKED) blocked   $(glyph_merge FOLLOW) post-merge tip→prod   ${d}blank${z} clean"
  out "${k}REVIEW${z}  $(glyph_review approved) approved   $(glyph_review changes) changes   $(glyph_review commented) commented   $(glyph_review waiting) waiting   $(glyph_review noreviewers) no reviewers   $(glyph_review 3) unresolved threads"
  out "${k}DRAFT${z}   $(draft_tag) in PRS — reviewers optional; D in the PR cell only when CI did not run because of it"
  out "${k}MERGED${z}  soft-dim while following tip→prod; still on that branch → amber ⚠ (catch-up); after 48 weekday-hours → ${d}a${z} archived"
  out "${k}PIPE${z}    TIP = default_ref pipeline; PROD = production_ref when different. Glyphs link to Bitbucket (⌘-click / OSC-8)."
}

procs_table() {
  root_pid="$(pgrep -f "herdr --session $(herdr_session_name) server" 2>/dev/null | head -n1 || true)"
  if [ -z "$root_pid" ]; then
    out "(no herdr session server running)"
    return 0
  fi
  printf -v hdr '\033[1m%7s %6s %6s %9s  %s\033[0m' PID %CPU %MEM RSS COMMAND
  out "$hdr"
  ps -axo pid=,ppid=,pcpu=,pmem=,rss=,args= | awk -v root="$root_pid" '
    { pid[NR]=$1; ppid[NR]=$2; cpu[NR]=$3; mem[NR]=$4; rss[NR]=$5
      a=""; for (i=6; i<=NF; i++) a=a (i>6?" ":"") $i; args[NR]=substr(a,1,58); n=NR }
    END {
      keep[root]=1
      do { more=0
           for (i=1; i<=n; i++) if (!keep[pid[i]] && keep[ppid[i]]) { keep[pid[i]]=1; more=1 }
      } while (more)
      for (i=1; i<=n; i++)
        if (keep[pid[i]] && pid[i] != root)
          printf "%7s %6s %6s %8.0fM  %s\n", pid[i], cpu[i], mem[i], rss[i]/1024, args[i]
    }' | sort -k2 -nr
}

render() {
  if [ "$format" != ansi ]; then
    [ "$snapshot_loaded" = yes ] || load_snapshot
    emit_snapshot_output
    return 0
  fi
  draw_tty
  return 0
}

draw_tty() {
  [ "$snapshot_loaded" = yes ] || return 0
  layout
  line=0
  _frame_buf=yes
  _frame=""
  draw_title_bar
  case "$want" in
    repos) draw_repos_tty; draw_prs_tty ;;
    procs)
      if [ -n "$_procs_cached" ]; then
        _frame="$_procs_cached"
        line=$(printf '%s' "$_procs_cached" | awk 'END{print NR+0}')
      else
        procs_table
      fi
      ;;
    both)
      draw_repos_tty
      draw_prs_tty
      out ""
      if [ -n "$_procs_cached" ]; then
        _frame="${_frame}${_procs_cached}"
        line=$((line + $(printf '%s' "$_procs_cached" | awk 'END{print NR+0}')))
      else
        procs_table
      fi
      ;;
  esac
  if [ "$click" = yes ] || [ "$watch" = yes ]; then
    if [ "$show_help" = yes ]; then help_block; else legend; fi
  fi
  flush_frame
  _frame_buf=no
  return 0
}

# --- clicking ---------------------------------------------------------------
# Mouse reports only; output processing stays on (-icanon, not raw) so the
# table still prints with normal line endings. Clicks open forge PR pages
# (#n — Bitbucket or GitHub) and Bitbucket pipeline results (T/P) when those
# columns are shown. PR numbers are also OSC-8 hyperlinks.

mouse_on()  { printf '\033[?1000h\033[?1006h\033[?25l'; }  # button events, SGR, no cursor
mouse_off() { printf '\033[?1006l\033[?1000l\033[?25h'; }

tty_setup() {
  tty_saved="$(stty -g)"
  trap tty_restore EXIT
  trap 'exit 0' INT TERM
  stty -icanon -echo min 1 time 0
  mouse_on
}

tty_restore() {
  mouse_off
  [ -n "${tty_saved:-}" ] && stty "$tty_saved" 2>/dev/null || true
}

on_click() { # <button>;<column>;<line> from an SGR mouse report
  btn="${1%%;*}"; rest="${1#*;}"; x="${rest%%;*}"; y="${rest##*;}"
  [ "$btn" = 0 ] || return 0
  case "$x$y" in *[!0-9]*) return 0 ;; esac
  pentry="${PROWS[$y]:-}"
  if [ -n "$pentry" ]; then
    pslug="${pentry%%|*}"; pnum="${pentry##*|}"
    [ -n "$pnum" ] || return 0
    open_pr_web "$pslug" "$pnum"
    return 0
  fi
  entry="${ROWS[$y]:-}"
  tip_url="${TIPURL[$y]:-}"
  prod_url="${PRODURL[$y]:-}"
  if [ "$show_tip" = yes ] && [ -n "$tip_url" ] \
     && [ "$x" -ge "$col_tip" ] && [ "$x" -lt $((col_tip + c_tip)) ]; then
    (open "$tip_url" >/dev/null 2>&1 || xdg-open "$tip_url" >/dev/null 2>&1 || true) &
    return 0
  fi
  if [ "$show_prod" = yes ] && [ -n "$prod_url" ] \
     && [ "$x" -ge "$col_prod" ] && [ "$x" -lt $((col_prod + c_prod)) ]; then
    (open "$prod_url" >/dev/null 2>&1 || xdg-open "$prod_url" >/dev/null 2>&1 || true) &
    return 0
  fi
  [ -n "$entry" ] || return 0
  rest="${entry#*|}"; slug="${rest%%|*}"; rest="${rest#*|}"
  pr_num="${rest##*|}"
  if [ -n "$pr_num" ] && [ "$x" -ge "$col_pr" ] && [ "$x" -lt $((col_pr + c_pr)) ]; then
    case "${ROWKIND[$y]:-wide}" in
      id) return 0 ;;
    esac
    open_pr_web "$slug" "$pr_num"
    return 0
  fi
}

# A click is a press and a release on the same cell, as everywhere else a
# pointer exists. Acting on the press meant a drag opened whatever it started
# on, so highlighting a branch name launched it. Mode 1000 asks for buttons and
# not motion, so the drag itself never reaches us: the terminal keeps it and
# makes the selection, and a release somewhere else is our cue to do nothing.
_press_btn="" _press_x=0 _press_y=0 _press_at=0
_mouse_held=no

read_mouse() { # after ESC: consume "[<b;x;y" then M (press) or m (release)
  IFS= read -r -s -n1 -t 1 ch || return 0
  [ "$ch" = '[' ] || return 0
  IFS= read -r -s -n1 -t 1 ch || return 0
  [ "$ch" = '<' ] || return 0
  seq=""
  while IFS= read -r -s -n1 -t 1 ch; do
    case "$ch" in
      M) mouse_press "$seq"; return 0 ;;
      m) mouse_release "$seq"; return 0 ;;
      *) seq="$seq$ch" ;;
    esac
  done
}

mouse_press() { # <button>;<column>;<line>
  _press_btn="${1%%;*}"; rest="${1#*;}"
  _press_x="${rest%%;*}"; _press_y="${rest##*;}"
  _press_at="$(date +%s)"
  _mouse_held=yes
}

mouse_release() { # <button>;<column>;<line>
  _mouse_held=no
  [ -n "$_press_btn" ] || return 0
  btn="${1%%;*}"; rest="${1#*;}"; x="${rest%%;*}"; y="${rest##*;}"
  same=no
  [ "$btn" = "$_press_btn" ] && [ "$x" = "$_press_x" ] && [ "$y" = "$_press_y" ] && same=yes
  _press_btn=""
  [ "$same" = yes ] || return 0
  on_click "$btn;$x;$y"
}

# The one thing a redraw must not interrupt. Clearing the screen under a drag
# takes the selection with it, so a held button holds the frame — bounded, in
# case the release is lost with the pointer outside the pane.
mouse_dragging() {
  [ "$_mouse_held" = yes ] || return 1
  [ $(( $(date +%s) - _press_at )) -lt 10 ]
}

wait_events() {
  _tick=0
  while [ "$_tick" -lt "$interval" ]; do
    # A pending redraw normally means "stop waiting and paint it", but not
    # while the button is down: leaving would spin here until the release.
    if [ "$_redraw_only" = yes ] && ! mouse_dragging; then return 0; fi
    if IFS= read -r -s -n1 -t 1 ch; then
      case "$ch" in
        q|Q) exit 0 ;;
        r|R) _refresh_pending=yes; return 0 ;;
        '?'|h|H) if [ "$show_help" = yes ]; then show_help=no; else show_help=yes; fi
                 _redraw_only=yes; return 0 ;;
        a|A) if [ "$show_archived" = yes ]; then show_archived=no; else show_archived=yes; fi
             _redraw_only=yes; return 0 ;;
        $'\033') read_mouse; return 0 ;;
      esac
    fi
    _tick=$((_tick + 1))
    # A finished refresh has to land on its own. Polling only between waits
    # meant the new table appeared when the next event arrived — so a pane
    # nobody touched kept the stale one for a whole interval, and a click
    # looked like what caused the repaint.
    if poll_refresh_complete; then
      _redraw_only=yes
      return 0
    fi
    update_status_clock
  done
  _refresh_pending=yes
}

trap snapshot_close EXIT

watch_loop() {
  while :; do
    if [ "$_refresh_pending" = yes ] && [ "$_refresh_active" != yes ]; then
      if [ "$snapshot_loaded" = yes ]; then
        start_refresh_bg
        _refresh_pending=no
      else
        do_refresh_sync
        draw_tty
      fi
    fi
    if poll_refresh_complete; then
      _redraw_only=yes
    fi
    if [ "$_redraw_only" = yes ] && ! mouse_dragging; then
      draw_tty
      _redraw_only=no
    fi
    wait_events
  done
}

wtc_status_main_oneshot() {
  if [ "$cached" = yes ]; then
    wtc_status_render_cached
    return $?
  fi
  if [ "$load_only" = yes ]; then
    load_snapshot
    python3 "$FORMAT_PY" --json < "$_snapshot_ndjson"
    return 0
  fi
  watch=no
  click=no
  case "$format" in
    auto)
      if [ -t 1 ] && [ "$want" != procs ]; then format=ansi
      else format=md
      fi
      ;;
  esac
  load_snapshot
  case "$format" in
    json|md) emit_snapshot_output ;;
    *) draw_tty ;;
  esac
}

# --cached: render the last snapshot without touching git or a forge — for
# fixture testing (a .wtc-status.json copied in from elsewhere) as much as
# for a quick look. .wtc-status.json is authoritative when present (same
# assembled shape load_snapshot itself writes); .last-wtc-status.yml is the
# fallback so a collection that only ever ran the boilerplate's own cache
# writer still has something to show.
wtc_status_render_cached() {
  [ -n "$only" ] || {
    echo "error: --cached reads one collection's snapshot; --all has none to read" >&2
    return 1
  }
  [ "$want" != procs ] || {
    echo "error: --cached has no process snapshot; it covers the repo table only" >&2
    return 1
  }
  case "$format" in
    auto) if [ -t 1 ]; then format=ansi; else format=md; fi ;;
  esac
  json_path="$ROOT/$only/.wtc-status.json"
  case "$format" in
    json)
      [ -f "$json_path" ] || { echo "error: no cached snapshot: $json_path" >&2; return 1; }
      cat "$json_path"
      return 0
      ;;
    md)
      md_path="$ROOT/$only/.wtc-status.md"
      [ -f "$md_path" ] || { echo "error: no cached snapshot: $md_path" >&2; return 1; }
      # Age line matches the ANSI title bar's "snapshot, Ns old" so tests and
      # humans can tell a --cached render from a live one without grepping JSON.
      age="$(file_age_secs "$json_path" 2>/dev/null || file_age_secs "$md_path")"
      printf '# %s (snapshot, %ss old)\n\n' "$only" "$age"
      # Drop the leading `# collection` heading from the cached md — we just
      # wrote a dated one.
      sed '1{/^# /d;}' "$md_path"
      return 0
      ;;
  esac
  watch=no
  click=no
  if apply_snapshot_from_json "$json_path" 2>/dev/null; then
    # Same age cue the legacy boiler put in the table header.
    _snapshot_epoch=$(( $(date +%s) - $(file_age_secs "$json_path") ))
    draw_tty
    return 0
  fi
  if wtc_status_render_cached_yml; then
    return 0
  fi
  echo "error: no snapshot for '$only' — run tools/wtc-status.sh without --cached first" >&2
  return 1
}

# The plain fallback when there is no .wtc-status.json to read: a bare TSV
# listing straight off .last-wtc-status.yml, with none of draw_tty's glyphs
# or click map — the yml cache does not carry enough (no review/merge detail
# per repo) to reconstruct those, and guessing would show something that
# looks exact but is not.
wtc_status_render_cached_yml() {
  local rows
  rows="$(wtc_status_cache_rows "$only")"
  [ -n "$rows" ] || return 1
  printf '%s — cached %ss old (.last-wtc-status.yml; no .wtc-status.json)\n' \
    "$only" "$(wtc_status_cache_age "$only")"
  printf '%-16s %-24s %-8s %-4s %-4s %s\n' REPO BRANCH PR AHEAD BEHIND TREE
  local repo branch head ahead behind tree pr forge state checks merge review title
  while IFS=$'\t' read -r repo branch head ahead behind tree pr forge state checks merge review title; do
    [ -n "$repo" ] || continue
    case "$branch" in -) branch="" ;; esac
    case "$pr" in -) pr="" ;; esac
    case "$ahead" in -) ahead=0 ;; esac
    case "$behind" in -) behind=0 ;; esac
    case "$tree" in -) tree="clean" ;; esac
    printf '%-16s %-24s %-8s %-4s %-4s %s\n' \
      "$repo" "$branch" "${pr:+#$pr}" "$ahead" "$behind" "$tree"
  done <<EOF
$rows
EOF
  return 0
}

wtc_status_main_tui() {
  watch=yes
  [ "$interval" = 0 ] && interval=60
  watch_setup

  # Stale-while-revalidate: show the on-disk snapshot immediately if we have one.
  if [ -n "$only" ] && [ -f "$ROOT/$only/.wtc-status.json" ]; then
    apply_snapshot_from_json 2>/dev/null || true
    if [ "$snapshot_loaded" = yes ]; then
      draw_tty
    fi
  fi

  _refresh_pending=yes
  if [ "$click" = yes ]; then
    tty_setup
    watch_loop
  else
    watch_loop
  fi
}
