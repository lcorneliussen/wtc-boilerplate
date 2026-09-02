# lib.sh — shared helpers for harness tools. Source this, don't execute it.
# Bash 3.2-safe (macOS default): no mapfile, no associative arrays.
#
# Callers must set HARNESS_DIR (the harness worktree, i.e. dirname of tools/)
# and then call harness_lib_init. Provides: ROOT, REGISTRY, LOCAL_REPOS and
# the functions below.

harness_lib_init() {
  ROOT="$HARNESS_DIR"
  while [ "$ROOT" != "/" ] && [ ! -d "$ROOT/.bare" ]; do
    ROOT="$(dirname "$ROOT")"
  done
  [ -d "$ROOT/.bare" ] || { echo "error: no .bare/ found above $HARNESS_DIR" >&2; exit 1; }
  REGISTRY="$HARNESS_DIR/.harness-repos.yml"
  LOCAL_REPOS="$HARNESS_DIR/.harness-repos"
  # Deliberately not fatal when absent, unlike REGISTRY: a harness worktree on
  # a branch that predates .mcp-servers.yml must still run every other tool.
  MCP_REGISTRY="${MCP_REGISTRY:-$HARNESS_DIR/.mcp-servers.yml}"
  [ -f "$REGISTRY" ] || { echo "error: $REGISTRY missing" >&2; exit 1; }
}

# The collection folder is always `harness/`; the repo behind it is whatever
# you named your fork of this one. Set WTC_HARNESS_REPO to that name — it has
# to match the bare in `.bare/` and the `name:` in the registry.
harness_repo() {
  printf '%s\n' "${WTC_HARNESS_REPO:-agent-harness}"
}

registry_field() { # <repo-name> <field> — one scalar field from the repo's block
  # Soft-fail when the file is gone (a status --watch still running after its
  # harness worktree was retired) rather than dumping awk noise into the table.
  [ -f "$REGISTRY" ] || return 0
  awk -v repo="$1" -v field="$2:" '
    $1 == "-" && $2 == "name:"   { cur = $3 }
    cur == repo && $1 == field   { print $2; exit }
  ' "$REGISTRY"
}

registry_all_names() {
  [ -f "$REGISTRY" ] || return 0
  awk '$1 == "-" && $2 == "name:" { print $3 }' "$REGISTRY"
}

# --- MCP registry (.mcp-servers.yml) ------------------------------------
# Same block-scanner shape as the repo registry above, with one difference:
# these fields hold lists (`args`, `env`, `agents`), so the value is the whole
# rest of the line rather than $2. Callers split on whitespace.

mcp_registry_file() {
  printf '%s\n' "${MCP_REGISTRY:-$HARNESS_DIR/.mcp-servers.yml}"
}

# Locals are _mcp_-prefixed throughout: lib.sh is sourced, has no `local`
# discipline (bash 3.2), and callers already own short names — wtc-status.sh
# keeps its mode flag in `want` and a cache path in `f`.

mcp_all_names() {
  _mcp_f="$(mcp_registry_file)"
  [ -f "$_mcp_f" ] || return 0
  awk '$1 == "-" && $2 == "name:" { print $3 }' "$_mcp_f"
}

mcp_field() { # <server-name> <field> — rest of the line after "<field>:"
  _mcp_f="$(mcp_registry_file)"
  [ -f "$_mcp_f" ] || return 0
  awk -v srv="$1" -v field="$2:" '
    $1 == "-" && $2 == "name:" { cur = $3 }
    cur == srv && $1 == field {
      # Strip leading blanks and the field token itself; what remains is the
      # value, spaces and all. sub() on $0 so a list field survives intact.
      sub(/^[[:blank:]]*[^[:blank:]]+[[:blank:]]*/, "")
      # Then a trailing inline comment, which YAML would not consider part of
      # the value either. Only when preceded by blanks, so a value containing
      # a bare # survives. Without this, `enabled: no  # for now` reads as
      # "no  # for now" and the server renders anyway — and the schema example
      # in instructions/mcp.md is written with inline comments, so this is the
      # documented way to write the file, not an edge case.
      sub(/[[:blank:]]+#.*$/, "")
      sub(/[[:blank:]]+$/, "")
      print
      exit
    }
  ' "$_mcp_f"
}

# Does this server render for <agent>? Absent `agents:` means all of them.
mcp_wants_agent() { # <server-name> <agent>
  _mcp_want="$(mcp_field "$1" agents)"
  [ -n "$_mcp_want" ] || return 0
  for _mcp_a in $_mcp_want; do [ "$_mcp_a" = "$2" ] && return 0; done
  return 1
}

mcp_enabled() { # <server-name>
  case "$(mcp_field "$1" enabled)" in
    no|false|No|False) return 1;;
    *) return 0;;
  esac
}

bare_for() { # <repo-name> -> bare path (local file first, then convention)
  bare=""
  if [ -f "$LOCAL_REPOS" ]; then
    bare="$(sed -n "s|^$1=||p" "$LOCAL_REPOS" | head -n1)"
  fi
  [ -n "$bare" ] || bare="$ROOT/.bare/$1.git"
  printf '%s\n' "$bare"
}

# Where a worktree's refs actually live. bare_for maps a NAME onto the
# `.bare/` convention and so only knows registry repos; this asks the worktree
# itself and therefore also resolves unmanaged `ext.` siblings, whose owner is
# an ordinary clone outside the workspace
# (instructions/worktree-workspace.md). Prefer it wherever a worktree is
# already in hand — fetching and teardown both need the real owner, not the
# path a registry name would have implied.
owner_of() { # <worktree> -> absolute git common dir, or empty
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true
}

default_ref_for() { # <repo-name> -> default_ref from registry (fallback origin/main)
  ref="$(registry_field "$1" default_ref)"
  [ -n "$ref" ] || ref="origin/main"
  printf '%s\n' "$ref"
}

