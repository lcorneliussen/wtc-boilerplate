#!/usr/bin/env bash
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$(dirname "$TESTS_DIR")"
. "$TESTS_DIR/helpers.sh"
export WTC_HARNESS_REPO=agent-harness
root="$(make_workspace)"
TEST_TMPDIRS="$TEST_TMPDIRS $root"
export WTC_CONFIG_ROOT="$root/config"
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=wtc-test
export GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=wtc-test@example.invalid
for name in clean dirty conflict detached operating; do
  mkdir -p "$root/$name"
  add_fixture_worktree "$root" agent-harness "$root/$name/harness"
done
add_fixture_worktree "$root" widget "$root/clean/widget"
widget_before="$(git -C "$root/clean/widget" rev-parse HEAD)"
base="$(git -C "$root/clean/harness" rev-parse HEAD)"
printf 'local dirty\n' > "$root/dirty/harness/local-file"
git -C "$root/conflict/harness" switch -qc topic
printf 'branch version\n' > "$root/conflict/harness/README.md"
git -C "$root/conflict/harness" commit -qam branch
conflict_before="$(git -C "$root/conflict/harness" rev-parse HEAD)"
printf 'detached work\n' > "$root/detached/harness/extra"
git -C "$root/detached/harness" add extra
git -C "$root/detached/harness" commit -qm detached
extra_before="$(git -C "$root/detached/harness" rev-parse HEAD)"
operation="$(git -C "$root/operating/harness" rev-parse --git-path rebase-merge)"
mkdir -p "$operation"
# Advance the local origin; never touch a forge or a real collection.
origin="$(git --git-dir="$root/.bare/agent-harness.git" remote get-url origin)"
printf 'main version\n' > "$origin/README.md"
git -C "$origin" commit -qam upstream
tip="$(git -C "$origin" rev-parse HEAD)"
mock="$root/mock-bin"; mkdir -p "$mock"
export CATCH_TEST_LOG="$root/calls" CATCH_TEST_REAL_GIT="$(command -v git)" CATCH_TEST_ROOT="$root"
cat > "$mock/git" <<'MOCK'
#!/usr/bin/env bash
case " $* " in *' fetch '*) printf '%s\n' "$*" >> "$CATCH_TEST_LOG" ;; esac
if [ "${CATCH_TEST_LOSE_WORKTREE:-}" = yes ]; then
  case " $* " in *' fetch '*) mv "$CATCH_TEST_ROOT/clean/harness/.git" "$CATCH_TEST_ROOT/lost-git" ;; esac
fi
exec "$CATCH_TEST_REAL_GIT" "$@"
MOCK
cat > "$mock/gh" <<'MOCK'
#!/usr/bin/env bash
# No PRs in this fixture. Never reach the developer's signed-in forge.
exit 0
MOCK
chmod +x "$mock/git" "$mock/gh"
export PATH="$mock:$PATH"
runner="$root/main/harness/tools/catch-up.sh"
no_hooks=(--no-skills --no-mcp --no-env --no-secrets)

it 'selective fleet catch-up updates clean worktrees and restores conflicts'
"$runner" --all --harness-only --json "${no_hooks[@]}" > "$root/result.json" 2> "$root/stderr"
assert_eq 1 "$?" 'partial owner attention produces nonzero exit'
assert_eq "$tip" "$(git -C "$root/clean/harness" rev-parse HEAD)"
assert_eq "$base" "$(git -C "$root/dirty/harness" rev-parse HEAD)"
assert_eq 'local dirty' "$(cat "$root/dirty/harness/local-file")"
assert_eq "$conflict_before" "$(git -C "$root/conflict/harness" rev-parse HEAD)"
assert_empty "$(git -C "$root/conflict/harness" status --porcelain)" 'conflict returns clean original tree'
assert_eq "$extra_before" "$(git -C "$root/detached/harness" rev-parse HEAD)"
assert_eq "$base" "$(git -C "$root/operating/harness" rev-parse HEAD)"
assert_eq "$widget_before" "$(git -C "$root/clean/widget" rev-parse HEAD)"
assert_eq 1 "$(wc -l < "$CATCH_TEST_LOG" | tr -d ' ')" 'one fetch for shared selected owner'
assert_not_contains "$(cat "$CATCH_TEST_LOG")" 'widget.git' 'unselected owner never fetched'
assert_ok python3 - "$root/result.json" "$root/main" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p['initiator']==sys.argv[2]
rows={r['collection']:r for r in p['outcomes'] if r['kind']=='repo'}
assert rows['clean']['outcome']=='updated'
for key in ['dirty','conflict','detached','operating']:
    assert rows[key]['outcome']=='needs-owner', rows[key]
    assert rows[key]['source_sha']==rows[key]['result_sha']
    assert rows[key]['next_actor'].endswith(key)
