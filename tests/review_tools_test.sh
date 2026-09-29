#!/usr/bin/env bash
# test_review_tools.sh — offline tests for the review tools, the gate and guard-pr-ready.
#
# Builds a throwaway workspace (bare-marker dir, collection, harness copy, a
# demo repo and a downstream repo), runs review-bundle.sh and review-run.sh
# with a fake agent (WTC_REVIEW_AGENT_CMD) and checks the outputs. No network,
# no forge, no real agent. Uses stand-in prompts, not review/prompts/*.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/review-tools-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fails=0 passed=0
ok()   { printf 'ok   %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL %s\n' "$1" >&2; fails=$((fails + 1)); }
check() { # <desc> <cmd…>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi
}

# Never talk to a real forge: a stub bb on PATH (driven by $BBSTUB fixtures), no
# REST credentials, the fallback (bb) posting path forced.
export WTC_REVIEW_NO_API=1 HOME="$T/home" WTC_CONFIG_ROOT="$T/home"
export WTC_HARNESS_REPO=harness
mkdir -p "$HOME" "$T/stubbin"
unset BB_USERNAME BB_API_TOKEN ATLASSIAN_ACCOUNT_EMAIL ATLASSIAN_API_TOKEN
export BBSTUB="$T/bbstub"; mkdir -p "$BBSTUB"
cat >"$T/stubbin/bb" <<'EOF'
#!/usr/bin/env bash
d="${BBSTUB:-/nonexistent}"
echo "bb $*" >>"$d/calls.log" 2>/dev/null || true
case "$1" in
  --version) echo 2.2.1 ;;
  pr)
    case "$2" in
      view) [ -f "$d/pr.json" ] && cat "$d/pr.json" || exit 1 ;;
      comments)
        case "$3" in
          list) [ -f "$d/comments.json" ] && cat "$d/comments.json" || exit 1 ;;
          add)
            inline=0
            for a in "$@"; do
              [ "$a" = "--file" ] && inline=1
            done
            if [ "$inline" -eq 1 ]; then
              n="$(cat "$d/inline-n" 2>/dev/null || echo 600)"
              n=$((n + 1))
              printf '%s\n' "$n" >"$d/inline-n"
              printf '{"id": %s}\n' "$n"
            else
              echo '{"id": 501}'
            fi
            ;;
          edit|resolve|reply) echo ok ;;
          *) exit 1 ;;
        esac ;;
      ready) echo "marked ready" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/stubbin/bb"
export PATH="$T/stubbin:$PATH"

# --- workspace ----------------------------------------------------------------
ws="$T/ws"; coll="$ws/coll"; h="$coll/harness"
mkdir -p "$ws/.bare" "$h/review/prompts" "$h/review/concerns"
cp -R "$here/tools" "$h/tools"
cat >"$h/.harness-repos.yml" <<'EOF'
version: 1
selected:
  - name: demo
    remote: git@bitbucket.org:x/demo.git
    default_ref: origin/main
    downstream: lib2   # consumer
  - name: lib2
    remote: git@example.com:x/lib2.git
    default_ref: origin/main
EOF
cat >"$h/review/prompts/concern.md" <<'EOF'
CONCERN {{CONCERN_ID}} WRITE {{FINDINGS_FILE}} REPO {{REPO_DIR}} FILE {{CONCERN_FILE}} M {{MANIFEST}} B {{BUNDLE}}
EOF
cat >"$h/review/prompts/lead.md" <<'EOF'
LEAD SUMMARY {{SUMMARY_FILE}} VERDICT {{VERDICT_FILE}} BUNDLE {{BUNDLE}} REPO {{REPO_DIR}} M {{MANIFEST}}
EOF
cat >"$h/review/concerns/dup.md" <<'EOF'
---
id: dup
tier: fast
applies: always
---
harness layer
EOF

mkrepo() { # <dir>
  git init -q -b main "$1"
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
  echo base >"$1/README.md"
  git -C "$1" add -A
  git -C "$1" commit -q -m base
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}
mkrepo "$coll/demo"
mkrepo "$coll/lib2"
demo="$coll/demo"
git -C "$demo" checkout -q -b feature
mkdir -p "$demo/models/a" "$demo/.review/concerns"
echo "select 1" >"$demo/models/a/x.sql"
echo "print(1)" >"$demo/tool.py"
git -C "$demo" add -A
git -C "$demo" commit -q -m feature
mk_concern() { # <id> <tier> <applies> [needs]
  { echo "---"; echo "id: $1"; echo "tier: $2   # comment"; echo "applies: $3"
    [ -z "${4:-}" ] || echo "needs: $4"; echo "---"; echo "body of $1"; } \
    >"$demo/.review/concerns/$1.md"
}
mk_concern t-ok standard always
mk_concern t-sql fast "**/*.sql"
mk_concern t-py fast "docs/**/*.py"
mk_concern t-never fast never
mk_concern t-fail fast always
mk_concern t-slow fast always
mk_concern t-block fast always
mk_concern t-die fast always
mk_concern dup strong always
git -C "$demo" add -A
git -C "$demo" commit -q -m concerns
# lib2 (downstream of demo) lands on its production ref only
echo v1 >"$coll/lib2/consumer.txt"; git -C "$coll/lib2" add -A; git -C "$coll/lib2" commit -q -m c
git -C "$coll/lib2" update-ref refs/remotes/origin/main HEAD

# --- fake agent ---------------------------------------------------------------
fake="$T/fake-agent.sh"
cat >"$fake" <<'EOF'
#!/usr/bin/env bash
# args: agent model prompt-file cwd
echo "fake agent=$1 model=$2 cwd=$4" >&2
if [ -n "${FAKE_LIMIT_AGENT:-}" ] && [ "$1" = "$FAKE_LIMIT_AGENT" ]; then
  echo "You've hit your session limit · resets later" >&2
  exit 1
