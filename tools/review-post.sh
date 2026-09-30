#!/usr/bin/env bash
# review-post.sh — post a bundle's review comment to its PR (create or update in place).
#
# One summary comment per bundle: the first post creates it and stores its id in
# <bundle>/comment.id; every later post updates that comment. A summary post also
# adds one inline comment per open finding that names a file and a new-file line
# (skipped when that finding was already commented, or prior is "addressed").
# Refuses when the bundle was built for a commit that is no longer the PR's head
# unless --force. Prints the summary comment URL (or "posted").
set -euo pipefail

# Delegate to the exact pinned CLI when available. The shell path remains for
# bootstrap, older pins, and explicitly requested Bitbucket CLI fallback.
native_review_post_supported() {
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
  if native_review_post_supported "$cli_pin"; then
    cli_cmd=()
    if command -v mise >/dev/null 2>&1; then
      cli_version="$(cd "$source_collection" && mise exec -- wtc --version 2>/dev/null)" || cli_version=""
      if [ "$cli_version" = "wtc version $cli_pin" ] &&
          (cd "$source_collection" && mise exec -- wtc review post --help >/dev/null 2>&1); then
        cli_cmd=(mise exec -- wtc)
      fi
    fi
    if [ "${#cli_cmd[@]}" -eq 0 ] && command -v wtc >/dev/null 2>&1; then
      cli_version="$(cd "$source_collection" && wtc --version 2>/dev/null)" || cli_version=""
      if [ "$cli_version" = "wtc version $cli_pin" ] &&
          (cd "$source_collection" && wtc review post --help >/dev/null 2>&1); then
        cli_cmd=(wtc)
      fi
    fi
    if [ "${#cli_cmd[@]}" -gt 0 ]; then
      caller_dir="$(pwd -P)"
      native_args=()
      bundle_seen=0
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --body)
            native_args+=("$1")
            shift
            if [ "$#" -gt 0 ]; then
              case "$1" in
                /*) native_args+=("$1") ;;
                *) native_args+=("$caller_dir/$1") ;;
              esac
              shift
            fi ;;
          --body=*)
            value="${1#--body=}"
            case "$value" in
              /*) native_args+=("$1") ;;
              *) native_args+=("--body=$caller_dir/$value") ;;
            esac
            shift ;;
          --reason)
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
      exec "${cli_cmd[@]}" review post "${native_args[@]}"
    fi
  fi
fi

usage() {
  cat <<'EOF' >&2
Usage:
  tools/review-post.sh <bundle-dir> [--force]                 post/update the final summary
  tools/review-post.sh <bundle-dir> --progress [--body FILE]  post/update the "in progress" comment
  tools/review-post.sh <bundle-dir> --failed [--reason TEXT]  turn the comment into "failed"

One summary comment per bundle: the first post creates it and stores its id in
<bundle>/comment.id; every later post updates that comment in place
(no comment.id -> create). The default body is <bundle>/summary.md, which ends
in the `wtc-review v1 …` status line written by review-run.sh.
A summary post also writes inline comments for open findings (file + line) and
records them in <bundle>/inline-comments.json. --progress and --failed do not.
GitHub via `gh pr comment` / `gh api -X PATCH`; Bitbucket via the REST API with
the bb credentials (fallback: bb pr comments add|edit; WTC_REVIEW_NO_API=1
forces the fallback).
--force posts even when the bundle HEAD_SHA is not the PR's current head
(--failed never checks: it only marks the run dead).
EOF
  exit "${1:-2}"
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="$(dirname "$script_dir")"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
harness_lib_init
load_wtc_config
# shellcheck source=review-common.sh
. "$script_dir/review-common.sh"
py="$script_dir/review_lib.py"

bundle="" force=0 mode=summary body="" reason=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --force) force=1 ;;
    --progress) mode=progress ;;
    --failed) mode=failed ;;
    --body)   [ $# -ge 2 ] || usage; body="$2"; shift ;;
    --reason) [ $# -ge 2 ] || usage; reason="$2"; shift ;;
    -*) echo "error: unknown flag $1" >&2; usage ;;
    *) [ -z "$bundle" ] || usage; bundle="$1" ;;
  esac
  shift
done
[ -n "$bundle" ] && [ -f "$bundle/manifest.env" ] || usage
bundle="$(cd "$bundle" && pwd)"
# shellcheck disable=SC1091
. "$bundle/manifest.env"

die() { echo "review-post: error: $*" >&2; exit 1; }
short() { printf '%s' "${1%"${1#???????}"}"; }
[ -n "$PR" ] || die "bundle is branch-only (no PR); nothing to post to"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/review-post.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

lead_spec="$HARNESS_REVIEW_LEAD"
[ ! -s "$bundle/lead.spec" ] || lead_spec="$(cat "$bundle/lead.spec")"
case "$mode" in
  summary)
    [ -s "$bundle/summary.md" ] || die "no summary.md in $bundle (run review-run.sh first)"
    status_line="$(python3 "$py" status-line "$bundle/summary.md")" || die "summary.md needs exactly one status line"
    read -r posted_head posted_verdict <<<"$status_line"
    review_same_sha "$posted_head" "$HEAD_SHA" || die "summary status head does not match the bundle"
    post_file="$bundle/summary.md"
    ;;
  progress)
    if [ -n "$body" ]; then
      [ -s "$body" ] || die "--body $body is empty or missing"
      [ "$body" -ef "$bundle/progress.md" ] || cp "$body" "$bundle/progress.md"
    else
      python3 "$py" progress-md "$bundle" "$HARNESS_REVIEW_STRONG" "$HARNESS_REVIEW_STANDARD" \
        "$HARNESS_REVIEW_FAST" "$lead_spec" >"$bundle/progress.md"
    fi
    post_file="$bundle/progress.md"
    ;;
  failed)
    python3 "$py" failure-md "$bundle" "$lead_spec" "$reason" >"$bundle/failed.md"
    post_file="$bundle/failed.md"
    force=1   # marking a dead run must work even when the PR has moved on
    ;;
esac

if review_pr_json "$FORGE" "$SLUG" "$REPO_DIR" "$PR" "$tmp/pr.json"; then
  eval "$(python3 "$py" pr-info "$tmp/pr.json" "$tmp/pr.md")"
  if ! review_same_sha "$HEAD_SHA" "$PRI_HEAD"; then
    if [ "$force" -eq 1 ]; then
      [ "$mode" = failed ] || echo "review-post: warn: bundle head $(short "$HEAD_SHA") != PR head $(short "$PRI_HEAD"); posting anyway (--force)" >&2
    else
      die "stale bundle: reviewed $(short "$HEAD_SHA"), PR #$PR head is $(short "$PRI_HEAD"). Push and re-run review-bundle/review-run, or pass --force."
    fi
  fi
else
  [ "$force" -eq 1 ] || die "cannot read PR #$PR from the forge to check it is current (offline? CLI missing?); --force to post anyway"
fi

idfile="$bundle/comment.id"
cid=""
[ ! -s "$idfile" ] || cid="$(tr -d '[:space:]' <"$idfile")"

# Each backend prints "<id><TAB><url>" (either may be empty); non-zero = failure.
gh_create() {
  local u
  u="$(cd "$REPO_DIR" && gh pr comment "$PR" --repo "$SLUG" -F "$post_file")" || return 1
  printf '%s\t%s\n' "$(printf '%s' "$u" | sed -n 's/.*issuecomment-\([0-9][0-9]*\).*/\1/p' | tail -n1)" "$u"
}
gh_update() { # <id>
  local u
  u="$(cd "$REPO_DIR" && gh api -X PATCH "repos/$SLUG/issues/comments/$1" -F "body=@$post_file" --jq .html_url)" || return 1
  printf '%s\t%s\n' "$1" "$u"
}
bb_create() {
  local out
  if [ -z "${WTC_REVIEW_NO_API:-}" ] && bb_api_credentials; then
    BB_API_USER="$BB_API_USER" BB_API_PASS="$BB_API_PASS" python3 "$py" bb-comment "$SLUG" "$PR" "$post_file"
    return
  fi
  # bb takes the message as an argument (no file/stdin form).
  if out="$(cd "$REPO_DIR" && bb pr comments add "$PR" "$(cat "$post_file")" --json 2>/dev/null)"; then
    printf '%s\t%s\n' "$(printf '%s' "$out" | python3 "$py" json-field id 2>/dev/null || true)" "${URL:-}"
  else
    (cd "$REPO_DIR" && bb pr comments add "$PR" "$(cat "$post_file")") >/dev/null || return 1
    echo "review-post: warn: could not learn the comment id; the next post will create a new comment" >&2
    printf '\t%s\n' "${URL:-}"
  fi
}
bb_update() { # <id>
  if [ -z "${WTC_REVIEW_NO_API:-}" ] && bb_api_credentials; then
    BB_API_USER="$BB_API_USER" BB_API_PASS="$BB_API_PASS" python3 "$py" bb-comment "$SLUG" "$PR" "$post_file" "$1"
    return
  fi
  (cd "$REPO_DIR" && bb pr comments edit "$PR" "$1" "$(cat "$post_file")") >/dev/null || return 1
  printf '%s\t%s\n' "$1" "${URL:-}"
}
gh_inline() { # <body-file> <path> <line>
  local out
  out="$(cd "$REPO_DIR" && gh api --method POST "repos/$SLUG/pulls/$PR/comments" \
    -f body="$(cat "$1")" -f commit_id="$HEAD_SHA" -f path="$2" -F line="$3" -f side=RIGHT)" || return 1
  printf '%s' "$out" | python3 "$py" json-pair id html_url
}
bb_inline() { # <body-file> <path> <line>
  local out
  if [ -z "${WTC_REVIEW_NO_API:-}" ] && bb_api_credentials; then
    BB_API_USER="$BB_API_USER" BB_API_PASS="$BB_API_PASS" python3 "$py" bb-inline "$SLUG" "$PR" "$1" "$2" "$3"
    return
  fi
  if out="$(cd "$REPO_DIR" && bb pr comments add "$PR" "$(cat "$1")" --file "$2" --line-to "$3" --json 2>/dev/null)"; then
    printf '%s\t%s\n' "$(printf '%s' "$out" | python3 "$py" json-field id 2>/dev/null || true)" "${URL:-}"
  else
    (cd "$REPO_DIR" && bb pr comments add "$PR" "$(cat "$1")" --file "$2" --line-to "$3") >/dev/null || return 1
    echo "review-post: warn: inline comment on $2:$3 posted, but its id is unknown" >&2
    printf '\t%s\n' "${URL:-}"
  fi
}
# After the summary comment exists: one inline thread per open file:line finding.
# A failure here does not undo the summary (the gate reads that comment).
post_inline() {
  local plan="$tmp/inline.plan" shell result new_id url line
  python3 "$py" inline-plan "$bundle" >"$plan" || {
    echo "review-post: warn: could not plan inline comments" >&2
    return 0
  }
  [ -s "$plan" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line" >"$tmp/one.json"
    if ! shell="$(python3 "$py" inline-shell <"$tmp/one.json")"; then
      echo "review-post: warn: skipping a bad inline plan entry" >&2
      continue
    fi
    # shellcheck disable=SC2086
    eval "$shell"
    if result="$("${fn}_inline" "$IL_BODY" "$IL_FILE" "$IL_LINE")"; then
      new_id="${result%%$'\t'*}"
      url="${result#*$'\t'}"
      if [ -n "$new_id" ]; then
        python3 "$py" inline-record "$bundle" "$tmp/one.json" "$new_id" "$url" "" || true
        echo "review-post: inline $IL_FILE:$IL_LINE -> ${url:-$new_id}" >&2
      else
        python3 "$py" inline-record "$bundle" "$tmp/one.json" "" "" "no comment id" || true
        echo "review-post: warn: inline comment on $IL_FILE:$IL_LINE has no id" >&2
      fi
    else
      python3 "$py" inline-record "$bundle" "$tmp/one.json" "" "" "post failed" || true
      echo "review-post: warn: inline comment on $IL_FILE:$IL_LINE failed" >&2
    fi
  done <"$plan"
}

case "$FORGE" in
  github) fn=gh ;;
  bitbucket) fn=bb ;;
  *) die "unknown forge '$FORGE'" ;;
esac
result=""
if [ -n "$cid" ]; then
  result="$("${fn}_update" "$cid")" || {
    echo "review-post: warn: updating comment $cid failed; posting a new comment" >&2
    result="" cid=""
  }
fi
if [ -z "$cid" ]; then
  result="$("${fn}_create")" || die "posting the comment failed"
fi
new_id="${result%%$'\t'*}"
url="${result#*$'\t'}"
[ -z "$new_id" ] || printf '%s\n' "$new_id" >"$idfile"
if [ "$mode" = summary ]; then
  if [ -n "$new_id" ]; then
    receipt="$(review_trust_marker "$(this_collection_dir)" "$FORGE" "$SLUG" "$PR" "$posted_head" "$new_id" "$posted_verdict")" || die "could not build local review receipt"
    mkdir -p "$(dirname "$receipt")"
    : >"$receipt"
  else
    echo "review-post: warn: no comment id; the ready gate cannot verify this post" >&2
  fi
  post_inline || echo "review-post: warn: inline comments were not all posted" >&2
fi
echo "${url:-posted}"
