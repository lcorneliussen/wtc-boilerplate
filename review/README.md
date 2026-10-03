# Local review — contract

A draft PR is promoted to *ready* only after a review by a **separate headless
agent run** (claude, codex, …) whose summary is posted to the PR as a comment.
The authoring thread reads that comment, fixes or answers, resolves the inline
threads, pushes, and runs another round — in the same session, without a
separate ask. The same mechanism is meant to run on a server later: nothing
here depends on an interactive session, a collection, or a particular forge
beyond `wtc review post` / `wtc review status`.

The concerns shipped in this tree are generic: no organisation, repo, or
product names. A deployment adds its own in `concerns.d/`; a repo adds its
own under `.review/concerns/`.

## Pieces

| Piece | Role |
|---|---|
| `skills/wtc-local-review/` | main-thread procedure: bundle → run → read → post → fix → resolve inline threads → re-run |
| `wtc review bundle` | builds a review bundle (diff, PR text, concerns, downstream snapshots, prior rounds) |
| `wtc review run` | fans out one headless agent per concern, then one lead pass; writes `summary.md` + `verdict` + per-run stats; `--post` runs the comment lifecycle |
| `wtc review post` | creates or updates the bundle's one summary comment (bb or gh): `--progress`, final summary, `--failed`; a summary post also adds inline comments |
| `wtc review resolve` | replies to and resolves the bundle's inline threads (not the summary comment) |
| `wtc review status` | reads the latest review comment on a PR: `current|stale|none` + verdict (incl. `pending` / `error`) |
| `wtc review ready` | the gate: undrafts only when the review is current and its verdict is `pass` or `pass-with-notes` |
| `prompts/concern.md` | prompt for one concern run |
| `prompts/lead.md` | prompt for the aggregation run |
| `concerns/*.md` | generic concerns (always shipped) |
| `concerns.d/*.md` | optional drop-in concerns for one deployment; not shipped here |
| `<repo>/.review/concerns/*.md` | repo concerns, read from the review base commit |

The reviewer is **not** a skill. A reviewer run is a fresh process told by its
prompt what it is; it never delegates to another harness, so there is no mode
detection and no recursion.

Agents must use `wtc review ready` for undrafting; that command enforces the
current-review check. A shell hook cannot reliably police arbitrary commands
that invoke a forge CLI, so the review procedure is an agent instruction.

## Concern files

```markdown
---
id: backwards-compat          # unique; a later layer with the same id replaces an earlier one
title: Backwards compatibility with downstream
tier: strong                  # strong | standard | fast  → model via HARNESS_REVIEW_<TIER>
applies: always               # always | space-separated globs matched against changed paths
needs: downstream             # optional: downstream — skip (status "skipped") when the bundle has none
---
What to check, what evidence to look at in the bundle, and what counts as
blocker / major / minor / nit for this concern.
```

Layer order, later wins by `id`: `review/concerns/` → `review/concerns.d/` →
`<repo>/.review/concerns/` at the review base commit. The PR cannot change
its own review criteria; when the harness itself is reviewed, its generic
concerns also come from the base commit if present. An initial review of a
harness that has no base concerns uses the new concern files. The `.d` is the
usual drop-in directory pattern
(same idea as `cron.d`): concerns dropped in that directory override a generic
concern with the same `id`. That directory is a local overlay, not part of
this repository.
A base-commit repo file with `applies: never` disables a concern.

## Model selection

Each tier is an `agent:model` spec, or a comma- or space-separated list of
them. Empty model means the agent's own default. The runner tries the list in
order and moves to the next spec only when the output says the run stopped for
a token, session, or rate limit. Any other failure stops there.

| Variable (`$WTC_CONFIG_ROOT/wtc.env`) | Default | Used for |
|---|---|---|
| `HARNESS_REVIEW_STRONG` | `claude:opus` | `tier: strong` concerns |
| `HARNESS_REVIEW_STANDARD` | `claude:sonnet` | `tier: standard` |
| `HARNESS_REVIEW_FAST` | `claude:haiku` | `tier: fast` |
| `HARNESS_REVIEW_LEAD` | `$HARNESS_REVIEW_STRONG` | aggregation pass |
| `HARNESS_REVIEW_PARALLEL` | `4` | concurrent concern runs |
| `HARNESS_REVIEW_TIMEOUT` | `900` | seconds per agent run |
| `HARNESS_REVIEW_GROK_EFFORT` | `low` | `grok --reasoning-effort` |

Example: `HARNESS_REVIEW_STRONG=grok:,codex:,claude:opus` tries grok, then
codex, then claude opus, and only moves on when that run hits a limit.
`wtc review run --strong grok: --lead codex:` overrides one run. Concerns and
the lead are separate lists, so a machine can run the concerns on one agent
and the final pass on another. Each machine sets the list for the CLIs it
actually has; an entry whose binary is missing fails that run.

