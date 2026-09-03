#!/usr/bin/env bash
# wtc-open.sh — open collections as herdr workspaces (terminal ergonomics).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/wtc-open.sh [options] [<collection> ...]
  tools/wtc-open.sh --all [options]
  tools/wtc-open.sh --list

Opens each collection as one workspace in the workspace root's herdr session:
a single tab at the collection root, default panes agent / browse / shell /
status, all carrying the collection env (.env.collection, then
.env.collection.local) and the sibling toolchain prefix (.env.toolchain) —
so no mise or shell activation is needed for ports, collection-scoped
secrets, or repo-pinned tools to resolve.

With no <collection>, opens the collection containing this harness worktree.
Re-running is safe: an existing workspace with that label is reused, never
duplicated, and every pane that is sitting at a bare prompt gets its command
back — the agent, browse's nvim, the status table. That is the fix for a
session restored after a reboot, which comes back with the layout but not the
processes. The herdr session is started headless if it is not running; you
attach to it yourself with `herdr --session <name>`.

A workspace holds no state — it is a view onto worktrees that already exist
(AGENTS.md → "State lives in git"). Closing it loses nothing; retire.sh
removes it along with the collection.

  --all             every collection in the workspace root
  --list            report what is open in each workspace, pane by pane, and
                    exit — nothing is created, started, or focused
  --dry-run         say what each pane needs; change nothing
  --session <name>  herdr session (default: workspace-root name minus a
                    trailing "-wtc" or "-harness"; override with
                    $HARNESS_HERDR_SESSION)
  --agent <kind>    agent kind to start (default: claude; see `herdr agent`)
  --agent-args "…"  args passed to the agent, replacing the default
                    (claude: --dangerously-skip-permissions; a wtc is an
                    isolated worktree on its own branch, so the prompts buy
                    nothing that branch review doesn't already give)
  --no-remote-control
                    start claude without Remote Control. On by default for
                    claude started with the default args — passing
                    --agent-args replaces those wholesale and leaves it off.
                    With it, the session appears in the Claude mobile app and
                    on claude.ai, named for the collection. Start-time only —
                    a session started without it cannot be attached later
  --no-agent        create the panes but start no agent
  --no-first-prompt start the agent but do not hand it its first prompt.
                    On a fresh collection (HANDOFF.md still present) the
                    agent is otherwise told to run /wtc-start as soon as it
                    is ready, and the submission is checked — the agent has
                    to be seen working on it, not just holding the text
  --no-status       leave the status pane at a shell prompt (it is otherwise
                    (re)started whenever that pane is idle)
  --no-browse       leave the browse pane at a shell prompt. By default it
                    opens LazyVim on the collection (tools/wtc-browse.sh)
                    when nvim is on PATH, which is what that pane is for — a
                    workspace whose human pane is an empty prompt asks you to
                    type the one command it already knows. Without nvim the
                    pane is left alone either way
  --focus           focus the last opened workspace (default: no focus)
EOF
  exit "${1:-1}"
}

all=no list=no dry_run=no session="" agent_kind="" agent_kind_set=no start_agent=yes focus=no
agent_args="" agent_args_set=no remote_control=yes start_browse=yes start_status=yes
first_prompt=yes
while [ $# -gt 0 ]; do
  case "$1" in
    --all) all=yes; shift ;;
    --list) list=yes; shift ;;
    --session) session="${2:?--session needs a name}"; shift 2 ;;
    --agent) agent_kind="${2:?--agent needs a kind}"; agent_kind_set=yes; shift 2 ;;
    --agent-args) agent_args="${2-}"; agent_args_set=yes; shift 2 ;;
    --no-remote-control) remote_control=no; shift ;;
    --dry-run) dry_run=yes; shift ;;
    --no-agent) start_agent=no; shift ;;
    --no-first-prompt) first_prompt=no; shift ;;
    --no-browse) start_browse=no; shift ;;
    --no-status) start_status=no; shift ;;
    --focus) focus=yes; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
