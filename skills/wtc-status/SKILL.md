---
name: wtc-status
description: Report where every worktree collection stands — branches, open PRs and their check rollups, working-tree state, and what is running under the herdr session. Use when the user asks what is in flight, which wtcs exist, what is red or blocked, whether a PR is green, or what they should pick up next.
---

# Where does everything stand

Use the pinned `wtc status` command to inspect this collection. The
`harness/tools/wtc-status.sh` and `wtc-status-tui.sh` entry points dispatch to
that exact released version when installed and retain their shell path for
bootstrap or older pins. Status does not change worktree branches or files.

```bash
wtc status                         # this collection; one pass when captured
wtc status --json                  # canonical snapshot JSON
wtc status --md                    # agent Markdown
wtc status --cached                # last snapshot; no Git or forge calls
wtc status --no-fetch              # use current local refs
```

Scoped runs write `.wtc-status.json`, `.wtc-status.md`, and the shell-compatible
`.last-wtc-status.yml` in the collection root. `--cached` reports their age and
falls back to a plain listing from the YAML cache when the JSON cache is absent.
Forge failures remain unknown; an empty or cached check is not proof of a
current passing build.

## Scope and live views

```bash
wtc status other-collection        # one named collection
wtc status --all                   # every collection, no scoped snapshot files
wtc status --procs                 # processes under the herdr session
wtc status --tui                   # interactive repositories and PRs
wtc status --watch 120             # interactive view, 120-second refresh
```

`--all` is explicit because it reads every collection; it omits the enlisted
PR section and does not run other collections' build hooks. The CLI's `--repos`
flag hides the enlisted PR section when a compact table is needed; the
compatibility scripts keep their older selector behavior. The interactive
view starts with the last snapshot while a fresh one loads. `r` refreshes,
`?` shows help, `a` toggles archived PRs, and `q` quits. It refreshes less
often when unfocused. Captured output prints one pass and exits, so use a
one-shot command to answer a question rather than leaving a watch loop open.
`WTC_STATUS_WATCH`, `WTC_STATUS_WATCH_BG`, and `WTC_STATUS_NO_CLICK` can be set
in `$WTC_CONFIG_ROOT/wtc.env`.

## Read the table

- `⌂ main` is a worktree detached at its development tip, the normal resting
  state. A named branch has work in flight or needs catch-up after its PR lands.
- `±N` means changed files, `↑N` means local commits ahead, and `↓N` means the
  worktree is behind its development tip. The footer counts stale worktrees.
- The PR cell combines its number with checks, merge and review facts. `✓`
  means passing or approved; `✗` means failing; `●` means pending; `↓` means
  behind the base; `⚠` means conflicts; `⊘` means blocked; `…` means waiting
  for reviewers; `∅` means no reviewers. Inspect the PR itself before taking
  a merge or review action.
- The PR section lists `.wtc-prs` enlistments, including merged work that may
  still need main checks or delivery. A merged PR on its old branch calls for
  catch-up. Older merged entries can be hidden behind the `a` toggle.
- Optional `T` and `P` cells show tip and production builds supplied by an
  executable `harness/hooks/wtc/status.build.sh`. Their HTTP(S) URLs are mouse
  targets unless `--no-click` is set. The `wtc customize` guide documents the
  read-only JSON hook contract.

## Answer the actual question

Summarize what is in flight, what is blocked and on whom, and what is green but
waiting. For outside changes, use `wtc-catch-up`. For a PR this session owns,
use `wtc-follow` and verify its current checks, reviews and conversations.
A status-only request does not authorize PR mutations. Merged or archived rows
do not prove delivery is finished; follow main builds and required ports.

---
Canon: `harness/instructions/herdr.md`.