ensure_bare() { # <repo-name> — clone the bare owner from the registry remote if missing
  repo="$1"
  bare="$(bare_for "$repo")"
  [ -d "$bare" ] && return 0
  remote="$(registry_field "$repo" remote)"
  [ -n "$remote" ] || { echo "error: '$repo' not in $REGISTRY (no remote)" >&2; exit 1; }
  echo "==> $repo: bare owner missing — cloning $remote"
  git clone --bare "$remote" "$bare"
  git --git-dir="$bare" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git --git-dir="$bare" fetch --all --prune
}

file_age_secs() { # <file> -> age in seconds, or a huge number if absent
  [ -f "$1" ] || { echo 999999999; return 0; }
  # GNU first: `stat -f %m` is valid on GNU coreutils but means "filesystem
  # mount point", a non-numeric string that would crash the $(( )) below.
  m="$(stat -c %Y "$1" 2>/dev/null || true)"
  case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null || true)" ;; esac
  case "$m" in ''|*[!0-9]*) m=0 ;; esac
  echo $(($(date +%s) - m))
}

# Working on stale refs is how you write a PR against a base that moved a week
# ago. Fetching is cheap; fetching on every redraw of a --watch pane is not,
# hence the age gate rather than a flag nobody remembers to pass.
fetch_if_stale() { # <bare> [max-age-secs, default 300] -> 0 if refs are fresh
  bare="$1" max="${2:-300}"
  [ -d "$bare" ] || return 1
  [ "$(file_age_secs "$bare/FETCH_HEAD")" -lt "$max" ] && return 0
  git --git-dir="$bare" fetch --prune origin >/dev/null 2>&1 || return 1
  return 0
}

# The resting state of a worktree is DETACHED AT THE TIP, not a branch:
#   * a branch can only be checked out in one worktree, so branch-per-collection
#     made the development tip a resource collections had to queue for;
#     detached HEADs let every collection sit on it at once
#   * a branch created before the work has an identity gets the wrong name, and
#     the name is the issue mapping — so branches are created at the first
#     commit, when the name is actually known
# Pass an empty <branch> for that. A non-empty <branch> is an explicit request
# (a PR's head branch, or -b), and still checks out / creates a real branch.
add_worktree() { # <repo-name> <dir-name> <dest-root> <branch-or-empty>
  repo="$1" dir="$2" dest_root="$3" branch="$4"
  ensure_bare "$repo"
  bare="$(bare_for "$repo")"
  ref="$(default_ref_for "$repo")"
  echo "==> $repo: fetch --prune"
  git --git-dir="$bare" fetch --prune origin
  if [ -z "$branch" ]; then
    echo "==> $repo: worktree $dest_root/$dir detached at $ref"
    git --git-dir="$bare" worktree add --detach "$dest_root/$dir" "$ref"
  elif git --git-dir="$bare" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    echo "==> $repo: worktree $dest_root/$dir on existing branch $branch"
    git --git-dir="$bare" worktree add "$dest_root/$dir" "$branch"
  elif git --git-dir="$bare" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
    echo "==> $repo: worktree $dest_root/$dir tracking origin/$branch"
    git --git-dir="$bare" worktree add -b "$branch" "$dest_root/$dir" "origin/$branch"
  else
    echo "==> $repo: worktree $dest_root/$dir on new branch $branch (from $ref)"
    git --git-dir="$bare" worktree add -b "$branch" "$dest_root/$dir" "$ref"
  fi
  trust_mise "$dest_root/$dir"
}

# One reading of "where is this worktree", so the status table and the
# catch-up procedure cannot disagree about what "up to date" means.
#
# The two numbers answer different questions and so use different references:
#   ahead  — work not yet pushed, measured against the branch's own upstream
#            (against the tip when it has no upstream, i.e. never pushed)
#   behind — how stale this worktree is, ALWAYS measured against the
#            development tip. Measuring it against the branch's upstream would
#            report a branch as current while the tip moved a week past it,
#            which is precisely the state catch-up exists to surface.
wt_head_state() { # <worktree> <repo-name> -> "<kind> <label> <ahead> <behind>"
  wt="$1" repo="$2"
  ref="$(default_ref_for "$repo")"
  if git -C "$wt" symbolic-ref -q HEAD >/dev/null 2>&1; then
    kind=branch
    label="$(git -C "$wt" branch --show-current)"
    up="$(git -C "$wt" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "$ref")"
  else
    kind=detached
    label="${ref#origin/}"
    up="$ref"
  fi
  ahead="$(git -C "$wt" rev-list --count "$up..HEAD" 2>/dev/null || echo 0)"
  behind="$(git -C "$wt" rev-list --count "HEAD..$ref" 2>/dev/null || echo 0)"
  printf '%s %s %s %s\n' "$kind" "$label" "$ahead" "$behind"
}

trust_mise() { # <dir> — trust dir/mise.toml if mise is installed (no-op otherwise)
  if [ -f "$1/mise.toml" ] && command -v mise >/dev/null 2>&1; then
    mise trust "$1/mise.toml" >/dev/null 2>&1 || true
  fi
}

# Lifecycle hook contract (instructions/hooks-and-env.md). Resolution order:
#   1. repo mise.toml defines task "harness:<hook>" and mise is installed
#   2. executable .harness/<hook>.sh in the repo
#   3. no-op
# A failing hook never fails its caller. Hooks are third-party code living in
# each product repo, and callers run under `set -e`: propagating the failure
# would abort collection creation partway, leaving a half-built collection —
# strictly worse than one repo whose setup did not complete. Report loudly and
# carry on; the operator fixes the repo and re-runs the hook's own tool.
run_hook() { # <worktree-path> <init|teardown>
  wt="$1" hook="$2" status=0
  if [ -f "$wt/mise.toml" ] && command -v mise >/dev/null 2>&1; then
    if (cd "$wt" && mise tasks ls 2>/dev/null | awk '{print $1}' | grep -qx "harness:$hook"); then
      echo "==> hook (mise): harness:$hook in $wt"
      (cd "$wt" && mise run "harness:$hook") || status=$?
      hook_warn "$wt" "$hook" "$status"
      return 0
    fi
  fi
  if [ -x "$wt/.harness/$hook.sh" ]; then
    echo "==> hook (script): .harness/$hook.sh in $wt"
    (cd "$wt" && "./.harness/$hook.sh") || status=$?
    hook_warn "$wt" "$hook" "$status"
    return 0
  fi
  return 0
}

