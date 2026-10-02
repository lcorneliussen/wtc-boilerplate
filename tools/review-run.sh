#!/usr/bin/env bash
# review-run.sh — run the headless review agents over a bundle.
#
# One agent run per concern (parallel), then one lead run that writes
# summary.md + verdict. This tool — not the lead — owns the trailing status
# line that review-status.sh / bb-pr-ready.sh parse. Contract: review/README.md.
set -euo pipefail

# Use the exact pinned native runner when available. The shell implementation
# remains the bootstrap path for older pins and installations without the CLI.
native_review_run_supported() {
  awk -v version="$1" 'BEGIN {
    if (version !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
    split(version, part, ".")
    exit !((part[1] + 0) > 0 || (part[2] + 0) > 1 ||
           ((part[2] + 0) == 1 && (part[3] + 0) >= 24))
  }'
}
source_harness="$(cd "$(dirname "$0")/.." && pwd)"
source_collection="$(dirname "$source_harness")"
if [ -f "$source_harness/.wtc-cli-version" ]; then
  cli_pin="$(tr -d '[:space:]' < "$source_harness/.wtc-cli-version")"
  if native_review_run_supported "$cli_pin"; then
    cli_cmd=()
    if command -v mise >/dev/null 2>&1; then
      cli_version="$(cd "$source_collection" && mise exec -- wtc --version 2>/dev/null)" || cli_version=""
      if [ "$cli_version" = "wtc version $cli_pin" ] &&
          (cd "$source_collection" && mise exec -- wtc review run --help >/dev/null 2>&1); then
        cli_cmd=(mise exec -- wtc)
      fi
    fi
    if [ "${#cli_cmd[@]}" -eq 0 ] && command -v wtc >/dev/null 2>&1; then
      cli_version="$(cd "$source_collection" && wtc --version 2>/dev/null)" || cli_version=""
      if [ "$cli_version" = "wtc version $cli_pin" ] &&
          (cd "$source_collection" && wtc review run --help >/dev/null 2>&1); then
        cli_cmd=(wtc)
      fi
    fi
    if [ "${#cli_cmd[@]}" -gt 0 ]; then
      caller_dir="$(pwd -P)"
      native_args=()
      bundle_seen=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --strong|--standard|--fast|--lead|--parallel|--only)
            native_args+=("$1")
            shift
            if [ "$#" -gt 0 ]; then native_args+=("$1"); shift; fi ;;
          -*|*)
            if [ "$bundle_seen" -eq 0 ] && [[ "$1" != -* ]]; then
              bundle_seen=1
              case "$1" in
                /*) native_args+=("$1") ;;
                *) native_args+=("$caller_dir/$1") ;;
              esac
            else
              native_args+=("$1")
            fi
            shift ;;
        esac
      done
      cd "$source_collection"
      exec "${cli_cmd[@]}" review run "${native_args[@]}"
    fi
  fi
fi

usage() {
  cat <<'EOF' >&2
Usage:
  tools/review-run.sh <bundle-dir> [--strong SPEC] [--standard SPEC] [--fast SPEC]
                      [--lead SPEC] [--parallel N] [--only id,id] [--post]

  SPEC        agent:model — agent is claude | codex | grok, model may be
              empty (agent default). A comma- or space-separated list is tried
              in order when a run hits a token or session limit
              (grok:,codex:,claude:opus). Defaults come from wtc.env:
              HARNESS_REVIEW_STRONG/STANDARD/FAST/LEAD, HARNESS_REVIEW_PARALLEL,
              HARNESS_REVIEW_TIMEOUT (seconds per agent run),
              HARNESS_REVIEW_GROK_EFFORT (grok --reasoning-effort; default low).
  --only      run just these concern ids (others keep no findings file)
  --post      post an "in progress" comment BEFORE the agents start, then
              update that same comment with summary.md (or a "failed" note)
              via tools/review-post.sh. A finished summary also posts one inline
              comment per open finding that has a file and line. The summary
              comment id lives in <bundle>/comment.id; inline ids in
              <bundle>/inline-comments.json

Env: WTC_REVIEW_AGENT_CMD replaces the launcher; it is run as
  $WTC_REVIEW_AGENT_CMD <agent> <model> <prompt-file> <cwd>
with the prompt on stdin too. Servers and tests use this. The runner sets
WTC_REVIEW_STATS_FILE; the command may write its own stats JSON there
(agent, model, seconds, input_tokens, output_tokens, cache_read_tokens,
cache_write_tokens, cost_usd, turns) — otherwise only wall-clock seconds are kept.

Exit 0 when summary.md and a valid verdict exist; non-zero otherwise.
Logs: <bundle>/run.log (plus .logs/ per concern). Stats: <bundle>/stats/<id>.json,
summarised in a "### Run stats" section of summary.md.
EOF
  exit "${1:-2}"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
harness_lib_init
load_wtc_config
py="$script_dir/review_lib.py"

bundle="" only="" post=0
spec_strong="$HARNESS_REVIEW_STRONG" spec_standard="$HARNESS_REVIEW_STANDARD"
spec_fast="$HARNESS_REVIEW_FAST" spec_lead="" parallel="$HARNESS_REVIEW_PARALLEL"
lead_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --strong)   [ $# -ge 2 ] || usage; spec_strong="$2"; shift ;;
    --standard) [ $# -ge 2 ] || usage; spec_standard="$2"; shift ;;
    --fast)     [ $# -ge 2 ] || usage; spec_fast="$2"; shift ;;
    --lead)     [ $# -ge 2 ] || usage; spec_lead="$2"; lead_set=1; shift ;;
    --parallel) [ $# -ge 2 ] || usage; parallel="$2"; shift ;;
    --only)     [ $# -ge 2 ] || usage; only="$2"; shift ;;
    --post)     post=1 ;;
    -*) echo "error: unknown flag $1" >&2; usage ;;
    *)  [ -z "$bundle" ] || usage; bundle="$1" ;;
  esac
  shift
done
[ -n "$bundle" ] && [ -f "$bundle/manifest.env" ] || { echo "error: not a review bundle: ${bundle:-<none>}" >&2; usage; }
bundle="$(cd "$bundle" && pwd)"
# An explicit --strong does not move the lead; the lead follows its own knob.
[ "$lead_set" -eq 1 ] || spec_lead="$HARNESS_REVIEW_LEAD"
printf '%s' "$parallel" | grep -Eq '^[1-9][0-9]*$' || { echo "error: --parallel must be a positive number" >&2; exit 2; }
printf '%s' "$HARNESS_REVIEW_TIMEOUT" | grep -Eq '^[0-9]+$' || { echo "error: HARNESS_REVIEW_TIMEOUT must be seconds" >&2; exit 2; }

# shellcheck disable=SC1091
. "$bundle/manifest.env"
prompts="$HARNESS_DIR/review/prompts"
for f in concern.md lead.md; do
  [ -f "$prompts/$f" ] || { echo "error: missing $prompts/$f" >&2; exit 1; }
done

runlog="$bundle/run.log"
mkdir -p "$bundle/findings" "$bundle/.logs" "$bundle/.prompts" "$bundle/stats"
rm -f "$bundle"/stats/*.json
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$runlog" >&2; }

spec_agent() { local a="${1%%:*}"; printf '%s' "$a"; }
spec_model() { case "$1" in *:*) printf '%s' "${1#*:}" ;; esac; }
# One spec per line. Commas and whitespace both separate; "codex:, claude:opus" works.
spec_list() { printf '%s\n' "$1" | tr ',' '\n' | tr -s '[:space:]' '\n' | sed '/^$/d'; }
limit_hit() { # <output-file> — true when the agent stopped for quota, not a real review error
  [ -f "$1" ] || return 1
  grep -Eiq 'session limit|usage limit|rate limit|too many requests|overloaded|quota|HTTP/? ?429|status 429|hit your .{0,40}limit' "$1"
}

# Try each spec in SPEC until one exits 0. On a limit error, try the next.
# Sets CHAIN_AGENT, CHAIN_MODEL, CHAIN_RC, CHAIN_SECS. Echoes progress to stdout
# (callers redirect that into the concern log).
run_chain() { # <label> <out-file> <prompt> <specs>
  local label="$1" out="$2" prompt="$3" specs="$4"
  local one agent model rc t0 next i
  local -a list
  list=()
  while IFS= read -r one; do list+=("$one"); done < <(spec_list "$specs")
  CHAIN_AGENT="" CHAIN_MODEL="" CHAIN_RC=127 CHAIN_SECS=0
  [ "${#list[@]}" -gt 0 ] || { echo "no agent spec in '$specs'" >&2; return 127; }
  for i in "${!list[@]}"; do
    one="${list[$i]}"
    agent="$(spec_agent "$one")"; model="$(spec_model "$one")"
    echo "start $label agent=$agent model=${model:-default}"
    t0="$(date +%s)"
    rc=0
    run_with_timeout "$HARNESS_REVIEW_TIMEOUT" "$out" "$agent" "$model" "$prompt" "$bundle" || rc=$?
    CHAIN_AGENT="$agent" CHAIN_MODEL="$model" CHAIN_RC="$rc"
    CHAIN_SECS=$(( $(date +%s) - t0 ))
    [ "$rc" -eq 0 ] && return 0
    next=""
    [ $((i + 1)) -lt ${#list[@]} ] && next="${list[$((i + 1))]}"
    if [ -n "$next" ] && limit_hit "$out"; then
      echo "limit on ${agent}:${model} — trying $next"
      continue
    fi
    return "$rc"
  done
  return "$CHAIN_RC"
}

# Runs in a subshell and ends in exec, so a watchdog kill reaches the real agent.
launch_agent() { # <agent> <model> <prompt-file> <cwd>
  local agent="$1" model="$2" prompt="$3" cwd="$4"
  cd "$cwd"
  if [ -n "${WTC_REVIEW_AGENT_CMD:-}" ]; then
    # shellcheck disable=SC2086
    exec $WTC_REVIEW_AGENT_CMD "$agent" "$model" "$prompt" "$cwd" <"$prompt"
  fi
  case "$agent" in
    claude)
      # Reads the repo through --add-dir; edits in it are denied (best effort:
      # the prompt also says read-only). The findings file lives in the bundle (cwd).
      # --output-format json: one result object with usage/cost/turns (stats); the
      # human text is its .result (review_lib.py run-stats converts it back).
      # git diff is not allowed (diff.patch is in the bundle) and every git
      # option that writes a file (--output=<file>, also abbreviated) is denied
      # for the git commands that stay (log, show).
      set -- -p --output-format json
      [ -z "$model" ] || set -- "$@" --model "$model"
      exec claude "$@" --add-dir "$REPO_DIR" --permission-mode acceptEdits \
        --disallowedTools "Edit($REPO_DIR/**)" "Write($REPO_DIR/**)" "Bash(git * --ou*)" \
        --allowedTools "Read Grep Glob Write Edit Bash(git log:*) Bash(git show:*) Bash(ls:*) Agent" \
        <"$prompt"
      ;;
    codex)
      # workspace-write: writes only under the bundle (cwd); reads are unrestricted.
      set -- exec --json
      [ -z "$model" ] || set -- "$@" -m "$model"
      exec codex "$@" -C "$cwd" --skip-git-repo-check -s workspace-write - <"$prompt"
      ;;
    grok)
      # grok CLI. workspace sandbox: read the repo, write only in the bundle
      # (cwd) plus /tmp. --prompt-file is one headless prompt with tool turns;
      # JSON result has .text plus usage (review_lib.py). --always-approve so
      # a review does not stop on a permission prompt. Web tools stay off.
      set -- --prompt-file "$prompt" --output-format json --cwd "$cwd" \
        --sandbox workspace --always-approve --no-alt-screen \
        --disable-web-search --no-subagents --verbatim \
        --disallowed-tools "web_search,web_fetch"
      [ -z "$model" ] || set -- "$@" --model "$model"
      # Default effort is low: the CLI default spent many minutes and tens of
      # thousands of output tokens on one concern.
      [ -z "${HARNESS_REVIEW_GROK_EFFORT:-}" ] || set -- "$@" --reasoning-effort "$HARNESS_REVIEW_GROK_EFFORT"
      exec grok "$@"
      ;;
    *)
      echo "unsupported review agent: $agent" >&2
      exit 127
      ;;
  esac
}

# Portable timeout (macOS has no GNU timeout): background the launcher, kill it
# from a sleeper. Returns 124 on timeout, else the agent's status.
run_with_timeout() { # <seconds> <out-file> <agent> <model> <prompt> <cwd>
  local secs="$1" out="$2"; shift 2
  local pid wd rc
  ( launch_agent "$@" ) >"$out" 2>&1 &
  pid=$!
  if [ "$secs" -gt 0 ]; then
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
    wd=$!
  else
    wd=""
  fi
  rc=0
  wait "$pid" || rc=$?
  if [ -n "$wd" ]; then
    kill "$wd" 2>/dev/null || true
    wait "$wd" 2>/dev/null || true
  fi
  # 143/137 = killed by the watchdog (a agent that died to SIGTERM on its own is rare enough)
  case "$rc" in 143|137) rc=124 ;; esac
  return "$rc"
}

# Turn an agent's raw output into stats/<id>.json and rewrite <out> as the human
# text (claude: .result; codex: agent messages; grok: .text). Custom launchers
# write their own
# stats to $WTC_REVIEW_STATS_FILE; whatever is missing stays null (seconds are ours).
finish_stats() { # <id> <out> <agent> <model> <seconds> <status>
  local custom=0
  [ -z "${WTC_REVIEW_AGENT_CMD:-}" ] || custom=1
  if python3 "$py" run-stats "$bundle/stats/$1.json" "$2" "$2.txt" "$3" "$4" "$5" "$6" "$custom" 2>>"$runlog"; then
    mv -f "$2.txt" "$2"
  fi
}

render() { # <template> <out> <KEY=VAL>…
  local t="$1" o="$2"; shift 2
  python3 "$py" render "$t" "$@" >"$o"
}

stub() { python3 "$py" stub-json "$1" "$2" "$3" >"$bundle/findings/$1.json"; }

# `needs: downstream` is satisfied by downstream/ or upstream/ snapshots.
has_downstream() {
  local d
  for d in downstream upstream; do
    if [ -d "$bundle/$d" ] && [ -n "$(ls -A "$bundle/$d" 2>/dev/null)" ]; then return 0; fi
  done
  return 1
}

run_concern() { # <id> — subshell job; all output goes to .logs/<id>.log
  local id="$1" cfile="$bundle/concerns/$1.md" out="$bundle/findings/$1.json"
  local tier needs spec agent model prompt rc=0 why t0 secs sstatus
  tier="$(python3 "$py" frontmatter "$cfile" tier)"; [ -n "$tier" ] || tier=standard
  needs="$(python3 "$py" frontmatter "$cfile" needs)"
  rm -f "$out" "$bundle/findings/$id.raw" "$bundle/stats/$id.json"
  if [ "$needs" = downstream ] && ! has_downstream; then
    stub "$id" skipped "needs downstream repos; the bundle has none"
    printf '{"agent":"","model":"","seconds":0,"status":"skipped"}\n' >"$bundle/stats/$id.json"
    echo "skipped (no downstream)"; return 0
  fi
  case "$tier" in
    strong) spec="$spec_strong" ;; fast) spec="$spec_fast" ;; *) spec="$spec_standard" ;;
  esac
  prompt="$bundle/.prompts/$id.md"
  render "$prompts/concern.md" "$prompt" \
    "BUNDLE=$bundle" "REPO_DIR=$REPO_DIR" "CONCERN_FILE=$cfile" "CONCERN_ID=$id" \
    "FINDINGS_FILE=$out" "MANIFEST=$bundle/manifest.env"
  export WTC_REVIEW_STATS_FILE="$bundle/stats/$id.json"
  run_chain "$id tier=$tier" "$bundle/.logs/$id.out" "$prompt" "$spec" || rc=$?
  agent="$CHAIN_AGENT" model="$CHAIN_MODEL" rc="$CHAIN_RC"
  secs="$CHAIN_SECS"
  # A nonzero exit stays a failure even when a findings file was written.
  # The file is kept as .raw for diagnosis; it does not clear the error.
  why=""
  if [ "$rc" -eq 124 ]; then why="timeout after ${HARNESS_REVIEW_TIMEOUT}s"
  elif [ "$rc" -ne 0 ]; then why="agent exited $rc"
  elif [ ! -f "$out" ]; then why="no findings file written"
  elif ! python3 "$py" validate-findings "$out" "$id" 2>"$bundle/.logs/$id.invalid"; then
    why="invalid findings JSON: $(head -c 300 "$bundle/.logs/$id.invalid")"
  fi
  if [ -z "$why" ]; then sstatus=ok; elif [ "$rc" -eq 124 ]; then sstatus=timeout; else sstatus=error; fi
  finish_stats "$id" "$bundle/.logs/$id.out" "$agent" "$model" "$secs" "$sstatus"
  cat "$bundle/.logs/$id.out"
  if [ -n "$why" ]; then
    if [ -f "$out" ]; then
      mv "$out" "$bundle/findings/$id.raw"
    elif [ ! -f "$bundle/findings/$id.raw" ]; then
      cp "$bundle/.logs/$id.out" "$bundle/findings/$id.raw"
    fi
    stub "$id" error "$why; raw output in findings/$id.raw"
    echo "ERROR $id: $why"
    return 0
  fi
  echo "done $id"
}

# --- concerns -----------------------------------------------------------------
ids=""
for f in "$bundle"/concerns/*.md; do
  [ -f "$f" ] || continue
  id="$(basename "$f" .md)"
  if [ -n "$only" ]; then
    case ",$only," in *",$id,"*) : ;; *) continue ;; esac
  fi
  ids="$ids $id"
done
log "run: bundle=$bundle concerns:${ids:- none} parallel=$parallel timeout=${HARNESS_REVIEW_TIMEOUT}s"
log "tiers: strong=$spec_strong standard=$spec_standard fast=$spec_fast lead=$spec_lead"
printf '%s\n' "$spec_lead" >"$bundle/lead.spec"
run_start="$(date +%s)"

# With --post the PR comment has a lifecycle: in progress -> summary (or failed).
finished=0 progress_posted=0 fail_reason=""
on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$finished" -eq 0 ] && [ "$progress_posted" -eq 1 ]; then
    "$script_dir/review-post.sh" "$bundle" --failed \
      --reason "${fail_reason:-run exited with status $rc}" >/dev/null 2>>"$runlog" ||
      echo "warn: could not mark the PR comment as failed" >&2
  fi
}
trap on_exit EXIT
trap 'fail_reason="interrupted"; exit 130' INT TERM

if [ "$post" -eq 1 ]; then
  python3 "$py" progress-md "$bundle" "$spec_strong" "$spec_standard" "$spec_fast" "$spec_lead" "$only" \
    >"$bundle/progress.md"
  # Refuses (stale head, forge unreachable) before any agent time is spent.
  "$script_dir/review-post.sh" "$bundle" --progress --body "$bundle/progress.md" >&2 ||
    { log "error: could not post the progress comment; not starting (run without --post to review offline)"; exit 1; }
  progress_posted=1
  log "progress comment posted (comment.id=$(cat "$bundle/comment.id" 2>/dev/null || echo unknown))"
fi

pids=() pid_ids=()
reap() { # wait for the oldest job, append its log
  local p="${pids[0]}" i="${pid_ids[0]}"
  wait "$p" || true
  { echo "=== concern $i ==="; cat "$bundle/.logs/$i.log"; } >>"$runlog"
  grep -E '^(ERROR|skipped)' "$bundle/.logs/$i.log" >&2 || true
  pids=("${pids[@]:1}"); pid_ids=("${pid_ids[@]:1}")
}
for id in $ids; do
  while [ "${#pids[@]}" -ge "$parallel" ]; do reap; done
  run_concern "$id" >"$bundle/.logs/$id.log" 2>&1 &
  pids+=("$!"); pid_ids+=("$id")
done
while [ "${#pids[@]}" -gt 0 ]; do reap; done

# A scheduled concern whose job died before writing anything must not vanish
# from the verdict: record it as an error (the lead and the verdict rule see it).
for id in $ids; do
  if [ ! -f "$bundle/findings/$id.json" ]; then
    stub "$id" error "concern run produced no findings file (the runner job ended without a result)"
    log "ERROR $id: no findings file; recorded as error"
    [ -f "$bundle/stats/$id.json" ] ||
      printf '{"agent":"","model":"","seconds":0,"status":"error"}\n' >"$bundle/stats/$id.json"
  fi
done

# --- lead ---------------------------------------------------------------------
rm -f "$bundle/summary.md" "$bundle/verdict"
lead_prompt="$bundle/.prompts/lead.md"
render "$prompts/lead.md" "$lead_prompt" \
  "BUNDLE=$bundle" "REPO_DIR=$REPO_DIR" "SUMMARY_FILE=$bundle/summary.md" \
  "VERDICT_FILE=$bundle/verdict" "MANIFEST=$bundle/manifest.env"
export WTC_REVIEW_STATS_FILE="$bundle/stats/lead.json"
rc=0
run_chain "lead" "$bundle/.logs/lead.out" "$lead_prompt" "$spec_lead" || rc=$?
lead_agent="$CHAIN_AGENT" lead_model="$CHAIN_MODEL" rc="$CHAIN_RC"
log "lead: agent=$lead_agent model=${lead_model:-default}"
lead_status=ok; [ "$rc" -eq 0 ] || lead_status=error; [ "$rc" -ne 124 ] || lead_status=timeout
finish_stats lead "$bundle/.logs/lead.out" "$lead_agent" "$lead_model" "$CHAIN_SECS" "$lead_status"
spec_lead="${lead_agent}:${lead_model}"
{ echo "=== lead ==="; cat "$bundle/.logs/lead.out"; } >>"$runlog"
# A nonzero lead exit is a failed run even when summary.md and verdict exist.
if [ "$rc" -ne 0 ]; then
  fail_reason="the lead run failed (exit $rc)"; log "error: $fail_reason"; exit 1
fi
[ -s "$bundle/summary.md" ] || { fail_reason="the lead wrote no summary.md"; log "error: $fail_reason"; exit 1; }
verdict="$(python3 "$py" verdict "$bundle/verdict")" || {
  fail_reason="verdict file missing or not one of pass | pass-with-notes | changes-requested"
  log "error: $fail_reason"; exit 1; }

# A concern that errored never silently passes (contract): pass → pass-with-notes.
if [ "$verdict" = pass ] && grep -l '"status": *"error"' "$bundle"/findings/*.json >/dev/null 2>&1; then
  verdict=pass-with-notes
  printf '%s\n' "$verdict" >"$bundle/verdict"
  log "verdict downgraded to pass-with-notes: at least one concern run errored"
fi

blockers="$(python3 "$py" blockers "$bundle/findings")"
if [ "$blockers" -gt 0 ] && [ "$verdict" != changes-requested ]; then
  verdict=changes-requested
  printf '%s\n' "$verdict" >"$bundle/verdict"
  log "verdict set to changes-requested: $blockers open blocker finding(s)"
fi
# The tool owns the status line: drop any the lead wrote, append ours.
tmp_summary="$bundle/.summary.tmp"
grep -v 'wtc-review v1 head=' "$bundle/summary.md" >"$tmp_summary" || true
{
  cat "$tmp_summary"
  printf '\n'
  python3 "$py" stats-table "$bundle" "$(( $(date +%s) - run_start ))" || true
  printf '\n`wtc-review v1 head=%s verdict=%s blockers=%s round=%s lead=%s`\n' \
    "$HEAD_SHA" "$verdict" "$blockers" "$ROUND" "$spec_lead"
} >"$bundle/summary.md"
rm -f "$tmp_summary"
python3 "$py" present "$bundle" || log "warn: could not color the summary"
log "verdict=$verdict blockers=$blockers round=$ROUND -> $bundle/summary.md"

if [ "$post" -eq 1 ]; then
  # Updates the progress comment in place.
  if ! "$script_dir/review-post.sh" "$bundle" >&2; then
    fail_reason="posting the summary failed (see review-post output; summary.md is kept in the bundle)"
    log "error: $fail_reason"; exit 1
  fi
fi
finished=1
echo "$bundle"