PY
assert_file "$root/main/.wtc-catch-up.json"
assert_no_file "$root/operating/.wtc-catch-up.json" 'report remains at initiator'

it 'dry-run is read-only and accepts registry names'
: > "$CATCH_TEST_LOG"
"$runner" --repos agent-harness --dry-run --json "${no_hooks[@]}" clean > "$root/dry.json" 2> "$root/stderr"
assert_eq 0 "$?"
assert_empty "$(cat "$CATCH_TEST_LOG")" 'dry-run does not fetch'
assert_ok python3 - "$root/dry.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); assert p['dry_run']
assert all(r['repo']=='agent-harness' for r in p['outcomes'])
PY
it 'unknown selection fails before fetching'
assert_fails "$runner" --all --repos typo --json "${no_hooks[@]}"
assert_empty "$(cat "$CATCH_TEST_LOG")"

it 'local catch-up preserves dirty stash behavior'
"$runner" --repos harness --json "${no_hooks[@]}" dirty > "$root/local.json" 2> "$root/stderr"
assert_eq 0 "$?"
assert_eq "$tip" "$(git -C "$root/dirty/harness" rev-parse HEAD)"
assert_eq 'local dirty' "$(cat "$root/dirty/harness/local-file")"
assert_empty "$(git -C "$root/dirty/harness" stash list)"

it 'selected secrets hook receives only selected repo'
cat > "$root/clean/harness/tools/link-secrets.sh" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CATCH_TEST_ROOT/secrets-calls"
MOCK
chmod +x "$root/clean/harness/tools/link-secrets.sh"
"$runner" --repos widget --json --no-skills --no-mcp --no-env clean > "$root/secrets.json" 2> "$root/stderr"
assert_eq 0 "$?"
assert_contains "$(cat "$root/secrets-calls")" '--repo widget'
assert_not_contains "$(cat "$root/secrets-calls")" 'agent-harness'
# Restore harness to make it eligible for pane testing.
git -C "$root/clean/harness" restore tools/link-secrets.sh

cat > "$mock/herdr" <<'MOCK'
#!/usr/bin/env bash
shift 2 # --session name
case "$1 $2" in
  'workspace list') echo '{"result":{"workspaces":[{"label":"clean","workspace_id":"w1"}]}}' ;;
  'pane list') echo '{"result":{"panes":[{"label":"status","pane_id":"w1:p3"},{"label":"browse","pane_id":"w1:p2"},{"label":"agent","pane_id":"w1:p1","agent":"codex"}]}}' ;;
  'pane process-info')
    if [ -f "$CATCH_TEST_ROOT/restarted" ]; then echo '{"result":{"cmdline":"bash ./harness/tools/wtc-status-tui.sh"}}'
    elif [ -f "$CATCH_TEST_ROOT/interrupted" ]; then echo '{"result":{"cmdline":"zsh"}}'
    else printf '{"result":{"cmdline":"%s"}}\n' "${CATCH_TEST_FOREGROUND:-bash ./harness/tools/wtc-status-tui.sh}"; fi ;;
  'pane send-keys') printf '%s\n' "$*" >> "$CATCH_TEST_ROOT/pane-calls"; touch "$CATCH_TEST_ROOT/interrupted" ;;
  'pane run') printf '%s\n' "$*" >> "$CATCH_TEST_ROOT/pane-calls"; touch "$CATCH_TEST_ROOT/restarted" ;;
  'agent list') echo '{"result":{"agents":[]}}' ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$mock/herdr"
export HERDR_ENV=1 HERDR_SESSION=fixture
it 'force reload touches only the verified status pane'
"$runner" --harness-only --reload-status --json "${no_hooks[@]}" clean > "$root/panes.json" 2> "$root/stderr"
assert_eq 0 "$?"
assert_contains "$(cat "$root/pane-calls")" 'pane send-keys w1:p3 ctrl+c'
assert_contains "$(cat "$root/pane-calls")" 'pane run w1:p3'
assert_not_contains "$(cat "$root/pane-calls")" 'w1:p2'
assert_not_contains "$(cat "$root/pane-calls")" 'w1:p1'
assert_ok python3 - "$root/panes.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); assert any(r['kind']=='pane' and r['outcome']=='restarted' for r in p['outcomes'])
PY
it 'unrelated foreground process is never interrupted'
rm "$root/interrupted" "$root/restarted"
: > "$root/pane-calls"
export CATCH_TEST_FOREGROUND=nvim
"$runner" --harness-only --reload-status --json "${no_hooks[@]}" clean > "$root/refused.json" 2> "$root/stderr"
assert_eq 1 "$?"
assert_empty "$(cat "$root/pane-calls")"

