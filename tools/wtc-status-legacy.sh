#!/usr/bin/env bash
# wtc-status-legacy.sh — boilerplate-native status of every collection, plus
# the processes running in them.
#
# Superseded as the wtc-status.sh / wtc-status-tui.sh pane by the Steep-ported
# implementation (wtc-status-common.sh et al, port/status-from-steep). Kept
# under this name, unwired from wtc-open.sh / retire.sh, so the two can be
# run side by side while that port is verified. Nothing here changed.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: tools/wtc-status.sh [--repos|--procs] [--tui [seconds]] [--no-click]
                          [--all | <collection>]

Prints once and exits. `--tui` is the live pane — redrawing, clickable, and
quit with q — and is also what tools/wtc-status-tui.sh runs. The mode is never
inferred from whether stdout is a terminal: one command must not loop for a
human and print once into a pipe. `--tui` without a terminal is an error, not
a silent downgrade. `--cached` renders the last snapshot
(<collection>/.last-wtc-status.yml) without touching git or a forge, and says
how old it is.

Prints per-collection branch / open PR + check rollup / working-tree state,
then the processes running under the herdr session (CPU, memory). Meant to
be left running in a pane — wtc-open.sh puts one in every wtc:

  tools/wtc-status.sh --repos --watch 120 <collection>
  tools/wtc-status.sh --procs --watch 5

  <collection>  another collection under the workspace root
  --all         every collection (default is this one)
  --repos       only the collection table (default: both)
  --procs       only the process table
  --watch       redraw every N seconds
  --no-watch    print once and exit
  --click       clickable rows even when stdin/stdout is not a terminal
  --no-click    plain table, no mouse capture
  --no-fetch    do not refresh remote refs first (offline, or a hot loop)
  --fetch-age   seconds a bare's last fetch may be before it is refreshed
                (default 300)

Scope is this collection unless --all or a name says otherwise, and defaults
for the flags above come from $WTC_CONFIG_ROOT/wtc.env (WTC_STATUS_REPOS /
_WATCH / _NO_CLICK) — so the bare command is already the one this machine
wants. Redirected output prints one pass: a watch loop nobody can quit is not
a status report.

BRANCH shows `⌂ <branch>` for a worktree detached at the development tip —
the resting state, and up to date unless a column says otherwise. ↑ and ↓ are
commits ahead of and behind the remote, blank when zero; any ↓ means a
catch-up will bring in remote changes. TREE carries ±changed files.

Scoped to one collection, a PRS section lists the pull requests enlisted for
it in <collection>/.wtc-prs (`tools/wtc-pr.sh enlist` — see the wtc-pr skill),
not a forge label search, so it costs no extra round trips beyond enriching
what is already listed. Open and draft PRs show live; a MERGED one fades
rather than disappearing, until it passes 48 weekday-hours since merge, at
which point it collapses behind the `a` (archived) toggle — the window is
48 weekday-hours, or WTC_PR_ARCHIVE_HOURS. A worktree still
sitting on a branch whose PR has already merged or closed is called out in
amber, since an open-PRs view would otherwise hide it.

The PR cell asks the worktree's own origin first and falls back to its
upstream, so a fork checkout whose PR is open against the repo it forked shows
`↗<n>` rather than blank.

On a terminal the collection table is clickable: REPO focuses that sibling
in the browse nvim, TREE opens its git status there (lazygit if nvim is not
up), the PR number opens the pull request on github.com, and ▣ opens it in
Octo in the browse pane. Each target does one thing and reports when it
cannot, rather than quietly doing the other. r redraws, a toggles archived
PRs, q quits.

`?` toggles a key and icon reference; the footer otherwise stays one line.

Clicking means the terminal never sees a drag, so its own text selection stops
working. `s` hands the mouse back and freezes the table until you press a key,
which is what lets you select and copy out of it. (Most terminals also have a
modifier that bypasses mouse reporting for one drag — Option in iTerm2, Shift
in many others — if you would rather not leave the table live.)
EOF
  exit "${1:-1}"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
. "$script_dir/lib.sh"
harness_lib_init
# Machine defaults first, flags on top: a changed default lives in the control
# root, not in every command line (instructions/secrets.md).
load_wtc_config

want=both
case "${WTC_STATUS_REPOS:-no}" in yes|1|true|TRUE) want=repos ;; esac
interval="${WTC_STATUS_WATCH:-60}"
case "$interval" in ''|*[!0-9]*) interval=60 ;; esac
# Mode is asked for, not inferred. This used to turn itself on whenever stdout
# was a terminal, so the same command looped forever for a human and printed
# once into a pipe — one invocation, two behaviours, decided by something the
# caller cannot see. `--tui` (or WTC_STATUS_TUI) is the live pane; the default
# is one pass, which is what a script, an agent, or a person reading a table
# actually wants.
watch=no
tui_asked=no   # on the command line specifically — see the tty guard below
case "${WTC_STATUS_TUI:-no}" in yes|1|true|TRUE) watch=yes ;; esac
click=auto
case "${WTC_STATUS_NO_CLICK:-no}" in yes|1|true|TRUE) click=no ;; esac
fetch=yes fetch_max_age=300 all=no only="" cached=no

while [ $# -gt 0 ]; do
  case "$1" in
    --repos) want=repos; shift ;;
    --procs) want=procs; shift ;;
    --all) all=yes; shift ;;
    # --tui is the name; --watch stays as its spelling with an interval, and
    # as what every existing pane command and doc already says.
    --cached) cached=yes; shift ;;
    --tui) watch=yes; tui_asked=yes; shift; case "${1:-}" in [0-9]*) interval="$1"; shift ;; esac ;;
    --watch) watch=yes; tui_asked=yes; shift; case "${1:-}" in [0-9]*) interval="$1"; shift ;; esac ;;
    --no-tui|--no-watch) watch=no; tui_asked=no; interval=0; shift ;;
    --click) click=yes; shift ;;
    --no-click) click=no; shift ;;
    --no-fetch) fetch=no; shift ;;
    --fetch-age) fetch_max_age="${2:?--fetch-age needs seconds}"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) only="$1"; shift ;;
  esac
done

