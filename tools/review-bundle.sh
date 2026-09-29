#!/usr/bin/env bash
# review-bundle.sh — build a review bundle for one repo (+ optional PR).
#
# The bundle is a directory a headless reviewer can read without any other
# context: diff, PR text, the concerns that apply, prior rounds, related PRs
# and downstream snapshots. Layout and contract: review/README.md.
# Prints the bundle directory as the LAST line of stdout.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  tools/review-bundle.sh <repo> [<pr-number>] [--base REF] [--head REF]
                         [--dir DIR] [--round K] [--no-catch-up]

  <repo>       sibling worktree name in this collection (e.g. app, harness)
  <pr-number>  default: the PR enlisted in .wtc-prs for the worktree's branch;
               none found → branch-only review (no PR text, no comments)
  --base REF   default: PR destination (origin/<dest>) when a PR is known and
               its forge CLI works, else the registry default_ref. BASE_SHA is
               the merge-base of BASE and HEAD.
  --head REF   default: HEAD of the worktree. Warns when it differs from the
               PR's remote head (unpushed commits are not reviewed on the forge).
  --no-catch-up  do not run tools/catch-up.sh. Checkout of the PR branch still
               happens when a PR number is known and --head is HEAD.

When a PR is known and --head is HEAD, the PR's branch is checked out first
(if this worktree is on another branch), then tools/catch-up.sh runs so the
review sees current tips. Downstream snapshots are whatever catch-up left in
the local owners. A missing ref is a warning, not an error.
  --dir DIR    bundle location (default <collection>/.wtc-reviews/<name>/);
               must not exist or be empty — bundles are never overwritten
  --round K    default: 1 + highest round of earlier bundles for this repo+PR

Concern layers (later wins by id): review/concerns → review/concerns.d →
<repo>/.review/concerns. `needs: downstream` concerns are KEPT in the bundle;
review-run.sh records them as skipped when the bundle has neither downstream/
nor upstream/ (upstream = repos whose `downstream:` names the reviewed repo).
Glob semantics for `applies:` — `*` within a path segment, `**` across
segments, a pattern without `/` also matches the basename anywhere.
EOF
  exit "${1:-2}"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
harness_lib_init
py="$script_dir/review_lib.py"

repo="" pr="" base_arg="" head_arg="HEAD" dir="" round="" catch_up=1
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --base)  [ $# -ge 2 ] || usage; base_arg="$2"; shift ;;
    --head)  [ $# -ge 2 ] || usage; head_arg="$2"; shift ;;
    --dir)   [ $# -ge 2 ] || usage; dir="$2"; shift ;;
    --round) [ $# -ge 2 ] || usage; round="$2"; shift ;;
    --no-catch-up) catch_up=0 ;;
    -*) echo "error: unknown flag $1" >&2; usage ;;
    *)
      if [ -z "$repo" ]; then repo="$1"
      elif [ -z "$pr" ] && printf '%s' "$1" | grep -Eq '^[0-9]+$'; then pr="$1"
      else usage; fi
      ;;
  esac
  shift
done
[ -n "$repo" ] || usage

warn() { echo "review-bundle: warn: $*" >&2; }
die()  { echo "review-bundle: error: $*" >&2; exit 1; }
short() { printf '%s' "${1%"${1#???????}"}"; }

coll="$(this_collection)"
coll_dir="$(this_collection_dir)"
wt="$(wtc_repo_worktree "$coll" "$repo")"
[ -e "$wt/.git" ] || die "no worktree for $repo at $wt"
reg_repo="$repo"
[ "$repo" = harness ] && reg_repo="$(harness_repo)"

head_branch="$(git -C "$wt" branch --show-current 2>/dev/null || true)"

# --- PR + forge ---------------------------------------------------------------
if [ -z "$pr" ] && [ -n "$head_branch" ]; then
  pr="$(wtc_pr_enlisted_for "$coll" "$reg_repo" "$head_branch" | cut -f1)"
  [ -n "$pr" ] || pr="$(wtc_pr_enlisted_for "$coll" "$repo" "$head_branch" | cut -f1)"
fi
IFS=$'\t' read -r slug forge < <(repo_slug_and_forge "$reg_repo" "$wt") || true
forge="${forge:-unknown}"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-bundle.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

pr_json="$tmp/pr.json"
PRI_TITLE="" PRI_DEST="" PRI_HEAD="" PRI_HEAD_BRANCH="" PRI_URL="" PRI_STATE="" PRI_DRAFT=""
if [ -n "$pr" ]; then
  : >"$pr_json"
  if forge_cli_usable "$forge"; then
    case "$forge" in
      bitbucket) (cd "$wt" && bb pr view "$pr" --json) >"$pr_json" 2>/dev/null || : >"$pr_json" ;;
      github)    gh pr view "$pr" --repo "$slug" \
                   --json title,body,baseRefName,headRefOid,headRefName,url,state,isDraft \
                   >"$pr_json" 2>/dev/null || : >"$pr_json" ;;
    esac
  else
    warn "forge CLI for '$forge' not usable; PR text/base not read from the forge"
  fi
  info="$(python3 "$py" pr-info "$pr_json" "$tmp/pr.md" 2>/dev/null || true)"
  if [ -n "$info" ]; then
    eval "$info"
  else
    warn "could not read PR #$pr from the forge (offline?)"
  fi
