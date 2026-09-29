# review-common.sh — forge reads shared by review-post.sh / review-status.sh.
# Source after lib.sh. Not executable on its own.

# Write the PR JSON (bb: API shape; gh: title,headRefOid,…) to <out>. 0 = usable.
review_pr_json() { # <forge> <slug> <worktree> <pr> <out>
  : >"$5"
  forge_cli_usable "$1" || return 1
  case "$1" in
    bitbucket) (cd "$3" && bb pr view "$4" --json) >"$5" 2>/dev/null ;;
    github)    gh pr view "$4" --repo "$2" \
                 --json title,body,baseRefName,headRefOid,headRefName,url,state,isDraft >"$5" 2>/dev/null ;;
    *) return 1 ;;
  esac
  [ -s "$5" ]
}

# Write all PR comments as JSON to <out>. 0 = usable.
review_comments_json() { # <forge> <slug> <worktree> <pr> <out>
  : >"$5"
  forge_cli_usable "$1" || return 1
  case "$1" in
    bitbucket) (cd "$3" && bb pr comments list "$4" --all --json) >"$5" 2>/dev/null ;;
    github)    gh pr view "$4" --repo "$2" --json comments >"$5" 2>/dev/null ;;
    *) return 1 ;;
  esac
  [ -s "$5" ]
}

# 0 when <local> (a full commit id: bundle HEAD_SHA or status-line head=) and
# <remote> (the forge's PR head; bb reports 12-char prefixes) name the same
# commit. Only the direction "remote is a prefix of local" counts, and both
# must be at least 12 hex chars: a short or reversed prefix never matches.
review_same_sha() { # <local> <remote>
  [ "${#1}" -ge 12 ] && [ "${#2}" -ge 12 ] || return 1
  case "$1" in "$2"*) return 0 ;; esac
  return 1
}