hook_warn() { # <worktree-path> <hook> <status> — no-op on success
  [ "$3" -eq 0 ] && return 0
  echo "WARNING: $2 hook for $(basename "$1") exited $3 — continuing." >&2
  echo "         That worktree may be incompletely set up; see the hook's output above." >&2
  return 0
}

repo_slug_for() { # <repo-name> -> GitHub owner/repo derived from the registry remote
  remote="$(registry_field "$1" remote)"
  [ -n "$remote" ] || return 0
  # Both remote forms have to work. Stripping to the first ":" answers for
  # SSH (git@github.com:owner/repo.git) and turns an HTTPS remote into
  # "//github.com/owner/repo", which gh cannot resolve — so every PR cell in
  # wtc-status renders a GraphQL NOT_FOUND blob. Same host-anchored strip
  # slug_for_worktree already uses just below.
  case "$remote" in *github.com[:/]*) ;; *) return 0 ;; esac
  slug="${remote#*github.com}"; slug="${slug#:}"; slug="${slug#/}"
  printf '%s\n' "${slug%.git}"
}

slug_for_worktree() { # <worktree> [repo-name] -> owner/repo
  # Registry first, because it is a file read and answers for every repo the
  # workspace owns. Falling back to the worktree's own remote is what makes
  # `ext.` siblings work: they are deliberately outside the registry
  # (instructions/worktree-workspace.md), so a registry-only lookup returns
  # nothing and they silently lose every PR column in the table.
  if [ -n "${2:-}" ]; then
    slug="$(repo_slug_for "$2")"
    if [ -n "$slug" ]; then printf '%s\n' "$slug"; return 0; fi
  fi
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 0
  case "$url" in *github.com[:/]*) ;; *) return 0 ;; esac
  slug="${url#*github.com}"; slug="${slug#:}"; slug="${slug#/}"
  printf '%s\n' "${slug%.git}"
}

repo_for_issue_prefix() { # <prefix incl. trailing dash> -> repo name owning it
  awk -v pfx="$1" '
    $1 == "-" && $2 == "name:"          { cur = $3 }
    $1 == "issues_prefix:" && $2 == pfx  { print cur; exit }
  ' "$REGISTRY"
}

alloc_port_base() { # lowest free 42000+100n across existing collections' .env.collection
  base=42000
  while :; do
    used=no
    for f in "$ROOT"/*/.env.collection; do
      [ -f "$f" ] || continue
      b="$(sed -n 's/^COLLECTION_PORT_BASE=//p' "$f" | head -n1)"
      [ "$b" = "$base" ] && used=yes
    done
    if [ "$used" = no ]; then printf '%s\n' "$base"; return; fi
    base=$((base + 100))
  done
}

port_var_for() { # <repo-name> -> env var name, e.g. console -> CONSOLE_PORT
  printf '%s_PORT\n' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
}

# ---------------------------------------------------------------------------
# herdr helpers — terminal ergonomics only. A herdr session is a disposable
# view onto collections that already exist on disk; nothing durable may live
# in it (AGENTS.md → "State lives in git"). Every helper degrades to a no-op
# when herdr is not installed.
# ---------------------------------------------------------------------------

# The collection this harness worktree lives in. Every wtc tool defaults to
# it — a bare `tools/wtc-xyz.sh` acts here, and only an explicit --all or a
# named collection widens that (instructions/collection-context.md).
this_collection_dir() {
  (cd "$HARNESS_DIR/.." && pwd)
}

this_collection() {
  basename "$(this_collection_dir)"
}

# Machine-wide tool defaults, in the control root next to the secrets:
# $WTC_CONFIG_ROOT/wtc.env. The one place a changed default belongs, so a bare
# `tools/wtc-xyz.sh` keeps doing what this machine wants without flags in every
# command line. CLI flags still win. See instructions/secrets.md.
load_wtc_config() {
  : "${WTC_CONFIG_ROOT:=$HOME/.config/wtc}"
  if [ -f "$WTC_CONFIG_ROOT/wtc.env" ]; then
    # shellcheck disable=SC1091
    . "$WTC_CONFIG_ROOT/wtc.env"
  fi
  : "${WTC_AGENT_KIND:=claude}"
  : "${WTC_AGENT_ARGS:=}"
  : "${WTC_STATUS_REPOS:=no}"
  : "${WTC_STATUS_WATCH:=60}"
  : "${WTC_STATUS_NO_CLICK:=no}"
}

herdr_present() { command -v herdr >/dev/null 2>&1; }

# The session is named for the PROJECT, not for the folder that happens to
# hold it: the workspace-root basename minus a trailing "-wtc" or "-harness".
# Both suffixes say "this is the workspace for X" — the session wants to be
# called X, since that is what the human is switching between.
herdr_session_name() {
  if [ -n "${HARNESS_HERDR_SESSION:-}" ]; then
    printf '%s\n' "$HARNESS_HERDR_SESSION"
    return
  fi
  name="$(basename "$ROOT")"
  name="${name%-harness}"
  printf '%s\n' "${name%-wtc}"
}

herdr_session_running() { # <session> — read-only probe; nonzero if no server
  herdr --session "$1" workspace list >/dev/null 2>&1
}

# Every pane the server spawns inherits the server's environment. When the
# server is started from inside an agent's own shell, that environment marks
# the new panes as child sessions of that agent (transcript saving off,
# inherited permission mode). Strip agent-injected vars so panes start clean;
# login shells re-read the user's profile for anything legitimately theirs.
# -E, not BRE: BSD sed (macOS) has no \| alternation.
herdr_agent_env_vars() {
  env | sed -nE 's/^(CLAUDE[A-Z0-9_]*|ANTHROPIC[A-Z0-9_]*|AI_AGENT|CODEX[A-Z0-9_]*|CURSOR[A-Z0-9_]*|GEMINI[A-Z0-9_]*)=.*/\1/p'
}