fi
pr_url="$PRI_URL"
[ -n "$pr_url" ] || pr_url="$(pr_url_for "$slug" "$forge" "$pr" 2>/dev/null || true)"

# --- checkout the PR branch, then catch up, before the diff is taken ---------
checkout_pr_branch() {
  [ -n "${PRI_HEAD_BRANCH:-}" ] || return 0
  local cur
  cur="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
  [ "$cur" = "$PRI_HEAD_BRANCH" ] && return 0
  echo "review-bundle: checking out $PRI_HEAD_BRANCH for PR #$pr" >&2
  git -C "$wt" fetch origin "$PRI_HEAD_BRANCH" >/dev/null 2>&1 ||
    warn "could not fetch origin/$PRI_HEAD_BRANCH"
  if git -C "$wt" show-ref --verify --quiet "refs/heads/$PRI_HEAD_BRANCH"; then
    git -C "$wt" switch --merge "$PRI_HEAD_BRANCH" || die "could not check out $PRI_HEAD_BRANCH"
  elif git -C "$wt" show-ref --verify --quiet "refs/remotes/origin/$PRI_HEAD_BRANCH"; then
    git -C "$wt" switch --merge -c "$PRI_HEAD_BRANCH" --track "origin/$PRI_HEAD_BRANCH" ||
      die "could not check out $PRI_HEAD_BRANCH"
  else
    die "PR #$pr branch $PRI_HEAD_BRANCH is not in $wt"
  fi
}
if [ -n "$pr" ] && [ "$head_arg" = HEAD ]; then
  checkout_pr_branch
  if [ "$catch_up" -eq 1 ]; then
    echo "review-bundle: catch-up before review" >&2
    "$script_dir/catch-up.sh" || die "catch-up failed; review not started"
    if [ -n "${PRI_HEAD_BRANCH:-}" ]; then
      cur="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
      [ "$cur" = "$PRI_HEAD_BRANCH" ] ||
        die "after catch-up, $repo is on '${cur:-detached}', not PR branch $PRI_HEAD_BRANCH"
    fi
  fi
fi
head_sha="$(git -C "$wt" rev-parse --verify "$head_arg^{commit}" 2>/dev/null)" ||
  die "cannot resolve head ref '$head_arg' in $wt"
if [ "$head_arg" = HEAD ]; then
  head_branch="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
else
  head_branch="$head_arg"
fi

# --- base ---------------------------------------------------------------------
base_ref="$base_arg"
if [ -z "$base_ref" ] && [ -n "$PRI_DEST" ] &&
   git -C "$wt" rev-parse --verify --quiet "origin/$PRI_DEST^{commit}" >/dev/null; then
  base_ref="origin/$PRI_DEST"
fi
[ -n "$base_ref" ] || base_ref="$(default_ref_for "$reg_repo")"
git -C "$wt" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null ||
  die "base ref '$base_ref' not found in $wt (run tools/catch-up.sh or pass --base)"
base_sha="$(git -C "$wt" merge-base "$base_ref" "$head_sha")" ||
  die "no merge-base between $base_ref and $(short "$head_sha")"

if [ -n "$PRI_HEAD" ]; then
  case "$head_sha" in
    "$PRI_HEAD"*) : ;;
    *) case "$PRI_HEAD" in
         "$head_sha"*) : ;;
         *) warn "local head $(short "$head_sha") != PR #$pr remote head $(short "$PRI_HEAD"): unpushed or stale — push before posting" ;;
       esac ;;
  esac
fi

# --- location + round ---------------------------------------------------------
rev_root="$coll_dir/.wtc-reviews"
scan_dirs=("$rev_root")
[ -z "$dir" ] || scan_dirs+=("$(dirname "$dir")")