. "$script_dir/lib.sh"
harness_lib_init

herdr_present || { echo "error: herdr is not installed (see instructions/herdr.md)" >&2; exit 1; }
[ -n "$session" ] || session="$(herdr_session_name)"

# Ceiling, in seconds, on waiting for a freshly created pane to reach its
# prompt. Polled rather than slept: a pane that settles in a second costs a
# second, and only a pane that never settles costs the whole budget.
PANE_SETTLE=10

# Machine defaults from the control root; flags still win (instructions/secrets.md).
load_wtc_config
[ "$agent_kind_set" = yes ] || agent_kind="$WTC_AGENT_KIND"
if [ "$agent_args_set" = no ] && [ -n "${WTC_AGENT_ARGS:-}" ]; then
  agent_args="$WTC_AGENT_ARGS"
  agent_args_set=yes
fi
if [ "$agent_args_set" = no ] && [ "$agent_kind" = claude ]; then
  agent_args="--dangerously-skip-permissions"
fi

# Which collections? Explicit args, --all, or the one holding this harness.
collections=""
if [ "$all" = yes ]; then
  for d in "$ROOT"/*/; do
    d="${d%/}"
    [ -d "$d/harness" ] || continue
    collections="$collections $(basename "$d")"
  done
elif [ $# -gt 0 ]; then
  collections="$*"
else
  here="$(cd "$HARNESS_DIR/.." && pwd)"
  [ -d "$here/harness" ] || { echo "error: $here is not a collection; name one explicitly" >&2; exit 1; }
  collections="$(basename "$here")"
fi
[ -n "${collections// /}" ] || { echo "error: no collections found under $ROOT" >&2; exit 1; }

# --- what is already open ---------------------------------------------------
# A pane can exist and still be an empty prompt — that is exactly what a herdr
# session restored after a reboot looks like, layout without processes. So the
# question is never "is there a status pane" but "is anything running in it",
# and every pane is inspected before anything is started. One `pane list` per
# workspace plus one process lookup per pane answers it.

# <rows> <label> -> missing | idle | stale <agent> | agent <kind> <status> | running <cmd>
pane_state() {
  _pid="$(herdr_row_col "$1" "$2" 2)"
  [ -n "$_pid" ] || { printf 'missing\n'; return 0; }
  _kind="$(herdr_row_col "$1" "$2" 3)"
  _cmd="$(herdr_pane_fg_cmdline "$session" "$_pid")"
  if herdr_cmdline_is_shell "$_cmd"; then
    # herdr still names an agent on a pane whose agent has exited. The prompt
    # is the truth: that pane is empty and wants its agent back.
    if [ -n "$_kind" ]; then printf 'stale %s\n' "$_kind"; else printf 'idle\n'; fi
    return 0
  fi
  if [ -n "$_kind" ]; then
    printf 'agent %s %s\n' "$_kind" "$(herdr_row_col "$1" "$2" 4)"
    return 0
  fi
  # A script's foreground process is its interpreter, so name the script:
  # a status pane reads "wtc-status.sh", not "bash".
  _show=""
  # shellcheck disable=SC2086
  for _w in $_cmd; do
    case "$_w" in *=*|-*) continue ;; esac
    _b="${_w##*/}"
    case "$_b" in env|zsh|bash|fish|sh|nu|dash|ksh|python3|python|node|ruby|perl) continue ;; esac
    _show="$_b"; break
  done
  if [ -z "$_show" ]; then _show="${_cmd%% *}"; _show="${_show##*/}"; fi
  printf 'running %s\n' "$_show"
}

state_label() { # <state words…> -> one human phrase
  case "$1" in
    missing) printf 'no pane' ;;
    idle)    printf 'empty' ;;
    stale)   printf 'empty (%s exited)' "$2" ;;
    agent)   printf '%s %s' "$2" "${3:-unknown}" ;;
    running) printf '%s' "$2" ;;
    *)       printf '%s' "$1" ;;
  esac
}