herdr_ensure_session() { # <session> — start a headless server if none is up
  herdr_session_running "$1" && return 0
  echo "==> herdr: starting session '$1' (headless)"
  unset_args=""
  for v in $(herdr_agent_env_vars); do
    unset_args="$unset_args -u $v"
  done
  # Intentional word-splitting: $unset_args holds "-u NAME" pairs.
  # shellcheck disable=SC2086
  (env $unset_args herdr --session "$1" server >/dev/null 2>&1 &)
  n=0
  while [ "$n" -lt 60 ]; do
    herdr_session_running "$1" && return 0
    sleep 0.25
    n=$((n + 1))
  done
  echo "error: herdr session '$1' did not come up" >&2
  return 1
}

# No jq dependency (no tool is load-bearing): split on braces so each record
# becomes one or more lines, then pair fields by their order within a record.
# Records are NOT one line each — a workspace carrying metadata tokens has a
# nested object, which splits it — so accumulate fields until the id appears.
herdr_ws_pairs() { # <session> -> "<label>\t<workspace-id>\t<agent-status>" per workspace
  herdr --session "$1" workspace list 2>/dev/null \
    | tr '{}' '\n\n' \
    | awk '
        match($0, /"agent_status":"[^"]*"/) { st  = substr($0, RSTART + 16, RLENGTH - 17) }
        match($0, /"label":"[^"]*"/)        { lbl = substr($0, RSTART + 9,  RLENGTH - 10) }
        match($0, /"workspace_id":"[^"]*"/) {
          id = substr($0, RSTART + 16, RLENGTH - 17)
          if (lbl != "") { print lbl "\t" id "\t" st; lbl = ""; st = "" }
        }
      '
}

herdr_ws_id() { # <session> <label> -> workspace id, or empty
  herdr_ws_pairs "$1" | awk -F'\t' -v l="$2" '$1 == l { print $2; exit }'
}

# herdr agent names: [a-z][a-z0-9_-]{0,31}, unique among live agents, and a
# name follows the pane occupant until that agent exits. Compose them as
# <session>--<collection> so one string says which session and which wtc — the
# same name herdr answers to, Claude Remote Control registers, and the phone
# lists. write_collection_env emits that string as WTC_AGENT_NAME so panes and
# wtc-open share one value. Past 32 characters the collection half is trimmed
# rather than the session prefix: the prefix is what keeps names from
# colliding across sessions on one machine.
herdr_agent_name() { # <session> <collection>
  _s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"
  _c="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"
  # herdr requires ^[a-z][a-z0-9_-]{0,31}$. A workspace or collection named
  # for a GitHub issue (`239-timeline-…`) would otherwise fail to start an
  # agent. Prefixing the session half is enough: <session>--<collection>
  # already starts with a letter when the session does, and this covers the
  # leftover case where the session itself does not.
  case "$_s" in [a-z]*) ;; *) _s="w$_s" ;; esac
  _room=$((32 - ${#_s} - 2))
  if [ "$_room" -lt 1 ]; then
    printf '%s\n' "$(printf '%s' "$_s" | cut -c1-32)"
    return 0
  fi
  printf '%s--%s\n' "$_s" "$(printf '%s' "$_c" | cut -c1-"$_room")"
}

# Prefer WTC_AGENT_NAME from .env.collection (same string injected into panes)
# when it matches the live session+collection composition; otherwise recompute
# (missing/stale file, or wtc-open --session override).
resolve_agent_name() { # <collection-dir> <session> <collection-name>
  _computed="$(herdr_agent_name "$2" "$3")"
  _from_env=""
  for _envf in "$1/.env.collection" "$1/.env.collection.local"; do
    [ -f "$_envf" ] || continue
    _v="$(sed -n 's/^WTC_AGENT_NAME=//p' "$_envf" | head -n1 | tr -d '[:space:]')"
    [ -n "$_v" ] && _from_env="$_v"
  done
  if [ -n "$_from_env" ] && [ "$_from_env" = "$_computed" ]; then
    printf '%s\n' "$_from_env"
  else
    printf '%s\n' "$_computed"
  fi
}

herdr_pane_id_by_label() { # <session> <workspace> <pane-label> -> pane id, or empty
  herdr --session "$1" pane list --workspace "$2" 2>/dev/null \
    | tr '{}' '\n\n' \
    | grep -F "\"label\":\"$3\"" \
    | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p' \
    | head -n1 || true
}

herdr_pane_has_agent() { # <session> <pane> — true if an agent occupies the pane
  herdr --session "$1" agent list 2>/dev/null \
    | tr '{}' '\n\n' \
    | grep -qF "\"pane_id\":\"$2\""
}

# True when *this process* is inside a herdr pane that a coding agent occupies.
# A human at a shell in the same workspace is not an agent: they typed the
# command, so the TUI belongs in this window.
herdr_caller_is_agent() {
  [ "${HERDR_ENV:-}" = 1 ] || return 1
  [ -n "${HERDR_SESSION:-}" ] && [ -n "${HERDR_PANE_ID:-}" ] || return 1
  herdr_pane_has_agent "$HERDR_SESSION" "$HERDR_PANE_ID"
}

herdr_pane_tab_id() { # <session> <pane> -> tab id
  herdr --session "$1" pane get "$2" 2>/dev/null \
    | tr '{}' '\n\n' \
    | sed -n 's/.*"tab_id":"\([^"]*\)".*/\1/p' \
    | head -n1 || true
}

# Panes on one tab, not the whole workspace — leftover browse/diff tabs
# must not make a 3-pane home tab look "off-template".
herdr_tab_pane_count() { # <session> <workspace> <tab>
  herdr --session "$1" pane list --workspace "$2" 2>/dev/null \
    | tr '{}' '\n\n' \
    | grep -cF "\"tab_id\":\"$3\"" || true
}

herdr_pane_fg_name() { # <session> <pane> -> foreground process name, or empty
  herdr --session "$1" pane process-info --pane "$2" 2>/dev/null \
    | tr '{}' '\n\n' \
    | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' \
    | head -n1 || true
}

herdr_pane_fg_cmdline() { # <session> <pane> -> foreground command line, or empty
  herdr --session "$1" pane process-info --pane "$2" 2>/dev/null \
    | tr '{}' '\n\n' \
    | sed -n 's/.*"cmdline":"\([^"]*\)".*/\1/p' \
    | head -n1 || true
}

# Is this command line a shell waiting at its prompt? The process NAME is not
# enough: a shell script's foreground process is also "bash", so a live
# `bash tools/wtc-status.sh` would read as idle and get a second one typed on
# top of it. A bare shell is a one-word command line ("-zsh", "bash"); a shell
# running something has arguments.
herdr_cmdline_is_shell() { # <cmdline>
  [ -n "$1" ] || return 0
  case "$1" in *[[:space:]]*) return 1 ;; esac
  case "${1#-}" in
    zsh|bash|fish|sh|nu|dash|ksh) return 0 ;;
    */zsh|*/bash|*/fish|*/sh|*/nu|*/dash|*/ksh) return 0 ;;
    *) return 1 ;;
  esac
}