# One numeric truth for the interval, before anything decides on it. `--watch`
# accepts anything starting with a digit and wtc.env accepts whatever is in it,
# so `00`, `007` and `0abc` all reach here — and `sleep` returns immediately for
# the first two and fails for the third, both inside a `while :` loop. 10# keeps
# a leading zero from being read as octal.
case "$interval" in
  ''|*[!0-9]*)
    echo "error: --watch / WTC_STATUS_WATCH wants a whole number of seconds: $interval" >&2
    exit 1 ;;
esac
interval=$((10#$interval))

# Collection-local by default; widening the view is always something you typed
# (instructions/collection-context.md).
if [ "$all" = yes ]; then
  [ -z "$only" ] || { echo "error: --all and a collection name are exclusive" >&2; exit 1; }
else
  [ -n "$only" ] || only="$(this_collection)"
  [ -d "$ROOT/$only/harness" ] \
    || { echo "error: $ROOT/$only is not a collection (no harness/)" >&2; exit 1; }
fi

# Scoped runs take the *target* collection's registry, not whichever harness
# worktree this script happened to be launched from. Opening collection B via
# A's tools (or a --watch that outlived A's retire) must still read B's tips.
if [ -n "$only" ]; then
  coll_harness="$ROOT/$only/harness"
  if [ -f "$coll_harness/.harness-repos.yml" ]; then
    HARNESS_DIR="$coll_harness"
    REGISTRY="$coll_harness/.harness-repos.yml"
    LOCAL_REPOS="$coll_harness/.harness-repos"
  fi
fi

# Clicking needs the collection table (that is what carries the cells) and a
# terminal on both ends: mouse reports come back in on stdin.
# Clicking needs the collection table (that is what carries the cells), a
# terminal on both ends (mouse reports come back in on stdin) — and a live
# table to click on. It follows the mode now instead of deciding it.
if [ "$click" = auto ]; then
  click=no
  if [ "$watch" = yes ] && [ "$want" != procs ] && [ -t 0 ] && [ -t 1 ]; then click=yes; fi
fi
# ...but an interval of 0 means "print once" — that is what --no-watch sets,
# what WTC_STATUS_WATCH=0 means, and what `--watch 0` asks for. It wins over
# anything that merely turned watching *on*, including the click rule above:
# the loop below is `render; sleep "$interval"`, so a zero interval is a busy
# loop re-fetching every bare as fast as the machine allows, and a table
# nobody redraws is not one worth capturing mouse reports for.
if [ "$interval" = 0 ]; then watch=no click=no; fi

# --cached reads one collection's snapshot, so it only means anything scoped to
# one. Unscoped it would print this collection's rows under a heading claiming
# every collection, with an empty COLLECTION column — a table that lies rather
# than one that is merely stale. And the snapshot holds repo rows only, so it
# selects that view rather than silently doing live work for the rest of a
# `both` render, which is what the flag exists to avoid.
if [ "$cached" = yes ]; then
  if [ "$all" = yes ]; then
    echo "error: --cached reads one collection's snapshot; --all has none to read" >&2
    exit 1
  fi
  case "$want" in
    procs)
      echo "error: --cached has no process snapshot; it covers the repo table only" >&2
      exit 1 ;;
    *) want=repos ;;
  esac
fi

# Asking for the TUI without a terminal is a request that cannot be honoured:
# the loop would redraw into a pipe forever and hang whatever is reading it.
# Refuse it rather than silently doing the other thing — the whole point of an
# explicit mode is that it does what it says or says why not.
if [ "$watch" = yes ] && { [ ! -t 1 ] || [ ! -t 0 ]; }; then
  if [ "$tui_asked" = yes ]; then
    echo "error: --tui needs a terminal on stdin and stdout; got a pipe" >&2
    exit 1
  fi
  # Reached only via the env var, which is set once and inherited by things
  # that legitimately capture output. Downgrade quietly there.
  watch=no click=no
fi

# Column widths are character counts, and the rollup glyphs (✓ ✗ ● — ↑ ±) are
# one column but several bytes — so the table needs a UTF-8 ctype to measure.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*) ;;
  *) export LC_CTYPE=en_US.UTF-8 ;;
esac

# One source of truth for the columns: the widths and the click map must not
# drift apart — and no row may wrap, or a click lands on the wrong worktree.
# BRANCH absorbs the terminal width; the status pane is a narrow one.
c_coll=22 c_repo=16 c_pr=12 c_ahead=4 c_behind=4 c_tree=8 c_branch=34
col_repo=0 col_pr=0 col_ahead=0 col_behind=0 col_tree=0
# Scoped to one collection, the COLLECTION column is a constant — spend those
# columns on branch names instead and name the collection above the table.
show_coll=yes; [ -n "$only" ] && show_coll=no
show_help=no   # ? toggles the key/icon reference; the footer stays one line
show_archived=no  # a toggles merged PRs past 48 weekday-hours

layout() { # recompute the columns for the terminal as it is now
  # stty asks the terminal itself; tput would believe an inherited $COLUMNS.
  cols="$(stty size 2>/dev/null | awk '{print $2}' || true)"
  [ -n "$cols" ] || cols="$(tput cols 2>/dev/null || true)"
  case "$cols" in ''|*[!0-9]*) cols=100 ;; esac
  [ "$cols" -ge 46 ] || cols=46
  c_repo=16
  # One gap between every pair of columns, plus 1 spare so nothing wraps.
  if [ "$show_coll" = yes ]; then c_coll=22; gaps=6; else c_coll=0; gaps=5; fi
  fixed=$((c_coll + c_repo + c_pr + c_ahead + c_behind + c_tree))
  c_branch=$((cols - fixed - gaps - 1))
  while [ "$c_branch" -lt 14 ] && [ "$c_coll" -gt 8 ]; do
    c_coll=$((c_coll - 1)); c_branch=$((c_branch + 1))
  done
  while [ "$c_branch" -lt 14 ] && [ "$c_repo" -gt 6 ]; do
    c_repo=$((c_repo - 1)); c_branch=$((c_branch + 1))
  done
  [ "$c_branch" -ge 6 ] || c_branch=6
  [ "$c_branch" -le 40 ] || c_branch=40   # a wide terminal is not a reason for a wide gap
  # 1-based screen columns, each one gap past the end of the previous cell.
  # Derived in a chain rather than summed per column: the click map and the
  # printed row then cannot drift apart.
  if [ "$show_coll" = yes ]; then col_repo=$((c_coll + 2)); else col_repo=1; fi
  col_branch=$((col_repo + c_repo + 1))
  col_pr=$((col_branch + c_branch + 1))
  col_ahead=$((col_pr + c_pr + 1))
  col_behind=$((col_ahead + c_ahead + 1))
  col_tree=$((col_behind + c_behind + 1))
}

