#!/usr/bin/env bash
# agent-env.sh — put a collection's pinned toolchains on PATH for agent shells.
#
# Agent CLIs (Grok, Claude Code, Cursor, Codex) often spawn a non-login shell
# that never ran `mise activate`. `/usr/bin/env ruby` then hits macOS system
# Ruby 2.6, and `mise exec` from the collection root uses the global pin, not
# the sibling's. This script:
#
#   * trusts every sibling `mise.toml` (fresh worktrees are a new path)
#   * unions `mise bin-paths` from those siblings into WTC_TOOLCHAIN_PATH
#   * caches that on `.env.toolchain` at the collection root
#   * prepends it to PATH
#
# Usage:
#   eval "$(harness/tools/agent-env.sh)"     # print exports (default)
#   harness/tools/agent-env.sh --write       # refresh the cache, print nothing
#   harness/tools/agent-env.sh --print-path  # WTC_TOOLCHAIN_PATH only
#   harness/tools/agent-env.sh --wrap        # PreToolUse stdin → updatedInput
#   harness/tools/agent-env.sh --write --collection <dir>
#
# Sourced (BASH_ENV, `. agent-env.sh`): apply to the calling shell silently, no
# stdout, and never `exit` — see _finish. This is the surface that works in a
# herdr pane: env passed to the pane process is set *before* the login shell
# runs, and on macOS /etc/zprofile's path_helper then demotes any injected PATH
# prefix below /usr/bin. Applying after the profile is the only ordering that
# wins.
# Always exit 0: a missing mise is not a reason to fail a hook or a command.
#
# Bash 3.2-safe (macOS default): no mapfile, no associative arrays.
# BASH_ENV sources this in every child shell. Run the script in a child and
# evaluate only its exports, so shell options, functions and scratch variables
# never leak into the caller. Clear BASH_ENV in that child to avoid recursion.
if [ -n "${BASH_VERSION:-}" ] && [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
  eval "$(BASH_ENV= bash "${BASH_SOURCE[0]}" --eval)"
  return 0
fi
# Keep the shell entry point for BASH_ENV and bootstrap. With a released CLI
# installed, its native command owns cache refresh, exports and hook wrapping.
_wtc_agent_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_wtc_collection="$(dirname "$(dirname "$_wtc_agent_dir")")"
_wtc_original_args=("$@")
_wtc_native_args=()
_wtc_selection_valid=yes
while [ "$#" -gt 0 ]; do
  case "$1" in
    --collection)
      if [ "$#" -lt 2 ]; then _wtc_selection_valid=no; break; fi
      _wtc_collection="$2"; shift 2 ;;
    *) _wtc_native_args+=("$1"); shift ;;
  esac
done
set -- "${_wtc_original_args[@]}"
if [ "$_wtc_selection_valid" = yes ] && [ -d "$_wtc_collection" ]; then
  _wtc_collection="$(cd "$_wtc_collection" && pwd -P)"
  if (cd "$_wtc_collection" && command -v wtc >/dev/null 2>&1 && wtc agent-env --help >/dev/null 2>&1); then
    cd "$_wtc_collection"
    exec wtc agent-env --collection "$_wtc_collection" "${_wtc_native_args[@]}"
  fi
fi
set -u

this="${BASH_SOURCE[0]:-$0}"

is_sourced=no
if [ -n "${BASH_VERSION:-}" ] && [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
  is_sourced=yes
fi

# Sourced (BASH_ENV, `. agent-env.sh`), `exit` takes the *calling* shell down
# with it — a spectacular way for a PATH helper to fail, and silent: the shell
# just stops. Every exit path goes through here instead.
_finish() {
  if [ "$is_sourced" = yes ]; then
    return "${1:-0}"
  fi
  exit "${1:-0}"
}

mode="eval"
collection_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --write) mode=write; shift ;;
    --print-path) mode=print; shift ;;
    --wrap) mode=wrap; shift ;;
    --eval) mode=eval; shift ;;
    --collection) collection_arg="${2:?--collection needs a directory}"; shift 2 ;;
    -h|--help)
      sed -n '2,24p' "$this"
      _finish 0
      return 0 2>/dev/null || exit 0
      ;;
    *) break ;;
  esac
done

# When sourced, BASH_ENV (or `.`) does not pass our flags. Apply, don't print.
[ "$is_sourced" = yes ] && mode=apply