herdr_pane_idle() { # <session> <pane>
  herdr_cmdline_is_shell "$(herdr_pane_fg_cmdline "$1" "$2")"
}

# Start <cmd> in a pane that is idle; leave a pane that is already working
# alone. This is what makes wtc-open re-runnable: a herdr session restored
# after a reboot comes back with the layout but not the processes, so every
# pane is a bare prompt and each one's own command has to be put back.
# <settle> seconds waits for a pane created moments ago to reach its prompt; a
# pane that has been sitting there since the reboot needs no wait at all.
herdr_pane_run_idle() { # <session> <pane> <cmd> [settle-seconds]
  [ -n "$2" ] || return 1
  herdr_pane_idle "$1" "$2" || return 1
  [ -z "${4:-}" ] || [ "${4:-0}" = 0 ] || sleep "$4"
  herdr --session "$1" pane run "$2" "$3" >/dev/null 2>&1 || return 1
}

# One `pane list` per workspace, as "<label>\t<pane-id>\t<agent>\t<agent-status>".
# herdr reports the agent on the pane itself, so this answers both halves of
# "what is already open here" — which labels exist, and which one is an agent —
# in a single call. Flattening the JSON with tr would not do: a pane carrying
# an agent has a nested agent_session object, and the fields land in different
# fragments.
herdr_pane_rows() { # <session> <workspace>
  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is required to inspect herdr panes (wtc-open --list / idle restart)" >&2
    return 1
  fi
  herdr --session "$1" pane list --workspace "$2" 2>/dev/null | python3 -c '
import json, sys
try:
    panes = json.load(sys.stdin)["result"]["panes"]
except Exception:
    sys.exit(0)
for p in panes:
    print("\t".join([p.get("label") or "", p.get("pane_id") or "",
                     p.get("agent") or "", p.get("agent_status") or ""]))
'
}

# Column 1 label, 2 pane id, 3 agent kind, 4 agent status.
herdr_row_col() { # <rows> <label> <column>
  printf '%s\n' "$1" | awk -F'\t' -v l="$2" -v c="$3" '$1 == l { print $c; exit }'
}

# Default layout (new workspaces), see instructions/herdr.md:
#
#   [ agent | browse        ]
#   [       | shell | status]
#
# Agent is the full-height conversation. Browse is the human TUI slot
# (LazyVim / lazygit); empty, it is just a shell. Terminal and status
# sit under browse, not under the agent.
#
# Heal is non-destructive. A leftover `tui` label is renamed to `browse`.
# A standard 3-pane workspace (agent / shell / status) gets `browse` by
# splitting agent to the right. A workspace that already grew extra panes
# is left alone — callers fall back to `shell`.
herdr_ensure_browse_pane() { # <session> <workspace> <cwd> -> pane id
  session="$1" ws="$2" cwd="$3"
  id="$(herdr_pane_id_by_label "$session" "$ws" browse)"
  if [ -z "$id" ]; then
    id="$(herdr_pane_id_by_label "$session" "$ws" tui)"
    if [ -n "$id" ]; then
      herdr --session "$session" pane rename "$id" browse >/dev/null || true
    fi
  fi
  if [ -n "$id" ]; then
    printf '%s\n' "$id"
    return 0
  fi

  home="$(herdr_pane_id_by_label "$session" "$ws" agent)"
  [ -n "$home" ] || home="$(herdr_pane_id_by_label "$session" "$ws" shell)"
  tab="$(herdr_pane_tab_id "$session" "$home")"
  count=99
  if [ -n "$tab" ]; then
    count="$(herdr_tab_pane_count "$session" "$ws" "$tab")"
  fi
  case "$count" in
    ''|*[!0-9]*) count=99 ;;
  esac
  if [ "$count" -gt 3 ]; then
    herdr_pane_id_by_label "$session" "$ws" shell
    return 0
  fi

  base="$(herdr_pane_id_by_label "$session" "$ws" agent)"
  [ -n "$base" ] || base="$(herdr_pane_id_by_label "$session" "$ws" shell)"
  [ -n "$base" ] || return 1

  # ratio is the original pane's share: agent keeps 40%, browse gets the rest.
  pane="$(herdr --session "$session" pane split "$base" \
    --direction right --ratio 0.40 --cwd "$cwd" --no-focus | herdr_first_pane_id)"
  [ -n "$pane" ] || return 1
  herdr --session "$session" pane rename "$pane" browse >/dev/null || true
  sleep 1
  printf '%s\n' "$pane"
}

herdr_ensure_tui_pane() { herdr_ensure_browse_pane "$@"; } # leftover name

# Socket for the collection's browse nvim (--listen). Short path: macOS
# unix-socket names are capped around 104 bytes.
wtc_browse_socket() { # <collection-name>
  printf '/tmp/wtc-browse-%s.nvim' "$1"
}

wtc_browse_alive() { # <collection-name> — 0 if a browse nvim is answering
  command -v nvim >/dev/null 2>&1 || return 1
  nvim --server "$(wtc_browse_socket "$1")" --remote-expr "1" >/dev/null 2>&1
}

wtc_browse_eval() { # <collection-name> <vim-expr> -> stdout (trim)
  nvim --server "$(wtc_browse_socket "$1")" --remote-expr "$2" 2>/dev/null || true
}