ROWS=("")   # ROWS[<screen line>] = "<worktree>|<slug>|<branch>|<pr number>"
TERMX=("")  # TERMX[<screen line>] = screen column of that row's ▣ (terminal PR)
PROWS=("")  # PROWS[<screen line>] = "<slug>|<pr number>" for the PRS section
line=0      # lines printed so far, i.e. the screen line of the last one
# The PRS section is a fixed layout, so its two click zones are constants.
prs_x_num=3 prs_w_num=6 prs_x_term=0
TERM_GLYPH="❯"   # a prompt chevron: opens the PR in the browse pane,
                 # where ▣ read as a fourth status icon rather than an action

out() { printf '%s\n' "$1"; line=$((line + 1)); }

# --- PR facts: one round trip each, run in parallel, cached -----------------
# Every fact a row shows about a PR comes from one GraphQL query, so a row
# costs one round trip rather than one per column. They are then fired off
# together and waited on once: the table was spending ~4s of a 4.5s render
# sitting in sequential HTTP, which is a shape no language fixes for you.
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

# number, state, checks, merge, review, title — the shape every renderer reads.
# State is carried so one query answers both "what is in flight" and "is this
# worktree still sitting on a branch whose PR is already gone".
PR_SHAPE='.data.repository.pullRequests.nodes[0] // empty | [
    (.number|tostring),
    .state,
    (if .isDraft then "draft" else (.commits.nodes[0].commit.statusCheckRollup.state // "NONE") end),
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
  now="$(date +%s)"
  mt="$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0)"
  [ $((now - mt)) -lt "$pr_cache_age" ]
}

pr_fetch_bg() { # <slug> <branch> — refresh one cache entry, in the background
  f="$(pr_cache_file "$1" "$2")"
  pr_cache_fresh "$f" && return 0
  (
    owner="${1%%/*}"; nm="${1#*/}"
    gh api graphql -F owner="$owner" -F name="$nm" -F branch="$2" \
      -f query="$PR_QUERY" --jq "$PR_SHAPE" > "$f.$$" 2>/dev/null || : > "$f.$$"
    mv -f "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$"
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
    draft)                        printf '\033[33mD\033[0m' ;;  # draft; PRS also prints DRAFT
    *)                            printf '%s' "$G_NONE" ;;
  esac
}

glyph_merge() { # <mergeStateStatus|MERGED> -> one column, blank when there is nothing to flag
  case "$1" in
    BEHIND)          printf '\033[33m↓\033[0m' ;;
    DIRTY)           printf '\033[31m⚠\033[0m' ;;
    BLOCKED)         printf '\033[33m⊘\033[0m' ;;
    MERGED)          printf '\033[2m·\033[0m' ;;  # merged — fades with the row
    *)               printf ' ' ;;
  esac
}

glyph_review() { # <approved|changes|waiting|commented|noreviewers|merged|none|N> -> one column
  case "$1" in
    approved)     printf '\033[32m✓\033[0m' ;;
    changes)      printf '\033[31m!\033[0m' ;;
    waiting)      printf '\033[33m…\033[0m' ;;          # reviewers assigned, silent
    commented)    printf '\033[33m✎\033[0m' ;;          # reviewer participated, not approved
    noreviewers)  printf '\033[31;1m⚠\033[0m' ;;       # ready-for-review with nobody assigned
    merged)       printf '\033[2m·\033[0m' ;;
    none|'')      printf ' ' ;;
    *)            printf '\033[33m%s\033[0m' "$1" ;;   # unresolved comment count
  esac
}

# Bold yellow DRAFT tag for the PRS title / inline when checks say draft.
draft_tag() { # -> prints DRAFT badge
  printf '\033[33;1mDRAFT\033[0m'
}

# Both write to a variable rather than stdout: cells end in padding, and
# command substitution would eat it.

