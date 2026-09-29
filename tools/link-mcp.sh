#!/usr/bin/env bash
# link-mcp.sh — render the harness MCP registry (.mcp-servers.yml) into the
# per-agent config files a collection's agent CLIs actually read.
#
#   <collection>/.mcp.json           -> Claude Code (project scope)
#   <collection>/.cursor/mcp.json    -> Cursor
#   <collection>/.codex/config.toml  -> Codex (trusted projects only)
#
# Rendered, not symlinked: the three CLIs want two different serialisations
# (JSON and TOML) of the same facts, so one file cannot serve them the way
# skills/ can. Same tracked-source/generated-output split the repo registry
# uses (.harness-repos.yml -> refresh-configs.sh -> .harness-repos).
#
# Why the collection root: it is not a git repo, so these files are invisible
# to git and no repo needs an ignore rule — the same reasoning as
# link-skills.sh. It is also where AGENTS.md says to start an agent.
#
# CREDENTIALS ARE NEVER WRITTEN HERE. The registry names the variables a
# server needs; this renderer emits "${NAME}" (Claude/Cursor) or
# env_vars = [...] (Codex), and the values arrive from the collection env at
# launch — .env.collection for non-secrets, .env.collection.local or the
# control root for secrets (instructions/secrets.md).
#
# Idempotent, and re-running is the point — same lifecycle as link-skills.sh:
#   * creation time  — branch-off.sh / add-repo.sh call it
#   * catch-up       — picks up servers added to the harness since, and drops
#                      ones removed or disabled since
#
# No jq: lib.sh states the rule (no tool is load-bearing), so JSON and TOML
# are emitted by hand. That is why the registry schema is deliberately flat.
#
# Bash 3.2-safe (macOS default): no mapfile, no associative arrays.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
harness_lib_init

collection="$(dirname "$HARNESS_DIR")"
harness_dirname="$(basename "$HARNESS_DIR")"
dry_run=no
all=no

usage() {
  cat <<'EOF'
Usage: link-mcp.sh [options]

Renders a collection's own harness/.mcp-servers.yml into .mcp.json,
.cursor/mcp.json and .codex/config.toml at the collection root, so Claude
Code, Cursor and Codex all see the same servers. Idempotent.

  --collection <dir>  Collection to wire (default: the one holding this
                      harness worktree).
  --all               Every collection under the workspace root. Use after
                      landing a registry change, to roll it out in one pass.
  --dry-run           Report what would change; touch nothing.
  -h, --help          Show this help.

Each collection is rendered from ITS OWN harness worktree, so a collection
developing the harness keeps its own in-progress registry. Order is catch-up,
then this.

Credentials are never written into the rendered files — only the variable
names. Supply the values via the collection env (instructions/secrets.md);
without them the server is configured but will fail to authenticate, which is
the intended failure mode.

Codex reads a project-scoped .codex/config.toml only for projects you have
marked trusted; an untrusted project silently ignores it.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --collection) collection="${2:?--collection needs a directory}"; shift 2;;
    --all)        all=yes; shift;;
    --dry-run)    dry_run=yes; shift;;
    -h|--help)    usage; exit 0;;
    *) echo "error: unknown option: $1 (use --help)" >&2; exit 1;;
  esac
done

