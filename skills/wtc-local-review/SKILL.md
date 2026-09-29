---
name: wtc-local-review
description: >-
  Self-review gate for a draft PR — bundle the diff, run a separate headless
  multi-concern review, post the summary and inline comments, address and
  resolve findings, re-run, then undraft through the gate. Use for "review
  before ready", "self-review", "follow the review", /wtc-local-review,
  "request another review", or before undrafting a PR.
---

# Local review gate (draft → ready)

A draft PR becomes ready only after a **separate headless reviewer run** has
posted its summary on the PR's **current head**. Contract, bundle layout,
schemas: `review/README.md`.

**You are not the reviewer.** This skill drives the tools; the review is a
fresh process started by `tools/review-run.sh`. Never review "in-thread" as a
substitute, and never write or edit `summary.md` / `verdict` yourself — the
point is an opinion that does not share your context. An in-thread
reading of the diff does not gate.

## Steps (from `harness/`)

1. **Pick the PR(s)** — `tools/wtc-pr.sh list`. One repo the user named, or
   each enlisted PR of the collection (one bundle and run per PR).
2. **Bundle** — `tools/review-bundle.sh <repo> [<n>]`; the last stdout line is
   the bundle dir. When a PR number is known this **checks out that PR's
   branch** (if the worktree is on another branch) and **runs `tools/catch-up.sh`
   first**. `--no-catch-up` skips only the catch-up. PR number defaults to the
   enlisted one. Rounds and prior summaries/comments are picked up
   automatically.
   For a public or unknown-audience PR, pass `--public` so related PR patches
   and dependency snapshots stay out of the bundle. Inspect the remaining
   bundle for private identities before giving it to an external reviewer.
3. **Push** if catch-up or local commits left the branch ahead of the remote.
   The review must match the remote head or posting refuses:
   `git -C ../<repo> push` (feature branch only; `wtc-draft-pr` targets).
   If you pushed, bundle again so the diff is that head.
4. **Run** — `tools/review-run.sh <dir> --post` for a private PR. It first posts an
   "in progress" comment on the PR (round, head, concerns, agent:model), runs
   one agent per concern and a lead (minutes), then **updates that same
   comment** with the summary — no second summary comment; on failure the
   comment becomes "failed". It also posts **one inline comment per open
   finding** that has a file and a new-file line (`<dir>/inline-comments.json`).
   Posting is part of this workflow (the gate reads the summary comment); tell
   the user it was posted, including how many inline threads. For a public or
   unknown-audience PR, run without `--post`, inspect `summary.md` and every
   planned inline comment, then post with `tools/review-post.sh <dir>` after
   removing private context. The gate stays closed until that post. It refuses a
   stale bundle before spending any agent time. Start it in the background
   (`run_in_background`, a herdr pane, or equivalent) and wait for completion;
   do not poll `run.log` in a loop. Several PRs may run concurrently.
5. **Read** `<dir>/summary.md` and `<dir>/verdict`. A concern that errored is
   listed in the table; check `<dir>/run.log` / `findings/<id>.raw` if the
   cause is not obvious. The `### Run stats` section gives time, tokens and
   cost per agent run (`<dir>/stats/*.json`); mention the total to the user.
6. **Post** — automatic with `--post` for private PRs. Standalone: `tools/review-post.sh <dir>`
   creates or updates the summary in `<dir>/comment.id` and posts any missing
   inline comments. `tools/review-post.sh <dir> --progress` posts only the
   progress comment (no inline comments).
7. **Follow the review in this same thread. Do not stop to ask whether to.**
   For every open finding:
   - agree → fix and commit on the PR branch;
   - disagree / out of scope → the reply *is* the answer; do not change code.
   Then resolve each inline thread you have answered (fix or reply). Never
   resolve the summary comment — the gate reads it.
   A finding carried into a later round keeps its original inline thread;
   use the bundle from the round that first posted that thread when resolving
   it. Later bundles retain its key to avoid creating a duplicate thread.
   ```bash
   tools/review-resolve.sh <dir> --file path/in/repo --line N --reply "Addressed in <sha>."
   tools/review-resolve.sh <dir> --reply "Addressed in <sha>."   # every open thread in the bundle
   ```
   A finding with no line lives only in the summary; reply on that comment
   (`bb pr comments reply <n> <comment.id> "…"`) and do not resolve it.
   The next round reads replies from `prior/comments.md`. Decisions worth
   keeping go to the bean.
8. **Push and re-run** (steps 2–7; a new bundle means a new summary comment).
   A push after the review makes it `stale` — the gate needs another round.
   Stop when the latest verdict is `pass`, or `pass-with-notes` and every
   remaining finding is one you have already answered and do not agree to
   change. Do not loop on nits you have already replied to.
9. **Undraft only when the user asks**:
   `tools/bb-pr-ready.sh <n>` (run inside the repo worktree). It refuses when
   the review is stale, missing, or `changes-requested`. Raw `bb pr ready` is
   blocked by a hook. Override only with the user's words:
   `tools/bb-pr-ready.sh <n> --user-authorized "<verbatim quote>"`.
   Undrafting is not merging — merge stays `wtc-pr` + `bb-pr-merge.sh`.

`tools/review-status.sh <repo> <n>` shows `current|stale|none` + verdict at
any time. `pending` (a run is in flight) and `error` (a run failed) never open
the gate.
The ready gate also requires the local receipt written by `review-post.sh`;
a status line in a comment posted by another path does not satisfy it.

## Multi-repo

Run per enlisted PR. Each bundle carries the other enlisted PRs as
`related/*.patch`, and snapshots of consumers (`downstream:` in
`.harness-repos.yml`) at their production ref and PR head, so
backwards-compat concerns judge both deploy orders. Run `tools/catch-up.sh`
first if refs may be stale. Post each summary on its own PR.

## Config

- Tiers in `$WTC_CONFIG_ROOT/wtc.env`: `HARNESS_REVIEW_STRONG`,
  `_STANDARD`, `_FAST`, `_LEAD`. Each value is `agent:model` or a comma- or
  space-separated list tried in order when a run hits a token or session
  limit (`grok:,codex:,claude:opus`). Agents: `claude`, `codex`, `grok`.
  Each person lists the CLIs they have. Concerns and the lead are separate,
  so concerns can start on grok and the lead can stay on a stronger spec.
  `HARNESS_REVIEW_GROK_EFFORT` defaults to `low` so a grok concern does not
  sit for a quarter of an hour. Also `HARNESS_REVIEW_PARALLEL`,
  `HARNESS_REVIEW_TIMEOUT`.
- Per run: `tools/review-run.sh <dir> --strong grok: --lead codex:` —
  e.g. a cross-vendor second opinion when the user asks for one.

## Concerns

Layers, later wins by `id`: `review/concerns/` (shipped with the harness) →
`review/concerns.d/` (this collection's drop-in, not part of the generic
tree) → `<repo>/.review/concerns/<id>.md` (read from the base commit). A repo
file with the same `id` overrides; one with `applies: never` disables that
concern for the repo. Frontmatter: `id`, `title`, `tier`, `applies`, optional
`needs: downstream`.

---
Canon: `review/README.md`. See also: `wtc-draft-pr`, `wtc-pr`.