find_collection_root() {
  _d="$1"
  while [ -n "$_d" ] && [ "$_d" != "/" ]; do
    if [ -x "$_d/harness/tools/agent-env.sh" ] || [ -f "$_d/harness/tools/lib.sh" ]; then
      printf '%s\n' "$_d"
      return 0
    fi
    _d="$(dirname "$_d")"
  done
  return 1
}

collection=""
if [ -n "$collection_arg" ]; then
  collection="$(find_collection_root "$collection_arg")" || collection=""
  [ -n "$collection" ] || collection="$collection_arg"
fi
if [ -z "$collection" ]; then
  for _start in \
      "${GROK_WORKSPACE_ROOT:-}" \
      "${CLAUDE_PROJECT_DIR:-}" \
      "${PWD:-}" \
      "$(cd "$(dirname "$this")" && pwd)"
  do
    [ -n "$_start" ] || continue
    collection="$(find_collection_root "$_start")" && break
  done
fi
if [ -z "$collection" ]; then
  [ "$mode" = wrap ] && cat >/dev/null
  _finish 0
  return 0 2>/dev/null || exit 0
fi

cache="$collection/.env.toolchain"

append_unique() { # <dir>
  _p="$1"
  [ -n "$_p" ] && [ -d "$_p" ] || return 0
  case ":${toolchain_path:-}:" in *":$_p:"*) return 0 ;; esac
  if [ -n "${toolchain_path:-}" ]; then
    toolchain_path="$toolchain_path:$_p"
  else
    toolchain_path="$_p"
  fi
}

add_mise_bins() { # <dir with mise.toml>
  _dir="$1"
  [ -f "$_dir/mise.toml" ] || return 0
  command -v mise >/dev/null 2>&1 || return 0
  mise trust "$_dir/mise.toml" >/dev/null 2>&1 || true
  _bins=""
  _bins="$(mise -C "$_dir" bin-paths 2>/dev/null)" || _bins=""
  [ -n "$_bins" ] || return 0
  _old_ifs="$IFS"
  IFS='
'
  for _b in $_bins; do
    IFS="$_old_ifs"
    append_unique "$_b"
  done
  IFS="$_old_ifs"
}

cache_is_fresh() {
  [ -f "$cache" ] || return 1
  _line="$(sed -n 's/^WTC_TOOLCHAIN_PATH=//p' "$cache" | head -n1)"
  [ -n "$_line" ] || return 1
  _old_ifs="$IFS"
  IFS=:
  for _p in $_line; do
    IFS="$_old_ifs"
    [ -n "$_p" ] || continue
    [ -d "$_p" ] || return 1
  done
  IFS="$_old_ifs"
  if [ -f "$collection/mise.toml" ] && [ "$collection/mise.toml" -nt "$cache" ]; then
    return 1
  fi
  for _wt in "$collection"/*/; do
    _wt="${_wt%/}"
    [ -f "$_wt/mise.toml" ] || continue
    if [ "$_wt/mise.toml" -nt "$cache" ]; then
      return 1
    fi
  done
  return 0
}

compute_toolchain_path() {
  toolchain_path=""
  command -v mise >/dev/null 2>&1 || return 0
  # Product siblings first so a repo pin (a sibling's `mise.toml`) wins over the
  # global / collection-root pin (often an older ruby). harness last.
  _harness=""
  for _wt in "$collection"/*/; do
    _wt="${_wt%/}"
    [ -f "$_wt/mise.toml" ] || continue
    if [ "$(basename "$_wt")" = "harness" ]; then
      _harness="$_wt"
      continue
    fi
    add_mise_bins "$_wt"
  done
  [ -n "$_harness" ] && add_mise_bins "$_harness"
  add_mise_bins "$collection"
}

cached_value() {
  [ -f "$cache" ] || return 0
  sed -n 's/^WTC_TOOLCHAIN_PATH=//p' "$cache" | head -n1
}