fit() { # <text> <width> -> $_fit, exactly <width> columns (%-*s counts bytes)
  _fit="${1:0:$2}"
  if [ "${#_fit}" -lt "$2" ]; then
    printf -v _fit '%s%*s' "$_fit" $(( $2 - ${#_fit} )) ''
  fi
}

cell() { # <text> <width> -> $_cell: <width> columns, the text itself underlined
  s="${1:0:$2}"
  pad=$(( $2 - ${#s} ))
  if [ "$click" = yes ] && [ -n "${s// /}" ]; then
    s=$'\033[4m'"$s"$'\033[24m'   # the underline marks the text, not the padding
  fi
  if [ "$pad" -gt 0 ]; then
    printf -v s '%s%*s' "$s" "$pad" ''
  fi
  _cell="$s"
}

# The column header. Shared for the same reason format_repo_row is: a cached
# table with different headings from the live one would be a different table.
repos_header() { # [suffix shown after the collection name]
  hdr=""
  if [ "$show_coll" = yes ]; then
    fit COLLECTION $c_coll; hdr="$_fit "
  else
    out $'\033[1m'"$only"$'\033[0m'"${1:-}"
  fi
  fit REPO $c_repo;       hdr="$hdr$_fit "
  fit BRANCH $c_branch;   hdr="$hdr$_fit "
  fit PR $c_pr;           hdr="$hdr$_fit "
  fit "↑" $c_ahead;       hdr="$hdr$_fit "
  fit "↓" $c_behind;      hdr="$hdr$_fit TREE"
  out $'\033[1m'"$hdr"$'\033[0m'
}

# One repo row, formatted. Both the live table and the --cached one call this,
# so the two cannot drift into printing different tables from the same facts —
# which is the whole argument against having two renderers at all.
#
# Reads only what it is given. Sets $_row and $_term_x for the caller.
format_repo_row() { # <coll> <dir> <branch> <pr_num> <sigil> <checks> <draft> <merge> <review> <ahead_disp> <behind_disp> <tree>
  _fr_coll="$1" _fr_dir="$2" _fr_branch="$3" _fr_num="$4" _fr_sigil="$5"
  _fr_checks="$6" _fr_draft="$7" _fr_merge="$8" _fr_review="$9"
  shift 9; _fr_a="$1" _fr_b="$2" _fr_tree="$3"

  _row=""
  if [ "$show_coll" = yes ]; then fit "$_fr_coll" $c_coll; _row="$_fit "; fi
  # Projects whose repos all share a prefix (`acme-api`, `acme-web`, …)
  # waste a third of this column repeating it. Set WTC_REPO_PREFIX to trim
  # it from the display only; unset, nothing is stripped.
  cell "${_fr_dir#${WTC_REPO_PREFIX:-}}" $c_repo; _row="$_row$_cell "
  fit "$_fr_branch" $c_branch;  _row="$_row$_fit "
  # The number and the ▣ are two targets, not one cell with a fallback:
  # each does exactly one thing, so a click can no longer set off both.
  # Built by hand rather than through cell(): the underline belongs on
  # "#225" alone, and the escape codes in the glyphs would break its
  # width arithmetic anyway.
  if [ -n "$_fr_num" ]; then
    _cg="$(glyph_checks "$_fr_checks")"
    [ "$_fr_draft" = yes ] && _cg="$(glyph_checks draft)"
    _term_x=$((col_pr + 4 + ${#_fr_num} + 1))
    printf -v _cell '\033[4m%s%s\033[24m %s%s%s %s' "$_fr_sigil" "$_fr_num" \
      "$_cg" "$(glyph_merge "$_fr_merge")" \
      "$(glyph_review "$_fr_review")" "$TERM_GLYPH"
    _pad=$((c_pr - (1 + ${#_fr_num} + 1 + 3 + 1 + 1)))
    [ "$_pad" -gt 0 ] && printf -v _cell '%s%*s' "$_cell" "$_pad" ''
  else
    _term_x=0
    fit "" $c_pr; _cell="$_fit"
  fi
  _row="$_row$_cell "
  fit "$_fr_a" $c_ahead;   _row="$_row$_fit "
  fit "$_fr_b" $c_behind;  _row="$_row$_fit "
  cell "$_fr_tree" $c_tree; _row="$_row$_cell"
}

# The same table, from the last snapshot, without touching git or a forge.
# Everything it prints came out of format_repo_row, so it cannot drift from
# the live one; what it cannot do is tell you anything newer than the file.
#
# It refuses rather than falling back to a live render. Quietly doing the slow
# thing when asked for the fast one is the same class of surprise as inferring
# the mode from a tty — say what is missing and let the caller choose.
cached_repos_table() {
  ROWS=("")
  layout
  _rows="$(wtc_status_cache_rows "$only")"
  if [ -z "$_rows" ]; then
    echo "error: no snapshot for '${only:-this collection}' — run tools/wtc-status.sh without --cached first" >&2
    return 1
  fi
  # Say how old it is, every time. A stale table that does not admit it is
  # worse than no table: the whole point of the live one is that it is live.
  repos_header " $(printf '\033[2m(snapshot, %ss old)\033[0m' "$(wtc_status_cache_age "$only")")"
  # Field names deliberately unlike the c_* column widths format_repo_row
  # reads — an earlier draft called one of these c_branch and silently
  # replaced the branch column's width with a branch name.
  while IFS=$'\t' read -r f_repo f_branch f_head f_ahead f_behind f_tree \
                           f_pr f_forge f_state f_checks f_merge f_review f_title; do
    [ -n "$f_repo" ] || continue
    # "-" is the snapshot's placeholder for an empty field; turn it back.
    # Written out rather than looped: a loop here needs either eval or an
    # indirection, and eight plain lines are easier to be sure about than
    # either. `case` rather than `[ … ] && …` because the latter returns the
    # test's status — put one of those last in a loop body under `set -e` and
    # the loop ends early on the first field that is not "-".
    case "$f_branch" in -) f_branch="" ;; esac
    case "$f_pr"     in -) f_pr=""     ;; esac
    case "$f_state"  in -) f_state=""  ;; esac
    case "$f_checks" in -) f_checks="" ;; esac
    case "$f_merge"  in -) f_merge=""  ;; esac
    case "$f_review" in -) f_review="" ;; esac
    case "$f_title"  in -) f_title=""  ;; esac
    case "$f_tree"   in -) f_tree=""   ;; esac
    _a=""; [ "${f_ahead:-0}"  != 0 ] && _a="↑$f_ahead"
    _b=""; [ "${f_behind:-0}" != 0 ] && _b="↓$f_behind"
    _draft=no; [ "$f_state" = DRAFT ] && _draft=yes
    format_repo_row "" "$f_repo" "$f_branch" "$f_pr" "#" \
      "$f_checks" "$_draft" "$f_merge" "$f_review" "$_a" "$_b" "$f_tree"
    out "$_row"
  done <<EOF
$_rows
EOF
  return 0
}

repos_table() {
  ROWS=("")
  layout
  # One snapshot per render, written as the rows are built and moved into
  # place at the end. Only when scoped to a single collection: the file lives
  # in that collection, and a --all sweep has no single home to write to.
  cache_on=no
  if [ -n "$only" ]; then
    cache_on=yes
    # The name, not $0: the full path is a temp dir under test and a machine
    # detail everywhere else, and this field is read by people.
    wtc_status_cache_begin "$only" "$(basename "$0")$([ "$watch" = yes ] && printf ' --tui')"
  fi
  # Refresh the refs the table is about to measure against — "behind" computed
  # from a week-old fetch is worse than no number at all. Age-gated, so a
  # --watch pane redrawing every 5s still only fetches every few minutes.
  if [ "$fetch" = yes ]; then
    for c in "$ROOT"/*/; do
      c="${c%/}"
      [ -d "$c/harness" ] || continue
      if [ -n "$only" ] && [ "$(basename "$c")" != "$only" ]; then continue; fi
      for wt in "$c"/*/; do
        wt="${wt%/}"
        [ -e "$wt/.git" ] || continue
        fetch_if_stale "$(owner_of "$wt")" "$fetch_max_age" || true
      done
    done
  fi

  # Pass one: walk the worktrees, fire off every PR query at once, wait once.
  # Sequential lookups were the whole of the render time; the walk itself is
  # local git and costs nothing.
  mkdir -p "$PR_CACHE" 2>/dev/null || true
  WTS=(); WT_REPO=(); WT_SLUG=(); WT_BRANCH=(); WT_UPSTREAM=()
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
      # The repo a fork checkout contributes to. Its PRs are the ones that
      # matter for that sibling and they are not on origin at all, so the
      # branch has to be looked up in both places (below).
      wup="$(upstream_slug_for_worktree "$wt")"
      case "$wup" in "$wslug") wup="" ;; esac
      WTS+=("$wt"); WT_REPO+=("$wrepo"); WT_SLUG+=("$wslug"); WT_BRANCH+=("$wbranch")
      WT_UPSTREAM+=("$wup")
      if [ -n "$wbranch" ] && [ -n "$wslug" ] && command -v gh >/dev/null 2>&1; then
        pr_fetch_bg "$wslug" "$wbranch"
        # Fired alongside rather than after: the whole point of this block is
        # that every round trip is in flight at once, and a fallback that
        # waited for the first answer would put one back in series. GitHub
        # matches a cross-fork PR by head branch on the base repo, so the
        # same query answers for the upstream unchanged.
        [ -z "$wup" ] || pr_fetch_bg "$wup" "$wbranch"
      fi
    done
  done
  wait 2>/dev/null || true

  stale=0
  repos_header
  for c in "$ROOT"/*/; do
    c="${c%/}"
    [ -d "$c/harness" ] || continue
    cname="$(basename "$c")"
    name="$cname"
    if [ -n "$only" ] && [ "$cname" != "$only" ]; then continue; fi
    for wt in "$c"/*/; do
      wt="${wt%/}"
      [ -e "$wt/.git" ] || continue
      dir="$(basename "$wt")"
      repo="$dir"; [ "$dir" = harness ] && repo="$(harness_repo)"
      # Detached at the tip is the resting state, not an anomaly: show it as
      # the tip it is (⌂ develop), and let ↓ be the only "you are behind"
      # signal — for a detached HEAD and a stale branch alike.
      state="$(wt_head_state "$wt" "$repo")"
      kind="$(printf '%s' "$state" | awk '{print $1}')"
      label="$(printf '%s' "$state" | awk '{print $2}')"
      ahead="$(printf '%s' "$state" | awk '{print $3}')"
      behind="$(printf '%s' "$state" | awk '{print $4}')"
      changed="$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

      branch="$label"
      [ "$kind" = detached ] && branch="⌂ $label"

      # ↑ and ↓ are their own columns now: two numbers you can scan down,
      # rather than three facts crammed into one cell. TREE keeps the one
      # thing that is about the working tree rather than the remote.
      tree=""
      [ "$changed" != 0 ] && tree="±$changed"
      a_disp=""; [ "$ahead" != 0 ] && a_disp="$ahead"
      b_disp=""
      if [ "$behind" != 0 ]; then
        b_disp="$behind"
        stale=$((stale + 1))
      fi
      [ -n "$tree" ] || tree=clean
      # A detached HEAD has no branch to look a PR up by; ⌂ rows show no PR
      # because there is no work in flight to have one.
      pr_num=""; pr_draft=no; pr_slug=""; pr_sigil="#"
      if [ "$kind" = branch ]; then
        # .wtc-prs is source of truth: an enlisted PR for this repo+branch is
        # enriched directly (no GraphQL-by-headRef guess), and title/state come
        # from the enlistment rather than a query that could miss a rename.
        enlisted="$(wtc_pr_enlisted_for "$cname" "$repo" "$label" | head -n1)"
        if [ -n "$enlisted" ]; then
          pr_num="${enlisted%%$'\t'*}"
          ent_title="${enlisted#*$'\t'}"
          tsv_from_cmd _n pr_state pr_checks pr_merge pr_review _ _ _ -- \
            wtc_pr_enrich "$repo" "$pr_num" "$ent_title" "$wt"
          case "$pr_state" in OPEN|DRAFT) ;; *) pr_num="" ;; esac
          [ "$pr_state" = DRAFT ] && pr_draft=yes
          [ -n "$pr_num" ] && pr_slug="$(slug_for_worktree "$wt" "$repo")"
        else
          pr_slug="$(slug_for_worktree "$wt" "$repo")"
          IFS=$'\t' read -r pr_num pr_state pr_checks pr_merge pr_review _ <<EOF
$(pr_facts "$pr_slug" "$label")
EOF
          # A merged or closed PR is not in flight; the row for it is the
          # orphan warning under PRS, not a PR cell that looks live.
          [ "$pr_state" = OPEN ] || pr_num=""
          # Nothing on origin means this may be a fork checkout, whose PR was
          # opened against the repo it forked — there is no PR on origin to
          # find and the cell would read "no PR yet" for work that is in
          # review. Ask the upstream for the same branch; GitHub matches a
          # cross-fork PR by head branch on the base repo. Origin still wins
          # when both answer: that is the one this worktree is pushing to.
          if [ -z "$pr_num" ]; then
            up_slug="$(upstream_slug_for_worktree "$wt")"
            if [ -n "$up_slug" ] && [ "$up_slug" != "$pr_slug" ]; then
              IFS=$'\t' read -r pr_num pr_state pr_checks pr_merge pr_review _ <<EOF
$(pr_facts "$up_slug" "$label")
EOF
              [ "$pr_state" = OPEN ] || pr_num=""
              # ↗ in place of #, the same mark the PRS section uses. It costs
              # no width and it has to be said: the number belongs to someone
              # else's repo, and so does the page a click on it opens.
              if [ -n "$pr_num" ]; then pr_slug="$up_slug"; pr_sigil="↗"; fi
            fi
          fi
        fi
      fi

      format_repo_row "$name" "$dir" "$branch" "$pr_num" "$pr_sigil" \
        "${pr_checks:-}" "$pr_draft" "${pr_merge:-}" "${pr_review:-}" \
        "$a_disp" "$b_disp" "$tree"
      term_x=$_term_x
      out "$_row"
      # $label, not $branch: the click map wants a real ref for `gh browse`,
      # not the ⌂-prefixed display string.
      # $pr_slug, not the worktree's origin: when the PR is on the upstream,
      # that is the repo a click has to open. Falls back for a ⌂ row, which
      # has no PR and so no slug of its own to carry.
      ROWS[$line]="$wt|${pr_slug:-$(slug_for_worktree "$wt" "$repo")}|$label|$pr_num"
      if [ "$cache_on" = yes ]; then
        wtc_status_cache_repo "$dir" "$branch" "$(git -C "$wt" rev-parse --short HEAD 2>/dev/null)" \
          "${ahead:-0}" "${behind:-0}" "$tree" "$pr_num" \
          "$(forge_for_worktree "$wt" "$repo")" "${pr_state:-}" "${pr_checks:-}" \
          "${pr_merge:-}" "${pr_review:-}" "${pr_title:-}"
      fi
      TERMX[$line]=$term_x
      name=""
    done
  done
  if [ "$stale" -gt 0 ]; then
    out $'\033[2m'"↓ = behind remote — $stale worktree(s) need a catch-up"$'\033[0m'
  fi
  # Moved into place only once every row is written: a reader never sees a
  # half-built snapshot, and a render that dies partway leaves the last good
  # one where it was.
  [ "$cache_on" = yes ] && wtc_status_cache_commit
  return 0
}

prs_table() { # the collection's enlisted PRs (.wtc-prs), in detail
  # Scoped runs only. Unscoped, this would be one gh call per repo per
  # collection on every redraw, which is a rate limit waiting to happen — so
  # the all-collections view keeps the inline PR column and nothing more.
  [ -n "$only" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0

  rows="$(wtc_pr_list "$only" 2>/dev/null || true)"

  # repo \t number \t checks \t merge \t review \t title \t archived \t
  # merged_on \t draft — one row per enlisted PR (open/draft/merged). A row
  # whose worktree still sits on the merged branch is flagged on_branch=yes
  # and forced out of the quiet archive, so catch-up territory never goes
  # silent; the plain orphan scan below then skips that repo+branch so the
  # warning is not shown twice.
  PR_ROW_REPO=(); PR_ROW_NUM=(); PR_ROW_CHECKS=(); PR_ROW_MERGE=()
  PR_ROW_REVIEW=(); PR_ROW_TITLE=(); PR_ROW_SLUG=(); PR_ROW_ARCHIVED=()
  PR_ROW_DRAFT=(); PR_ROW_ON_BRANCH=()
  orphan_covered=""  # " repo|branch " already shown as an on-branch PR row

  if [ -n "$rows" ]; then
    enlist_rows="$(wtc_pr_enlist_rows "$only")"
    while IFS=$'\t' read -r repo num checks merge review title archived merged_on draft; do
      [ -n "$num" ] || continue
      slug="$(repo_slug_for "$repo")"
      [ -n "$slug" ] || slug="$repo"
      enlist_br=""
      while IFS=$'\t' read -r r n b _url _t; do
        [ "$r" = "$repo" ] && [ "$n" = "$num" ] && enlist_br="$b"
      done <<EOF
$enlist_rows
EOF
      on_branch=no
      if [ "$merge" = MERGED ] && [ -n "$enlist_br" ]; then
        wt="$(wtc_repo_worktree "$only" "$repo")"
        if [ -d "$wt" ]; then
          cur="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || true)"
          if [ "$cur" = "$enlist_br" ]; then
            on_branch=yes
            archived=no  # catch-up needed — keep out of the quiet archive
            orphan_covered="$orphan_covered $(basename "$wt")|$enlist_br "
          fi
        fi
      fi
      PR_ROW_REPO+=("$repo"); PR_ROW_NUM+=("$num"); PR_ROW_CHECKS+=("$checks")
      PR_ROW_MERGE+=("$merge"); PR_ROW_REVIEW+=("$review"); PR_ROW_TITLE+=("$title")
      PR_ROW_SLUG+=("$slug"); PR_ROW_ARCHIVED+=("$archived")
      PR_ROW_DRAFT+=("$draft"); PR_ROW_ON_BRANCH+=("$on_branch")
    done <<EOF
$rows
EOF
  fi
  pr_count="${#PR_ROW_NUM[@]}"

  # A worktree still sitting on a branch whose per-branch PR cache says the
  # PR is gone (merged/closed) is exactly what an open-PRs-only view hides —
  # unless a PR row above already called it out in amber.
  orphans=""
  i=0
  while [ "$i" -lt "${#WTS[@]}" ]; do
    ob="${WT_BRANCH[$i]}"; os="${WT_SLUG[$i]}"
    owt="${WTS[$i]}"
    if [ -n "$ob" ] && [ -n "$os" ]; then
      case " $orphan_covered " in
        *" $(basename "$owt")|$ob "*) i=$((i + 1)); continue ;;
      esac
      IFS=$'\t' read -r _ ostate _ <<EOF
$(pr_facts "$os" "$ob")
EOF
      case "$ostate" in
        MERGED|CLOSED)
          orphans="$orphans$(basename "$owt")	$ob	$ostate
"
          ;;
      esac
    fi
    i=$((i + 1))
  done

  [ "$pr_count" -gt 0 ] || [ -n "$orphans" ] || return 0

  local active_n=0 archived_n=0
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
    local repo num checks merge review title slug draft on_branch prow room show tag
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
    room=$((cols - prs_x_num - prs_w_num - c_repo - 10))
    [ "$room" -ge 10 ] || room=10
    show="${title:0:$room}"
    prs_x_term=$((prs_x_num + prs_w_num + c_repo + 5))
    if [ "$on_branch" = yes ]; then
      # Same amber as the orphan warning — merged but still checked out.
      printf -v prow '  ⚠ #%s%*s%s  %s' \
        "$num" $((prs_w_num - 1 - ${#num})) '' "$_fit" "$show"
      out $'\033[33m'"$prow"$'\033[0m'
    elif [ "$as_archived" = yes ]; then
      printf -v prow '  #%s%*s%s  %s' \
        "$num" $((prs_w_num - 1 - ${#num})) '' "$_fit" "$show"
      out $'\033[2m'"$prow"$'\033[0m'
    elif [ "$merge" = MERGED ]; then
      # Fade rather than disappear — the row is still there to click.
      printf -v prow '  #%s%*s%s  %s' \
        "$num" $((prs_w_num - 1 - ${#num})) '' "$_fit" "$show"
      out $'\033[2m'"$prow"$'\033[0m'
    else
      tag=""
      if [ "$draft" = yes ] || [ "$checks" = draft ]; then
        tag="$(draft_tag) "
      fi
      # Underline on the number and chevron only — those are the click
      # targets; nothing else in the row is.
      printf -v prow '  \033[4m#%s\033[24m%*s%s %s%s%s%s \033[4m%s\033[24m  %s' \
        "$num" $((prs_w_num - 1 - ${#num})) '' "$_fit" \
        "$tag" \
        "$(glyph_checks "$checks")" "$(glyph_merge "$merge")" "$(glyph_review "$review")" \
        "$TERM_GLYPH" "$show"
      out "$prow"
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
        [ "${PR_ROW_ARCHIVED[$i]:-no}" = yes ] && _draw_pr_row "$i" yes
        i=$((i + 1))
      done
      out $'\033[2m'"▸ archived · a to hide"$'\033[0m'
    else
      out $'\033[2m'"▸ archived ($archived_n) · a to show"$'\033[0m'
    fi
  fi

  # A worktree still sitting on a branch whose PR has already gone is exactly
  # what an open-PRs-only view hides. Say it, and say what fixes it.
  if [ -n "$orphans" ]; then
    while IFS=$'\t' read -r repo branch state; do
      [ -n "$repo" ] || continue
      out $'\033[33m'"  ⚠ $repo on $branch — PR $state; catch-up returns it to the tip"$'\033[0m'
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
  out ""
  out $'\033[2m'"? keys · a archived · s select · r redraw · q quit"$'\033[0m'
}

help_block() {
  d=$'\033[2m'; z=$'\033[0m'; k=$'\033[1m'
  out ""
  out "${k}KEYS${z}    ${d}?${z} this list   ${d}a${z} archived   ${d}s${z} select text   ${d}r${z} redraw   ${d}q${z} quit"
  out "${k}CLICK${z}   ${d}REPO${z} open in nvim   ${d}TREE${z} git status   ${d}#n${z} github.com   ${d}$TERM_GLYPH${z} octo in browse"
  out "${k}PRS${z}     ${d}↗${z} sent to that owner's repo, not one of yours — ${d}↗n${z} in PR too"
  out ""
  out "${k}CHECKS${z}  $(glyph_checks SUCCESS) passing   $(glyph_checks FAILURE) failing   $(glyph_checks PENDING) running   $(glyph_checks draft) draft   $(glyph_checks NONE) none"
  out "${k}MERGE${z}   $(glyph_merge BEHIND) behind base   $(glyph_merge DIRTY) conflict   $(glyph_merge BLOCKED) blocked   ${d}blank${z} clean"
  out "${k}REVIEW${z}  $(glyph_review approved) approved   $(glyph_review changes) changes   $(glyph_review commented) commented   $(glyph_review waiting) waiting   $(glyph_review noreviewers) no reviewers   $(glyph_review 3) unresolved threads"
  out "${k}DRAFT${z}   $(draft_tag) open draft — reviewers optional until ready"
  out "${k}MERGED${z}  faded almost away; still on that branch → amber ⚠ (catch-up); after 48 weekday-hours → ${d}a${z} archived"
  out "${k}PRS${z}     from <collection>/.wtc-prs (\`tools/wtc-pr.sh enlist\`), not a forge label search"
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
  line=0
  [ "$watch" = yes ] && printf '\033[H\033[2J'
  case "$want" in
    repos) if [ "$cached" = yes ]; then cached_repos_table || return 1; else repos_table; prs_table; fi ;;
    procs) procs_table ;;
    both)  repos_table; prs_table; out ""; procs_table ;;
  esac
  if [ "$click" = yes ]; then
    if [ "$show_help" = yes ]; then help_block; else legend; fi
  fi
  return 0
}

# --- clicking ---------------------------------------------------------------
# Mouse reports only; output processing stays on (-icanon, not raw) so the
# table still prints with normal line endings.

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

# While the table reports mouse events the terminal never sees the drag, so
# its own text selection cannot work — copying a branch name out of the table
# is impossible while clicking is on. Select mode hands the mouse back.
#
# It also stops the clock: a --watch redraw mid-drag would clear the screen
# under the selection, so the table freezes until you come back. That is the
# whole point of a mode rather than a modifier — the freeze is half the fix.
select_mode() {
  mouse_off
  printf '\033[%d;1H\033[2K\033[7m SELECT \033[0m select and copy as usual — any key resumes' \
    $((line + 2))
  # No -t: this blocks, which is what freezes the redraw.
  IFS= read -r -s -n1 ch || true
  case "$ch" in q|Q) exit 0 ;; esac
  mouse_on
}

differ_cmd() { # <worktree> -> the diff view to run there
  if command -v lazygit >/dev/null 2>&1; then
    printf 'lazygit --path %s' "$1"
  else
    printf 'git -C %s diff' "$1"
  fi
}

collection_of() { # <worktree> -> collection folder name
  basename "$(dirname "$1")"
}

# Ask the collection's browse nvim to switch to this sibling.
# Returns 0 if nvim handled it.
open_nvim() { # <worktree> <want: files|git> [pr-number]
  wt="$1" want="${2:-files}" pr="${3:-}"
  coll="$(collection_of "$wt")"
  repo="$(basename "$wt")"
  wtc_browse_alive "$coll" || return 1
  if [ -n "$pr" ]; then
    got="$(wtc_browse_eval "$coll" "luaeval(\"WtcBrowsePr('$repo', '$pr')\")")"
    case "$got" in octo|octo-list) return 0 ;; esac
    return 1
  fi
  got="$(wtc_browse_eval "$coll" "luaeval(\"WtcBrowseFocus('$repo', '$want')\")")"
  [ "$got" = ok ]
}

# Two targets, one action each. The old single target tried nvim and fell
# through to the browser when Octo did not confirm — so a half-working browse
# pane jumped tabs *and* opened a tab in your browser off one click. A target
# that cannot do its one thing now says so instead of doing the other one.

open_pr_web() { # <slug> <branch> <pr number>
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$1" ] || return 0
  if [ -n "$3" ]; then
    (gh pr view "$3" --repo "$1" --web >/dev/null 2>&1 &)
  else
    (gh browse --repo "$1" --branch "$2" >/dev/null 2>&1 &)
  fi
}

open_pr_term() { # <worktree> <pr number> — Octo in the collection's browse nvim
  [ -n "$2" ] || return 0
  open_nvim "$1" files "$2" && return 0
  flash "no browse pane for $(collection_of "$1") — run wtc-browse, or click the number for the web"
}

# A one-line message under the table that survives until the next redraw.
flash() {
  printf '\033[s\033[%d;1H\033[2K\033[33m%s\033[0m\033[u' $((line + 2)) "$1"
}

open_diff() { # <worktree> — nvim git-status tab, else lazygit in a herdr tab
  if open_nvim "$1" git; then
    return 0
  fi
  label="diff:$(basename "$1")"
  if herdr_present && [ -n "${HERDR_SESSION:-}" ] && [ -n "${HERDR_WORKSPACE_ID:-}" ]; then
    tab="$(herdr --session "$HERDR_SESSION" tab list 2>/dev/null \
      | tr '{}' '\n\n' \
      | grep -F "\"label\":\"$label\"" \
      | grep -F "\"workspace_id\":\"$HERDR_WORKSPACE_ID\"" \
      | sed -n 's/.*"tab_id":"\([^"]*\)".*/\1/p' | head -n1 || true)"
    if [ -n "$tab" ]; then
      herdr --session "$HERDR_SESSION" tab focus "$tab" >/dev/null 2>&1 || true
      return 0
    fi
    pane="$(herdr --session "$HERDR_SESSION" tab create --workspace "$HERDR_WORKSPACE_ID" \
      --cwd "$1" --label "$label" --focus 2>/dev/null | herdr_first_pane_id || true)"
    if [ -n "$pane" ]; then
      sleep 1
      herdr --session "$HERDR_SESSION" pane run "$pane" "$(differ_cmd "$1")" >/dev/null 2>&1 || true
      return 0
    fi
  fi
  tty_restore
  eval "$(differ_cmd "$1")" || true
  tty_setup
}

on_click() { # <button>;<column>;<line> from an SGR mouse report
  btn="${1%%;*}"; rest="${1#*;}"; x="${rest%%;*}"; y="${rest##*;}"
  [ "$btn" = 0 ] || return 0                       # left button only, no wheel/drag
  case "$x$y" in *[!0-9]*) return 0 ;; esac
  # The PRS section first: its rows are laid out differently and carry only
  # a slug and a number, no worktree.
  pentry="${PROWS[$y]:-}"
  if [ -n "$pentry" ]; then
    pslug="${pentry%%|*}"; pnum="${pentry##*|}"
    if [ "$x" -ge "$prs_x_num" ] && [ "$x" -lt $((prs_x_num + prs_w_num)) ]; then
      open_pr_web "$pslug" "" "$pnum"
    elif [ "$prs_x_term" -gt 0 ] && [ "$x" -ge "$prs_x_term" ] \
         && [ "$x" -lt $((prs_x_term + 2)) ]; then
      # slug -> worktree dir. The harness sibling is always `harness/`,
      # never its repo name, so map that one back before building the path.
      pdir="${pslug#*/}"
      [ "$pdir" = "$(harness_repo)" ] && pdir=harness
      open_pr_term "$ROOT/$only/$pdir" "$pnum"
    fi
    return 0
  fi

  entry="${ROWS[$y]:-}"
  [ -n "$entry" ] || return 0
  wt="${entry%%|*}"; rest="${entry#*|}"
  slug="${rest%%|*}"; rest="${rest#*|}"
  branch="${rest%%|*}"; pr_num="${rest##*|}"
  term_x="${TERMX[$y]:-0}"
  # Only the cells themselves act — empty space right of the table does not.
  if [ "$x" -ge "$col_tree" ] && [ "$x" -lt $((col_tree + c_tree)) ]; then
    open_diff "$wt"
  elif [ "$term_x" -gt 0 ] && [ "$x" -ge "$term_x" ] && [ "$x" -lt $((term_x + 2)) ]; then
    open_pr_term "$wt" "$pr_num"
  elif [ "$x" -ge "$col_pr" ] && [ "$x" -lt $((col_pr + c_pr)) ]; then
    open_pr_web "$slug" "$branch" "$pr_num"
  elif [ "$x" -ge "$col_repo" ] && [ "$x" -lt $((col_repo + c_repo)) ]; then
    open_nvim "$wt" files || open_diff "$wt"
  fi
}

read_mouse() { # after ESC: consume "[<b;x;yM" and act on the press
  IFS= read -r -s -n1 -t 1 ch || return 0
  [ "$ch" = '[' ] || return 0
  IFS= read -r -s -n1 -t 1 ch || return 0
  [ "$ch" = '<' ] || return 0
  seq=""
  while IFS= read -r -s -n1 -t 1 ch; do
    case "$ch" in
      M) on_click "$seq"; return 0 ;;
      m) return 0 ;;                 # release — the press already acted
      *) seq="$seq$ch" ;;
    esac
  done
}

wait_events() { # until the next redraw is due, or a key asks for one
  waited=0
  while [ "$waited" -lt "$interval" ]; do
    if IFS= read -r -s -n1 -t 1 ch; then
      case "$ch" in
        q|Q) exit 0 ;;
        r|R|' ') return 0 ;;
        s|S) select_mode; return 0 ;;
        '?'|h|H) if [ "$show_help" = yes ]; then show_help=no; else show_help=yes; fi
                 return 0 ;;
        a|A) if [ "$show_archived" = yes ]; then show_archived=no; else show_archived=yes; fi
             return 0 ;;
        $'\033') read_mouse ;;
      esac
    else
      waited=$((waited + 1))
    fi
  done
}

if [ "$click" = yes ]; then
  tty_setup
  while :; do render; wait_events; done
elif [ "$watch" = yes ]; then
  while :; do render; sleep "$interval"; done
else
  render
fi
