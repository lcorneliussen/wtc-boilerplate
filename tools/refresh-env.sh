#!/usr/bin/env bash
# refresh-env.sh — regenerate a collection's .env.collection from the current
# registry and the current generator.
#
# Why this exists: .env.collection is written by write_collection_env, and only
# branch-off.sh (new collection) and add-repo.sh (only when the file is absent)
# ever call it. So a variable added to the generator — ports for a newly
# registered repo, GH_CONFIG_DIR — reaches new collections only, and every
# collection created before the change stays stale forever. This is the missing
# "pick it up afterwards" half, the same one link-skills.sh already has.
#
# It is also how the opt-in tool-identity variables get turned on or off: they
# are emitted from the presence of $WTC_CONFIG_ROOT/gh and friends
# (instructions/secrets.md → Tool identity), and that presence is only re-read
# when the file is regenerated.
#
# Safe to re-run, and re-running is the point:
#   * the existing COLLECTION_PORT_BASE is preserved, so ports do not move
#   * .env.collection.local is NOT touched — it is seeded once and hand-authored
#
# It regenerates .env.collection WHOLESALE, which is its documented contract
# (instructions/secrets.md): anything hand-added there is lost, and always was
# on the next branch-off. Hand-authored values belong in .env.collection.local,
# which this tool leaves alone and which wins on a conflicting key.
#
# Already-open herdr panes do NOT pick this up: tools/wtc-open.sh injects the
# env at workspace *creation* and skips that block when reusing an existing
# workspace. Close and reopen the workspace, or export by hand in the pane.
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
skip_hooks=no

usage() {
  cat <<'EOF'
Usage: refresh-env.sh [options]

Regenerates <collection>/.env.collection from the current registry and
generator, preserving the collection's port base. Leaves
.env.collection.local untouched.

  --collection <dir>  Collection to refresh (default: the one holding this
                      harness worktree).
  --all               Every collection under the workspace root. Use after
                      landing a generator change.
  --dry-run           Preview generated env and mise config; write nothing.
  --skip-hooks        Do not run target hooks or trust mise (used by --all).
  -h, --help          Show this help.

Already-open herdr panes keep the environment they were created with —
wtc-open.sh injects it at workspace creation and skips it when reusing an
open workspace. Close and reopen the workspace to pick up changes.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --collection) collection="${2:?--collection needs a directory}"; shift 2;;
    --all)        all=yes; shift;;
    --dry-run)    dry_run=yes; shift;;
    --skip-hooks) skip_hooks=yes; shift;;
    -h|--help)    usage; exit 0;;
    *) echo "error: unknown option: $1 (use --help)" >&2; exit 1;;
  esac
done

