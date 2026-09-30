#!/usr/bin/env bash
# Review posting and resolving use the released CLI behind matching-pin shims.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$(dirname "$TESTS_DIR")"
. "$TESTS_DIR/helpers.sh"

root="$(make_workspace)"
add_fixture_worktree "$root" widget "$root/main/widget"
mock="$root/mock-bin"
mkdir -p "$mock"
export REVIEW_WRITE_CLI_CALLS="$root/calls"
cat > "$mock/mise" <<'MOCK'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
case "$*" in
  --version) printf 'wtc version %s\n' "${REVIEW_WRITE_CLI_VERSION:-$(cat "$PWD/harness/.wtc-cli-version")}" ;;
  'review post --help'|'review resolve --help') exit 0 ;;
  *) printf '%s|%s\n' "$PWD" "$*" >> "$REVIEW_WRITE_CLI_CALLS"; printf 'ok\n' ;;
esac
MOCK
chmod +x "$mock/mise"
export PATH="$mock:$PATH"
poster="$root/main/harness/tools/review-post.sh"
resolver="$root/main/harness/tools/review-resolve.sh"

it 'matching pin forwards posting paths and resolve filters'
(cd "$root" && "$poster" --progress --body progress.md review >/dev/null)
assert_contains "$(cat "$REVIEW_WRITE_CLI_CALLS")" \
  "$root/main|review post --progress --body $root/progress.md $root/review" \
  'progress body and bundle remain caller-relative'
(cd "$root" && "$resolver" --reply 'Fixed in the patch.' --file feature.go review >/dev/null)
assert_contains "$(cat "$REVIEW_WRITE_CLI_CALLS")" \
  "$root/main|review resolve --reply Fixed in the patch. --file feature.go $root/review" \
  'reply and file filter are not treated as paths'

it 'older and mismatched pins keep shell posting and resolution'
: > "$REVIEW_WRITE_CLI_CALLS"
printf '0.1.23\n' > "$root/main/harness/.wtc-cli-version"
assert_contains "$("$poster" --help 2>&1)" 'Usage:' 'older pin uses shell post help'
assert_contains "$("$resolver" --help 2>&1)" 'Usage:' 'older pin uses shell resolve help'
assert_empty "$(cat "$REVIEW_WRITE_CLI_CALLS")" 'older pin did not dispatch'
printf '0.1.24\n' > "$root/main/harness/.wtc-cli-version"
assert_contains "$(REVIEW_WRITE_CLI_VERSION=0.1.23 "$poster" --help 2>&1)" 'Usage:' \
  'mismatched pin uses shell post help'
assert_contains "$(REVIEW_WRITE_CLI_VERSION=0.1.23 "$resolver" --help 2>&1)" 'Usage:' \
  'mismatched pin uses shell resolve help'
assert_empty "$(cat "$REVIEW_WRITE_CLI_CALLS")" 'mismatched CLI did not dispatch'
assert_contains "$(WTC_REVIEW_NO_API=1 "$poster" --help 2>&1)" 'Usage:' \
  'explicit API fallback keeps shell post'
assert_contains "$(WTC_REVIEW_NO_API=1 "$resolver" --help 2>&1)" 'Usage:' \
  'explicit API fallback keeps shell resolve'
assert_empty "$(cat "$REVIEW_WRITE_CLI_CALLS")" 'explicit API fallback did not dispatch'

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'the published binary posts and resolves synthetic GitHub review findings'
  assert_eq 'wtc version 0.1.24' "$("$WTC_TEST_RELEASE_BINARY" --version)"
  export REVIEW_TEST_RELEASE_BINARY="$WTC_TEST_RELEASE_BINARY"
  cat > "$mock/mise" <<'REAL_MISE'
#!/usr/bin/env bash
[ "$1 $2 $3" = 'exec -- wtc' ] || exit 2
shift 3
exec "$REVIEW_TEST_RELEASE_BINARY" "$@"
REAL_MISE
  chmod +x "$mock/mise"
  export REVIEW_FAKE_GH_LOG="$root/gh-calls"
  cat > "$mock/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REVIEW_FAKE_GH_LOG"
case "$*" in
  *'--json headRefOid'*) printf '{"headRefOid":"1234567890abcdef1234567890abcdef12345678"}\n' ;;
  *'api graphql'*'resolveReviewThread'*) printf '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}\n' ;;
  *'api graphql'*'reviewThreads'*) printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"id":"THREAD_1","isResolved":false,"comments":{"nodes":[{"databaseId":401}]}}]}}}}}\n' ;;
  *'pulls/7/comments?per_page=100'*) printf '[[]]\n' ;;
  *'repos/example/widget/pulls/7/comments'*) cat >/dev/null; printf '{"id":401,"html_url":"https://github.com/example/widget/pull/7#discussion_r401"}\n' ;;
  *'repos/example/widget/issues/7/comments'*) cat >/dev/null; printf '{"id":301,"html_url":"https://github.com/example/widget/pull/7#issuecomment-301"}\n' ;;
  *'repos/example/widget/issues/comments/301'*) cat >/dev/null; printf '{"id":301,"html_url":"https://github.com/example/widget/pull/7#issuecomment-301"}\n' ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 2 ;;
esac
GH
  chmod +x "$mock/gh"
  bundle="$root/review"
  mkdir -p "$bundle/findings"
  python3 - "$bundle" "$root/main/widget" <<'PY'
import json, pathlib, sys
bundle, repo = pathlib.Path(sys.argv[1]), sys.argv[2]
head = "1234567890abcdef1234567890abcdef12345678"
(bundle / "manifest.json").write_text(json.dumps({"repo":"widget","pr":"7","forge":"github","slug":"example/widget","url":"https://github.com/example/widget/pull/7","head_sha":head,"round":1,"repo_dir":repo,"collection":"main","public":True}) + "\n")
(bundle / "summary.md").write_text("**Local review: pass**\n\n`wtc-review v1 head=" + head + " verdict=pass blockers=0 round=1 lead=test:`\n")
(bundle / "findings" / "code.json").write_text(json.dumps({"concern":"code","status":"issues","findings":[{"severity":"minor","file":"feature.go","line":4,"title":"Synthetic edge","detail":"Synthetic finding."}]}) + "\n")
PY
  printf '**Local review: in progress**\n\n`wtc-review v1 head=1234567890abcdef1234567890abcdef12345678 verdict=pending blockers=0 round=1 lead=test:`\n' > "$root/progress.md"
  (cd "$root" && "$poster" review --progress --body progress.md) > "$root/progress.out" 2> "$root/progress.err"
  assert_eq 0 "$?" "published progress post: $(cat "$root/progress.err")"
  (cd "$root" && "$poster" review) > "$root/post.out" 2> "$root/post.err"
  assert_eq 0 "$?" "published summary post: $(cat "$root/post.err")"
  assert_eq 301 "$(cat "$bundle/comment.id")" 'summary comment id saved'
  assert_contains "$(cat "$bundle/inline-comments.json")" '"id": "401"' 'inline finding posted'
  (cd "$root" && "$resolver" review --reply 'Fixed in the patch.' --concern code) > "$root/resolve.out" 2> "$root/resolve.err"
  assert_eq 0 "$?" "published resolve: $(cat "$root/resolve.err")"
  assert_contains "$(cat "$root/resolve.out")" 'resolved 1 threads' 'one thread resolved'
  assert_contains "$(cat "$bundle/inline-comments.json")" '"resolved": true' 'resolution recorded'
  assert_contains "$(cat "$REVIEW_FAKE_GH_LOG")" 'resolveReviewThread' 'GitHub thread resolution invoked'
fi