it 'a status script name passed to an editor is not a status process'
export CATCH_TEST_FOREGROUND='nvim ./harness/tools/wtc-status-tui.sh'
"$runner" --harness-only --reload-status --json "${no_hooks[@]}" clean > "$root/refused.json" 2> "$root/stderr"
assert_eq 1 "$?"
assert_empty "$(cat "$root/pane-calls")"

it 'missing worktree after inventory does not prevent later outcomes'
export CATCH_TEST_LOSE_WORKTREE=yes
"$runner" --harness-only --json "${no_hooks[@]}" clean main > "$root/lost.json" 2> "$root/stderr"
assert_eq 1 "$?"
unset CATCH_TEST_LOSE_WORKTREE
mv "$root/lost-git" "$root/clean/harness/.git"
assert_ok python3 - "$root/lost.json" <<'PY'
import json,sys
rows={r['collection']:r for r in json.load(open(sys.argv[1]))['outcomes'] if r['kind']=='repo'}
assert rows['clean']['outcome']=='failed'
assert rows['main']['outcome']=='current'
PY

it 'target registry identity does not depend on initiating shell environment'
sed 's/agent-harness/custom-harness/g' "$root/clean/harness/.harness-repos.yml" > "$root/registry"
mv "$root/registry" "$root/clean/harness/.harness-repos.yml"
# Match the target registry origin; only dry-run, so this URL is never fetched.
git --git-dir="$root/.bare/agent-harness.git" remote set-url origin https://github.com/example/custom-harness.git
env -u WTC_HARNESS_REPO "$runner" --repos custom-harness --dry-run --json "${no_hooks[@]}" clean > "$root/identity.json" 2> "$root/stderr"
identity_rc=$?
assert_eq 0 "$identity_rc" "identity invocation: $(cat "$root/stderr") $(cat "$root/identity.json")"
assert_ok python3 - "$root/identity.json" <<'PY'
import json,sys
assert any(r['repo']=='custom-harness' for r in json.load(open(sys.argv[1]))['outcomes'])
PY
git --git-dir="$root/.bare/agent-harness.git" remote set-url origin "$origin"
git -C "$root/clean/harness" restore .harness-repos.yml

it 'partial fetch failure still reports every selected repo'
git --git-dir="$root/.bare/widget.git" remote set-url origin "$root/nonexistent"
"$runner" --repos harness,widget --json "${no_hooks[@]}" clean > "$root/fetch-failed.json" 2> "$root/stderr"
assert_eq 1 "$?"
assert_ok python3 - "$root/fetch-failed.json" <<'PY'
import json,sys
rows={r['repo']:r for r in json.load(open(sys.argv[1]))['outcomes'] if r['kind']=='repo'}
assert rows['agent-harness']['outcome']=='current'
assert rows['widget']['outcome']=='failed'
PY

it 'updating the initiating implementation cannot replace the running sweep'
printf '#!/usr/bin/env bash\nexit 91\n' > "$origin/tools/catch-up.sh"
printf 'raise RuntimeError("replaced report helper")\n' > "$origin/tools/catch-up-report.py"
printf 'exit 92\n' > "$origin/tools/lib.sh"
git -C "$origin" commit -qam replace-runner
new_tip="$(git -C "$origin" rev-parse HEAD)"
"$runner" --harness-only --json "${no_hooks[@]}" main clean > "$root/self-update.json" 2> "$root/stderr"
assert_eq 0 "$?"
assert_eq "$new_tip" "$(git -C "$root/clean/harness" rev-parse HEAD)"
assert_ok python3 - "$root/self-update.json" "$root/main" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); assert p['initiator']==sys.argv[2]
assert len([r for r in p['outcomes'] if r['kind']=='repo' and r['outcome']=='updated'])==2
PY

it 'report write failure still emits the collected JSON'
: > "$root/report-rows"
python3 "$HARNESS_SRC/tools/catch-up-report.py" finish "$root/report-rows" "$root/main" no 0 "$root/missing/report.json" json > "$root/report-output.json" 2> "$root/stderr"
assert_eq 1 "$?"
assert_ok python3 - "$root/report-output.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); assert p['exit_status']==1 and p['report_error']
PY
