#!/usr/bin/env bash
# review-status.sh — is the PR's latest local review current?
#
# Prints:  current|stale|none|untrusted <verdict> <blockers> <round>
# (verdict may also be `pending` — a run is in flight — or `error` — it failed;
# both mean the gate is closed)
# (`none` alone when the PR has no review comment). Exit 0 unless the PR or the
# forge cannot be read (then 1) — the state is data, not an exit code.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage (run anywhere in the collection):
  tools/review-status.sh <repo> [<pr-number>] [--json] [--trusted-local]

Finds the newest PR comment carrying the `wtc-review v1 head=… verdict=…` line
and compares head= with the PR's current head commit:
  current   review covers the PR head
  stale     PR moved on since the review
  none      no review comment
  untrusted newest status comment lacks a matching local posting receipt
The verdict is pass | pass-with-notes | changes-requested, or pending (a run is
in flight; the newest status comment wins over older complete ones) or error.
<pr-number> defaults to the PR enlisted for the worktree's current branch.
--trusted-local also requires a local receipt from review-post.sh for the
specific status comment; the ready gate uses it to reject forged comments.
EOF
  exit "${1:-2}"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
harness_lib_init
# shellcheck source=review-common.sh
. "$script_dir/review-common.sh"
py="$script_dir/review_lib.py"

repo="" pr="" json=0 trusted=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --json) json=1 ;;
    --trusted-local) trusted=1 ;;
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

die() { echo "review-status: error: $*" >&2; exit 1; }
coll="$(this_collection)"
wt="$(wtc_repo_worktree "$coll" "$repo")"
[ -e "$wt/.git" ] || die "no worktree for $repo at $wt"
reg_repo="$repo"; [ "$repo" = harness ] && reg_repo="$(harness_repo)"
if [ -z "$pr" ]; then
  br="$(git -C "$wt" branch --show-current 2>/dev/null || true)"
  pr="$(wtc_pr_enlisted_for "$coll" "$reg_repo" "$br" | cut -f1)"
  [ -n "$pr" ] || pr="$(wtc_pr_enlisted_for "$coll" "$repo" "$br" | cut -f1)"
fi
[ -n "$pr" ] || die "no PR given and none enlisted for the current branch of $repo"

IFS=$'\t' read -r slug forge < <(repo_slug_and_forge "$reg_repo" "$wt") || true
tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-status.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
review_pr_json "$forge" "$slug" "$wt" "$pr" "$tmp/pr.json" || die "cannot read PR #$pr ($forge CLI unusable or offline)"
eval "$(python3 "$py" pr-info "$tmp/pr.json" "$tmp/pr.md")"
review_comments_json "$forge" "$slug" "$wt" "$pr" "$tmp/comments.json" || die "cannot read comments of PR #$pr"

state=none v="" b="" r="" h="" u="" cid=""
if line="$(python3 "$py" latest-status "$tmp/comments.json" 2>/dev/null)"; then
  read -r h v b r u cid <<<"$line"
  if review_same_sha "$h" "$PRI_HEAD"; then state=current; else state=stale; fi
fi
if [ "$trusted" -eq 1 ] && [ "$state" = current ]; then
  receipt="$(review_trust_marker "$(this_collection_dir)" "$forge" "$slug" "$pr" "$h" "$cid" "$v")" || die "could not check local review receipt"
  [ -f "$receipt" ] || state=untrusted
fi

if [ "$json" -eq 1 ]; then
  python3 - "$state" "$v" "$b" "$r" "$h" "$PRI_HEAD" "$u" "$pr" "$cid" <<'PY'
import json, sys
s, v, b, r, h, ph, u, pr, cid = sys.argv[1:10]
print(json.dumps({"state": s, "pr": int(pr), "verdict": v or None,
                  "blockers": int(b) if b else None, "round": int(r) if r else None,
                  "review_head": h or None, "pr_head": ph or None,
                  "comment_url": u if u not in ("", "-") else None,
                  "comment_id": cid if cid not in ("", "-") else None}))
PY
elif [ "$state" = none ]; then
  echo none
else
  echo "$state $v $b $r"
fi