herdr_tab_id_by_label() { # <session> <workspace> <label> -> tab id
  herdr --session "$1" tab list --workspace "$2" 2>/dev/null \
    | tr '{}' '\n\n' \
    | grep -F "\"label\":\"$3\"" \
    | sed -n 's/.*"tab_id":"\([^"]*\)".*/\1/p' \
    | head -n1 || true
}

# Inbox TUI (gh-dash) as a sibling herdr tab labelled `pr`. Non-destructive:
# an existing tab is reused; a busy pane is left alone.
herdr_ensure_pr_tab() { # <session> <workspace> <cwd>
  session="$1" ws="$2" cwd="$3"
  command -v gh >/dev/null 2>&1 || return 0
  if ! gh dash -h >/dev/null 2>&1; then
    return 0
  fi
  tab="$(herdr_tab_id_by_label "$session" "$ws" pr)"
  if [ -z "$tab" ]; then
    created="$(herdr --session "$session" tab create --workspace "$ws" \
      --cwd "$cwd" --label pr --no-focus 2>/dev/null || true)"
    tab="$(printf '%s' "$created" | tr '{}' '\n\n' \
      | sed -n 's/.*"tab_id":"\([^"]*\)".*/\1/p' | head -n1 || true)"
    pane="$(printf '%s' "$created" | herdr_first_pane_id || true)"
    [ -n "$pane" ] || return 0
    herdr --session "$session" pane rename "$pane" pr >/dev/null || true
    sleep 1
  else
    pane="$(herdr_pane_id_by_label "$session" "$ws" pr)"
    [ -n "$pane" ] || return 0
  fi
  fg="$(herdr_pane_fg_name "$session" "$pane")"
  case "$fg" in
    gh|gh-dash) return 0 ;;
    ''|zsh|bash|fish|sh|nu) ;;
    *) return 0 ;;
  esac
  herdr --session "$session" pane run "$pane" "gh dash" >/dev/null 2>&1 || true
}

herdr_first_pane_id() { # reads a herdr JSON response on stdin -> first pane id
  tr '{}' '\n\n' \
    | sed -n 's/.*"pane_id":"\([^"]*\)".*/\1/p' \
    | head -n1
}

write_collection_env() { # <collection-dir> <collection-name>
  dir="$1" name="$2"
  # Regeneration keeps the collection's existing port base (idempotent).
  base=""
  if [ -f "$dir/.env.collection" ]; then
    base="$(sed -n 's/^COLLECTION_PORT_BASE=//p' "$dir/.env.collection" | head -n1)"
  fi
  [ -n "$base" ] || base="$(alloc_port_base)"
  # Machine-wide defaults from $WTC_CONFIG_ROOT/wtc.env, so a lever set there
  # once (WTC_TWG_SITE) reaches every path that generates this file —
  # branch-off, add-repo and refresh-env — none of which take a flag for it.
  load_wtc_config
  cfg_root="$WTC_CONFIG_ROOT"
  {
    echo "# Generated by harness tools — collection-scoped env (not committed)."
    echo "# Ports cover every registry repo with a port_offset, whether or not"
    echo "# it is checked out here, so absent repos still resolve to a port."
    echo "WTC_COLLECTION=$name"
    # Same string wtc-open passes to `herdr agent start` / Claude --remote-control.
    printf 'WTC_AGENT_NAME=%s\n' "$(herdr_agent_name "$(herdr_session_name)" "$name")"
    echo "WTC_CONFIG_ROOT=$cfg_root"
    echo "COLLECTION_PORT_BASE=$base"
    for repo in $(registry_all_names); do
      off="$(registry_field "$repo" port_offset)"
      [ -n "$off" ] || continue
      echo "$(port_var_for "$repo")=$((base + off))"
    done

    # Tool identity (instructions/secrets.md → Tool identity). gh and jira-cli
    # otherwise resolve credentials from one machine-global store, so every
    # project on this machine shares whichever account is logged in. These
    # variables name a config *directory/file/site* — never a token; each CLI
    # keeps its own store and is only told which one.
    #
    # OPT-IN BY PRESENCE, deliberately: emitting GH_CONFIG_DIR unconditionally
    # would point gh at an empty directory and log you out inside every
    # collection before anyone asked for it. Creating the store IS the opt-in —
    # `mkdir -p "$cfg_root"/gh && tools/refresh-env.sh` turns it on, removing
    # the directory turns it back off. A machine with only this workspace on it
    # wants none of this and gets none of it.
    #
    # twg needs a different lever: its config dir does follow XDG_CONFIG_HOME,
    # but that would relocate config for every XDG-respecting tool in the
    # collection (git and nvim among them), so TWG_SITE — which pins only the
    # site — is the narrow one. TWG_USER is deliberately NOT emitted: twg
    # auto-loads the account from auth.conf, so it is only needed to
    # disambiguate two accounts, and a default here would put a person's
    # address in a generated file. That, and TWG_TOKEN, belong in
    # .env.collection.local.
    if [ -d "$cfg_root/gh" ] || [ -d "$cfg_root/jira" ] || [ -n "${WTC_TWG_SITE:-}" ]; then
      echo
      echo "# Tool identity — this workspace's own CLI stores rather than the"
      echo "# machine-global ones (instructions/secrets.md → Tool identity)."
      echo "# These name a config directory/file/site, never a credential."
      if [ -d "$cfg_root/gh" ]; then
        echo "GH_CONFIG_DIR=$cfg_root/gh"
      fi
      if [ -d "$cfg_root/jira" ]; then
        echo "JIRA_CONFIG_FILE=$cfg_root/jira/.config.yml"
      fi
      if [ -n "${WTC_TWG_SITE:-}" ]; then
        echo "TWG_SITE=$WTC_TWG_SITE"
      fi
    fi
  } > "$dir/.env.collection"

  # Collection-scoped secrets. Seeded empty once and never rewritten afterwards:
  # .env.collection above is regenerated wholesale on every branch-off, so
  # anything hand-added there is lost. This second file is the one place a
  # secret scoped to THIS collection survives, which the shared control root
  # deliberately cannot be (instructions/secrets.md: one canonical copy per
  # file keeps rotation sane). Listed in mise.toml unconditionally, so it must
  # exist even when empty. umask 077 + unconditional chmod so a secrets tier
  # is never briefly (or lastingly) world-readable.
  # The symlink guard comes BEFORE the write, not after it. A *dangling* link
  # here is invisible to `-f` (which follows it to a target that is not there),
  # so seeding would happily follow the link and create the secrets file
  # wherever it points — outside the collection, at whatever mode. Guarding
  # afterwards catches the chmod and misses the escape entirely.
  if [ -L "$dir/.env.collection.local" ]; then
    echo "error: $dir/.env.collection.local is a symlink; refusing to seed or chmod through it" >&2
    return 1
  fi
  if [ ! -e "$dir/.env.collection.local" ]; then
    (
      umask 077
      cat > "$dir/.env.collection.local" <<'EOF'
# Collection-scoped secrets and overrides. Seeded empty once, then hand-
# authored. NOT committed (the collection root is not a git repo), and never
# rewritten by harness tools.
#
# Use this for credentials scoped to this collection's work — a throwaway
# sandbox key for one investigation, say. Anything that should rotate once for
# the whole machine belongs in the control root instead
# ($WTC_CONFIG_ROOT/<repo>/<path>, linked by tools/link-secrets.sh).
#
# Inherited by every repo in this collection, not just one.
EOF
    )
  fi
  chmod 600 "$dir/.env.collection.local"

  cat > "$dir/mise.toml" <<'EOF'
# Generated by harness tools. Collection-scoped env: mise finds this file as a
# parent config of every sibling repo worktree, so all of them inherit the
# variables from .env.collection.
#
# .env.collection.local is the collection-scoped secrets tier — hand-authored,
# 600, never regenerated. Listed second so it wins on conflict.
# Without mise: `set -a; . ./.env.collection; . ./.env.collection.local; set +a`.
[env]
_.file = [".env.collection", ".env.collection.local"]
EOF
  trust_mise "$dir"
  echo "wrote $dir/.env.collection (port base $base) + $dir/mise.toml + $dir/.env.collection.local"
}