# --all re-execs per collection rather than looping inline: one code path for
# one collection, and a collection whose harness is mid-rebase can't take the
# sweep down with it. (Mirrors link-skills.sh.)
if [ "$all" = yes ]; then
  swept=0 failed=0
  for dir in "$ROOT"/*/; do
    dir="${dir%/}"
    [ -d "$dir/$harness_dirname" ] || continue
    swept=$((swept + 1))
    echo "=== $(basename "$dir")"
    if [ "$dry_run" = yes ]; then
      "$0" --collection "$dir" --dry-run || failed=$((failed + 1))
    else
      "$0" --collection "$dir" || failed=$((failed + 1))
    fi
    echo
  done
  echo "swept $swept collection(s), $failed failed"
  [ "$failed" -eq 0 ] || exit 1
  exit 0
fi

[ -d "$collection" ] || { echo "error: collection not found: $collection" >&2; exit 1; }
collection="$(cd "$collection" && pwd)"
[ -d "$collection/$harness_dirname" ] || {
  echo "error: $collection has no $harness_dirname/ — not a collection" >&2; exit 1; }

# Use the target collection's CLI pin. The --all sweep above re-enters this
# script per target so mixed-version workspaces remain safe during upgrades.
native_mcp_supported() { # v0.1.13 first shipped workspace-wide MCP rendering
  awk -v version="$1" 'BEGIN {
    if (version !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
    split(version, part, ".")
    exit !((part[1] + 0) > 0 || (part[2] + 0) > 1 ||
           ((part[2] + 0) == 1 && (part[3] + 0) >= 13))
  }'
}
if [ -f "$collection/$harness_dirname/.wtc-cli-version" ]; then
  cli_pin="$(tr -d '[:space:]' < "$collection/$harness_dirname/.wtc-cli-version")"
  cli_version=""
  cli_cmd=()
  if native_mcp_supported "$cli_pin" && command -v mise >/dev/null 2>&1; then
    cli_version="$(cd "$collection" && mise exec -- wtc --version 2>/dev/null)" || cli_version=""
    [ -z "$cli_version" ] || cli_cmd=(mise exec -- wtc)
  fi
  if native_mcp_supported "$cli_pin" && [ -z "$cli_version" ] && command -v wtc >/dev/null 2>&1; then
    cli_version="$(cd "$collection" && wtc --version 2>/dev/null)" || cli_version=""
    [ -z "$cli_version" ] || cli_cmd=(wtc)
  fi
  if [ "$cli_version" = "wtc version $cli_pin" ] &&
      (cd "$collection" && "${cli_cmd[@]}" mcp render --help >/dev/null 2>&1); then
    cli_args=(render --collection "$collection")
    [ "$dry_run" = no ] || cli_args+=(--dry-run)
    cd "$collection"
    exec "${cli_cmd[@]}" mcp "${cli_args[@]}"
  fi
fi

# Read the registry from the TARGET collection's harness worktree, not the one
# running this script — same reasoning as link-skills.sh reading its skills
# there: a collection mid-change on the harness renders what it actually has.
MCP_REGISTRY="$collection/$harness_dirname/.mcp-servers.yml"

echo "collection: $collection"

if [ ! -f "$MCP_REGISTRY" ]; then
  # Not an error: an older harness worktree predates the registry. Name the
  # worktree that is short, so "catch it up, then re-run" is the obvious fix
  # rather than this looking like a silent failure.
  echo "servers:    (none — $harness_dirname/ has no .mcp-servers.yml on its"
  echo "            current branch; catch that worktree up first, then re-run)"
  # Write NOTHING and succeed. An absent registry means "this worktree has no
  # opinion yet", which is not the same as "no servers": rendering empty
  # configs here would clobber a hand-made .mcp.json in a collection that
  # simply predates the registry. A registry that exists and yields no servers
  # DOES render empty, further down — that is how a removed server is pruned.
  echo "0 written, nothing to render"
  exit 0
fi

# --- validation ----------------------------------------------------------
# Refuse rather than emit a broken config. Both output formats quote these
# values and there is no jq here to escape them, so a " or \ in a registry
# field yields JSON/TOML that neither agent can parse — and it would fail
# opaquely inside the agent, long after this ran. link-secrets.sh sets the
# precedent: refuse the unsafe thing, name it, exit nonzero.
validate_registry() {
  bad=0
  for s in $(mcp_all_names); do
    case "$s" in
      *'"'*|*\\*) echo "error: server name has a quote or backslash: $s" >&2; bad=1;;
    esac
    for field in command args url env token_env agents; do
      val="$(mcp_field "$s" "$field")"
      case "$val" in
        *'"'*|*\\*)
          echo "error: $s.$field has a quote or backslash: $val" >&2
          bad=1
          ;;
      esac
    done
    # env/token_env name shell variables, and the unset-check below expands
    # them indirectly. A token that is not a valid identifier is a registry
    # mistake rather than something to work around — and refusing it here is
    # what keeps that expansion from being handed something shaped like code.
    for v in $(mcp_field "$s" env) $(mcp_field "$s" token_env); do
      case "$v" in
        [A-Za-z_][A-Za-z0-9_]*) ;;
        *) echo "error: $s names a variable that is not an identifier: $v" >&2; bad=1;;
      esac
    done
  done
  [ "$bad" -eq 0 ] || {
    echo "error: refusing to render — see the value(s) above (instructions/mcp.md)." >&2
    echo "       A quote or backslash would produce JSON and TOML that no agent" >&2
    echo "       can parse; there is no jq here to escape them, so a server that" >&2
    echo "       truly needs a quoted argument wants a wrapper script as its" >&2
    echo "       command. A variable name that is not an identifier cannot be" >&2
    echo "       looked up at all, and is a typo in the registry." >&2
    exit 1
  }
}

validate_registry

# Registry values are split on whitespace in a dozen places below (args, env,
# agents). Word-splitting is wanted; pathname expansion is not — an arg like
# `--include=*.py` would otherwise expand against whatever is in the cwd and
# render whatever it found. The --all sweep above is the only glob this script
# needs, and it has already run and exited by here.
set -f

# --- rendering helpers --------------------------------------------------

json_array() { # <space-separated words> -> ["a", "b"]
  out="["; sep=""
  for w in $1; do out="$out$sep\"$w\""; sep=", "; done
  printf '%s]' "$out"
}

# Servers that are enabled AND want this agent.
servers_for() { # <agent>
  for s in $(mcp_all_names); do
    mcp_enabled "$s" || continue
    mcp_wants_agent "$s" "$1" || continue
    printf '%s\n' "$s"
  done
}

render_json() { # <agent> — a complete .mcp.json / .cursor/mcp.json document
  echo "{"
  echo "  \"_generated\": \"harness tools/link-mcp.sh — edits are overwritten; change .mcp-servers.yml\","
  echo "  \"mcpServers\": {"
  first=yes
  for s in $(servers_for "$1"); do
    [ "$first" = yes ] || echo ","
    first=no
    printf '    "%s": {\n' "$s"
    case "$(mcp_field "$s" transport)" in
      http)
        printf '      "type": "http",\n'
        printf '      "url": "%s"' "$(mcp_field "$s" url)"
        tok="$(mcp_field "$s" token_env)"
        if [ -n "$tok" ]; then
          printf ',\n      "headers": { "Authorization": "Bearer ${%s}" }' "$tok"
        fi
        ;;
      *)
        printf '      "command": "%s"' "$(mcp_field "$s" command)"
        args="$(mcp_field "$s" args)"
        [ -n "$args" ] && printf ',\n      "args": %s' "$(json_array "$args")"
        env="$(mcp_field "$s" env)"
        if [ -n "$env" ]; then
          printf ',\n      "env": {\n'
          esep=""
          for v in $env; do
            # Separator printed as its own call: printf '%s' would emit a
            # literal backslash-n rather than a newline.
            [ -z "$esep" ] || printf ',\n'
            printf '        "%s": "${%s}"' "$v" "$v"
            esep=x
          done
          printf '\n      }'
        fi
        ;;
    esac
    printf '\n    }'
  done
  [ "$first" = yes ] || echo
  echo "  }"
  echo "}"
}

render_toml() { # Codex — [mcp_servers.<name>] blocks
  echo "# Generated by harness tools/link-mcp.sh — edits are overwritten."
  echo "# Change harness/.mcp-servers.yml and re-run, or tools/link-mcp.sh --all."
  echo "#"
  echo "# Codex reads a project-scoped .codex/config.toml only for projects you"
  echo "# have marked trusted; an untrusted project ignores it silently."
  for s in $(servers_for codex); do
    echo
    # Quoted key: a name with a dot in it would otherwise be a *nested*
    # table (`[mcp_servers.a.b]`), silently configuring a server nobody
    # named. Quoting is safe because validation has already refused any
    # name containing a quote or backslash.
    printf '[mcp_servers."%s"]\n' "$s"
    case "$(mcp_field "$s" transport)" in
      http)
        printf 'url = "%s"\n' "$(mcp_field "$s" url)"
        tok="$(mcp_field "$s" token_env)"
        [ -n "$tok" ] && printf 'bearer_token_env_var = "%s"\n' "$tok"
        ;;
      *)
        printf 'command = "%s"\n' "$(mcp_field "$s" command)"
        args="$(mcp_field "$s" args)"
        [ -n "$args" ] && printf 'args = %s\n' "$(json_array "$args")"
        env="$(mcp_field "$s" env)"
        # env_vars forwards the named variables from the ambient environment,
        # which mise has already populated from .env.collection*. Nothing is
        # written into this file, and Codex needs no ${VAR} expansion.
        [ -n "$env" ] && printf 'env_vars = %s\n' "$(json_array "$env")"
        ;;
    esac
  done
}

# --- write ---------------------------------------------------------------

written=0; current=0

write_if_changed() { # <path> <content>
  path="$1"; content="$2"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
    echo "  current  ${path#$collection/}"
    current=$((current + 1))
    return 0
  fi
  if [ "$dry_run" = yes ]; then
    echo "  would write ${path#$collection/}"
    written=$((written + 1))
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
  echo "  wrote    ${path#$collection/}"
  written=$((written + 1))
}

names="$(mcp_all_names)"
if [ -n "$names" ]; then
  echo "servers:    $(printf '%s' "$names" | tr '\n' ' ')"
fi

write_if_changed "$collection/.mcp.json"          "$(render_json claude)"
write_if_changed "$collection/.cursor/mcp.json"   "$(render_json cursor)"
write_if_changed "$collection/.codex/config.toml" "$(render_toml)"

echo "$written written, $current already current"

# Name the variables the rendered servers expect but the environment does not
# have. Not fatal: rendering config for a credential you have not created yet
# is a normal ordering, and the failure would otherwise only show up as an
# opaque auth error inside an agent.
missing=""
for s in $(mcp_all_names); do
  mcp_enabled "$s" || continue
  for v in $(mcp_field "$s" env) $(mcp_field "$s" token_env); do
    # Indirect expansion, not eval: the name comes from a tracked file, but
    # "tracked" is not "safe to execute" — a typo shaped like a command
    # substitution would run. validate_registry has already established that
    # this is an identifier.
    [ -n "${!v:-}" ] || case " $missing " in *" $v "*) ;; *) missing="$missing $v";; esac
  done
done
if [ -n "$missing" ]; then
  echo
  echo "note: unset in this shell:$missing"
  echo "      set them in <collection>/.env.collection.local (secrets) or the"
  echo "      control root — see instructions/secrets.md. Until then the"
  echo "      servers are configured but will fail to authenticate."
fi
