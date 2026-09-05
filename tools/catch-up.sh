#!/usr/bin/env bash
# catch-up.sh — selected worktrees, with one report anchored to the initiator.
set -euo pipefail

# A selected initiating harness may replace these files during the sweep.
# Execute a private copy; target hooks still come from each updated harness.
if [ -z "${WTC_CATCH_UP_SOURCE_DIR:-}" ]; then
  rollout_source="$(cd "$(dirname "$0")" && pwd)"
  rollout_runner="$(mktemp -d "${TMPDIR:-/tmp}/wtc-catch-up-runner.XXXXXX")"
  trap 'rm -rf "$rollout_runner"' EXIT
  cp "$rollout_source/catch-up.sh" "$rollout_source/lib.sh" "$rollout_source/catch-up-report.py" "$rollout_runner/"
  rollout_exit=0
  WTC_CATCH_UP_SOURCE_DIR="$rollout_source" bash "$rollout_runner/catch-up.sh" "$@" || rollout_exit=$?
  exit "$rollout_exit"
fi

usage() {
  cat <<'HELP'
Usage: tools/catch-up.sh [options] [collection ...]
  --all                every collection (clean worktrees only)
  --repos CSV          registry or sibling names; "harness" is an alias
  --harness-only       shorthand for --repos harness
  --clean-only         skip dirty trees (default for --all)
  --reload-status      interrupt/restart eligible status panes only
  --dry-run            plan with local refs; no fetch, repo, hook or pane writes
  --json               emit JSON instead of the readable report
  --report PATH        also write JSON and PATH.md (including during dry-run)
  --no-skills --no-mcp --no-env --no-secrets  skip named refresh hooks

Local catch-up retains stash/update/pop behavior. Fleet conflicts are aborted
and reported for the owning collection agent. No report wakes an idle agent.
Normal runs save .wtc-catch-up.json and .wtc-catch-up.json.md in the initiating
collection unless --report chooses another path. Partial failures still report
all targets and return nonzero. No rebase, force-push, or remote branch deletion.
HELP
}
log() { printf 'catch-up: %s\n' "$*" >&2; }
require_value() {
  case "$2" in ''|-*) printf '%s requires a value\n' "$1" >&2; exit 2 ;; esac
}
all=no dry_run=no clean_only=no reload_status=no output=readable
selector='' report='' do_skills=yes do_mcp=yes do_env=yes do_secrets=yes
collections=()
while [ $# -gt 0 ]; do
  case "$1" in
    --all) all=yes; clean_only=yes; shift ;;
    --repos) require_value "$1" "${2:-}"; selector="$2"; shift 2 ;;
    --harness-only) selector=harness; shift ;;
    --clean-only) clean_only=yes; shift ;;
    --reload-status) reload_status=yes; shift ;;
    --dry-run) dry_run=yes; shift ;;
    --json) output=json; shift ;;
    --report) require_value "$1" "${2:-}"; report="$2"; shift 2 ;;
    --no-skills) do_skills=no; shift ;;
    --no-mcp) do_mcp=no; shift ;;
    --no-env) do_env=no; shift ;;
    --no-secrets) do_secrets=no; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) collections+=("$1"); shift ;;
  esac