note() { report="${report:+$report, }$*"; }

if [ "$list" = yes ]; then
  if ! herdr_session_running "$session"; then
    echo "herdr session '$session': not running"
    exit 0
  fi
  echo "herdr session '$session':"
  for c in $collections; do
    if [ ! -d "$ROOT/$c/harness" ]; then
      printf '  %-34s %-4s not a collection (no harness/)\n' "$c" "-"
      continue
    fi
    ws="$(herdr_ws_id "$session" "$c")"
    if [ -z "$ws" ]; then
      printf '  %-34s %-4s no workspace\n' "$c" "-"
      continue
    fi
    rows="$(herdr_pane_rows "$session" "$ws")"
    line=""
    for lbl in agent browse shell status; do
      st="$(pane_state "$rows" "$lbl")"
      # A shell pane at its prompt is not empty, it is what it should be.
      [ "$lbl" = shell ] && [ "$st" = idle ] && st=ready
      # shellcheck disable=SC2086
      line="$line  $lbl: $(state_label $st)"
    done
    printf '  %-34s %-4s%s\n' "$c" "$ws" "$line"
  done
  echo "attach: herdr --session $session"
  exit 0
fi

herdr_ensure_session "$session"

# The status pane, like browse: beside the shell (under browse), or under the
# shell on a pre-browse workspace where the right column is already stacked.
ensure_status_pane() { # <workspace> <cwd> -> pane id
  _base="$(herdr_pane_id_by_label "$session" "$1" shell)"
  _dir=right
  if [ -z "$_base" ]; then
    _base="$(herdr_pane_id_by_label "$session" "$1" browse)"
    _dir=down
  fi
  [ -n "$_base" ] || return 1
  _pane="$(herdr --session "$session" pane split "$_base" \
    --direction "$_dir" --cwd "$2" --no-focus | herdr_first_pane_id)"
  [ -n "$_pane" ] || return 1
  herdr --session "$session" pane rename "$_pane" status >/dev/null
  printf '%s\n' "$_pane"
}

