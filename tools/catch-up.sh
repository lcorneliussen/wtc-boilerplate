#!/usr/bin/env bash
# catch-up.sh — reconcile worktree collection(s) with remotes.
# Procedure: skills/wtc-catch-up, instructions/development-workflows.md
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tools/catch-up.sh [options] [<collection> ...]
  tools/catch-up.sh --all [options]

Fetch/prune every sibling owner. Each collection updates its harness/
worktree first (self-update: tools/skills from origin/main), then reconciles
sibling repos, then link-skills, link-mcp, refresh-env and link-secrets.

Safe: no rebase, no force-push. Dirty trees are stashed (including
untracked) around the update, then the stash is applied. In-progress
merges/rebases are still skipped.

  --all         every collection under the workspace root
  --dry-run     report only; touch nothing
  --no-skills   skip link-skills.sh
  --no-mcp      skip link-mcp.sh (rendered MCP configs)
  --no-env      skip refresh-env.sh (the generated .env.collection)
  --no-secrets  skip link-secrets.sh (control-root -> worktree symlinks)
  -h, --help    show this help
EOF
}

log() { printf 'catch-up: %s\n' "$*"; }
warn() { printf 'catch-up: warning: %s\n' "$*" >&2; }

all=no dry_run=no do_skills=yes do_mcp=yes do_secrets=yes do_env=yes
while [ $# -gt 0 ]; do
  case "$1" in
    --all) all=yes; shift ;;
    --dry-run) dry_run=yes; shift ;;
    --no-skills) do_skills=no; shift ;;
    --no-mcp) do_mcp=no; shift ;;
    --no-secrets) do_secrets=no; shift ;;
    --no-env) do_env=no; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
harness_lib_init

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
  collections="$(this_collection)"
fi
[ -n "${collections// /}" ] || { echo "error: no collections" >&2; exit 1; }

# GitHub PR state for a repo branch (OPEN|DRAFT|MERGED|CLOSED|…|empty).
# Enlisted rows first (this collection's own bookkeeping); a branch with no
# enlistment falls back to asking GitHub directly, one state per branch, in
# every state — `gh pr list` defaults to open-only, and a branch whose PR
# merged without ever being enlisted must not look "still live" forever.
pr_state_for_branch() { # <collection> <repo> <branch>
  coll="$1" repo="$2" branch="$3"
  saw=""
  while IFS=$'\t' read -r r num b url title; do
    [ "$r" = "$repo" ] || continue
    [ "$b" = "$branch" ] || continue
    st="$(wtc_pr_enrich "$repo" "$num" "$title" "$(wtc_repo_worktree "$coll" "$repo")" \
      | awk -F'\t' '{print $2; exit}')"
    # Empty / unknown: gh missing or view failed — do not treat as OPEN (would
    # push) or MERGED (would prune). Keep looking / fall through.
    [ -n "$st" ] || continue
    case "$st" in
      OPEN|open|DRAFT|draft) printf '%s\n' "$st"; return 0 ;;
    esac
    [ -n "$saw" ] || saw="$st"
  done <<EOF
$(wtc_pr_enlist_rows "$coll")
EOF
  if [ -n "$saw" ]; then
    printf '%s\n' "$saw"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 0
  IFS=$'\t' read -r slug _forge <<EOF
$(repo_slug_and_forge "$repo" "$(wtc_repo_worktree "$coll" "$repo")")
EOF
  [ -n "$slug" ] || return 0
  gh pr list --repo "$slug" --head "$branch" --state all --json state \
    --jq '.[0].state' 2>/dev/null || true
}

# The harness worktree is always named `harness/`; its registry identity is
# whatever `harness_repo` resolves to (default `agent-harness`, override via
# `WTC_HARNESS_REPO`) — same mapping wtc-status.sh already uses.
wt_repo_name() { # <worktree-path> <collection>
  base="$(basename "$1")"
  if [ "$base" = harness ]; then
    printf '%s\n' "$(harness_repo)"
  else
    printf '%s\n' "$base"
  fi
}