done
case "$selector" in ,*|*,|*,,*|*[!a-zA-Z0-9_.,/-]*) echo 'invalid repository selector' >&2; exit 2 ;; esac
execution_dir="$(cd "$(dirname "$0")" && pwd)"
script_dir="$WTC_CATCH_UP_SOURCE_DIR"
unset WTC_CATCH_UP_SOURCE_DIR
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$execution_dir/lib.sh"
harness_lib_init
load_wtc_config
# Capture before target context changes. An auxiliary sibling checkout still
# belongs to its parent collection, not the last collection in the sweep.
initiator="$(cd "$(dirname "$HARNESS_DIR")" && pwd)"
[ "$all" != yes ] || [ "${#collections[@]}" -eq 0 ] || { echo '--all cannot be combined with collection names' >&2; exit 2; }
command -v python3 >/dev/null || { echo 'python3 required for complete catch-up reports' >&2; exit 2; }
if [ "$all" = yes ]; then
  for d in "$ROOT"/*/; do
    [ -d "$d/harness" ] && collections+=("$(basename "$d")")
  done
elif [ "${#collections[@]}" -eq 0 ]; then
  collections+=("$(basename "$initiator")")
fi
[ "${#collections[@]}" -gt 0 ] || { echo 'no collections' >&2; exit 2; }
if [ -z "$report" ] && [ "$dry_run" = no ]; then report="$initiator/.wtc-catch-up.json"; fi
# Resolve a caller-supplied relative report path before any context changes.
if [ -n "$report" ]; then
  report="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$report")"
  [ -d "$(dirname "$report")" ] || { echo 'report parent directory does not exist' >&2; exit 2; }
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/wtc-catch-up.XXXXXX")"
: > "$work/rows"
: > "$work/targets"
: > "$work/fetches"
failed=0
configured_harness_repo="${WTC_HARNESS_REPO:-}"
finish() {
  local rc=$?
  trap - EXIT
  [ "$rc" -eq 0 ] || failed=1
  python3 "$execution_dir/catch-up-report.py" finish "$work/rows" "$initiator" "$dry_run" "$failed" "$report" "$output" || failed=1
  rm -rf "$work"
  exit "$failed"
}
trap finish EXIT
row() { # kind collection repo outcome reason source target result
  python3 "$execution_dir/catch-up-report.py" row "$work/rows" "$@"
  case "$4" in failed|needs-owner) failed=1 ;; esac
}
context() {
  HARNESS_DIR="$ROOT/$1/harness"
  REGISTRY="$HARNESS_DIR/.harness-repos.yml"
  LOCAL_REPOS="$HARNESS_DIR/.harness-repos"
  WTC_HARNESS_REPO="$(target_harness_repo)"
  export WTC_HARNESS_REPO
}
target_harness_repo() {
  local owner_name remote name candidate
  owner_name="$(basename "$(owner_of "$HARNESS_DIR")" .git)"
  for name in $(registry_all_names); do
    if [ "$name" = "$owner_name" ]; then printf '%s\n' "$name"; return; fi
  done
  remote="$(git -C "$HARNESS_DIR" config --get remote.origin.url 2>/dev/null || true)"
  remote="$(normalize_remote "$remote")"
  for name in $(registry_all_names); do
    candidate="$(registry_field "$name" remote)"
    candidate="$(normalize_remote "$candidate")"
    if [ -n "$remote" ] && [ "$candidate" = "$remote" ]; then printf '%s\n' "$name"; return; fi
  done
  printf '%s\n' "${configured_harness_repo:-agent-harness}"
}
normalize_remote() {
  printf '%s\n' "$1" | sed -e 's#^[a-z]*://##' -e 's#^[^/@]*@##' -e 's#\.git$##' -e 's#:#/#'
}
selected() { # sibling-name registry-name
  [ -n "$selector" ] || return 0
  case ",$selector," in *",$1,"*|*",$2,"*) return 0 ;; esac
  return 1
}
status_process() {
  python3 - "$1" <<'PY'
import os, shlex, sys
try:
    argv = shlex.split(sys.argv[1])
except ValueError:
    sys.exit(1)
if argv and os.path.basename(argv[0]) in ('bash', 'sh'):
    argv = argv[1:]
names = ('wtc-status-tui.sh', 'wtc-status.sh', 'wtc-status-legacy-tui.sh', 'wtc-status-legacy.sh')
sys.exit(0 if argv and os.path.basename(argv[0]) in names else 1)
PY
}
pane_command() { # session pane; use the foreground group leader, not a renderer child
  herdr --session "$1" pane process-info --pane "$2" 2>/dev/null | python3 -c '
import json, shlex, sys
try:
    info = json.load(sys.stdin)["result"]["process_info"]
    group = info["foreground_process_group_id"]
    leader = next(p for p in info["foreground_processes"] if p.get("pid") == group)
    argv = leader.get("argv")
    print(" ".join(shlex.quote(x) for x in argv) if argv else leader.get("cmdline", ""))
except (KeyError, ValueError, TypeError, StopIteration):
    pass
'
}
pr_state_for_branch() { # <collection> <repo> <branch>; NONE is a verified absence
  local coll="$1" repo="$2" branch="$3" saw='' matched=no unknown=no
  local r num b url title st slug forge payload
  while IFS=$'\t' read -r r num b url title; do
    [ "$r" = "$repo" ] && [ "$b" = "$branch" ] || continue
    matched=yes
    # Lifecycle decisions cannot reuse a table's cached OPEN after a merge.
    st="$(WTC_FORGE_CACHE_AGE=0 wtc_pr_enrich "$repo" "$num" "$title" "$(wtc_repo_worktree "$coll" "$repo")" \
      | awk -F'\t' '{print $2; exit}')"
    case "$st" in
      OPEN|open|DRAFT|draft) saw="$st" ;;
      MERGED|merged|CLOSED|closed) [ -n "$saw" ] || saw="$st" ;;
      *) unknown=yes ;;
    esac
  done <<EOF_ROWS
$(wtc_pr_enlist_rows "$coll")
EOF_ROWS
  if [ "$matched" = yes ]; then
    if [ "$unknown" = yes ]; then printf 'UNKNOWN\n'; else printf '%s\n' "$saw"; fi
    return
  fi
  command -v gh >/dev/null 2>&1 || { printf 'UNKNOWN\n'; return; }
  IFS=$'\t' read -r slug forge <<EOF_REPO
$(repo_slug_and_forge "$repo" "$(wtc_repo_worktree "$coll" "$repo")")
EOF_REPO
  if [ -z "$slug" ] || [ "$forge" != github ]; then printf 'UNKNOWN\n'; return; fi
  if ! payload="$(gh pr list --repo "$slug" --head "$branch" --state all --json state 2>/dev/null)"; then
    printf 'UNKNOWN\n'; return
  fi
  python3 - "$payload" <<'PY_STATE'
import json, sys
try:
    prs = json.loads(sys.argv[1])
    assert isinstance(prs, list)
    state = prs[0]['state'] if prs else 'NONE'
    assert state in ('OPEN', 'DRAFT', 'MERGED', 'CLOSED', 'NONE')
    print(state)
except (ValueError, TypeError, KeyError, AssertionError):
    print('UNKNOWN')
PY_STATE
}


# Build the selected inventory before any mutations, with the target registry.
# Fetch shared owners only once for the whole invocation, even after failures.
for collection in "${collections[@]}"; do
  case "$collection" in ''|.|..|*/*|*$'\t'*|*$'\n'*) row collection "$collection" '' failed 'invalid collection name' '' '' ''; continue ;; esac
  if [ ! -d "$ROOT/$collection/harness" ]; then row collection "$collection" '' failed 'missing harness' '' '' ''; continue; fi
  context "$collection"
  matched=''
  for wt in "$HARNESS_DIR" "$ROOT/$collection"/*/; do
    wt="${wt%/}"
    [ -e "$wt/.git" ] || continue
    label="$(basename "$wt")"
    # The explicit harness first entry is repeated by the glob.
    if [ "$label" = harness ]; then
      case "$matched" in *'|harness|'*) continue ;; esac
      matched="$matched|harness|"
      repo="$(harness_repo)"
    else repo="$label"; fi
    selected "$label" "$repo" || continue
    owner="$(owner_of "$wt")"
    printf '%s\t%s\t%s\t%s\n' "$collection" "$wt" "$repo" "$owner" >> "$work/targets"
  done
done
# Reject typos before fetching or changing anything. A selected repo may be
# absent in some collections; it must match at least one target in the sweep.
selection_failed=no
if [ -n "$selector" ]; then
  old_ifs="$IFS"; IFS=,; read -r -a selectors <<EOF_SELECT
$selector
EOF_SELECT
  IFS="$old_ifs"
  for name in "${selectors[@]}"; do
    if ! awk -F'\t' -v n="$name" '$3 == n {found=1} {p=$2; sub(/^.*\//,"",p); if(p==n)found=1} END{exit !found}' "$work/targets"; then
      row selection "$(basename "$initiator")" "$name" failed 'selector matches no checked-out repository' '' '' ''
      selection_failed=yes
    fi
  done
fi
[ "$selection_failed" = no ] || exit 1
while IFS=$'\t' read -r collection wt repo owner; do
  [ -n "$owner" ] || continue
  if awk -F'\t' -v o="$owner" '$1 == o {found=1} END{exit !found}' "$work/fetches"; then continue; fi
  fetch_state=ok
  if [ "$dry_run" = yes ]; then fetch_state=planned
  elif ! git --git-dir="$owner" fetch --prune origin >&2; then fetch_state=failed; fi
  printf '%s\t%s\n' "$owner" "$fetch_state" >> "$work/fetches"
  row fetch "$collection" "$repo" "$fetch_state" "$owner" '' '' ''
done < "$work/targets"

# Return to the exact original worktree after an aborted merge. Stashes are
# identified by object ID so a no-op stash can never pop somebody else's entry.
restore_stash() {
  [ -n "$stash_oid" ] || return 0
  if git -C "$wt" stash apply "$stash_oid" >&2; then
    if [ "$(git -C "$wt" rev-parse -q --verify refs/stash || true)" = "$stash_oid" ]; then
      if git -C "$wt" stash drop 'stash@{0}' >&2; then stash_oid=''; return 0; fi
    fi
    outcome=needs-owner; reason="changes restored; retained stash $stash_oid because stack changed or drop failed"
    return 1
  fi
  outcome=needs-owner; reason="stash restore conflicted; retained $stash_oid"
  return 1
}
reconcile() {
  outcome=current; reason='already contains default tip'; stash_oid=''
  local marker path branch extra pr_state before after
  for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
    path="$(git -C "$wt" rev-parse --git-path "$marker")"
    case "$path" in /*) ;; *) path="$wt/$path" ;; esac
    if [ -e "$path" ]; then outcome=needs-owner; reason="in-progress $marker; untouched"; return; fi
  done
  if [ "$clean_only" = yes ] && [ -n "$(git -C "$wt" status --porcelain)" ]; then
    outcome=needs-owner; reason='dirty worktree; clean-only leaves it untouched'; return
  fi
  branch="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || true)"
  if [ -z "$branch" ] && ! git -C "$wt" merge-base --is-ancestor HEAD "$target"; then
    outcome=needs-owner; reason='detached commits not contained in default tip; preserve them on an owner branch'; return
  fi
  pr_state=''
  [ -z "$branch" ] || pr_state="$(pr_state_for_branch "$collection" "$repo" "$branch")"
  case "$pr_state" in
    UNKNOWN) outcome=needs-owner; reason='PR state unavailable; branch left untouched'; return ;;
    CLOSED|closed) outcome=needs-owner; reason='closed PR branch; owner must decide continuation'; return ;;
    MERGED|merged)
      extra="$(git -C "$wt" rev-list --count "$target..HEAD")"
      if [ "$extra" != 0 ]; then outcome=needs-owner; reason='merged PR has commits beyond default tip'; return; fi ;;
    *)
      if git -C "$wt" merge-base --is-ancestor "$target" HEAD; then return; fi ;;
  esac
  if [ "$dry_run" = yes ]; then
    outcome=planned; reason='would update against local default ref (remote not fetched)'; return
  fi
  if [ -n "$(git -C "$wt" status --porcelain)" ]; then
    before="$(git -C "$wt" rev-parse -q --verify refs/stash || true)"
    if ! git -C "$wt" stash push --include-untracked -m "wtc-catch-up $collection/$repo" >&2; then
      outcome=needs-owner; reason='stash failed; update skipped'; return
    fi
    after="$(git -C "$wt" rev-parse -q --verify refs/stash || true)"
    [ "$after" = "$before" ] || stash_oid="$after"
  fi
  if [ -z "$branch" ] || [ "$pr_state" = MERGED ] || [ "$pr_state" = merged ]; then
    if git -C "$wt" checkout --detach "$target" >&2; then
      outcome=updated; reason='detached at default tip'
      if [ -n "$branch" ] && ! git -C "$wt" branch -d "$branch" >&2; then
        outcome=needs-owner; reason='updated but local merged-branch pruning refused'
      fi
    else outcome=needs-owner; reason='checkout refused'; fi
  elif git -C "$wt" merge --no-edit "$target" >&2; then
    outcome=updated; reason="merged default tip into $branch"
    case "$pr_state" in
      OPEN|open|DRAFT|draft)
        if ! git -C "$wt" push >&2; then outcome=needs-owner; reason='merge succeeded but push refused'; fi ;;
    esac
  else
    outcome=needs-owner
    if git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
      if git -C "$wt" merge --abort >&2; then reason='merge conflict; aborted to original tree'
      else reason='merge abort failed; owner must restore worktree'; fi
    else reason='merge refused before creating merge state'; fi
  fi
  restore_stash || true
}

run_hook() { # executable-name report-label optional repo argument
  local executable="$HARNESS_DIR/tools/$1" hook="$2" only_repo="${3:-}" result=ok why='completed'
  if [ ! -x "$executable" ]; then result=skipped; why='optional hook unavailable in target harness'
  elif [ "$dry_run" = yes ]; then result=planned; why='would run target harness hook'
  elif [ -n "$only_repo" ]; then
    if ! "$executable" --collection "$ROOT/$collection" --repo "$only_repo" >&2; then result=failed; why='target hook failed'; fi
  elif ! "$executable" --collection "$ROOT/$collection" >&2; then result=failed; why='target hook failed'; fi
  row hook "$collection" "$hook" "$result" "$why" '' '' ''
}

reload_pane() {
  local session ws rows pane agent command status_command attempt
  if ! command -v herdr >/dev/null; then
    row pane "$collection" status skipped 'herdr unavailable; no pane control attempted' '' '' ''; return
  fi
  session="${HERDR_SESSION:-$(herdr_session_name)}"
  if ! ws="$(herdr_ws_id "$session" "$collection")"; then
    row pane "$collection" status failed 'herdr workspace lookup failed; no pane control attempted' '' '' ''; return
  fi
  if [ -z "$ws" ]; then row pane "$collection" status skipped 'no matching herdr workspace' '' '' ''; return; fi
  if ! rows="$(herdr_pane_rows "$session" "$ws")"; then
    row pane "$collection" status failed 'herdr pane lookup failed; no pane control attempted' '' '' ''; return
  fi
  pane="$(herdr_row_col "$rows" status 2)"
  agent="$(herdr_row_col "$rows" status 3)"
  if [ -z "$pane" ]; then row pane "$collection" status skipped 'no status pane' '' '' ''; return; fi
  if [ -n "$agent" ]; then row pane "$collection" status needs-owner 'status-labelled pane contains an agent; untouched' '' '' ''; return; fi
  if ! command="$(pane_command "$session" "$pane")"; then
    row pane "$collection" status failed 'foreground lookup failed; no pane control attempted' '' '' ''; return
  fi
  if [ -z "$command" ]; then row pane "$collection" status needs-owner 'foreground process unknown; untouched' '' '' ''; return; fi
  if ! status_process "$command" && ! herdr_cmdline_is_shell "$command"; then
    row pane "$collection" status needs-owner 'status pane runs an unrelated process; untouched' '' '' ''; return
  fi
  if [ ! -x "$HARNESS_DIR/tools/wtc-status-tui.sh" ]; then row pane "$collection" status skipped 'target status entrypoint unavailable' '' '' ''; return; fi
  if [ "$dry_run" = yes ]; then row pane "$collection" status planned "would reload $pane" '' '' ''; return; fi
  if ! herdr_cmdline_is_shell "$command"; then
    if ! herdr --session "$session" pane send-keys "$pane" ctrl+c >/dev/null; then
      row pane "$collection" status failed "could not interrupt $pane" '' '' ''; return
    fi
  fi
  # Fail closed: the shared idle helper treats missing process data as idle.
  # Here an empty response must never permit typing over an unknown occupant.
  for attempt in 1 2 3 4 5; do
    if ! command="$(pane_command "$session" "$pane")"; then
      row pane "$collection" status failed "foreground lookup failed after interrupting $pane" '' '' ''; return
    fi
    if [ -n "$command" ] && herdr_cmdline_is_shell "$command"; then break; fi
    sleep 1
  done
  if ! rows="$(herdr_pane_rows "$session" "$ws")"; then
    row pane "$collection" status failed "pane lookup failed before restarting $pane" '' '' ''; return
  fi
  if [ "$(herdr_row_col "$rows" status 2)" != "$pane" ]; then
    row pane "$collection" status needs-owner "status pane identity changed from $pane; no command sent" '' '' ''; return
  fi
  if [ -n "$(herdr_row_col "$rows" status 3)" ]; then
    row pane "$collection" status needs-owner "agent appeared in status pane $pane; no command sent" '' '' ''; return
  fi
  if [ -z "$command" ] || ! herdr_cmdline_is_shell "$command"; then
    row pane "$collection" status needs-owner "pane $pane did not become a verified shell" '' '' ''; return
  fi
  printf -v status_command 'cd %q && ./harness/tools/wtc-status-tui.sh' "$ROOT/$collection"
  if herdr --session "$session" pane run "$pane" "$status_command" >/dev/null; then
    for attempt in 1 2 3 4 5; do
      if ! command="$(pane_command "$session" "$pane")"; then
        row pane "$collection" status failed "foreground lookup failed after restarting $pane" '' '' ''; return
      fi
      if status_process "$command"; then
        row pane "$collection" status restarted "observed status process in $pane; ongoing health not monitored" '' '' ''; return
      fi
      sleep 1
    done
    row pane "$collection" status failed "command delivered to $pane but status restart not observed" '' '' ''
  else row pane "$collection" status failed "restart failed for $pane" '' '' ''; fi
}

while IFS=$'\t' read -r collection wt repo owner; do
  context "$collection"
  ref="$(default_ref_for "$repo")"
  if ! source="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null)"; then
    row repo "$collection" "$repo" failed 'worktree HEAD unreadable; target may have moved or disappeared' '' '' ''
    continue
  fi
  target="$(git -C "$wt" rev-parse --verify "$ref^{commit}" 2>/dev/null || true)"
  outcome=failed; reason='default ref unavailable'
  fetch_state="$(awk -F'\t' -v o="$owner" '$1 == o {print $2;exit}' "$work/fetches")"
  if [ "$fetch_state" = failed ]; then reason='owner fetch failed; stale refs not used'
  elif [ -n "$target" ]; then reconcile; fi
  result="$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null || true)"
  if [ -z "$result" ]; then outcome=failed; reason='worktree HEAD unreadable after update'; fi
  row repo "$collection" "$repo" "$outcome" "$reason" "$source" "$target" "$result"
  case "$outcome" in
    updated|current|planned)
      # Run only repo-scoped secrets, never a whole-collection secrets sweep.
      [ "$do_secrets" = no ] || run_hook link-secrets.sh "secrets:$repo" "$(basename "$wt")"
      if [ "$(basename "$wt")" = harness ]; then
        [ "$do_skills" = no ] || run_hook link-skills.sh skills
        [ "$do_mcp" = no ] || run_hook link-mcp.sh mcp
        [ "$do_env" = no ] || run_hook refresh-env.sh env
        [ "$reload_status" = no ] || reload_pane
      fi ;;
    *)
      if [ "$(basename "$wt")" = harness ] && [ "$reload_status" = yes ]; then
        row pane "$collection" status skipped 'harness update needs attention; pane left running' '' '' ''
      fi ;;
  esac
done < "$work/targets"
exit "$failed"