fi
p="$(cat "$3")"
case "$p" in
  CONCERN*)
    id="$(printf '%s' "$p" | awk '{print $2}')"
    out="$(printf '%s' "$p" | awk '{print $4}')"
    case "$id" in
      t-fail) echo "this is not json" >"$out" ;;
      t-slow) exec sleep 30 ;;
      t-die) kill -9 "$PPID"; exit 0 ;;   # kills the runner's concern job: no findings, no stub
      t-block)
        cat >"$out" <<J
{"concern":"$id","status":"issues","notes":"n","findings":[
 {"severity":"blocker","file":"a","line":null,"title":"open","detail":"d","prior":"new"},
 {"severity":"blocker","file":"a","line":3,"title":"fixed","detail":"d","prior":"addressed"},
 {"severity":"minor","file":"a","line":1,"title":"m","detail":"d"}]}
J
        ;;
      *)
        [ "$id" != t-ok ] || [ -z "${WTC_REVIEW_STATS_FILE:-}" ] ||
          echo '{"input_tokens":182000,"output_tokens":9100,"cache_read_tokens":1200000,"cost_usd":0.39,"turns":7}' >"$WTC_REVIEW_STATS_FILE"
        echo "{\"concern\":\"$id\",\"status\":\"ok\",\"notes\":\"n\",\"findings\":[]}" >"$out"
        [ -z "${FAKE_WRITE_AND_FAIL:-}" ] || exit 1
        ;;
    esac
    ;;
  LEAD*)
    [ -z "${FAKE_LEAD_FAIL:-}" ] || exit 3
    sum="$(printf '%s' "$p" | awk '{print $3}')"
    ver="$(printf '%s' "$p" | awk '{print $5}')"
    printf '**Local review: pass**\n\nbody\n\n`wtc-review v1 head=deadbeef verdict=pass blockers=0 round=9 lead=x`\n' >"$sum"
    echo "${FAKE_VERDICT:-pass}" >"$ver"
    [ -z "${FAKE_LEAD_WRITE_AND_FAIL:-}" ] || exit 1
    ;;
esac
EOF
chmod +x "$fake"
export WTC_REVIEW_AGENT_CMD="$fake"

# --- bundle -------------------------------------------------------------------
B="$h/tools/review-bundle.sh"
out="$("$B" demo 2>"$T/bundle.err")" || { cat "$T/bundle.err" >&2; fail "bundle builds"; }
bd="$(printf '%s\n' "$out" | tail -n1)"
check "bundle dir printed and exists" test -d "$bd"
for f in manifest.env pr.md diff.patch changed-files.txt log.txt; do
  check "bundle has $f" test -s "$bd/$f"
done
check "diff mentions x.sql" grep -q 'models/a/x.sql' "$bd/diff.patch"
check "manifest REPO=demo ROUND=1" bash -c ". '$bd/manifest.env' && [ \"\$REPO\" = demo ] && [ \"\$ROUND\" = 1 ] && [ -z \"\$PR\" ]"
check "concern applies:always kept" test -f "$bd/concerns/t-ok.md"
check "glob ** matches nested .sql" test -f "$bd/concerns/t-sql.md"
check "glob docs/** filters out" test ! -e "$bd/concerns/t-py.md"
check "applies:never dropped" test ! -e "$bd/concerns/t-never.md"
check "repo layer wins by id" grep -q 'body of dup' "$bd/concerns/dup.md"
check "downstream old/ snapshot" test -f "$bd/downstream/lib2/old/consumer.txt"
check "downstream REFS" grep -q '^old=origin/main ' "$bd/downstream/lib2/REFS"
check "downstream absent new/ (lib2 on tip)" test ! -d "$bd/downstream/lib2/new"
ub="$("$B" lib2 2>/dev/null | tail -n1)"
check "upstream snapshot for the consumer repo" test -f "$ub/upstream/demo/old/README.md"

# glob unit cases
check "glob: *.sql basename anywhere" python3 -c "
import sys; sys.path.insert(0,'$h/tools'); import review_lib as r
assert r.applies_to('*.sql',['a/b/c.sql']); assert not r.applies_to('*.sql',['a/c.py'])
assert r.applies_to('dags/**',['dags/x/y.py']); assert r.applies_to('a/**/b.py',['a/b.py'])
assert not r.applies_to('a/*.py',['a/b/c.py'])"

# --- run ----------------------------------------------------------------------
export HARNESS_REVIEW_TIMEOUT=3
rc=0; "$h/tools/review-run.sh" "$bd" --parallel 3 >"$T/run.out" 2>"$T/run.err" || rc=$?
check "review-run exits 0" test "$rc" -eq 0
check "findings t-ok valid" python3 "$h/tools/review_lib.py" validate-findings "$bd/findings/t-ok.json" t-ok
check "findings t-fail is error + .raw" bash -c "grep -q '\"error\"' '$bd/findings/t-fail.json' && grep -q 'not json' '$bd/findings/t-fail.raw'"
check "findings t-slow is error (timeout)" bash -c "grep -q 'timeout' '$bd/findings/t-slow.json'"
check "findings t-never absent" test ! -e "$bd/findings/t-never.json"
check "verdict downgraded (errored concerns)" test "$(cat "$bd/verdict")" = pass-with-notes
check "status line format" grep -Eq 'wtc-review v1 head=[0-9a-f]{40} verdict=pass-with-notes blockers=1 round=1 lead=claude:opus' "$bd/summary.md"
check "status footer reads as a sentence" grep -q '🟡 \*\*pass-with-notes\*\* · round 1 · `' "$bd/summary.md"
check "exactly one status line" test "$(grep -c 'wtc-review v1 head=' "$bd/summary.md")" -eq 1
check "lead heading kept" grep -q 'Local review: pass' "$bd/summary.md"
check "run.log written" test -s "$bd/run.log"
check "scheduled concern with no findings gets an error stub" bash -c "grep -q '\"error\"' '$bd/findings/t-die.json' && grep -q 'no findings file' '$bd/findings/t-die.json'"
check "custom launcher stats are kept (tokens, cost)" python3 -c "
import json; d=json.load(open('$bd/stats/t-ok.json'))
assert d['input_tokens']==182000 and d['output_tokens']==9100 and d['cache_read_tokens']==1200000 and d['cost_usd']==0.39 and d['turns']==7 and d['status']=='ok', d"
check "missing custom stats -> seconds only" python3 -c "
import json; d=json.load(open('$bd/stats/t-sql.json'))
assert isinstance(d['seconds'],int) and d['input_tokens'] is None and d['cost_usd'] is None, d"
check "timed-out run has status timeout in stats" grep -q '\"timeout\"' "$bd/stats/t-slow.json"
check "stats for lead written" test -s "$bd/stats/lead.json"
check "summary has Run stats section" grep -q 'Run stats' "$bd/summary.md"
check "Run stats: total row, wall-clock, humanized tokens, cost" bash -c "grep -q '^| \*\*Total\*\*' '$bd/summary.md' && grep -q 'Wall-clock for the whole run' '$bd/summary.md' && grep -q '182k / 9.1k (1.2M)' '$bd/summary.md' && grep -q '\\\$0.39' '$bd/summary.md'"
check "Run stats sits before the status line" bash -c "[ \$(grep -n 'Run stats' '$bd/summary.md' | head -n1 | cut -d: -f1) -lt \$(grep -n 'wtc-review v1' '$bd/summary.md' | cut -d: -f1) ]"