# --- collection PR label ----------------------------------------------------
# Which collection launched a PR is a fact worth keeping, and keeping it on the
# PR rather than in a local file is what makes it survive the worktree going
# back to the tip, the collection being retired, or the work moving machines.
# A label is the cheapest durable place: one server-side filter answers "what
# is this collection carrying" without any local bookkeeping to go stale.

wtc_pr_label() { # [collection] -> the label this collection's PRs carry
  name="${1:-}"
  [ -n "$name" ] || name="${WTC_COLLECTION:-}"
  [ -n "$name" ] || name="$(basename "$(cd "$HARNESS_DIR/.." && pwd)")"
  printf 'wtc:%s\n' "$name"
}

wtc_pr_ensure_label() { # <slug> <label> — create it if the repo lacks it
  command -v gh >/dev/null 2>&1 || return 0
  if gh label list --repo "$1" --search "$2" --json name --jq '.[].name' 2>/dev/null \
     | grep -Fxq "$2"; then
    return 0
  fi
  # Colour is cosmetic and the description says why a stranger is seeing it.
  gh label create "$2" --repo "$1" --color ededed \
    --description "Opened from the ${2#wtc:} worktree collection" >/dev/null 2>&1 || true
}

wtc_pr_label_add() { # <slug> <pr-number> <label> — tag an existing PR
  command -v gh >/dev/null 2>&1 || return 0
  wtc_pr_ensure_label "$1" "$3"
  gh pr edit "$2" --repo "$1" --add-label "$3" >/dev/null 2>&1 || true
}

