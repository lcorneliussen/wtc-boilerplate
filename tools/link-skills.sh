#!/usr/bin/env bash
# link-skills.sh — expose the harness skills (skills/wtc-*) at a collection
# root, under the directory names the agent CLIs actually read.
#
# The skills are authored once, in this repo (git-durable). Collections are
# generated and disposable, so they get symlinks — one per skill, which is the
# form Claude Code and Codex both document as supported:
#
#   <collection>/.claude/skills/<name> -> ../../harness/skills/<name>   (Claude Code)
#   <collection>/.agents/skills/<name> -> ../../harness/skills/<name>   (Codex, Cursor)
#
# Two directories cover all three CLIs; Cursor reads .agents/skills natively
# and .claude/skills for back-compat, so it needs no third copy. Why the
# collection root and not each worktree: the root is not a git repo, so the
# links are invisible to git and no repo needs an ignore rule for them.
# See instructions/skills.md for the discovery rules this encodes.
#
# Idempotent, and re-running is the point — same lifecycle as link-secrets.sh:
#   * creation time  — branch-off.sh / add-repo.sh call it
#   * catch-up       — picks up skills added to the harness since the
#                      collection was created, and prunes ones removed since
#
# It also installs the collection's entry point, which is what an agent opening
# this directory reads before anything else:
#
#   <collection>/AGENTS.md -> harness/collection-AGENTS.md   (versioned, shared)
#   <collection>/WTC-SCOPE.md                                (--seed-scope, local)
#
# And the agent-toolchain surface (instructions/hooks-and-env.md):
#
#   <collection>/.grok/hooks/wtc-agent-env.json -> harness/hooks/agent-env.json
#   <collection>/.claude/settings.json          -> harness/hooks/agent-env.json
#   <collection>/.cursor/hooks.json             -> harness/hooks/agent-env.json
#   <collection>/.envrc                         generated (PATH prepend)
#   <collection>/.env.toolchain                 generated (mise bin-paths)
#
# Bash 3.2-safe (macOS default): no mapfile, no associative arrays.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
harness_lib_init

# Directory names read by the agent CLIs. Each gets the same set of links.
SKILL_ROOTS=".claude/skills .agents/skills"

collection="$(dirname "$HARNESS_DIR")"
harness_dirname="$(basename "$HARNESS_DIR")"
dry_run=no
seed_scope=no
all=no

usage() {
  cat <<'EOF'
Usage: link-skills.sh [options]

Links a collection's own harness/skills/* into its .claude/skills and
.agents/skills so Claude Code, Codex, and Cursor all discover them.
Also installs agent toolchain hooks (.grok/hooks, .claude/settings.json,
.cursor/hooks.json) and refreshes .env.toolchain so a fresh agent shell
hits repo-pinned tools instead of the system ones. Idempotent.

  --seed-scope        Also write WTC-SCOPE.md from harness/collection-SCOPE.md
                      when the collection has none. Local and ephemeral, so it
                      is seeded (branch-off, /wtc-start) rather than linked,
                      and an existing one is never touched.
  --collection <dir>  Collection to wire (default: the one holding this
                      harness worktree).
  --all               Every collection under the workspace root. Use after
                      landing a new skill, to roll it out in one pass.
  --dry-run           Report what would change; touch nothing.
  -h, --help          Show this help.

Each collection is linked against ITS OWN harness worktree, not the one
running this script — the links are relative, so that is what they resolve
against, and a collection developing the harness keeps its own in-progress
skills. Consequence: a skill only reaches another collection once that
collection's harness worktree has it in git. Order is catch-up, then this.

Agents started inside a sibling worktree rather than at the collection root
see these only in Codex (it also scans $CWD/..). For Claude Code, start it at
the collection root or pass `--add-dir ..`.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --collection) collection="${2:?--collection needs a directory}"; shift 2;;
    --all)        all=yes; shift;;
    --seed-scope) seed_scope=yes; shift;;
    --dry-run)    dry_run=yes; shift;;
    -h|--help)    usage; exit 0;;
    *) echo "error: unknown option: $1 (use --help)" >&2; exit 1;;
  esac
done

# --all re-execs per collection rather than looping inline: one code path for
# one collection, and a collection whose harness is mid-rebase can't take the
# sweep down with it.
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

# Select the target collection's pinned CLI. The --all loop above re-enters
# this script per target so mixed-version workspaces keep their own renderer.
# Older pins and collections still bootstrapping keep the shell implementation.
if command -v wtc >/dev/null 2>&1 && [ -f "$collection/$harness_dirname/.wtc-cli-version" ]; then
  cli_pin="$(tr -d '[:space:]' < "$collection/$harness_dirname/.wtc-cli-version")"
  cli_version="$(cd "$collection" && wtc --version 2>/dev/null)" || cli_version=""
  if [ "$cli_version" = "wtc version $cli_pin" ] &&
      (cd "$collection" && wtc skills render --help >/dev/null 2>&1); then
    cli_args=(--collection "$collection")
    [ "$dry_run" = no ] || cli_args+=(--dry-run)
    [ "$seed_scope" = no ] || cli_args+=(--seed-scope)
    cd "$collection"
    exec wtc skills render "${cli_args[@]}"
  fi