write_cache() {
  compute_toolchain_path
  # Fail-open, and that means the cache too. No mise on PATH computes nothing —
  # and the SessionStart hook is exactly the place to be running in a shell too
  # bare to find mise, which is the moment a good cache matters most. Keep it
  # rather than replacing it with an empty value.
  if [ -z "${toolchain_path:-}" ]; then
    _kept="$(cached_value)"
    if [ -n "$_kept" ]; then
      toolchain_path="$_kept"
      return 0
    fi
  fi
  {
    echo "# Generated by harness/tools/agent-env.sh — machine-local toolchain bins."
    echo "# Prepend WTC_TOOLCHAIN_PATH to PATH so agent shells hit repo Ruby/Node"
    echo "# rather than macOS /usr/bin/ruby. Regenerated by link-skills.sh,"
    echo "# wtc-open.sh, and a SessionStart hook. Not committed."
    echo "WTC_TOOLCHAIN_PATH=${toolchain_path:-}"
  } > "$cache"
}

load_toolchain_path() {
  toolchain_path=""
  if [ "${1:-}" = force ] || ! cache_is_fresh; then
    write_cache
  fi
  [ -f "$cache" ] || return 0
  toolchain_path="$(cached_value)"
}

apply_env() {
  load_toolchain_path
  [ -n "${toolchain_path:-}" ] || return 0
  # `${PATH:-}` because `set -u` is on and an unset PATH must not abort a hook.
  # `${PATH:+:...}` because an empty PATH would otherwise leave a trailing
  # colon, and an empty PATH element means the current directory.
  case ":${PATH:-}:" in *":$toolchain_path:"*) ;; *)
    # Prepend the whole cached prefix as a unit; individual bins are already
    # ordered inside it.
    PATH="$toolchain_path${PATH:+:$PATH}"
    ;;
  esac
  export PATH
  export WTC_TOOLCHAIN_PATH="$toolchain_path"
  export WTC_AGENT_ENV=1
}

emit_eval() {
  load_toolchain_path
  [ -n "${toolchain_path:-}" ] || return 0
  # POSIX-ish so bash and zsh both eval it. Quote the value; bins have no
  # spaces in practice, but a colon-list still wants quotes.
  printf '# wtc-agent-env\n'
  printf 'WTC_AGENT_ENV=1\n'
  printf 'WTC_TOOLCHAIN_PATH=%s\n' "$(printf '%s' "$toolchain_path" | sed "s/'/'\\\\''/g; s/^/'/; s/$/'/")"
  # Same two guards as apply_env, since both `.envrc` and the herdr workspace
  # env may already have prepended this prefix before the hook evals us.
  printf 'case ":${PATH:-}:" in *":${WTC_TOOLCHAIN_PATH}:"*) ;; *)\n'
  printf '  PATH="${WTC_TOOLCHAIN_PATH}${PATH:+:$PATH}" ;;\n'
  printf 'esac\n'
  printf 'export WTC_AGENT_ENV WTC_TOOLCHAIN_PATH PATH\n'
}

wrap_command() {
  # Fail-open: no python, no command field, or a parse error → no rewrite.
  if ! command -v python3 >/dev/null 2>&1; then
    cat >/dev/null
    return 0
  fi
  load_toolchain_path
  script="$(cd "$(dirname "$this")" && pwd)/$(basename "$this")"
  WTC_AGENT_ENV_SCRIPT="$script" python3 -c '
import json, os, re, sys

marker = "# wtc-agent-env"
script = os.environ.get("WTC_AGENT_ENV_SCRIPT", "")
raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)
try:
    ev = json.loads(raw)
except Exception:
    sys.exit(0)
inp = ev.get("toolInput") or ev.get("tool_input") or {}
if not isinstance(inp, dict):
    sys.exit(0)
cmd = inp.get("command")
if not isinstance(cmd, str) or not cmd.strip():
    sys.exit(0)
head = cmd.lstrip()
if head.startswith(marker) or "WTC_AGENT_ENV=1" in cmd[:400]:
    sys.exit(0)
# Unquoted path in the wrapper; skip rather than mangle a weird worktree path.
if not script or not re.match(r"^[A-Za-z0-9_@%+=:,./-]+$", script):
    sys.exit(0)
wrapped = marker + "\neval \"$(bash " + script + ")\"\n" + cmd
out = dict(inp)
out["command"] = wrapped
json.dump(
    {"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": out}},
    sys.stdout,
)
'
}

case "$mode" in
  wrap) wrap_command ;;
  write) write_cache ;;
  print)
    load_toolchain_path
    [ -n "${toolchain_path:-}" ] && printf '%s\n' "$toolchain_path"
    ;;
  apply) apply_env ;;
  *) emit_eval ;;
esac

_finish 0