open_collection() { # <collection>
  name="$1"
  dir="$ROOT/$name"
  [ -d "$dir/harness" ] || { echo "skip: $name is not a collection (no harness/)" >&2; return 0; }
  report="" settle=0
  # Same WTC_AGENT_NAME the pane env carries (from .env.collection).
  WTC_AGENT_NAME="$(resolve_agent_name "$dir" "$session" "$name")"

  ws_id="$(herdr_ws_id "$session" "$name")"
  if [ -z "$ws_id" ]; then
    if [ "$dry_run" = yes ]; then
      echo "==> $name: no workspace — would create one: agent, browse, shell, status"
      return 0
    fi
    # Collection env into the workspace, so ports, collection-scoped secrets,
    # and sibling toolchain bins resolve without mise activate. Local last so
    # it wins on a conflicting key, same order as mise.toml's _.file list.
    set -- create --cwd "$dir" --label "$name" --no-focus
    for envf in "$dir/.env.collection" "$dir/.env.collection.local"; do
      [ -f "$envf" ] || continue
      while IFS= read -r kv; do
        case "$kv" in ''|\#*) continue ;; esac
        set -- "$@" --env "$kv"
      done < "$envf"
    done
    if [ -x "$dir/harness/tools/agent-env.sh" ]; then
      "$dir/harness/tools/agent-env.sh" --write >/dev/null 2>&1 || true
    fi
    _tp=""
    if [ -f "$dir/.env.toolchain" ]; then
      _tp="$(sed -n 's/^WTC_TOOLCHAIN_PATH=//p' "$dir/.env.toolchain" | head -n1)"
    fi
    if [ -n "$_tp" ]; then
      # Pass the prefix, not a PATH. herdr sets these before the pane's shell
      # runs, and on macOS /etc/zprofile's path_helper then rebuilds PATH with
      # the system paths first — an injected prefix lands *below* /usr/bin, so
      # `ruby` resolves to system 2.6 and the injection silently achieves the
      # opposite of its purpose. Verified: prefix passed at position 1 comes
      # out at position 18, /usr/bin at 6.
      #
      # WTC_TOOLCHAIN_PATH is an ordinary variable, so path_helper leaves it
      # alone, and the surfaces that apply it all run *after* the profile:
      # BASH_ENV for the non-interactive shells agent CLIs spawn, the
      # PreToolUse hook for their tool calls, `.envrc` for direnv/Grok.
      set -- "$@" --env "WTC_TOOLCHAIN_PATH=$_tp"
      if [ -x "$dir/harness/tools/agent-env.sh" ]; then
        set -- "$@" --env "BASH_ENV=$dir/harness/tools/agent-env.sh"
      fi
    fi

    ws_out="$(herdr --session "$session" workspace "$@")"
    ws_id="$(printf '%s' "$ws_out" | tr '{}' '\n\n' | sed -n 's/.*"workspace_id":"\([^"]*\)".*/\1/p' | head -n1)"
    agent_pane="$(printf '%s' "$ws_out" | herdr_first_pane_id)"
    [ -n "$agent_pane" ] || { echo "error: $name: could not read the new pane id" >&2; return 1; }

    # Default layout: agent is the full-height left column; browse (nvim)
    # is the human pane on the right; terminal and status split under it.
    #   [ agent | browse        ]
    #   [       | shell | status]
    browse_pane="$(herdr --session "$session" pane split "$agent_pane" \
      --direction right --ratio 0.40 --cwd "$dir" --no-focus | herdr_first_pane_id)"
    herdr --session "$session" pane rename "$agent_pane" agent >/dev/null
    if [ -n "$browse_pane" ]; then
      herdr --session "$session" pane rename "$browse_pane" browse >/dev/null
      shell_pane="$(herdr --session "$session" pane split "$browse_pane" \
        --direction down --ratio 0.70 --cwd "$dir" --no-focus | herdr_first_pane_id)"
    else
      shell_pane="$(herdr --session "$session" pane split "$agent_pane" \
        --direction right --cwd "$dir" --no-focus | herdr_first_pane_id)"
    fi
    if [ -n "$shell_pane" ]; then
      herdr --session "$session" pane rename "$shell_pane" shell >/dev/null
    fi
    settle=$PANE_SETTLE   # its panes have not reached their prompts yet
    note "workspace created"
  fi

  # browse / status — added to workspaces opened before they existed. Panes
  # that are already there are untouched.
  if [ "$dry_run" = no ]; then
    had_browse="$(herdr_pane_id_by_label "$session" "$ws_id" browse)"
    fresh="$(herdr_ensure_browse_pane "$session" "$ws_id" "$dir" || true)"
    # Only a pane this call just made needs settling. An existing browse pane
    # is quite likely running nvim, and waiting on that would spend the whole
    # budget to learn what one look already says.
    if [ -z "$had_browse" ] && [ -n "$fresh" ]; then
      herdr_pane_wait_idle "$session" "$fresh" "$PANE_SETTLE" || true
    fi
    if [ "$start_status" = yes ] \
       && [ -z "$(herdr_pane_id_by_label "$session" "$ws_id" status)" ]; then
      fresh="$(ensure_status_pane "$ws_id" "$dir" || true)"
      [ -z "$fresh" ] || herdr_pane_wait_idle "$session" "$fresh" "$PANE_SETTLE" || true
    fi
  fi

  # A workspace created a moment ago has four panes still running their shell
  # rc, and herdr reports that rc's own commands as each pane's foreground
  # process. Reading the rows now is a coin flip per pane, and a pane that
  # comes up busy is "left alone" — the agent never starts, browse never
  # opens, and re-running wtc-open is the only way back. So wait for the
  # prompts before looking; nothing runs in a workspace this young, so every
  # pane is expected to hold one. Afterwards the panes are settled and the
  # per-pane budgets below have nothing left to wait for.
  if [ "$settle" != 0 ]; then
    herdr_ws_wait_idle "$session" "$ws_id" "$settle"
    settle=0
  fi

  rows="$(herdr_pane_rows "$session" "$ws_id")"

  # --- agent ---------------------------------------------------------------
  agent_pane="$(herdr_row_col "$rows" agent 2)"
  st="$(pane_state "$rows" agent)"
  if [ "$start_agent" = no ]; then
    note "agent skipped"
  else
    # shellcheck disable=SC2086  # state_label takes the split words on purpose
    case "${st%% *}" in
      missing) note "agent no pane" ;;
      agent)   note "agent live ($(state_label $st))" ;;
      running) note "agent busy (${st#running }) — left alone" ;;
      *)
        # A collection that still has its launch note has not been started:
        # the agent's first move is /wtc-start, and nobody should have to
        # type it into the pane. Only on this path — an agent that is
        # already live keeps whatever it is doing.
        want_first=no
        [ "$first_prompt" = yes ] && [ -f "$dir/HANDOFF.md" ] && want_first=yes
        if [ "$dry_run" = yes ]; then
          note "agent empty → would start $agent_kind"
          [ "$want_first" = no ] || note "would submit $(first_prompt_text)"
        elif start_agent_in_pane; then
          if [ "$want_first" = no ]; then
            note "agent started ($agent_kind)"
          elif first_prompt_in_pane; then
            note "agent started ($agent_kind), $(first_prompt_text) running"
          else
            note "agent started ($agent_kind) — first prompt not taken, type it"
          fi
        else
          note "agent start failed"
        fi
        ;;
    esac
  fi

  # --- browse --------------------------------------------------------------
  # `pane run` takes a shell command string, so both halves are quoted: a
  # collection directory may contain spaces, and anything unquoted here would
  # be evaluated by that pane's shell. The target collection's own tools — not
  # this script's: opening collection B via collection A's wtc-open used to
  # leave B's panes bound to A's harness path, and retiring A then broke them.
  st="$(pane_state "$rows" browse)"
  if [ "$start_browse" = no ]; then
    note "browse skipped"
  else
    case "${st%% *}" in
      missing) note "browse no pane" ;;
      running) note "browse live (${st#running })" ;;
      *)
        if ! command -v nvim >/dev/null 2>&1; then
          note "browse empty (no nvim)"
        elif [ "$dry_run" = yes ]; then
          note "browse empty → would start nvim"
        else
          # Relative to the pane's cwd (the collection root), and no
          # collection argument: wtc-browse defaults to the one it is run
          # from. What lands in that pane's shell history is then a command
          # anyone can re-run from any collection, instead of one machine's
          # absolute paths.
          browse_cmd='./harness/tools/wtc-browse.sh --here'
          if herdr_pane_run_idle "$session" "$(herdr_row_col "$rows" browse 2)" \
               "$browse_cmd" "$settle"; then
            note "browse started"
          else
            note "browse start failed"
          fi
        fi
        ;;
    esac
  fi

  # --- shell ---------------------------------------------------------------
  st="$(pane_state "$rows" shell)"
  case "${st%% *}" in
    missing) note "shell no pane" ;;
    running) note "shell busy (${st#running })" ;;
    *)       note "shell ready" ;;
  esac

  # --- status --------------------------------------------------------------
  st="$(pane_state "$rows" status)"
  if [ "$start_status" = no ]; then
    note "status skipped"
  else
    case "${st%% *}" in
      missing) note "status no pane" ;;
      running) note "status live" ;;
      *)
        if [ "$dry_run" = yes ]; then
          note "status empty → would start wtc-status"
        else
          # --repos is the pane's intent (the process table is its own pane);
          # the interval, click and scope come from wtc-status itself now.
          status_cmd='./harness/tools/wtc-status-tui.sh'
          if herdr_pane_run_idle "$session" "$(herdr_row_col "$rows" status 2)" \
               "$status_cmd" "$settle"; then
            note "status started"
          else
            note "status start failed"
          fi
        fi
        ;;
    esac
  fi

  if [ "$focus" = yes ] && [ -n "$ws_id" ] && [ "$dry_run" = no ]; then
    herdr --session "$session" workspace focus "$ws_id" >/dev/null
  fi
  echo "==> $name: $ws_id — $report"
  return 0
}

