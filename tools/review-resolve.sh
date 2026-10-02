#!/usr/bin/env bash
# review-resolve.sh — reply to and resolve inline review threads for one bundle.
#
# Reads <bundle>/inline-comments.json (written by review-post.sh). Resolves
# every unresolved thread that has an id, or only the ones selected by
# --file/--line, --concern or --key. Never touches the summary comment: the
# gate reads that. Prints one line per thread resolved.
set -euo pipefail

# Use the exact pinned native resolver when available. Retain the shell path
# for bootstrap, older pins, and explicit Bitbucket CLI fallback.
native_review_resolve_supported() {
  awk -v version="$1" 'BEGIN {
    if (version !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
    split(version, part, ".")
    exit !((part[1] + 0) > 0 || (part[2] + 0) > 1 ||
           ((part[2] + 0) == 1 && (part[3] + 0) >= 24))
  }'
}
source_harness="$(cd "$(dirname "$0")/.." && pwd)"
source_collection="$(dirname "$source_harness")"
if [ "${WTC_REVIEW_NO_API:-}" != 1 ] && [ -f "$source_harness/.wtc-cli-version" ]; then
  cli_pin="$(tr -d '[:space:]' < "$source_harness/.wtc-cli-version")"
  if native_review_resolve_supported "$cli_pin"; then
    cli_cmd=()
    if command -v mise >/dev/null 2>&1; then
      cli_version="$(cd "$source_collection" && mise exec -- wtc --version 2>/dev/null)" || cli_version=""
      if [ "$cli_version" = "wtc version $cli_pin" ] &&
          (cd "$source_collection" && mise exec -- wtc review resolve --help >/dev/null 2>&1); then
        cli_cmd=(mise exec -- wtc)
      fi
    fi
    if [ "${#cli_cmd[@]}" -eq 0 ] && command -v wtc >/dev/null 2>&1; then
      cli_version="$(cd "$source_collection" && wtc --version 2>/dev/null)" || cli_version=""
      if [ "$cli_version" = "wtc version $cli_pin" ] &&
          (cd "$source_collection" && wtc review resolve --help >/dev/null 2>&1); then
        cli_cmd=(wtc)
      fi
    fi
    if [ "${#cli_cmd[@]}" -gt 0 ]; then
      caller_dir="$(pwd -P)"
      native_args=()
      bundle_seen=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --reply|--file|--line|--concern|--key)
            native_args+=("$1")
            shift
            if [ "$#" -gt 0 ]; then native_args+=("$1"); shift; fi ;;
          -*|*)
            if [ "$bundle_seen" -eq 0 ] && [[ "$1" != -* ]]; then
              bundle_seen=1
              case "$1" in
                /*) native_args+=("$1") ;;
                *) native_args+=("$caller_dir/$1") ;;
              esac
            else
              native_args+=("$1")
            fi
            shift ;;
        esac
      done
      cd "$source_collection"
      exec "${cli_cmd[@]}" review resolve "${native_args[@]}"
    fi
  fi
fi

usage() {
  cat <<'EOF' >&2
Usage: tools/review-resolve.sh <bundle-dir> [--reply TEXT]
       [--file PATH] [--line N] [--concern ID] [--key KEY]

Resolve inline review threads posted for this bundle. With no filter, every
unresolved thread that has a comment id. --reply is posted on each thread
first (the next round reads it from prior/comments.md). The summary comment
in comment.id is left alone.

Bitbucket: bb pr comments reply / resolve (or the REST API).
GitHub: a pull-comment reply, then resolveReviewThread.
EOF
  exit "${1:-2}"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
harness_lib_init
load_wtc_config
py="$script_dir/review_lib.py"

bundle="" reply="" file="" line="" concern="" key=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --reply)   [ $# -ge 2 ] || usage; reply="$2"; shift ;;
    --file)    [ $# -ge 2 ] || usage; file="$2"; shift ;;
    --line)    [ $# -ge 2 ] || usage; line="$2"; shift ;;
    --concern) [ $# -ge 2 ] || usage; concern="$2"; shift ;;
    --key)     [ $# -ge 2 ] || usage; key="$2"; shift ;;
    -*) echo "error: unknown flag $1" >&2; usage ;;
    *) [ -z "$bundle" ] || usage; bundle="$1" ;;
  esac
  shift
done
[ -n "$bundle" ] && [ -f "$bundle/manifest.env" ] || usage
bundle="$(cd "$bundle" && pwd)"
# shellcheck disable=SC1091
. "$bundle/manifest.env"

die() { echo "review-resolve: error: $*" >&2; exit 1; }
[ -n "$PR" ] || die "bundle is branch-only (no PR)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-resolve.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
[ -z "$reply" ] || printf '%s\n' "$reply" >"$tmp/reply.md"

gh_reply() { # <comment-id>
  (cd "$REPO_DIR" && gh api --method POST "repos/$SLUG/pulls/$PR/comments" \
    -f body="$(cat "$tmp/reply.md")" -F in_reply_to="$1") >/dev/null
}
gh_resolve() { # <comment-id>
  local owner repo q out tid cursor next
  owner="${SLUG%%/*}"; repo="${SLUG#*/}"
  q='query($o:String!,$n:String!,$num:Int!,$cursor:String){repository(owner:$o,name:$n){pullRequest(number:$num){reviewThreads(first:100,after:$cursor){nodes{id isResolved comments(first:50){nodes{databaseId}}} pageInfo{hasNextPage endCursor}}}}}'
  cursor=""
  while :; do
    if [ -n "$cursor" ]; then
      out="$(gh api graphql -f query="$q" -f o="$owner" -f n="$repo" -F num="$PR" -f cursor="$cursor")" || return 1
    else
      out="$(gh api graphql -f query="$q" -f o="$owner" -f n="$repo" -F num="$PR")" || return 1
    fi
    tid="$(printf '%s' "$out" | python3 "$py" gh-thread-id "$1")" || tid=""
    [ -z "$tid" ] || break
    next="$(printf '%s' "$out" | python3 -c 'import json,sys; p=((((json.load(sys.stdin).get("data") or {}).get("repository") or {}).get("pullRequest") or {}).get("reviewThreads") or {}).get("pageInfo") or {}; print(p.get("endCursor") or "" if p.get("hasNextPage") else "")')" || return 1
    [ -n "$next" ] && [ "$next" != "$cursor" ] || return 1
    cursor="$next"
  done
  [ "$tid" != already ] || return 0
  [ -n "$tid" ] || return 1
  q='mutation($id:ID!){resolveReviewThread(input:{threadId:$id}){thread{isResolved}}}'
  gh api graphql -f query="$q" -f id="$tid" >/dev/null
}
bb_reply() { # <comment-id>
  if [ -z "${WTC_REVIEW_NO_API:-}" ] && bb_api_credentials; then
    BB_API_USER="$BB_API_USER" BB_API_PASS="$BB_API_PASS" \
      python3 "$py" bb-reply "$SLUG" "$PR" "$1" "$tmp/reply.md" >/dev/null
    return
  fi
  (cd "$REPO_DIR" && bb pr comments reply "$PR" "$1" "$reply") >/dev/null
}
bb_resolve() { # <comment-id>
  if [ -z "${WTC_REVIEW_NO_API:-}" ] && bb_api_credentials; then
    BB_API_USER="$BB_API_USER" BB_API_PASS="$BB_API_PASS" \
      python3 "$py" bb-resolve "$SLUG" "$PR" "$1" >/dev/null
    return
  fi
  (cd "$REPO_DIR" && bb pr comments resolve "$PR" "$1") >/dev/null
}