fi

# Source is the TARGET collection's own harness worktree, not necessarily the
# one running this script: the links are relative, so they resolve against the
# harness sitting next to them. Reading the list from anywhere else would
# happily write links that dangle (another collection's harness may be on a
# branch where a skill does not exist yet).
src_root="$collection/$harness_dirname/skills"

# Skill names: a directory under skills/ holding a SKILL.md. Anything else
# there (README, shared references) is deliberately not a skill.
skill_names() {
  [ -d "$src_root" ] || return 0
  for d in "$src_root"/*/; do
    [ -f "${d}SKILL.md" ] || continue
    basename "${d%/}"
  done
}

# An empty list is not an early exit: the prune pass below still has to clear
# links left over from skills that have since been removed or renamed.
names="$(skill_names)"

echo "collection: $collection"
if [ -n "$names" ]; then
  echo "skills:     $(printf '%s' "$names" | tr '\n' ' ')"
else
  # Not an error: an older harness worktree simply predates skills/. Say which
  # worktree is short, so the fix (update it, then re-run) is obvious rather
  # than looking like this tool failing silently.
  echo "skills:     (none — $harness_dirname/ has no skills/ on its current"
  echo "            branch; catch that worktree up first, then re-run)"
fi

linked=0; current=0; pruned=0; skipped=0

for root in $SKILL_ROOTS; do
  dest_root="$collection/$root"
  # Both roots sit two levels below the collection, so one relative prefix
  # serves both. Relative, not absolute: the links stay correct if the whole
  # workspace moves, and they read as obviously collection-internal.
  rel_prefix="../../$harness_dirname/skills"

  # Don't conjure an empty skills dir in a collection that has no skills —
  # Claude Code only watches skill roots that existed at startup, so an empty
  # one is worse than absent.
  if [ -n "$names" ] && [ "$dry_run" = no ]; then
    mkdir -p "$dest_root"
  fi

  for name in $names; do
    dest="$dest_root/$name"
    want="$rel_prefix/$name"

    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$want" ]; then
      current=$((current + 1))
      continue
    fi

    # Never replace a hand-authored skill: a real directory here is somebody's
    # deliberate local override, and there is no safe place to back it up.
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      echo "    skip (not a symlink — local override?): $root/$name" >&2
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$dry_run" = yes ]; then
      echo "    would link: $root/$name"
      linked=$((linked + 1))
      continue
    fi

    ln -sfn "$want" "$dest"
    echo "    linked: $root/$name"
    linked=$((linked + 1))
  done

  # Prune links this tool owns whose skill is gone (renamed or deleted
  # upstream). Ownership test is the target prefix, so unrelated skills
  # symlinked in by hand are left alone.
  [ -d "$dest_root" ] || continue
  for entry in "$dest_root"/*; do
    [ -L "$entry" ] || continue
    target="$(readlink "$entry")"
    case "$target" in "$rel_prefix"/*) ;; *) continue ;; esac
    [ -f "$entry/SKILL.md" ] && continue
    if [ "$dry_run" = yes ]; then
      echo "    would prune: $root/$(basename "$entry")"
    else
      rm -f "$entry"
      echo "    pruned: $root/$(basename "$entry")"
    fi
    pruned=$((pruned + 1))
  done
done

echo
echo "linked=$linked already-current=$current pruned=$pruned skipped=$skipped"

# The collection entry point. An agent started at the collection root reads
# AGENTS.md there and nothing else automatically — not harness/AGENTS.md, not
# instructions/ — so that file is where the geometry, the isolation rule and
# the pointer to this collection's scope have to live. It is authored once as
# harness/collection-AGENTS.md — named for where it lands, since a file called
# AGENTS.md in the harness would be read as instructions for that folder — and
# linked, like the skills: relative, so it resolves against this collection's
# own harness worktree.
entry_src="$collection/$harness_dirname/collection-AGENTS.md"
entry_dest="$collection/AGENTS.md"
entry_rel="$harness_dirname/collection-AGENTS.md"
if [ -f "$entry_src" ]; then
  if [ -L "$entry_dest" ] && [ "$(readlink "$entry_dest")" = "$entry_rel" ]; then
    echo "entry: AGENTS.md already-current"
  elif [ -e "$entry_dest" ] && [ ! -L "$entry_dest" ]; then
    echo "entry: skip AGENTS.md (a real file is there, not a link)" >&2
  elif [ "$dry_run" = yes ]; then
    echo "entry: would link AGENTS.md -> $entry_rel"
  else
    ln -sfn "$entry_rel" "$entry_dest"
    echo "entry: linked AGENTS.md -> $entry_rel"
  fi
fi

# WTC-SCOPE.md says what THIS collection is for. It is per-collection and dies
# with it, so it is a seeded copy rather than a link — and it is seeded only on
# request (branch-off, /wtc-start): an unfilled template in a live collection
# would be worse than no file, since an agent would read the placeholders as
# the scope. An existing scope file is never overwritten; widening the scope is
# the user's edit to make.
scope_tpl="$collection/$harness_dirname/collection-SCOPE.md"
scope_dest="$collection/WTC-SCOPE.md"
if [ "$seed_scope" = yes ] && [ -f "$scope_tpl" ]; then
  if [ -e "$scope_dest" ]; then
    echo "scope: WTC-SCOPE.md already there — left alone"
  elif [ "$dry_run" = yes ]; then
    echo "scope: would seed WTC-SCOPE.md from the template"
  else
    # The repo table is the one part the tooling knows better than the agent:
    # what is actually checked out here, right now.
    {
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          *"{{REPOS}}"*)
            printf '| Repo | Why it is here |\n|---|---|\n'
            for wt in "$collection"/*/; do
              wt="${wt%/}"
              [ -e "$wt/.git" ] || continue
              printf '| `%s` |  |\n' "$(basename "$wt")"
            done
            ;;
          *) printf '%s\n' "$line" ;;
        esac
      done < "$scope_tpl"
    } | sed "s/{{COLLECTION}}/$(basename "$collection")/g" > "$scope_dest"
    echo "scope: seeded WTC-SCOPE.md"
  fi
