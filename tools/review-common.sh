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

# Local receipt for a status comment posted by review-post.sh. The ready gate
# requires this receipt as well as the forge comment, so another commenter
# cannot satisfy it with a copied status line. Hashing keeps forge identifiers
# out of path components and avoids traversal from a malformed slug.
review_trust_marker() { # <collection-dir> <forge> <slug> <pr> <head> <comment-id> <verdict>
  local coll="$1"; shift
  local key
  key="$(python3 - "$@" <<'PY'
import hashlib, sys
h = hashlib.sha256()
for field in sys.argv[1:]:
    h.update(field.encode())
    h.update(b'\0')
print(h.hexdigest())
PY
)" || return 1
  printf '%s/.wtc-review-posted/%s\n' "$coll" "$key"
}