case "$FORGE" in
  github) fn=gh ;;
  bitbucket) fn=bb ;;
  *) die "unknown forge '$FORGE'" ;;
esac

python3 "$py" inline-open "$bundle" "$concern" "$file" "$line" "$key" >"$tmp/open.jsonl" || die "could not read inline comments"
if [ ! -s "$tmp/open.jsonl" ]; then
  if [ -n "$file$line$concern$key" ]; then
    die "no open inline comment matches"
  fi
  echo "review-resolve: nothing to resolve"
  exit 0
fi

n=0
while IFS= read -r row || [ -n "$row" ]; do
  [ -n "$row" ] || continue
  printf '%s\n' "$row" >"$tmp/one.json"
  if ! shell="$(python3 "$py" inline-shell <"$tmp/one.json")"; then
    die "bad inline-comments row"
  fi
  # shellcheck disable=SC2086
  eval "$shell"
  [ -n "$IL_ID" ] || die "inline comment $IL_FILE:$IL_LINE has no id"
  if [ -n "$reply" ]; then
    "${fn}_reply" "$IL_ID" || die "reply on $IL_FILE:$IL_LINE ($IL_ID) failed"
  fi
  "${fn}_resolve" "$IL_ID" || die "resolve $IL_FILE:$IL_LINE ($IL_ID) failed"
  python3 "$py" inline-resolved "$bundle" "$IL_KEY" || die "could not record $IL_KEY resolved"
  echo "resolved $IL_FILE:$IL_LINE ($IL_ID)"
  n=$((n + 1))
done <"$tmp/open.jsonl"
echo "review-resolve: $n thread(s)"