fi

# Agent toolchain hooks. Same link-not-copy rule as skills: one authored file
# in this repo, collection-root destinations the CLIs actually read. A real
# file at the destination (not a symlink) is a local override and is left
# alone. Relative targets: .grok/hooks is two levels down, .claude and
# .cursor are one.
link_hook() { # <dest> <rel-target>
  _dest="$1" _want="$2"
  if [ -L "$_dest" ] && [ "$(readlink "$_dest")" = "$_want" ]; then
    echo "hooks: $(echo "$_dest" | sed "s|^$collection/||") already-current"
    return 0
  fi
  if [ -e "$_dest" ] && [ ! -L "$_dest" ]; then
    echo "hooks: skip $(echo "$_dest" | sed "s|^$collection/||") (a real file is there, not a link)" >&2
    return 0
  fi
  if [ "$dry_run" = yes ]; then
    echo "hooks: would link $(echo "$_dest" | sed "s|^$collection/||") -> $_want"
    return 0
  fi
  mkdir -p "$(dirname "$_dest")"
  ln -sfn "$_want" "$_dest"
  echo "hooks: linked $(echo "$_dest" | sed "s|^$collection/||") -> $_want"
}

hooks_src="$collection/$harness_dirname/hooks/agent-env.json"
if [ -f "$hooks_src" ]; then
  link_hook "$collection/.grok/hooks/wtc-agent-env.json" "../../$harness_dirname/hooks/agent-env.json"
  link_hook "$collection/.claude/settings.json" "../$harness_dirname/hooks/agent-env.json"
  link_hook "$collection/.cursor/hooks.json" "../$harness_dirname/hooks/agent-env.json"
else
  echo "hooks: (none — $harness_dirname/hooks/agent-env.json is missing)"
fi

# .envrc: Grok load_envrc injects it into bash commands without needing project
# hook trust. direnv users get the same PATH prepend. Regenerated whenever
# this tool runs; it only sources generated files, never secrets by value.
envrc_dest="$collection/.envrc"
envrc_body='# Generated by harness/tools/link-skills.sh. Do not edit.
# Grok load_envrc and direnv both pick this up. Agent CLIs that never
# activate mise still need the sibling toolchain on PATH so `/usr/bin/env
# ruby` does not fall back to macOS system Ruby.
[ -f ./.env.collection ] && { set -a; . ./.env.collection; set +a; }
[ -f ./.env.collection.local ] && { set -a; . ./.env.collection.local; set +a; }
[ -f ./.env.toolchain ] && { set -a; . ./.env.toolchain; set +a; }
case ":${PATH:-}:" in
  *":${WTC_TOOLCHAIN_PATH:-__unset__}:"*) ;;
  *) [ -n "${WTC_TOOLCHAIN_PATH:-}" ] && PATH="${WTC_TOOLCHAIN_PATH}${PATH:+:${PATH}}" ;;
esac
export PATH
'
if [ "$dry_run" = yes ]; then
  echo "envrc: would write .envrc"
elif [ -e "$envrc_dest" ] && [ ! -L "$envrc_dest" ] && ! grep -q 'Generated by harness/tools/link-skills.sh' "$envrc_dest" 2>/dev/null; then
  echo "envrc: skip .envrc (a real file is there without the generated marker)" >&2
else
  printf '%s' "$envrc_body" > "$envrc_dest"
  echo "envrc: wrote .envrc"
fi

# Refresh cached bin paths after siblings exist. Cheap when mise is missing
# (agent-env.sh exits 0). After init hooks have installed tools, re-running
# this (catch-up, add-repo, wtc-open) picks the new bins up.
if [ "$dry_run" = yes ]; then
  echo "toolchain: would refresh .env.toolchain"
elif [ -x "$collection/$harness_dirname/tools/agent-env.sh" ]; then
  if "$collection/$harness_dirname/tools/agent-env.sh" --write; then
    echo "toolchain: wrote .env.toolchain"
  else
    echo "toolchain: agent-env.sh --write failed (continuing)" >&2
  fi
fi

exit 0