# matching earlier bundles: "<round>\t<dir>", oldest first
matches="$tmp/matches"; : >"$matches"
for sd in "${scan_dirs[@]}"; do
  [ -d "$sd" ] || continue
  for d in "$sd"/*/; do
    [ -f "${d}manifest.env" ] || continue
    m="$(REPO='' PR='' HEAD_BRANCH='' ROUND=0
         # shellcheck disable=SC1090,SC1091
         . "${d}manifest.env" >/dev/null 2>&1 || true
         printf '%s|%s|%s|%s' "$REPO" "$PR" "$HEAD_BRANCH" "$ROUND")"
    IFS='|' read -r m_repo m_pr m_br m_round <<<"$m"
    [ "$m_repo" = "$repo" ] || continue
    if [ -n "$pr" ]; then
      [ "$m_pr" = "$pr" ] || continue
    else
      [ -z "$m_pr" ] && [ "$m_br" = "$head_branch" ] || continue
    fi
    printf '%s\t%s\n' "$m_round" "${d%/}" >>"$matches"
  done
done
sort -n "$matches" -o "$matches"
if [ -z "$round" ]; then
  max="$(tail -n1 "$matches" | cut -f1)"
  round=$(( ${max:-0} + 1 ))
fi
printf '%s' "$round" | grep -Eq '^[0-9]+$' || die "--round must be a number"

if [ -z "$dir" ]; then
  if [ -n "$pr" ]; then name="$repo-pr$pr-$(short "$head_sha")-r$round"
  else name="$repo-br-$(short "$head_sha")-r$round"; fi
  dir="$rev_root/$name"
fi
if [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
  die "$dir already exists; bundles are never overwritten (use another --round or --dir)"
fi
mkdir -p "$dir"
dir="$(cd "$dir" && pwd)"

# --- core files ---------------------------------------------------------------
if [ -s "$tmp/pr.md" ]; then
  cp "$tmp/pr.md" "$dir/pr.md"
else
  printf '# %s\n\n(no PR text: %s)\n' "${head_branch:-$(short "$head_sha")}" \
    "$([ -n "$pr" ] && echo "PR #$pr not readable" || echo "branch-only review")" >"$dir/pr.md"
fi
git -C "$wt" diff --no-color "$base_sha" "$head_sha" >"$dir/diff.patch"
git -C "$wt" diff --name-only "$base_sha" "$head_sha" >"$dir/changed-files.txt"
git -C "$wt" log --oneline "$base_sha..$head_sha" >"$dir/log.txt"

# --- downstream / upstream snapshots -------------------------------------------
# downstream: repos that consume the reviewed one (registry `downstream:` on it).
# upstream:   repos whose `downstream:` lists the reviewed one (it consumes them).
snapshot_repo() { # <repo> <downstream|upstream> — echoes the name when snapshotted
  local ds="$1" kind="$2" ds_wt owner prod_ref old_sha ddir ds_head ds_tip
  ds_wt="$(wtc_repo_worktree "$coll" "$ds")"
  owner=""
  if [ -e "$ds_wt/.git" ]; then owner="$(owner_of "$ds_wt")"
  else owner="$(owner_path_for "$ds" 2>/dev/null || true)"; fi
  if [ -z "$owner" ] || [ ! -d "$owner" ]; then
    warn "$kind $ds: no git owner found; skipped (tools/add-repo.sh $ds, then catch-up.sh)"
    return 0
  fi
  prod_ref="$(production_ref_for "$ds")"
  old_sha="$(git --git-dir="$owner" rev-parse --verify --quiet "$prod_ref^{commit}" || true)"
  if [ -z "$old_sha" ]; then
    warn "$kind $ds: ref $prod_ref missing in $owner; skipped (run tools/catch-up.sh first)"
    return 0
  fi
  ddir="$dir/$kind/$ds"
  mkdir -p "$ddir/old"
  git --git-dir="$owner" archive "$old_sha" | tar -x -C "$ddir/old"
  printf 'old=%s %s\n' "$prod_ref" "$old_sha" >"$ddir/REFS"
  if [ -e "$ds_wt/.git" ]; then
    ds_head="$(git -C "$ds_wt" rev-parse --verify HEAD 2>/dev/null || true)"
    ds_tip="$(default_ref_for "$ds")"
    if [ -n "$ds_head" ] && ! git -C "$ds_wt" merge-base --is-ancestor "$ds_head" "$ds_tip" 2>/dev/null; then
      mkdir -p "$ddir/new"
      git -C "$ds_wt" archive "$ds_head" | tar -x -C "$ddir/new"
      printf 'new=%s %s\n' "$(git -C "$ds_wt" branch --show-current 2>/dev/null || echo HEAD)" "$ds_head" >>"$ddir/REFS"
    fi
  fi
  printf '%s ' "$ds"
}

downstream_list="$(awk -v repo="$reg_repo" '
  $1 == "-" && $2 == "name:" { cur = $3 }
  cur == repo && $1 == "downstream:" {
    for (i = 2; i <= NF; i++) { if ($i ~ /^#/) break; print $i }
    exit
  }
' "$REGISTRY" | tr '\n' ' ')"
upstream_list="$(awk -v repo="$reg_repo" '
  $1 == "-" && $2 == "name:" { cur = $3 }
  $1 == "downstream:" {
    for (i = 2; i <= NF; i++) { if ($i ~ /^#/) break; if ($i == repo) { print cur; break } }
  }
' "$REGISTRY" | tr '\n' ' ')"
downstream_done="" upstream_done=""
for ds in $downstream_list; do downstream_done="$downstream_done$(snapshot_repo "$ds" downstream)"; done
for us in $upstream_list; do upstream_done="$upstream_done$(snapshot_repo "$us" upstream)"; done

# --- concerns -----------------------------------------------------------------
mkdir -p "$dir/concerns"
n_concerns="$(python3 "$py" concerns "$dir/concerns" "$dir/changed-files.txt" \
  "$HARNESS_DIR/review/concerns" "$HARNESS_DIR/review/concerns.d" "$wt/.review/concerns" |
  wc -l | tr -d ' ')"

# --- prior rounds + comments --------------------------------------------------
mkdir -p "$dir/prior"
while IFS=$'\t' read -r r_round r_dir; do
  [ -n "$r_dir" ] || continue
  if [ -f "$r_dir/summary.md" ]; then cp "$r_dir/summary.md" "$dir/prior/r$r_round.md"; fi
done <"$matches"
if [ -n "$pr" ] && forge_cli_usable "$forge"; then
  : >"$tmp/comments.json"
  case "$forge" in
    bitbucket) (cd "$wt" && bb pr comments list "$pr" --all --json) >"$tmp/comments.json" 2>/dev/null || : >"$tmp/comments.json" ;;
    github)    gh pr view "$pr" --repo "$slug" --json comments >"$tmp/comments.json" 2>/dev/null || : >"$tmp/comments.json" ;;
  esac
  if [ -s "$tmp/comments.json" ]; then
    python3 "$py" comments "$tmp/comments.json" --after-review >"$dir/prior/comments.md" 2>/dev/null || :
    [ -s "$dir/prior/comments.md" ] || rm -f "$dir/prior/comments.md"
  fi
fi

# --- related PRs (other enlisted PRs whose worktree is on that PR's branch) ----
mkdir -p "$dir/related"
rel=0
while IFS=$'\t' read -r r_repo r_num r_branch _u _t; do
  [ -n "$r_repo" ] && [ -n "$r_branch" ] || continue
  if [ "$r_repo" = "$repo" ] && [ "$r_num" = "$pr" ]; then continue; fi
  r_reg="$r_repo"; [ "$r_repo" = harness ] && r_reg="$(harness_repo)"
  r_wt="$(wtc_repo_worktree "$coll" "$r_repo")"
  [ -e "$r_wt/.git" ] || continue
  [ "$(git -C "$r_wt" branch --show-current 2>/dev/null || true)" = "$r_branch" ] || continue
  r_base="$(default_ref_for "$r_reg")"
  r_mb="$(git -C "$r_wt" merge-base "$r_base" HEAD 2>/dev/null)" || continue
  r_out="$dir/related/$r_repo-pr$r_num.patch"
  git -C "$r_wt" diff --no-color "$r_mb" HEAD | head -c 400000 >"$r_out" || true
  if [ -s "$r_out" ]; then rel=$((rel + 1)); else rm -f "$r_out"; fi
  [ "$rel" -lt 20 ] || break
done < <(wtc_pr_enlist_rows "$coll")

# --- manifest -----------------------------------------------------------------
q() { printf '%q' "$1"; }
{
  echo "# review bundle manifest (sourceable)"
  echo "REPO=$(q "$repo")"
  echo "PR=$(q "$pr")"
  echo "FORGE=$(q "$forge")"
  echo "SLUG=$(q "$slug")"
  echo "URL=$(q "$pr_url")"
  echo "BASE_REF=$(q "$base_ref")"
  echo "BASE_SHA=$(q "$base_sha")"
  echo "HEAD_SHA=$(q "$head_sha")"
  echo "HEAD_BRANCH=$(q "$head_branch")"
  echo "ROUND=$(q "$round")"
  echo "REPO_DIR=$(q "$wt")"
  echo "COLLECTION=$(q "$coll")"
  echo "DOWNSTREAM=$(q "${downstream_done% }")"
  echo "UPSTREAM=$(q "${upstream_done% }")"
} >"$dir/manifest.env"

rmdir "$dir/prior" "$dir/related" 2>/dev/null || true
{
  echo "review-bundle: repo=$repo pr=${pr:-none} forge=$forge round=$round"
  echo "review-bundle: $base_ref@$(short "$base_sha")..$(short "$head_sha") files=$(wc -l <"$dir/changed-files.txt" | tr -d ' ')"
  echo "review-bundle: concerns=$n_concerns related=$rel downstream=${downstream_done:-none} upstream=${upstream_done:-none}"
} >&2
echo "$dir"