# Start the collection's agent in its pane. Remote Control puts this session in
# the Claude mobile app and claude.ai. The whole point of a wtc agent is that it
# keeps working while you are not at this machine, and a collection you cannot
# check on from a phone misses half of that. Claude only accepts it at START
# time — there is no in-session toggle — so it is decided here or not at all,
# and the remote session is named for the collection so the mobile list reads
# like the workspace does. Only applies to the default claude args:
# --agent-args or --no-remote-control leave it off.
start_agent_in_pane() {
  this_agent_args="$agent_args"
  if [ "$remote_control" = yes ] && [ "$agent_args_set" = no ] && [ "$agent_kind" = claude ]; then
    this_agent_args="$this_agent_args --remote-control $WTC_AGENT_NAME"
  fi

  # Agent names: [a-z][a-z0-9_-]{0,31}, unique among live agents.
  # Name comes from WTC_AGENT_NAME (collection env); kind/args from wtc.env.
  # Intentional word-splitting: $agent_args is a flag string, not a path.
  # shellcheck disable=SC2086
  set -- start "$WTC_AGENT_NAME" --kind "$agent_kind" --pane "$agent_pane"
  if [ -n "$this_agent_args" ]; then
    set -- "$@" -- $this_agent_args
  fi
  # A freshly created pane needs a moment before its shell is "available".
  n=0
  until err="$(herdr --session "$session" agent "$@" 2>&1 >/dev/null)"; do
    n=$((n + 1))
    if [ "$n" -ge 15 ]; then
      echo "error: $name: could not start $agent_kind in $agent_pane: $err" >&2
      return 1
    fi
    sleep 1
  done
  return 0
}