# --all re-execs per collection, same reasoning as link-skills.sh: one code
# path, and one broken collection cannot take the sweep down with it.
if [ "$all" = yes ]; then
  swept=0 failed=0
  for dir in "$ROOT"/*/; do
    dir="${dir%/}"
    [ -d "$dir/$harness_dirname" ] || continue
    swept=$((swept + 1))
    echo "=== $(basename "$dir")"
    if [ "$dry_run" = yes ]; then
      "$0" --collection "$dir" --dry-run --skip-hooks || failed=$((failed + 1))
    else
      "$0" --collection "$dir" --skip-hooks || failed=$((failed + 1))
    fi
  done
  echo "swept $swept collection(s), $failed failed"
  [ "$failed" -eq 0 ] || exit 1
  exit 0
fi

[ -d "$collection" ] || { echo "error: collection not found: $collection" >&2; exit 1; }
collection="$(cd "$collection" && pwd)"
[ -d "$collection/$harness_dirname" ] || {
  echo "error: $collection has no $harness_dirname/ — not a collection" >&2; exit 1; }

# The target collection's mise.toml chooses its CLI version. Keep the shell
# implementation for bootstrap and older pins; --all re-enters here per target.
native_env_supported() { # 0.1.9 first trusted generated mise.toml
  awk -v version="$1" 'BEGIN {
    if (version !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
    split(version, part, ".")
    exit !((part[1] + 0) > 0 || (part[2] + 0) > 1 ||
           ((part[2] + 0) == 1 && (part[3] + 0) >= 9))
  }'
}
native_env_skip_supported() { # v0.1.14 added safe hook controls for sweeps
  awk -v version="$1" 'BEGIN {
    if (version !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
    split(version, part, ".")
    exit !((part[1] + 0) > 0 || (part[2] + 0) > 1 ||
           ((part[2] + 0) == 1 && (part[3] + 0) >= 14))
  }'
}
if [ -f "$collection/$harness_dirname/.wtc-cli-version" ]; then
  cli_pin="$(tr -d '[:space:]' < "$collection/$harness_dirname/.wtc-cli-version")"
  cli_version=""
  cli_cmd=()
  if native_env_supported "$cli_pin" && { [ "$skip_hooks" = no ] || native_env_skip_supported "$cli_pin"; } && command -v mise >/dev/null 2>&1; then
    cli_version="$(cd "$collection" && mise exec -- wtc --version 2>/dev/null)" || cli_version=""
    [ -z "$cli_version" ] || cli_cmd=(mise exec -- wtc)
  fi
  if native_env_supported "$cli_pin" && { [ "$skip_hooks" = no ] || native_env_skip_supported "$cli_pin"; } && [ -z "$cli_version" ] && command -v wtc >/dev/null 2>&1; then
    cli_version="$(cd "$collection" && wtc --version 2>/dev/null)" || cli_version=""
    [ -z "$cli_version" ] || cli_cmd=(wtc)
  fi
  if [ "$cli_version" = "wtc version $cli_pin" ] &&
      (cd "$collection" && "${cli_cmd[@]}" env --help >/dev/null 2>&1); then
    cli_args=(--collection "$collection")
    [ "$dry_run" = no ] || cli_args+=(--dry-run)
    [ "$skip_hooks" = no ] || cli_args+=(--skip-hooks)
    cd "$collection"
    exec "${cli_cmd[@]}" env "${cli_args[@]}"
  fi
fi

name="$(basename "$collection")"
target="$collection/.env.collection"

# write_collection_env writes THREE files (.env.collection, mise.toml, and
# .env.collection.local when absent) and runs `mise trust`. So --dry-run cannot
# call it against the real collection and undo the damage afterwards — it would
# leave a regenerated mise.toml and a fresh .env.collection.local behind.
# Instead, dry-run generates into a throwaway directory seeded with the current
# .env.collection (so the port base is read from the real one and does not move)
# and diffs that. The real collection is never opened for writing at all.

work="$(mktemp -d "${TMPDIR:-/tmp}/wtc-refresh-env.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [ -f "$target" ]; then
  cp "$target" "$work/before"
else
  : > "$work/before"
fi
if [ -f "$collection/mise.toml" ]; then
  cp "$collection/mise.toml" "$work/mise-before"
else
  : > "$work/mise-before"
fi

if [ "$dry_run" = yes ]; then
  [ -f "$target" ] && cp "$target" "$work/.env.collection"
  # Preview generation must not register a temporary path in mise trust.
  write_collection_env "$work" "$name" "$collection/$harness_dirname" yes >/dev/null
  cp "$work/.env.collection" "$work/after"
  cp "$work/mise.toml" "$work/mise-after"
else
  write_collection_env "$collection" "$name" "$collection/$harness_dirname" "$skip_hooks" >/dev/null
  cp "$target" "$work/after"
  cp "$collection/mise.toml" "$work/mise-after"
fi

if cmp -s "$work/before" "$work/after" && cmp -s "$work/mise-before" "$work/mise-after"; then
  echo "$name: already current"
  exit 0
fi

if [ "$dry_run" = yes ]; then
  echo "$name: would change —"
else
  echo "$name: updated —"
fi

# diff exits 1 when files differ, which is the expected path here; `|| :` keeps
# that from tripping set -e. Head trimmed: the ---/+++ lines name temp paths.
diff -u "$work/before" "$work/after" 2>/dev/null | sed -n '4,$p' | sed 's/^/  /' || :
diff -u "$work/mise-before" "$work/mise-after" 2>/dev/null | sed -n '4,$p' | sed 's/^/  /' || :