fetch_owners_for_collection() { # <collection-dir>
  coll="$1"
  seen=""
  for wt in "$coll"/*/; do
    wt="${wt%/}"
    [ -e "$wt/.git" ] || continue
    owner="$(owner_of "$wt")"
    [ -n "$owner" ] || continue
    case " $seen " in *" $owner "*) continue ;; esac
    seen="$seen $owner"
    if [ "$dry_run" = yes ]; then
      log "  would fetch: $owner"
    else
      if [ -d "$owner/refs" ] || [ -f "$owner/HEAD" ]; then
        git --git-dir="$owner" fetch --prune origin
      else
        git -C "$owner" fetch --prune origin
      fi
    fi
  done
}

ensure_harness_skills() { # <harness-worktree>
  wt="$1"
  [ -d "$wt/skills" ] && return 0
  warn "$(basename "$(dirname "$wt")")/harness: no skills/ after harness catch-up — merge origin/main"
}

prepare_harness_for_catchup() { # <worktree>
  local wt="$1"
  [ -d "$wt/skills" ] || return 0
  [ -n "$(git -C "$wt" ls-files -- skills 2>/dev/null)" ] && return 0
  if [ "$dry_run" = yes ]; then
    log "  would remove untracked skills/ before harness merge (rsync residue)"
    return 0
  fi
  rm -rf "$wt/skills"
  log "  removed untracked skills/ before harness merge (rsync residue)"
}

# Stash tracked + untracked (not ignored) so HEAD can move; pop afterward.
# Sets did_stash=yes when a stash was created. Returns 1 if stash failed.
stash_dirty_for_catch_up() { # <worktree> <label>
  local wt="$1" label="$2" dirty msg
  did_stash=no
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null || true)"
  [ -n "$dirty" ] || return 0
  if [ "$dry_run" = yes ]; then
    log "  would stash dirty $coll_name/$label (incl. untracked)"
    did_stash=yes
    return 0
  fi
  msg="wtc-catch-up ${coll_name}/${label}"
  if git -C "$wt" stash push --include-untracked -m "$msg"; then
    did_stash=yes
    log "  $coll_name/$label: stashed local changes"
    return 0
  fi
  warn "$coll_name/$label: stash failed — skipped"
  return 1
}

pop_catch_up_stash() { # <worktree> <label>
  local wt="$1" label="$2"
  [ "$did_stash" = yes ] || return 0
  [ "$dry_run" = yes ] && { log "  would apply stash on $coll_name/$label"; return 0; }
  if git -C "$wt" stash pop; then
    log "  $coll_name/$label: restored stash"
    return 0
  fi
  warn "$coll_name/$label: stash pop conflicted — resolve conflicts, then git stash drop if the entry remains"
  return 1
}

catch_up_worktree() { # <collection-name> <worktree> <repo>
  local coll_name="$1" wt="$2" repo="$3" ref label branch behind pr_state extra
  ref="$(default_ref_for "$repo")"
  label="$(basename "$wt")"
  [ "$label" = harness ] && label="harness($repo)"
  did_stash=no

  if [ -d "$wt/.git/rebase-merge" ] || [ -d "$wt/.git/rebase-apply" ] \
     || [ -f "$wt/.git/CHERRY_PICK_HEAD" ] \
     || git -C "$wt" rev-parse --verify MERGE_HEAD >/dev/null 2>&1; then
    warn "$coll_name/$label: mid-merge/rebase — skipped"
    return 0
  fi

  branch="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || true)"

  if [ -z "$branch" ]; then
    behind="$(git -C "$wt" rev-list --count HEAD.."$ref" 2>/dev/null || echo 0)"
    [ "$behind" != 0 ] || { log "  $coll_name/$label: detached at tip"; return 0; }
    stash_dirty_for_catch_up "$wt" "$label" || return 0
    if [ "$dry_run" = yes ]; then
      log "  would detach $coll_name/$label at $ref ($behind behind)"
    else
      git -C "$wt" checkout --detach "$ref"
      log "  $coll_name/$label: detached at $ref (was $behind behind)"
    fi
    pop_catch_up_stash "$wt" "$label" || true
    return 0
  fi

  pr_state="$(pr_state_for_branch "$coll_name" "$repo" "$branch")"
  case "$pr_state" in
    MERGED|merged)
      extra="$(git -C "$wt" rev-list --count "$ref..HEAD" 2>/dev/null || echo 0)"
      if [ "$extra" != 0 ]; then
        warn "$coll_name/$label: PR merged but $extra commit(s) beyond base — skipped (rename branch?)"
        return 0
      fi
      stash_dirty_for_catch_up "$wt" "$label" || return 0
      if [ "$dry_run" = yes ]; then
        log "  would return $coll_name/$label from merged $branch to $ref"
      else
        git -C "$wt" checkout --detach "$ref"
        git -C "$wt" branch -d "$branch" 2>/dev/null || warn "$coll_name/$label: branch -d $branch refused"
        # Keep the .wtc-prs row: status ages MERGED into the archived toggle
        # after 48 weekday-hours. Unlisting here emptied the only store the
        # PRS section reads, so catch-up wiped the archive fodder.
        log "  $coll_name/$label: merged PR — detached at $ref, pruned $branch"
      fi
      pop_catch_up_stash "$wt" "$label" || true
      return 0
      ;;
  esac

  # Live branch — merge base forward
  behind="$(git -C "$wt" rev-list --count HEAD.."$ref" 2>/dev/null || echo 0)"
  [ "$behind" != 0 ] || { log "  $coll_name/$label: $branch current"; return 0; }
  stash_dirty_for_catch_up "$wt" "$label" || return 0
  if [ "$dry_run" = yes ]; then
    log "  would merge $ref into $coll_name/$label ($branch, $behind behind)"
    pop_catch_up_stash "$wt" "$label" || true
    return 0
  fi
  [ "$label" = "harness($repo)" ] && prepare_harness_for_catchup "$wt"
  if git -C "$wt" merge --no-edit "$ref"; then
    log "  $coll_name/$label: merged $ref into $branch"
    case "$pr_state" in
      OPEN|open|DRAFT|draft)
        if git -C "$wt" push 2>/dev/null; then
          log "  $coll_name/$label: pushed (open PR)"
        else
          warn "$coll_name/$label: merge ok but push failed — check upstream"
        fi
        ;;
    esac
  else
    git -C "$wt" merge --abort 2>/dev/null || true
    warn "$coll_name/$label: merge of $ref into $branch conflicted — aborted"
  fi
  pop_catch_up_stash "$wt" "$label" || true
}

catch_up_collection() { # <name>
  name="$1"
  coll="$(cd "$ROOT/$name" && pwd)"
  [ -d "$coll/harness" ] || { warn "skip $name (no harness/)"; return 0; }

  log "=== $name"
  HARNESS_DIR="$coll/harness"
  REGISTRY="$HARNESS_DIR/.harness-repos.yml"
  LOCAL_REPOS="$HARNESS_DIR/.harness-repos"

  fetch_owners_for_collection "$coll"

  harness_wt="$coll/harness"
  if [ -e "$harness_wt/.git" ]; then
    log "  harness self-update (before siblings)"
    catch_up_worktree "$name" "$harness_wt" "$(harness_repo)"
  fi

  for wt in "$coll"/*/; do
    wt="${wt%/}"
    [ -e "$wt/.git" ] || continue
    [ "$wt" = "$harness_wt" ] && continue
    repo="$(wt_repo_name "$wt" "$name")"
    catch_up_worktree "$name" "$wt" "$repo"
  done

  ensure_harness_skills "$harness_wt"

  coll_tools="$coll/harness/tools"
  if [ "$do_skills" = yes ]; then
    if [ "$dry_run" = yes ]; then
      log "  would run: link-skills.sh --collection $coll"
    else
      "$coll_tools/link-skills.sh" --collection "$coll" 2>/dev/null \
        || "$script_dir/link-skills.sh" --collection "$coll" \
        || warn "$name: link-skills failed"
    fi
  fi

  # Renders .mcp-servers.yml into .mcp.json / .cursor/mcp.json / .codex/config.toml.
  # Same ordering rule as skills: reads THIS collection's harness worktree, so
  # it must run after the harness self-update above moved that worktree.
  if [ "$do_mcp" = yes ]; then
    if [ "$dry_run" = yes ]; then
      log "  would run: link-mcp.sh --collection $coll"
    else
      "$coll_tools/link-mcp.sh" --collection "$coll" 2>/dev/null \
        || "$script_dir/link-mcp.sh" --collection "$coll" 2>/dev/null \
        || log "  mcp: refresh skipped (no link-mcp.sh in that harness yet)"
    fi
  fi

  # The generated collection env, for the same reason as the skills above: a
  # variable the generator learned since this collection was branched off
  # (a newly registered repo's port, GH_CONFIG_DIR) is otherwise only in new
  # collections. Uses the target collection's own tools, so a collection is
  # regenerated by the generator it actually carries.
  if [ "$do_env" = yes ]; then
    if [ "$dry_run" = yes ]; then
      log "  would run: refresh-env.sh --collection $coll"
    else
      "$coll_tools/refresh-env.sh" --collection "$coll" 2>/dev/null \
        || "$script_dir/refresh-env.sh" --collection "$coll" 2>/dev/null \
        || log "  env: refresh skipped (no refresh-env.sh in that harness yet)"
    fi
  fi

  # Control-root -> worktree symlinks (instructions/secrets.md). Init hooks
  # only ran at worktree creation, so a file added to the control root since
  # then has never reached this collection until catch-up re-links it.
  if [ "$do_secrets" = yes ]; then
    if [ "$dry_run" = yes ]; then
      log "  would run: link-secrets.sh --collection $coll"
    else
      HARNESS_DIR="$coll/harness"
      "$coll_tools/link-secrets.sh" --collection "$coll" 2>/dev/null \
        || "$script_dir/link-secrets.sh" --collection "$coll" 2>/dev/null \
        || log "  secrets: link skipped (no control root, or nothing to link)"
    fi
  fi
}

failed=0
for c in $collections; do
  catch_up_collection "$c" || failed=$((failed + 1))
done

log "done ($failed collection(s) reported errors)"
[ "$failed" -eq 0 ] || exit 1