Supported agents: `claude` (`claude -p --output-format json --model M`),
`codex` (`codex exec --json -m M`), `grok` (`grok --prompt-file P
--output-format json --sandbox workspace`). The runner parses their machine
output for stats and keeps the human text (claude: `.result`; codex: the
agent messages; grok: `.text`) in `run.log` and, on a failed run, in
`findings/<id>.raw`.
`WTC_REVIEW_AGENT_CMD` replaces the launcher entirely (tests, servers): it is
run as `$WTC_REVIEW_AGENT_CMD <agent> <model> <prompt-file> <cwd>`. The runner
sets `WTC_REVIEW_STATS_FILE` (= `<bundle>/stats/<id>.json`); the command may
write its own stats JSON there (fields below). Missing stats mean seconds only.

Claude reviewers get `Read Grep Glob Write Edit`, `git log`, `git show`, `ls`;
`git diff` is left out (the diff is in the bundle) and file-writing git options
(`--output=<file>`, also abbreviated) are denied for the rest. codex runs in a
`workspace-write` sandbox rooted at the bundle. grok runs in its `workspace`
sandbox (read the repo, write only in the bundle) with web tools off, and
passes `--reasoning-effort` from `HARNESS_REVIEW_GROK_EFFORT` (default `low`).
The CLI's own default spends many minutes and a lot of output tokens on one
concern. A faster model id such as `grok-4.7-build-fast` is a further notch
when that CLI lists it.

## Bundle layout

Default location `<collection>/.wtc-reviews/<repo>-pr<N>-<sha7>-r<round>/`
(disposable, dies with the collection); `--dir` overrides (servers, tmp).

```text
manifest.env        REPO PR FORGE URL BASE_REF BASE_SHA HEAD_SHA HEAD_BRANCH ROUND REPO_DIR COLLECTION
pr.md               PR title + description (empty body allowed for branch-only runs)
diff.patch          git diff BASE_SHA...HEAD_SHA
changed-files.txt   one path per line
log.txt             git log --oneline BASE_SHA..HEAD_SHA
concerns/<id>.md    only the concerns that apply to this diff (resolved layers)
prior/r<k>.md       earlier review summaries for this PR, oldest first
prior/comments.md   other PR comments since the last review (replies to findings)
prior/inline-keys.txt  keys from all earlier inline comments, across rounds
related/<repo>-pr<N>.patch   other PRs enlisted in the same collection (cross-PR context)
downstream/<repo>/old/       snapshot (git archive) of the downstream repo at its production ref
downstream/<repo>/new/       snapshot at its enlisted PR head, when there is one
downstream/<repo>/REFS       which refs/SHAs old/new are
upstream/<repo>/{old,new}/   same, for repos this one consumes (their `downstream:` lists this repo)
upstream/<repo>/REFS         which refs/SHAs old/new are
findings/<id>.json  written by each concern run (or by the runner: error / skipped stubs)
stats/<id>.json     per agent run (concerns and `lead`), written by the runner:
                    {agent, model, seconds, input_tokens, output_tokens,
                     cache_read_tokens, cache_write_tokens, cost_usd|null,
                     turns|null, status: ok|error|timeout|skipped}
summary.md          lead output + `### Run stats` + status line (assembled by wtc review run)
verdict             one word: pass | pass-with-notes | changes-requested
comment.id          id of the bundle's summary comment (written by wtc review post)
inline-comments.json  one row per inline thread: key, concern, file, line, severity,
                    title, id, url, error, resolved (written by wtc review post /
                    wtc review resolve)