# What a fresh collection's agent is told first. Claude runs the skill by its
# slash name; other kinds get the same thing in words, since their skill
# surfaces differ and the words are enough to make the right one fire.
first_prompt_text() {
  case "$agent_kind" in
    claude) printf '%s' "/wtc-start" ;;
    *) printf '%s' "Run the wtc-start skill (harness/skills/wtc-start/SKILL.md): read HANDOFF.md at the collection root, then start." ;;
  esac
}

# Hand the agent its first prompt and do not trust the send. Typing a slash
# command into Claude opens its command palette, and there the first Enter
# completes the command rather than sending it — so the text can sit in the
# chat entry looking submitted while the agent stays idle. herdr's prompt
# surface does add an Enter, but the only proof is the agent going to work:
# wait for exactly that, and when herdr reports the submission stalled, the
# palette has eaten the Enter and one more is what is owed.
first_prompt_in_pane() { # -> 0 once the agent is working on it
  _fp="$(first_prompt_text)"
  _out="$(herdr --session "$session" agent prompt "$WTC_AGENT_NAME" "$_fp" \
            --wait --until working --timeout 20000 2>&1)" && return 0
  case "$_out" in
    *agent_prompt_stalled*)
      herdr --session "$session" agent send-keys "$WTC_AGENT_NAME" enter >/dev/null 2>&1 || return 1
      herdr --session "$session" agent wait "$WTC_AGENT_NAME" \
        --until working --timeout 10000 >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

for c in $collections; do
  open_collection "$c"
done

echo "attach: herdr --session $session"