# needs: downstream with no snapshots -> skipped (own bundle, no downstream repo registered)
mk_concern t-needs standard always downstream
git -C "$demo" add -A; git -C "$demo" commit -q -m needs
sed -i.bak '/downstream:/d' "$h/.harness-repos.yml"
bd2="$("$B" demo 2>"$T/b2.err" | tail -n1)"
check "round 2 + prior/r1.md" bash -c ". '$bd2/manifest.env' && [ \"\$ROUND\" = 2 ] && test -s '$bd2/prior/r1.md'"
check "needs:downstream kept in bundle" test -f "$bd2/concerns/t-needs.md"
FAKE_VERDICT=changes-requested "$h/tools/review-run.sh" "$bd2" --only t-needs,t-ok --lead codex: >/dev/null 2>&1 || true
check "skipped without downstream" grep -q '"skipped"' "$bd2/findings/t-needs.json"
check "--only leaves others alone" test ! -e "$bd2/findings/t-sql.json"
check "verdict passthrough + lead spec" bash -c "test \"\$(cat '$bd2/verdict')\" = changes-requested && grep -q 'lead=codex:' '$bd2/summary.md'"
check "review-run rejects a bad bundle" bash -c "! '$h/tools/review-run.sh' '$T' 2>/dev/null"

# --- guard-pr-ready.py --------------------------------------------------------
g="$here/hooks/guard-pr-ready.py"
guard() { python3 -c 'import json,sys;print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1" |
  python3 "$g" >/dev/null 2>&1; }
deny_case()  { local rc=0; guard "$1" || rc=$?; if [ "$rc" -eq 2 ]; then ok "guard denies: $1"; else fail "guard should deny: $1 (rc=$rc)"; fi; }
allow_case() { local rc=0; guard "$1" || rc=$?; if [ "$rc" -eq 0 ]; then ok "guard allows: $1"; else fail "guard should allow: $1 (rc=$rc)"; fi; }
deny_case  'bb pr ready 12'
deny_case  'cd app && bb pr ready 12'
deny_case  'gh pr ready 3 --repo a/b'
deny_case  'FOO=1 bb pr ready 4'
deny_case  'echo x; exec bb pr ready 1'
allow_case 'harness/tools/bb-pr-ready.sh 12'
allow_case '../harness/tools/bb-pr-ready.sh 12 --user-authorized "undraft it"'
allow_case 'bb pr view 12'
allow_case 'bb pr create --draft -d dev'
allow_case 'git commit -m "docs: never run bb pr ready raw"'
allow_case 'echo not json'
rc=0; echo '{"command": "gh pr ready 1"}' | WTC_ALLOW_RAW_PR_READY=1 python3 "$g" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "guard escape hatch" || fail "guard escape hatch"
rc=0; printf '{broken' | python3 "$g" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "guard fail-open on garbage" || fail "guard fail-open"


