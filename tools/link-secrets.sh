#!/usr/bin/env bash
# link-secrets.sh — link machine-local secrets from the control root
# ($WTC_CONFIG_ROOT, see instructions/secrets.md) into a collection's
# worktrees.
#
# The control root stores each file at its repo-relative path
# (<repo>/<path-inside-repo>), so linking is mechanical: for every checked-out
# repo in the collection, every control-root file below <repo>/ becomes a
# symlink at the same relative path inside the worktree.
#
# Idempotent by design — safe to re-run, and re-running is the point:
#   * creation time  — each repo's .harness/init.sh calls it (hooks-and-env.md)
#   * catch-up       — picks up control-root files added since the collection
#                      was created, and repairs stale hand-made copies
#
# Rules enforced (secrets.md):
#   * a target that is not gitignored is REFUSED, never linked — the ignore
#     rule must exist first, or the secret is one `git add -A` from being
#     committed
#   * prod-capable material is skipped unless --include-prod: it stays out of
#     worktrees unless a task explicitly needs it (secrets.md rule 3)
#   * an existing regular file is moved to the collection's .harness-backups/
#     before being replaced, so a hand-made local copy is never lost
#
# Bash 3.2-safe (macOS default): no mapfile, no associative arrays.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
harness_lib_init

# Control-root paths that must never be auto-linked (secrets.md rule 3).
# Match is on "<repo>/<relpath>" as stored in the control root. Space-separated;
# list every prod-capable file here — a deploy env or signing material linked
# into a worktree by default is one careless command away from being used.
#   e.g. PROD_PATHS="worker/.env.prod api/.env.production"
PROD_PATHS=""

collection="$(dirname "$HARNESS_DIR")"
only_repo=""
dry_run=no
include_prod=no

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'
  cat <<'EOF'
Usage: link-secrets.sh [options]

  --collection <dir>  Collection to wire (default: the one holding this
                      harness worktree).
  --repo <name>       Only this repo (init hooks pass their own name).
  --include-prod      Also link prod-capable paths. Deliberate, task-scoped:
                      unlink them when the task is done (secrets.md rule 3).
  --dry-run           Report what would change; touch nothing.
  -h, --help          Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --collection)   collection="${2:?--collection needs a directory}"; shift 2;;
    --repo)         only_repo="${2:?--repo needs a name}"; shift 2;;
    --include-prod) include_prod=yes; shift;;
    --dry-run)      dry_run=yes; shift;;
    -h|--help)      usage; exit 0;;
    *) echo "error: unknown option: $1 (use --help)" >&2; exit 1;;
  esac
done

[ -d "$collection" ] || { echo "error: collection not found: $collection" >&2; exit 1; }
collection="$(cd "$collection" && pwd)"

# Control root: explicit env wins, then the collection's generated env, then
# the documented default. Catch-up may run in a shell mise never touched.
config_root="${WTC_CONFIG_ROOT:-${WTC_CONFIG_ROOT:-}}"
if [ -z "$config_root" ] && [ -f "$collection/.env.collection" ]; then
  config_root="$(sed -n 's/^WTC_CONFIG_ROOT=//p' "$collection/.env.collection" | head -n1)"
  [ -n "$config_root" ] || config_root="$(sed -n 's/^WTC_CONFIG_ROOT=//p' "$collection/.env.collection" | head -n1)"
fi
[ -n "$config_root" ] || config_root="$HOME/.config/wtc"

# An absent control root means "this machine has no local secrets to link",
# which is a legitimate state. Treating it as an error made every catch-up
# and every init hook report a failure for work that was correctly a no-op,
# which is how real failures stop being read.
if [ ! -d "$config_root" ]; then
  echo "control root $config_root does not exist — nothing to link."
  exit 0
fi

echo "collection:   $collection"
echo "control root: $config_root"

backup_root="$collection/.harness-backups"

linked=0; current=0; refused=0; skipped_prod=0; backed_up=0

is_prod_path() { # <repo/relpath>
  for p in $PROD_PATHS; do
    [ "$1" = "$p" ] && return 0
  done
  return 1
}

for repo_cfg in "$config_root"/*; do
  [ -d "$repo_cfg" ] || continue
  repo="$(basename "$repo_cfg")"

  [ -n "$only_repo" ] && [ "$repo" != "$only_repo" ] && continue

  worktree="$collection/$repo"
  # A control-root dir with no matching worktree is normal: the control root is
  # machine-wide, collections are scoped.
  [ -d "$worktree" ] || continue
  if ! git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1; then
    echo "==> $repo: not a git worktree — skipped"
    continue
  fi

  echo "==> $repo"
  # find | while-read runs the body in a subshell, so counters would be lost;
  # feed the loop from a here-doc-free redirect instead (bash 3.2: no lastpipe).
  while IFS= read -r src; do
    rel="${src#"$repo_cfg"/}"
    dest="$worktree/$rel"

    if is_prod_path "$repo/$rel" && [ "$include_prod" = no ]; then
      echo "    skip (prod-capable, --include-prod to override): $rel"
      skipped_prod=$((skipped_prod + 1))
      continue
    fi

    # Already correct? Compare link targets, not contents.
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
      current=$((current + 1))
      continue
    fi

    # The ignore check needs the parent dir to exist for a meaningful path, but
    # check-ignore works on the path string alone — run it before touching disk.
    if ! git -C "$worktree" check-ignore -q "$rel"; then
      echo "    REFUSED (not gitignored): $rel" >&2
      echo "      add an ignore rule in $repo first, then re-run" >&2
      refused=$((refused + 1))
      continue
    fi

    if [ "$dry_run" = yes ]; then
      echo "    would link: $rel"
      linked=$((linked + 1))
      continue
    fi

    # Preserve a hand-made copy before replacing it. Backups live at the
    # collection root, outside every worktree — a backup inside the repo would
    # not match the ignore rule that covers the original.
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      bak="$backup_root/$repo/$rel.$(date -u +%Y%m%dT%H%M%SZ)"
      mkdir -p "$(dirname "$bak")"
      mv "$dest" "$bak"
      echo "    backed up existing file -> ${bak#"$collection"/}"
      backed_up=$((backed_up + 1))
    fi

    mkdir -p "$(dirname "$dest")"
    ln -sfn "$src" "$dest"
    echo "    linked: $rel"
    linked=$((linked + 1))
  done <<EOF
$(find "$repo_cfg" -type f -o -type l | sort)
EOF
done

echo
echo "linked=$linked already-current=$current refused=$refused prod-skipped=$skipped_prod backed-up=$backed_up"
[ "$refused" -gt 0 ] && exit 1
exit 0
