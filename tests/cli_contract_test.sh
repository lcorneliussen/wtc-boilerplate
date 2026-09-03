#!/usr/bin/env bash
# cli_contract_test.sh — the promises every tool makes regardless of what it
# does: it parses, it runs on the bash macOS ships, and asking it for help is
# not an error.
#
# These are cheap and they cover the whole surface, which is the point: the
# regressions that prompted this suite (`--help` exiting 1, a bash-4-only
# construct) were both invisible to any test aimed at one tool's behaviour.
#
# Anything that *executes* a tool runs the fixture's copy, never the source
# tree. Tools locate the workspace from their own path, not from $PWD, so
# running $HARNESS_SRC/tools/foo.sh reaches the real .bare/ and the real
# collections however carefully you cd first — an early draft of this file had
# refresh-configs.sh rewriting the developer's live .harness-repos.
. "$(dirname "$0")/helpers.sh"

ws="$(make_workspace)"
fixture_tools="$ws/main/harness/tools"

# Static scans read the source tree: they never run anything, and checking the
# copy would only prove cp works.
src_scripts=""
for f in "$HARNESS_SRC"/tools/*.sh "$HARNESS_SRC"/hooks/*.sh; do
  [ -f "$f" ] || continue
  src_scripts="$src_scripts $f"
done

# Executable tools: everything with a CLI. lib.sh and *-common.sh are excluded
# because their first lines say "source this, don't execute" — they have no
# argv contract to keep (and running them only prints that error).
cli_tools=""
for f in "$fixture_tools"/*.sh; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in
    lib.sh|*-common.sh) continue ;;
  esac
  cli_tools="$cli_tools $f"
done

# --- it parses --------------------------------------------------------------

it "every script passes bash -n"
for f in $src_scripts; do
  out="$(bash -n "$f" 2>&1)"
  if [ $? -eq 0 ]; then
    _pass "bash -n $(basename "$f")"
  else
    _fail "bash -n $(basename "$f")" "$out"
  fi
done

# --- it runs on bash 3.2 ----------------------------------------------------
# macOS ships bash 3.2 and that is what `#!/usr/bin/env bash` gets unless the
# user has done something about it. Every construct below is a syntax error or
# a silent no-op there, and all of them are the kind of thing an editor or an
# assistant adds without thinking.

it "no bash 4+ constructs"
for f in $src_scripts; do
  base="$(basename "$f")"
  # Strip comments before scanning: a comment explaining why something is
  # avoided would otherwise trip the scan that enforces avoiding it.
  #
  # Only whole-line comments and inline ones preceded by whitespace. Cutting at
  # the first `#` on the line would eat `${remote#*github.com}` and every other
  # prefix-strip expansion — truncating the line, and with it anything after
  # the expansion that the scan was supposed to see.
  body="$(sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#[^}]*$//' "$f")"
  hits=""
  case "$body" in *mapfile*)      hits="$hits mapfile" ;; esac
  case "$body" in *readarray*)    hits="$hits readarray" ;; esac
  case "$body" in *"declare -A"*) hits="$hits declare-A" ;; esac
  case "$body" in *"local -A"*)   hits="$hits local-A" ;; esac
  # ${var,,} / ${var^^} — lower/upper expansion, bash 4 only.
  if printf '%s' "$body" | grep -q '\${[A-Za-z_][A-Za-z0-9_]*\(,,\|\^\^\)'; then
    hits="$hits case-expansion"
  fi
  if printf '%s' "$body" | grep -q '|&'; then
    hits="$hits pipe-ampersand"
  fi
  if [ -z "$hits" ]; then
    _pass "bash 3.2 clean: $base"
  else
    _fail "bash 4 construct in $base" "found:$hits"
  fi
done

# --- --help is not an error -------------------------------------------------
# `usage()` ending in a bare `exit 1` makes `tools/foo.sh --help` fail under
# `set -e` for no reason, and sends the text to stderr where a pager will not
# find it. Asking for help is a successful outcome.

it "--help exits 0 and prints usage"
for f in $cli_tools; do
  base="$(basename "$f")"
  out="$("$f" --help 2>&1)"
  rc=$?
  if [ "$rc" != 0 ]; then
    _fail "$base --help exited $rc" "$(printf '%s' "$out" | head -3)"
    continue
  fi
  case "$out" in
    *[Uu]sage*) _pass "$base --help" ;;
    *) _fail "$base --help printed no usage" "$(printf '%s' "$out" | head -3)" ;;
  esac
done

it "-h behaves like --help"
for f in $cli_tools; do
  base="$(basename "$f")"
  out="$("$f" -h 2>&1)"
  rc=$?
  if [ "$rc" = 0 ]; then
    _pass "$base -h"
  else
    _fail "$base -h exited $rc" "$(printf '%s' "$out" | head -3)"
  fi
done

it "--help works from outside any collection"
# An agent asking a tool how it works is usually lost, which is exactly when
# it is not standing in a collection. Resolving a workspace before parsing
# argv turns "how do I use this" into "error: registry missing".
outside="$(mktemp_dir outside)"
for f in $cli_tools; do
  base="$(basename "$f")"
  out="$(cd "$outside" && HARNESS_DIR="" "$f" --help 2>&1)"
  if [ $? = 0 ]; then
    _pass "$base --help outside a collection"
  else
    _fail "$base --help outside a collection" "$(printf '%s' "$out" | head -2)"
  fi
done

# --- an unknown flag is an error -------------------------------------------
# The other half: --help succeeding must not come from a tool that succeeds at
# everything. A typo'd flag has to be refused, or a mistyped destructive
# command runs with defaults.

it "an unknown flag is refused"
for f in $cli_tools; do
  base="$(basename "$f")"
  case "$base" in
    # agent-env.sh stops parsing at the first unknown token instead of failing:
    # it runs from a PreToolUse hook, where refusing to run breaks every shell
    # command in the session. Fail-open is the documented contract there.
    agent-env.sh) continue ;;
  esac
  out="$("$f" --definitely-not-a-real-flag 2>&1)"
  if [ $? != 0 ]; then
    _pass "$base rejects an unknown flag"
  else
    _fail "$base accepted --definitely-not-a-real-flag" "$(printf '%s' "$out" | head -3)"
  fi
done

# --- executable bits --------------------------------------------------------

it "every CLI tool is executable"
for f in $cli_tools; do
  base="$(basename "$f")"
  if [ -x "$f" ]; then _pass "executable: $base"; else _fail "not executable: $base"; fi
done