# One PullRequest node -> the row wtc-status prints. Shared by both queries
# below so the two paths cannot drift apart.
_WTC_PR_ROW_JQ='[
  (.number|tostring),
  (if .isDraft then "draft"
   else (.commits.nodes[0].commit.statusCheckRollup.state // "NONE") end),
  (.mergeStateStatus // "UNKNOWN"),
  (([.reviewThreads.nodes[] | select((.isResolved|not) and (.isOutdated|not))] | length) as $open
    | if $open > 0 then ($open|tostring)
      elif .reviewDecision == "APPROVED" then "approved"
      elif .reviewDecision == "CHANGES_REQUESTED" then "changes"
      else "none" end),
  (.title // "")
]'

wtc_pr_list() { # <collection> -> TSV rows, one per open PR this collection has
  # kind \t slug \t repo \t number \t checks \t merge \t review \t title
  #
  # kind:   own | out
  # checks: SUCCESS|FAILURE|ERROR|PENDING|draft|NONE
  # merge:  mergeStateStatus (BEHIND / DIRTY / BLOCKED / CLEAN / …)
  # review: approved | changes | <count of unresolved threads> | none
  #
  # The slug travels with the row because the caller cannot re-derive it from
  # the repo name: an `ext.` sibling is deliberately outside the registry, and
  # an `out` row's repo is not a sibling at all.
  #
  # Two kinds of PR, found two different ways:
  #
  # own — a PR on a sibling's own origin, found by the `wtc:<collection>`
  #   label the PR skills apply. The label outlives the branch going back to
  #   the tip, which is why it and not the branch is the key.
  #
  # out — a PR this collection sent to a sibling's *upstream*: the fork
  #   workflow, where the branch is pushed to your fork and the PR is opened
  #   against a repo you do not own. The label cannot be the key there —
  #   creating one needs write access you do not have, and `gh pr edit
  #   --add-label` just answers "not found" — so these are found by author.
  #   Without this half a collection whose whole purpose is sending fixes
  #   upstream cannot see a single one of them.
  #
  # Only open PRs: a merged one is not something you act on, and the row that
  # matters after a merge is the worktree still sitting on that branch, which
  # wtc_pr_orphans reports instead.
  command -v gh >/dev/null 2>&1 || return 0
  label="$(wtc_pr_label "$1")"

  # Driven by the collection's worktrees rather than the registry: that covers
  # `ext.` siblings, and it stops a two-repo collection querying every repo the
  # workspace has ever owned.
  targets="" own_slugs="" out_slugs="" me=""
  for wt in "$ROOT/$1"/*/; do
    wt="${wt%/}"
    [ -e "$wt/.git" ] || continue
    repo="$(basename "$wt")"
    [ "$repo" = harness ] && repo="$(harness_repo)"
    slug="$(slug_for_worktree "$wt" "$repo")"
    [ -n "$slug" ] || continue
    case " $own_slugs " in *" $slug "*) continue ;; esac
    own_slugs="$own_slugs $slug"
    targets="${targets}own|$slug|$repo
"
  done

  # The branches this collection currently has checked out. They are the
  # fallback hold on an `out` PR, for one opened before the body trailer
  # existed or opened by hand: the durable hold is the trailer itself, and
  # this only lasts as long as the branch does. Detached worktrees contribute
  # nothing, which is right — a collection back at the tip claims a PR by
  # what the PR says, not by where the collection happens to be sitting.
  branches=""
  for wt in "$ROOT/$1"/*/; do
    wt="${wt%/}"
    [ -e "$wt/.git" ] || continue
    b="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
    [ -n "$b" ] || continue
    branches="$branches $b"
  done

  # Upstreams in a second pass, so a slug that is already some sibling's
  # origin is never also queried as an upstream. Siblings commonly share one
  # upstream (a fork and the thing it forks), and a single pass would list its
  # PRs once per sibling.
  for wt in "$ROOT/$1"/*/; do
    wt="${wt%/}"
    [ -e "$wt/.git" ] || continue
    up="$(git -C "$wt" remote get-url upstream 2>/dev/null)" || continue
    case "$up" in *github.com[:/]*) ;; *) continue ;; esac
    up="${up#*github.com}"; up="${up#:}"; up="${up#/}"; up="${up%.git}"
    case " $own_slugs $out_slugs " in *" $up "*) continue ;; esac
    # Asked once, and only if there is an upstream to ask about.
    [ -n "$me" ] || me="$(gh api user --jq .login 2>/dev/null || true)"
    [ -n "$me" ] || break
    out_slugs="$out_slugs $up"
    targets="${targets}out|$up|${up#*/}
"
  done
  [ -n "${targets// /}" ] || return 0

  # One GraphQL round trip per repo returns every fact a row shows, and the
  # repos are queried in parallel — the same shape wtc-status uses per branch.
  tmp="$(mktemp -d)"
  while IFS='|' read -r kind slug repo; do
    [ -n "$slug" ] || continue
    (
      if [ "$kind" = own ]; then
        gh api graphql -F owner="${slug%%/*}" -F name="${slug#*/}" -F label="$label" -f query='
          query($owner:String!,$name:String!,$label:String!){
            repository(owner:$owner,name:$name){
              pullRequests(labels:[$label],states:OPEN,first:20,
                           orderBy:{field:UPDATED_AT,direction:DESC}){
                nodes{
                  number title isDraft mergeStateStatus reviewDecision
                  reviewThreads(first:100){nodes{isResolved isOutdated}}
                  commits(last:1){nodes{commit{statusCheckRollup{state}}}}
                }}}}' \
          --jq ".data.repository.pullRequests.nodes[] | $_WTC_PR_ROW_JQ | @tsv" 2>/dev/null
      else
        # No mergeStateStatus: GitHub only answers it for someone with push
        # access, and asking anyway fails the whole query rather than that one
        # field — which would drop the row silently, the exact bug this half
        # exists to fix. It renders blank, which is honest: from here you
        # cannot know whether their base has moved under you.
        #
        # Two leading fields carry what the filter below needs: the head
        # branch, and whether the body names this collection.
        #
        # `author:` alone is repo-wide — every collection sharing this
        # upstream would claim every PR you have open against it — so a row
        # has to earn its place twice:
        #
        #   the body carries `wtc:<collection>`, which the PR skills write as
        #     an HTML-comment trailer, precisely because the label cannot be
        #     created here. A comment rather than a visible line because the
        #     reader is a maintainer of someone else's repo, to whom our
        #     bookkeeping is noise.
        #     Durable: it survives the worktree going back to the tip, the
        #     same property the label gives an `own` PR.
        #   or a worktree here is still on its head branch. That is the
        #     fallback for a PR opened before the trailer existed, or by hand.
        #     It lasts only as long as the branch is checked out.
        gh api graphql -F q="repo:$slug is:pr is:open author:$me" -f query='
          query($q:String!){
            search(query:$q,type:ISSUE,first:20){
              nodes{ ... on PullRequest {
                number title isDraft reviewDecision headRefName body
                reviewThreads(first:100){nodes{isResolved isOutdated}}
                commits(last:1){nodes{commit{statusCheckRollup{state}}}}
              }}}}' \
          --jq ".data.search.nodes[]
                | [.headRefName,
                   (if ((.body // \"\") | contains(\"$label\")) then \"1\" else \"0\" end)]
                  + $_WTC_PR_ROW_JQ | @tsv" 2>/dev/null \
          | awk -F'\t' -v bs=" $branches " '$2 == "1" || index(bs, " " $1 " ") {
              sub(/^[^\t]*\t[^\t]*\t/, ""); print }'
      fi \
        | awk -v k="$kind" -v s="$slug" -v r="$repo" 'NF { print k "\t" s "\t" r "\t" $0 }' \
        > "$tmp/$kind-$(printf '%s' "$slug" | tr -c 'A-Za-z0-9._-' '_')" 2>/dev/null || :
    ) &
  done <<EOF
$targets
EOF
  wait 2>/dev/null || true
  # `own` before `out`: your own repos are the ones you act on directly.
  cat "$tmp"/own-* 2>/dev/null || true
  cat "$tmp"/out-* 2>/dev/null || true
  rm -rf "$tmp"
}

# NOTE: wtc-status derives "worktree still on a branch whose PR has gone" from
# the per-branch PR cache it already fills, so there is no separate orphan
# query here. Kept out deliberately rather than left as a second code path
# that would drift from the one the table actually uses.
