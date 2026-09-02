---
name: wtc-status
description: Report where every worktree collection stands — branches, open PRs and their check rollups, working-tree state, and what is running under the herdr session. Use when the user asks what is in flight, which wtcs exist, what is red or blocked, whether a PR is green, or what they should pick up next.
---

# Where does everything stand

Answers "what is in flight" across the workspace, without touching anything.
Read-only.

Ported from the Steep reference status stack (`port/status-from-steep`) —
LOCAL columns, compact two-line rows, `.wtc-status.json`/`.md` snapshots,
forge-only clicks. The previous boilerplate-native implementation is kept as
`tools/wtc-status-legacy.sh` / `wtc-status-legacy-tui.sh` for reference; it is
not wired into `wtc-open.sh` or `retire.sh`.

## One collection

```bash
harness/tools/wtc-status.sh
```

Prints, per repo in the collection: branch, open PR with its check rollup
(`✓ ✗ ● —`), and working-tree state. Bare is the command to reach for: scope
is this collection, and `--repos` / `--watch` / `--no-click` default from
`$WTC_CONFIG_ROOT/wtc.env`. Captured output prints one pass, so reading the
table from an agent shell never hangs on a watch loop.

```bash
harness/tools/wtc-status.sh --json     # canonical snapshot JSON
harness/tools/wtc-status.sh --md       # agent markdown
harness/tools/wtc-status.sh --cached   # last snapshot; no git, no forge round trip
```

When scoped to one collection, a run also writes `<collection>/.wtc-status.json`
(canonical), `.wtc-status.md` (agent view), and `.last-wtc-status.yml`
(boilerplate's own cache format, kept in step with the other two). `--cached`
reads `.wtc-status.json` back — falling back to `.last-wtc-status.yml` as a
plain listing if that is missing — rather than doing live work, and says how
old what it shows is.

## Everything at once

```bash
harness/tools/wtc-status.sh --all               # every collection
harness/tools/wtc-status.sh --procs             # processes under the herdr session
harness/tools/wtc-status.sh --repos --tui 120   # for a human to leave open
```

`--tui` (alias `--watch`) is for a pane a human is looking at — same as
running `wtc-status-tui.sh`. **Don't run a watch loop to answer a
question** — take the snapshot, answer, stop.

The collection table is clickable where both ends have a terminal — that's for
the human reading the pane, not for you. Every click opens the forge — the PR
page (number or `❯`), the branch page (`REPO`), or a pipeline (`T`/`P`, when
enabled) — nothing local (no nvim, no Octo, no lazygit). `?` toggles a key and
icon reference, `a` toggles merged PRs past 48 weekday-hours, `r` and the
watch interval reload in the background while the cached table stays visible.

## Reading it

The table fetches stale remote refs before measuring (age-gated, ~5 min), so
the numbers are current without you doing anything. `--no-fetch` when offline.

**BRANCH column**

- **`⌂ develop`** — detached at the development tip. This is the resting
  state, not a problem: no work is in flight in that worktree.
- **a branch name** — work in flight, or a branch whose PR has landed and
  hasn't been caught up yet.

**LOCAL column** — work that exists only here, split into its own cells:

- **`±N`** — N files not committed; a dim `·` for a clean tree.
- **`↑N`** — N commits on this branch not pushed yet.
- **`↓N`** — **N commits behind the development tip.** The catch-up signal,
  for a detached worktree and a branch alike: work started here would be
  built on stale ground. The footer counts them.

`T`/`P` pipeline glyphs (Bitbucket tip/prod builds) are hidden by default in
this fork — core boilerplate has no second forge wired in
(`forge_for_slug`/`pipe_facts` in `tools/lib.sh` are stubs). Set
`WTC_STATUS_PIPE=yes` to show them once something real backs `pipe_facts`.

**PR column**

`#N` followed by up to three status slots, each silent unless it has something
to say — so a healthy PR is just `#225 ✓`.

- **checks** — `✓` passing · `✗` failing · `●` running, nothing to conclude
  yet · `D` draft · `·` no checks reported
- **merge** — `↓` behind its base · `⚠` conflicts · `⊘` blocked · `·` merged
  (fading) · blank clean
- **review** — `✓` approved · `!` changes requested · `…` waiting on assigned
  reviewers · `✎` commented, not yet approved · dim red `◌` ready with no
  reviewers assigned (deliberately not the bold `⚠` merge conflicts use — a
  missing reviewer is not the same emergency) · `N` unresolved review threads
  · blank nothing outstanding

Blank overall means no open PR. Expected for `⌂` rows: nothing is in flight to
have one.

**PRS section** (scoped to one collection)

Lists the PRs enlisted for this collection in `<collection>/.wtc-prs`
(`tools/wtc-pr.sh enlist` — see the `wtc-pr` skill), not a forge label search —
so it costs no round trips beyond enriching what is already listed, and it is
still listed after the worktree has gone back to the tip. An open draft shows
a dim `◇ draft` badge — no shouting, since the inline `D` in the checks slot
already says it once. A **MERGED** PR fades rather than disappearing, and
after 48 weekday-hours since merge it collapses behind the `a` (archived)
toggle — `a` shows a count when there is anything hidden.

A worktree still sitting on a branch whose PR has already merged or closed is
called out in **amber** (`⚠ #N`) — the one thing an open-PRs-only view would
otherwise hide, and exactly what a catch-up clears.

Unscoped runs skip the section: it is one API call per repo per collection, and
a `--tui` pane doing that across every collection is a rate limit waiting to
happen.

A dirty tree in a collection nobody is working in is usually an interrupted
session. Worth surfacing; not yours to clean up.

Column widths hold steady for the life of a `--tui` process — once a column
has been as wide as some repo/branch/PR number needed, it does not shrink
back down just because a later render's content happened to be shorter.
One-shot runs always measure fresh.

## Then answer the actual question

Don't paste the table back. Say what is in flight, what is blocked and on
whom, what is green and merely waiting, and — if the user asked what to pick
up — which one, and why that one.

If a collection looks stale rather than blocked, the follow-up is
`wtc-catch-up`. If a wtc is finished, it is `wtc-retire`.

---
Canon: `harness/instructions/herdr.md`.