# --- stats parsing (real agent output shapes) ---------------------------------
sd="$T/statsparse"; mkdir -p "$sd"
cat >"$sd/claude.out" <<'EOF'
warning on stderr
{"type":"result","subtype":"success","is_error":false,"duration_ms":1207,"num_turns":3,"result":"final text","total_cost_usd":0.039,"usage":{"input_tokens":10,"cache_creation_input_tokens":18714,"cache_read_input_tokens":13689,"output_tokens":44},"modelUsage":{"claude-haiku-4-5":{"outputTokens":44}}}
EOF
python3 "$h/tools/review_lib.py" run-stats "$sd/c.json" "$sd/claude.out" "$sd/c.txt" claude "" 12 ok 0
check "claude JSON: usage/cost/turns parsed" python3 -c "
import json; d=json.load(open('$sd/c.json'))
assert (d['input_tokens'],d['output_tokens'],d['cache_read_tokens'],d['cache_write_tokens'],d['cost_usd'],d['turns'],d['seconds'],d['model'])==(10,44,13689,18714,0.039,3,12,'claude-haiku-4-5'), d"
check "claude JSON: human text is .result (findings fallback keeps working)" bash -c "grep -q 'final text' '$sd/c.txt' && ! grep -q total_cost_usd '$sd/c.txt'"
cat >"$sd/codex.out" <<'EOF'
{"type":"thread.started","thread_id":"t"}
{"type":"item.completed","item":{"id":"i0","type":"agent_message","text":"codex says ok"}}
{"type":"turn.completed","usage":{"input_tokens":17024,"cached_input_tokens":8064,"cache_write_input_tokens":0,"output_tokens":5}}
{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":7}}
EOF
python3 "$h/tools/review_lib.py" run-stats "$sd/x.json" "$sd/codex.out" "$sd/x.txt" codex gpt 5 ok 0
check "codex JSONL: usage summed over turns (input excludes cached)" python3 -c "
import json; d=json.load(open('$sd/x.json'))
assert (d['input_tokens'],d['output_tokens'],d['cache_read_tokens'],d['turns'],d['cost_usd'])==(9060,12,8064,2,None), d"
check "codex JSONL: human text from agent messages" grep -q 'codex says ok' "$sd/x.txt"
cat >"$sd/grok.out" <<'EOF'
note before the object
{
  "text": "grok says ok",
  "stopReason": "end_turn",
  "thought": "do not leak this thought",
  "usage": {
    "input_tokens": 100,
    "cache_read_input_tokens": 40,
    "cache_creation_input_tokens": 5,
    "output_tokens": 8
  },
  "num_turns": 2,
  "total_cost_usd": 0.01,
  "modelUsage": {"grok-4.7": {"outputTokens": 8}}
}
EOF
python3 "$h/tools/review_lib.py" run-stats "$sd/g.json" "$sd/grok.out" "$sd/g.txt" grok "" 9 ok 0
check "grok JSON: usage/cost/model parsed, thought dropped" python3 -c "
import json; d=json.load(open('$sd/g.json'))
assert (d['input_tokens'],d['output_tokens'],d['cache_read_tokens'],d['cache_write_tokens'],d['cost_usd'],d['turns'],d['model'],d['status'])==(100,8,40,5,0.01,2,'grok-4.7','ok'), d"
check "grok JSON: human text is .text" bash -c "grep -q 'grok says ok' '$sd/g.txt' && ! grep -q 'do not leak' '$sd/g.txt'"
check "grok launcher uses the workspace sandbox" grep -q -- '--sandbox workspace' "$here/tools/review-run.sh"
check "grok launcher passes reasoning effort" grep -q -- '--reasoning-effort' "$here/tools/review-run.sh"
echo "plain non-json output" >"$sd/plain.out"
python3 "$h/tools/review_lib.py" run-stats "$sd/p.json" "$sd/plain.out" "$sd/p.txt" claude opus 3 error 0
check "unparseable output -> seconds only, text kept" bash -c "grep -q 'plain non-json' '$sd/p.txt' && python3 -c \"
import json; d=json.load(open('$sd/p.json')); assert d['input_tokens'] is None and d['seconds']==3 and d['status']=='error'\""
check "humanizers" python3 -c "
import sys; sys.path.insert(0,'$h/tools'); import review_lib as r
assert r.fmt_secs(252)=='4m12s' and r.fmt_secs(52)=='52s' and r.fmt_secs(3720)=='1h02m'
assert r.fmt_tok(182000)=='182k' and r.fmt_tok(950)=='950' and r.fmt_tok(1200000)=='1.2M' and r.fmt_tok(None)=='-'"

# --- reviewer allowlist -------------------------------------------------------
check "reviewer allowlist has no git diff" bash -c "! grep -q 'Bash(git diff' '$here/tools/review-run.sh'"
check "reviewer denies git --output (file-writing option)" grep -q 'Bash(git \* --ou\*)' "$here/tools/review-run.sh"

# --- prompt placeholders ------------------------------------------------------
check "concern.md placeholders == what review-run substitutes" python3 - "$here" concern.md <<'PY'
import re, sys
here, name = sys.argv[1:3]
tpl = set(re.findall(r"\{\{([A-Z_]+)\}\}", open(here + "/review/prompts/" + name).read()))
src = open(here + "/tools/review-run.sh").read()
m = re.search(r'render "\$prompts/' + re.escape(name) + r'"((?:[^\n]*\\\n)*[^\n]*)', src)
keys = set(re.findall(r'"([A-Z_]+)=', m.group(1)))
assert tpl and tpl == keys, (sorted(tpl - keys), sorted(keys - tpl))
PY
check "lead.md placeholders == what review-run substitutes" python3 - "$here" lead.md <<'PY'
import re, sys
here, name = sys.argv[1:3]
tpl = set(re.findall(r"\{\{([A-Z_]+)\}\}", open(here + "/review/prompts/" + name).read()))
src = open(here + "/tools/review-run.sh").read()
m = re.search(r'render "\$prompts/' + re.escape(name) + r'"((?:[^\n]*\\\n)*[^\n]*)', src)
keys = set(re.findall(r'"([A-Z_]+)=', m.group(1)))
assert tpl and tpl == keys, (sorted(tpl - keys), sorted(keys - tpl))
PY

# --- sha matching -------------------------------------------------------------
H40="$(printf 'ab%.0s' $(seq 20))"; H12="${H40:0:12}"; O40="$(printf 'cd%.0s' $(seq 20))"
same() { bash -c ". '$h/tools/review-common.sh'; review_same_sha \"\$1\" \"\$2\"" _ "$@"; }
check "same_sha: equal 40" same "$H40" "$H40"
check "same_sha: 12-char remote is prefix of 40-char local" same "$H40" "$H12"
nsame() { ! same "$@"; }
check "same_sha: rejects a remote prefix shorter than 12" nsame "$H40" "${H40:0:11}"
check "same_sha: rejects the reverse direction (short local, long remote)" nsame "$H12" "$H40"
check "same_sha: rejects a short local" nsame "${H40:0:8}" "${H40:0:8}"
check "same_sha: different commits" nsame "$H40" "${O40:0:12}"

# --- gate: review-status + bb-pr-ready with a stub bb --------------------------
pr_json() { # <head>
  python3 -c '
import json,sys
print(json.dumps({"title":"t","description":"d","state":"OPEN","draft":True,
 "destination":{"branch":{"name":"main"}},"source":{"commit":{"hash":sys.argv[1]},"branch":{"name":"feature"}},
 "links":{"html":{"href":"https://example.invalid/pr/7"}}}))' "$1" >"$BBSTUB/pr.json"
}
mk_comments() { # <id> <when> <body> [<id> <when> <body>]…
  python3 -c '
import json,sys
a=sys.argv[1:]
print(json.dumps([{"id":int(a[i]),"created_on":a[i+1],"content":{"raw":a[i+2]},"user":{"display_name":"u"}} for i in range(0,len(a),3)]))' "$@" >"$BBSTUB/comments.json"
}
sl() { printf '`wtc-review v1 head=%s verdict=%s blockers=%s round=1 lead=x`' "$1" "$2" "${3:-0}"; }
status_of() { "$h/tools/review-status.sh" demo 7 2>/dev/null | head -n1; }
expect_status() { # <desc> <expected line>
  local got; got="$(status_of)"
  if [ "$got" = "$2" ]; then ok "status: $1 -> $2"; else fail "status: $1: expected '$2', got '$got'"; fi
}
T1=2026-01-01T00:00:00Z; T2=2026-01-02T00:00:00Z
pr_json "$H12"
mk_comments 1 "$T1" "just chatting"
expect_status "no review comment" "none"
mk_comments 1 "$T1" "**r**
$(sl "$O40" pass)"
expect_status "review of an older head" "stale pass 0 1"
mk_comments 1 "$T1" "**r**
$(sl "$H40" pass)"
expect_status "review of the PR head" "current pass 0 1"
mk_comments 1 "$T1" "**r**
$(sl "$H40" pass-with-notes 0)"
expect_status "pass-with-notes" "current pass-with-notes 0 1"
mk_comments 1 "$T1" "$(sl "$H40" changes-requested 2)"
expect_status "changes-requested" "current changes-requested 2 1"
mk_comments 1 "$T1" "$(sl "$H40" pass)" 2 "$T2" "$(sl "$H40" pending)"
expect_status "pending newer than a complete review of the same head" "current pending 0 1"
mk_comments 1 "$T1" "$(sl "$H40" error)"
expect_status "error" "current error 0 1"
mk_comments 1 "$T1" "$(sl "${H40:0:7}" pass)"
expect_status "status head shorter than 12 chars is not a status line" "none"
pr_json "$H40"
mk_comments 1 "$T1" "$(sl "$H12" pass)"
expect_status "12-char status head vs 40-char PR head (wrong direction)" "stale pass 0 1"

gate() { # <desc> <expected-rc> <expected-ready-calls> [bb-pr-ready args…]
  local d="$1" want="$2" ready="$3" rc=0 n; shift 3
  : >"$BBSTUB/calls.log"
  (cd "$coll/demo" && "$h/tools/bb-pr-ready.sh" 7 "$@") >/dev/null 2>&1 || rc=$?
  n="$(grep -c '^bb pr ready' "$BBSTUB/calls.log" || true)"
  if [ "$rc" -eq "$want" ]; then ok "gate: $d (rc=$want)"; else fail "gate: $d: rc=$rc, expected $want"; fi
  if [ "$n" -eq "$ready" ]; then ok "gate: $d (bb pr ready calls=$ready)"; else fail "gate: $d: bb pr ready called $n times, expected $ready"; fi
}
pr_json "$H12"
mk_comments 1 "$T1" "nothing here"
gate "refuses when there is no review" 1 0
mk_comments 1 "$T1" "$(sl "$O40" pass)"
gate "refuses a stale review" 1 0
mk_comments 1 "$T1" "$(sl "$H40" changes-requested 1)"
gate "refuses changes-requested" 1 0
mk_comments 1 "$T1" "$(sl "$H40" pending)"
gate "refuses pending" 1 0
mk_comments 1 "$T1" "$(sl "$H40" error)"
gate "refuses error" 1 0
mk_comments 1 "$T1" "$(sl "$H40" pass)" 2 "$T2" "$(sl "$H40" pending)"
gate "refuses pending even when an older review passed" 1 0
mk_comments 1 "$T1" "$(sl "$H40" pass)"
gate "allows current pass" 0 1
mk_comments 1 "$T1" "$(sl "$H40" pass-with-notes)"
gate "allows current pass-with-notes" 0 1
mk_comments 1 "$T1" "$(sl "$H40" changes-requested 1)"
gate "override on changes-requested with --user-authorized" 0 1 --user-authorized "undraft it anyway"
mk_comments 1 "$T1" "$(sl "$H40" pending)"
gate "override on pending with --user-authorized" 0 1 --user-authorized "undraft it anyway"
mk_comments 1 "$T1" "$(sl "$O40" pass)"
gate "override on stale with --user-authorized" 0 1 --user-authorized "undraft it anyway"

# --- review-post: create vs update, progress, failed, stale refusal ------------
mkbundle() { # <dir> — a bundle for PR 7 at the demo head
  local dh; dh="$(git -C "$demo" rev-parse HEAD)"
  mkdir -p "$1/concerns"
  printf 'REPO=demo\nPR=7\nFORGE=bitbucket\nSLUG=x/demo\nHEAD_SHA=%s\nROUND=2\nREPO_DIR=%s\n' "$dh" "$demo" >"$1/manifest.env"
  printf -- '---\nid: c1\ntier: strong\n---\nx\n' >"$1/concerns/c1.md"
  printf -- '---\nid: c2\ntier: fast\n---\nx\n' >"$1/concerns/c2.md"
  printf '**Local review: pass**\n\nbody\n\n%s\n' "$(sl "$dh" pass)" >"$1/summary.md"
  printf '%s' "$dh"
}
count() { grep -c "$1" "$BBSTUB/calls.log" || true; }
pb="$T/pb"; dh="$(mkbundle "$pb")"
pr_json "${dh:0:12}"; : >"$BBSTUB/calls.log"
"$h/tools/review-post.sh" "$pb" >/dev/null 2>&1 || true
check "post without comment.id creates (bb pr comments add)" test "$(count '^bb pr comments add 7')" -eq 1
check "comment.id stored from the create" test "$(cat "$pb/comment.id")" = 501
"$h/tools/review-post.sh" "$pb" >/dev/null 2>&1 || true
check "post with comment.id updates in place (bb pr comments edit 7 501)" test "$(count '^bb pr comments edit 7 501')" -eq 1
check "update did not create a second comment" test "$(count '^bb pr comments add 7')" -eq 1

pb2="$T/pb2"; mkbundle "$pb2" >/dev/null; : >"$BBSTUB/calls.log"
check "--progress posts a pending comment" bash -c "'$h/tools/review-post.sh' '$pb2' --progress >/dev/null 2>&1 && grep -q 'Local review: in progress' '$BBSTUB/calls.log' && grep -q 'verdict=pending blockers=0 round=2' '$BBSTUB/calls.log'"
check "progress lists concerns with tier -> agent:model" bash -c "grep -q '| c1 | strong | claude:opus |' '$pb2/progress.md' && grep -q '| c2 | fast | claude:haiku |' '$pb2/progress.md'"
check "progress stores comment.id" test "$(cat "$pb2/comment.id")" = 501
: >"$BBSTUB/calls.log"
printf 'x\ntoken=SECRETVALUE123 something\nfinal error line\n' >"$pb2/run.log"
"$h/tools/review-post.sh" "$pb2" --failed --reason "boom" >/dev/null 2>&1 || true
check "--failed updates the same comment to failed / verdict=error" bash -c "grep -q '^bb pr comments edit 7 501' '$BBSTUB/calls.log' && grep -q 'Local review: failed' '$BBSTUB/calls.log' && grep -q 'verdict=error' '$BBSTUB/calls.log'"
check "failure comment redacts secrets, keeps the log tail" bash -c "! grep -q SECRETVALUE123 '$BBSTUB/calls.log' && grep -q 'final error line' '$BBSTUB/calls.log'"
: >"$BBSTUB/calls.log"
"$h/tools/review-post.sh" "$pb2" >/dev/null 2>&1 || true
check "final summary after progress updates that comment" bash -c "grep -q '^bb pr comments edit 7 501' '$BBSTUB/calls.log' && grep -q 'Local review: pass' '$BBSTUB/calls.log'"

pr_json "${O40:0:12}"; : >"$BBSTUB/calls.log"; rm -f "$pb/comment.id"
rc=0; "$h/tools/review-post.sh" "$pb" >/dev/null 2>"$T/stale.err" || rc=$?
check "stale bundle: post refused" bash -c "[ $rc -ne 0 ] && grep -q 'stale bundle' '$T/stale.err' && [ \$(grep -c '^bb pr comments' '$BBSTUB/calls.log') -eq 0 ]"
rc=0; "$h/tools/review-post.sh" "$pb" --progress >/dev/null 2>&1 || rc=$?
check "stale bundle: --progress refused too" bash -c "[ $rc -ne 0 ] && [ \$(grep -c '^bb pr comments' '$BBSTUB/calls.log') -eq 0 ]"

# --- inline comments on open file:line findings; resolve those threads --------
pi="$T/pi"; dh="$(mkbundle "$pi")"
mkdir -p "$pi/findings"
cat >"$pi/findings/c1.json" <<'EOF'
{"concern":"c1","status":"issues","notes":"n","findings":[
  {"severity":"major","file":"models/a/x.sql","line":2,"title":"Needs a guard","detail":"because","suggestion":"add one","prior":"new"},
  {"severity":"minor","file":"models/a/x.sql","line":null,"title":"Whole file","detail":"d"},
  {"severity":"nit","file":"tool.py","line":1,"title":"Already fixed","detail":"d","prior":"addressed"},
  {"severity":"minor","file":"../etc/passwd","line":1,"title":"Bad path","detail":"d"}
]}
EOF
pr_json "${dh:0:12}"; : >"$BBSTUB/calls.log"
"$h/tools/review-post.sh" "$pi" >/dev/null 2>"$T/pi.err" || { cat "$T/pi.err" >&2; fail "inline post exits"; }
check "inline: summary comment id stays the general comment" test "$(cat "$pi/comment.id")" = 501
check "inline: one general add and one --line-to" bash -c "[ \$(grep -c '^bb pr comments add 7' '$BBSTUB/calls.log') -eq 2 ] && grep -q -- '--file models/a/x.sql --line-to 2' '$BBSTUB/calls.log'"
check "inline: null line, addressed, and unsafe path are not posted" bash -c "[ \$(grep -c -- '--line-to' '$BBSTUB/calls.log') -eq 1 ]"
check "inline-comments.json records id 601 unresolved" python3 -c "
import json, os
rows=json.load(open('$pi/inline-comments.json'))
assert len(rows)==1 and rows[0]['id']=='601' and rows[0]['file']=='models/a/x.sql'
assert rows[0]['line']==2 and rows[0]['resolved'] is False and rows[0]['key']
body=open(os.path.join('$pi/.inline', os.listdir('$pi/.inline')[0]), encoding='utf-8').read()
assert 'wtc-review-inline v1 key=%s' % rows[0]['key'] in body
"
: >"$BBSTUB/calls.log"
"$h/tools/review-post.sh" "$pi" >/dev/null 2>&1 || true
check "inline: re-post updates the summary and does not duplicate the thread" bash -c "grep -q '^bb pr comments edit 7 501' '$BBSTUB/calls.log' && [ \$(grep -c -- '--line-to' '$BBSTUB/calls.log') -eq 0 ]"
: >"$BBSTUB/calls.log"
"$h/tools/review-resolve.sh" "$pi" --reply "Addressed in abc." >/dev/null 2>"$T/resolve.err" || { cat "$T/resolve.err" >&2; fail "resolve exits"; }
check "resolve replies then resolves the inline thread" bash -c "grep -q '^bb pr comments reply 7 601' '$BBSTUB/calls.log' && grep -q '^bb pr comments resolve 7 601' '$BBSTUB/calls.log'"
check "resolve records resolved and does not touch the summary comment" python3 -c "
import json; rows=json.load(open('$pi/inline-comments.json'))
assert rows[0]['resolved'] is True and rows[0]['id']=='601'
"
: >"$BBSTUB/calls.log"
"$h/tools/review-resolve.sh" "$pi" >/dev/null 2>&1 || true
check "resolve is a no-op once the thread is resolved" bash -c "[ \$(grep -c '^bb pr comments resolve' '$BBSTUB/calls.log' || true) -eq 0 ]"
rc=0; "$h/tools/review-resolve.sh" "$pi" --file models/a/x.sql --line 9 >/dev/null 2>&1 || rc=$?
check "resolve: a filter that matches nothing fails" test "$rc" -ne 0

pi2="$T/pi2"; mkbundle "$pi2" >/dev/null
mkdir -p "$pi2/findings" "$pi2/prior"
cat >"$pi2/findings/c1.json" <<'EOF'
{"concern":"c1","status":"issues","notes":"n","findings":[
  {"severity":"minor","file":"tool.py","line":4,"title":"Still there","detail":"d","prior":"still-open"}
]}
EOF
python3 "$h/tools/review_lib.py" inline-plan "$pi2" >"$T/pi2.plan"
key="$(python3 -c 'import json; print(json.loads(open("'"$T/pi2.plan"'").readline())["key"])')"
printf 'earlier\nwtc-review-inline v1 key=%s concern=c1 file=tool.py line=4\n' "$key" >"$pi2/prior/comments.md"
pr_json "${dh:0:12}"; : >"$BBSTUB/calls.log"
"$h/tools/review-post.sh" "$pi2" >/dev/null 2>&1 || true
check "inline: a key already in prior/comments.md is not posted again" bash -c "[ \$(grep -c '^bb pr comments add 7' '$BBSTUB/calls.log') -eq 1 ] && [ \$(grep -c -- '--line-to' '$BBSTUB/calls.log') -eq 0 ]"

# --- review-run --post: progress first, then the same comment updated ----------
mkrun() { # <dir> — copy of the first bundle, pointed at PR 7
  cp -R "$bd" "$1"; rm -rf "$1/comment.id" "$1/findings" "$1/stats" "$1/summary.md" "$1/verdict"
  sed -i.bak -e "s/^PR=.*/PR=7/" -e "s/^FORGE=.*/FORGE=bitbucket/" -e "s#^SLUG=.*#SLUG=x/demo#" "$1/manifest.env"; rm -f "$1/manifest.env.bak"
}
dhead="$(. "$bd/manifest.env" && printf '%s' "$HEAD_SHA")"   # the head the copied bundle was built for
rb="$T/rb"; mkrun "$rb"
pr_json "${dhead:0:12}"; : >"$BBSTUB/calls.log"
rc=0; "$h/tools/review-run.sh" "$rb" --post --only t-ok,t-sql >/dev/null 2>"$T/rb.err" || rc=$?
[ "$rc" -eq 0 ] || cat "$T/rb.err" >&2
check "run --post exits 0" test "$rc" -eq 0
check "run --post: exactly one comment created, then updated in place" test "$(count '^bb pr comments add 7')" -eq 1 -a "$(count '^bb pr comments edit 7 501')" -ge 1
check "run --post: progress comment came first" bash -c "grep -n '^bb pr comments' '$BBSTUB/calls.log' | head -n1 | grep -q 'add 7.*in progress'"
check "run --post: final update carries Run stats + final status line" bash -c "grep -A80 '^bb pr comments edit 7 501' '$BBSTUB/calls.log' | grep -q 'Run stats' && grep -q 'verdict=pass blockers=0 round=1' '$BBSTUB/calls.log'"
check "run --post: comment.id stored in the bundle" test "$(cat "$rb/comment.id")" = 501
check "run --post: never undrafts" test "$(count '^bb pr ready')" -eq 0

rf="$T/rf"; mkrun "$rf"; : >"$BBSTUB/calls.log"
rc=0; FAKE_LEAD_FAIL=1 "$h/tools/review-run.sh" "$rf" --post --only t-ok >/dev/null 2>&1 || rc=$?
check "failed run: exit non-zero" test "$rc" -ne 0
check "failed run: comment updated to failed with verdict=error" bash -c "grep -q '^bb pr comments add 7.*in progress' '$BBSTUB/calls.log' && grep -q '^bb pr comments edit 7 501' '$BBSTUB/calls.log' && grep -q 'Local review: failed' '$BBSTUB/calls.log' && grep -q 'verdict=error' '$BBSTUB/calls.log'"

rs="$T/rs"; mkrun "$rs"; pr_json "${O40:0:12}"; : >"$BBSTUB/calls.log"
rc=0; "$h/tools/review-run.sh" "$rs" --post --only t-ok >/dev/null 2>&1 || rc=$?
check "run --post on a stale bundle: refuses before any agent runs, posts nothing" bash -c "[ $rc -ne 0 ] && [ \$(grep -c '^bb pr comments' '$BBSTUB/calls.log') -eq 0 ] && [ ! -e '$rs/findings/t-ok.json' ]"

# --- guard-pr-ready: shell-aware parsing ---------------------------------------
deny_case  'bash -c "bb pr ready 3"'
deny_case  "sh -c 'gh pr ready 4'"
deny_case  'bash -lc "cd x && bb pr ready 1"'
deny_case  'eval "bb pr ready 5"'
deny_case  'echo hi | bb pr ready 6'
deny_case  'true || bb pr ready 8'
deny_case  'echo $(bb pr ready 9)'
deny_case  $'ls\nbb pr ready 7'
deny_case  'echo "unbalanced; bb pr ready 1'
allow_case 'git commit -m "note: bb pr ready is gated"'
allow_case "git commit -m 'run bb pr ready later'"
allow_case 'echo "bb pr ready"; ls'
allow_case 'grep -rn "gh pr ready" hooks/'
allow_case $'git commit -m "$(cat <<\'EOF\'\nbb pr ready is blocked\nEOF\n)"'
allow_case 'bash -c "echo hello"'

# --- limit fallback: first agent in the list is skipped, the next runs -------
fl="$T/fl"
cp -R "$bd" "$fl"
rm -rf "$fl/findings" "$fl/stats" "$fl/summary.md" "$fl/verdict" "$fl/.logs" "$fl/run.log"
rc=0
FAKE_LIMIT_AGENT=codex "$h/tools/review-run.sh" "$fl" --only t-ok \
  --standard 'codex:,claude:sonnet' --lead claude:sonnet >/dev/null 2>"$T/fl.err" || rc=$?
[ "$rc" -eq 0 ] || { echo "--- fl.err" >&2; cat "$T/fl.err" >&2; }
check "limit: run exits 0 via the fallback agent" test "$rc" -eq 0
check "limit: codex is skipped and claude:sonnet runs" grep -q 'limit on codex: — trying claude:sonnet' "$fl/run.log"
check "limit: verdict still posted in the summary" grep -q 'verdict=pass ' "$fl/summary.md"

# --- summary color, hunk links, collapsed secondary sections ------------------
pbx="$T/present"
mkdir -p "$pbx"
printf 'FORGE=bitbucket\nURL=%s\nHEAD_SHA=%s\nSLUG=x/demo\n' \
  'https://example.invalid/proj/pull-requests/7' "$H40" >"$pbx/manifest.env"
cat >"$pbx/summary.md" <<EOF
**Local review: pass-with-notes** — round 2

### Major

- \`tools/review-run.sh:12\` — something

### Minor / nits

- small

### Run stats

| a | b |
EOF
printf '\n`wtc-review v1 head=%s verdict=pass-with-notes blockers=0 round=2 lead=codex:`\n' "$H40" >>"$pbx/summary.md"
python3 "$h/tools/review_lib.py" present "$pbx"
check "summary: verdict is marked" grep -q '🟡 \*\*Local review: pass-with-notes\*\*' "$pbx/summary.md"
check "summary: file:line links to the source line" grep -q "src/$H40/tools/review-run.sh#lines-12" "$pbx/summary.md"
check "summary: bitbucket keeps minor and run stats as headings" bash -c "! grep -q '^\`\`\`expand$' '$pbx/summary.md' && grep -q '^### Minor / nits$' '$pbx/summary.md' && grep -q '^### Run stats$' '$pbx/summary.md'"
check "summary: readable status sits outside the gate record" bash -c "
  pretty=\$(grep -n '· round 2 ·' '$pbx/summary.md' | head -n1 | cut -d: -f1)
  stamp=\$(grep -n '^### Gate record$' '$pbx/summary.md' | head -n1 | cut -d: -f1)
  test -n \"\$pretty\" && test -n \"\$stamp\" && test \"\$pretty\" -lt \"\$stamp\"
"
check "summary: machine line stays in the file for the gate" grep -q "wtc-review v1 head=$H40 verdict=pass-with-notes blockers=0 round=2 lead=codex:" "$pbx/summary.md"
printf 'FORGE=github\nSLUG=x/demo\nHEAD_SHA=%s\n' "$H40" >"$pbx/manifest.env"
printf '**Local review: changes-requested**\n\n### Minor / nits\n\n- n\n' >"$pbx/summary.md"
python3 "$h/tools/review_lib.py" present "$pbx"
check "summary: github folds with details, verdict marked" bash -c "grep -q '🔴 \*\*Local review: changes-requested\*\*' '$pbx/summary.md' && grep -q '<details>' '$pbx/summary.md' && grep -q '<summary>Minor / nits</summary>' '$pbx/summary.md'"

# --- a named PR is reviewed on that PR's branch --------------------------------
git -C "$demo" switch -q -c side
pr_json "$(git -C "$demo" rev-parse feature)"
co_rc=0
"$B" demo 7 --no-catch-up >/dev/null 2>"$T/co.err" || co_rc=$?
[ "$co_rc" -eq 0 ] || { echo "--- co.err" >&2; cat "$T/co.err" >&2; }
check "PR review checks out the PR branch" test "$(git -C "$demo" branch --show-current)" = feature
check "PR review says which branch it checked out" grep -q 'checking out feature for PR #7' "$T/co.err"
check "PR review with --no-catch-up does not catch up" bash -c "! grep -q 'catch-up before review' '$T/co.err'"

# A valid findings file does not excuse a nonzero agent exit.
wf="$T/wf"
cp -R "$bd" "$wf"
rm -rf "$wf/findings" "$wf/stats" "$wf/summary.md" "$wf/verdict" "$wf/.logs" "$wf/run.log"
FAKE_WRITE_AND_FAIL=1 "$h/tools/review-run.sh" "$wf" --only t-ok >/dev/null 2>"$T/wf.err" || true
check "nonzero exit with valid findings stays an error" grep -q 'agent exited' "$wf/findings/t-ok.json"
check "rejected findings file is kept as raw" test -s "$wf/findings/t-ok.raw"
lf="$T/lf"
cp -R "$bd" "$lf"
rm -rf "$lf/findings" "$lf/stats" "$lf/summary.md" "$lf/verdict" "$lf/.logs" "$lf/run.log"
rc=0
FAKE_LEAD_WRITE_AND_FAIL=1 "$h/tools/review-run.sh" "$lf" --only t-ok >/dev/null 2>"$T/lf.err" || rc=$?
check "nonzero lead exit fails the run even when summary files exist" test "$rc" -ne 0
check "lead failure names the exit" grep -q 'lead run failed' "$T/lf.err"

# Default PR bundle runs catch-up after checkout; a failing catch-up stops it.
mv "$h/tools/catch-up.sh" "$h/tools/catch-up.sh.real"
cat >"$h/tools/catch-up.sh" <<'EOF'
#!/bin/bash
git -C "$DEMO_WT" branch --show-current >>"${BBSTUB}/catchup.log"
exit "${CATCHUP_RC:-0}"
EOF
chmod +x "$h/tools/catch-up.sh"
export DEMO_WT="$demo"
git -C "$demo" switch -q side
pr_json "$(git -C "$demo" rev-parse feature)"
: >"$BBSTUB/catchup.log"
cu_rc=0
"$B" demo 8 >/dev/null 2>"$T/cu.err" || cu_rc=$?
[ "$cu_rc" -eq 0 ] || { echo "--- cu.err" >&2; cat "$T/cu.err" >&2; }
check "default PR bundle runs catch-up on the PR branch" bash -c "[ $cu_rc -eq 0 ] && [ \"\$(cat '$BBSTUB/catchup.log')\" = feature ]"
git -C "$demo" switch -q side
cu_rc=0
CATCHUP_RC=1 "$B" demo 8 >/dev/null 2>"$T/cu2.err" || cu_rc=$?
check "failing catch-up stops the bundle" bash -c "[ $cu_rc -ne 0 ] && grep -q 'catch-up failed' '$T/cu2.err'"
mv "$h/tools/catch-up.sh.real" "$h/tools/catch-up.sh"

[ "$fails" -eq 0 ] || { echo "--- b2.err" >&2; cat "$T/b2.err" >&2; ls "$bd2" >&2; }
if [ "$fails" -gt 0 ]; then
  echo "$fails test(s) failed, $passed passed" >&2
  echo "TALLY $passed $fails"
  exit 1
fi
echo "all review tool tests passed ($passed assertions)"
echo "TALLY $passed $fails"