.inline/            bodies of the inline comments, for the poster
progress.md         the last "in progress" body; failed.md the last "failed" body
lead.spec           the lead's agent:model for this run
run.log             launcher output, for debugging
```

`downstream` comes from the registry: `downstream: <repo> [<repo>…]` on a repo
entry in `.harness-repos.yml` names the repos that consume it. Snapshots are
read-only exports, not worktrees — nothing to clean up in the git owners.
For a public or unknown-audience PR, `wtc review bundle --public` omits
upstream/downstream snapshots and related PR patches. Inspect the bundle
before an external review run, then inspect the generated summary and inline
comment bodies before posting them.

## Findings schema (`findings/<id>.json`)

```json
{
  "concern": "backwards-compat",
  "status": "ok | issues | skipped | error",
  "notes": "one paragraph: what was checked and how",
  "findings": [
    {
      "severity": "blocker | major | minor | nit",
      "file": "path/in/repo",
      "line": 42,
      "title": "short claim",
      "detail": "why, with evidence from the bundle",
      "suggestion": "optional concrete fix",
      "prior": "optional: new | still-open | addressed — only on re-review"
    }
  ]
}
```

A run that does not produce valid JSON is recorded by the runner as
`status: error` with the raw output in `findings/<id>.raw`.

## Verdict rule (lead)

- The lead can refute a finding by setting `prior: "addressed"`, or lower its
  `severity`, in `findings/<id>.json`. It must explain the decision in the
  summary. The runner counts open blockers after those dispositions and forces
  `changes-requested` if any remain, even when the lead wrote a passing verdict.
- any open `blocker` → `changes-requested`
- `major` findings, no blockers → `pass-with-notes` unless the lead judges them
  merge-stopping, then `changes-requested`
- otherwise `pass`
- a concern with `status: error` never silently passes: it is listed, and the
  verdict is at best `pass-with-notes`

## Posted comment

`summary.md` is posted after the presenter marks the verdict, links
`` `path:line` ``, and folds secondary sections. The comment ends with a
readable footer — verdict, short head, round, blockers, and who ran — and,
under a **Gate record** heading, the line the tools parse:

```text
`wtc-review v1 head=<sha40> verdict=<verdict> blockers=<n> round=<k> lead=<agent:model>`
```

`head=` is 12 to 40 hex chars; tools write the full 40. `wtc review status` finds
the newest comment with that line: `current` when the PR's head (a 12+ char id
from the forge) is a prefix of `head=` (never the other way round, never
shorter than 12), else `stale`; `none` if there is no such comment.
`wtc review post` also writes a local receipt keyed by forge, repository, PR,
head, comment id and verdict under `<collection>/.wtc-review-posted/`.
`wtc review status --trusted-local` requires that receipt and reports
`untrusted` when the newest status comment lacks it. The ready gate uses this
mode, so another commenter cannot satisfy it by copying a status line.
The receipt is collection-local; a different machine needs its own review
bundle and post before its ready gate can pass.

### Comment lifecycle (one comment per bundle)

`wtc review run <dir> --post` (the skill's default flow):

1. **before** any agent starts: `⏳ **Local review: in progress**` — round, head
   (7 chars), concerns with tier and agent list, start time — ending in the
   readable footer with `verdict=pending`, and the machine line under a Gate
   record heading. That published comment is the
   pending review: forges have no separate "review in progress" state others
   can see. The comment id goes to `<bundle>/comment.id`. The stale-head check
   applies: a bundle whose head is not the PR head is refused before any agent
   time is spent.
2. **at the end**: that same comment is *updated* with `summary.md`. The poster
   marks the verdict (🟢 pass, 🟡 pass-with-notes, 🔴 changes-requested), turns
   `` `path:line` `` into a source link (`#lines-N` on Bitbucket, `#L` on
   GitHub), and keeps Minor, Concerns, Addressed and Run stats as headings on
   Bitbucket (an expand fence collapses there, and the Markdown inside it is
   not rendered). GitHub collapses those sections with `<details>`. Inline comments
   carry the same severity mark and sit on the diff line. No second summary
   comment.
3. **on failure**: the same comment becomes `❌ **Local review: failed**` with the
   reason and the redacted tail of `run.log`, status line `verdict=error`.

`wtc review post <dir>` creates when there is no `comment.id`, else updates
(Bitbucket: REST `PUT …/comments/<id>` with the bb credentials, fallback
`bb pr comments edit`; GitHub: `gh api -X PATCH …/issues/comments/<id>`).
`wtc review post <dir> --progress` posts only the progress comment.
`WTC_REVIEW_NO_API=1` forces the CLI fallback (tests, no REST credentials).

### Inline comments

A summary post (not `--progress` or `--failed`) also posts one inline comment
for each open finding that has a repo-relative `file` and a positive `line`.
`line` is the new-file line. `prior: addressed`, a missing line, and paths
that leave the repo are skipped. The body ends with:

```text
`wtc-review-inline v1 key=<10 hex> concern=<id> file=<path> line=<n>`
```

`key` is a hash of concern, file, line and title. A finding already recorded
in `inline-comments.json` with an id, or whose key already appears in
`prior/comments.md`, is not posted again. A failed inline post is a warning:
the summary comment still stands, and the row keeps `error` and an empty id
so a later summary post retries it.

`wtc review resolve <bundle> [--reply TEXT] [--file PATH --line N]`
replies (optional) and resolves those threads. It does not resolve the
summary comment. The authoring thread does this after fixing or answering,
then pushes and starts another round. Undrafting stays a separate, explicit
step.
When a finding remains open across rounds, its inline thread belongs to the
bundle that first posted it. Resolve it with that bundle; later bundles keep
its key to avoid posting the same finding again.

`pending` and `error` exist only in the status line: a lead never writes them
and they never open the gate. If the newest status comment is `pending`, that
is what `wtc review status` reports, even when an older review of the same head
was complete — a run is in flight.

### Run stats

`summary.md` carries a `### Run stats` table before the status line: concern,
`agent:model`, time (`4m12s`), tokens in / out (cache read) (`182k / 9.1k
(1.2M)`), cost, a total row, and the wall-clock of the whole run. Claude reports
real usage and cost; codex usage is summed from its `turn.completed` events (no
cost); grok reports usage and cost on its JSON result; anything unknown shows `-`.

## Gate

`wtc review ready <n>` undrafts only when `wtc review status` reports
`current`, zero open blockers, and a verdict of `pass` or `pass-with-notes` — `changes-requested`,
`pending` (a run is in flight) and `error` (it failed) stay closed. Anything else needs
`--user-authorized "<the user's words>"`.
Undrafting still happens only when the user asks for it; the gate adds a
precondition, it does not add an automatic step.
