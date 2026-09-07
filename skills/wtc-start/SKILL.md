---
name: wtc-start
description: Orient in a worktree collection (wtc) at the start of a session — consume and delete the HANDOFF.md launch note, identify the issue and working branch, check whether the branch is still live, and load the collection env. Use when starting or resuming work in a collection, when picking up someone else's wtc, when a HANDOFF.md is present, or when the user asks where things stand or what to do next here.
---

# Start work in a wtc

The premise: **sessions die, git survives.** Everything you need is on disk —
branch state, issues, PRs — plus one deliberately ephemeral file. This is the
cold-start procedure that turns that into working context.

## 1. Locate the collection

```bash
common="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$common" in */.bare/*.git) echo "in a collection" ;; esac
```

Cheaper: an `AGENTS.md` beside a `harness/` directory, in the current
directory or one level up. The
**collection root** is the directory holding `harness/`. Sibling repos are its
other subdirectories; the full inventory is `harness/.harness-repos.yml`.

If neither test passes you are in a standalone checkout: work single-repo, do
not guess at `../` paths, and stop following this skill.

## 2. Consume the launch note — first action, before anything else

If `HANDOFF.md` exists at the collection root:

1. Read it.
2. Turn anything durable into issues, commits, or PR text. Anything that
   matters and is only in that file is currently one `rm` from being lost.
3. Transcribe the scope into **`WTC-SCOPE.md`** at the collection root — the
   task in a paragraph, the issue, one line per repo saying why that repo is
   here, and what is deliberately out. That file is what the next session in
   this collection reads instead of the handoff. If the collection predates
   the file, seed it first:

   ```bash
   tools/link-skills.sh --seed-scope
   ```

4. **Delete the handoff.** Not later, not at the end of the session — now.

A `HANDOFF.md` still present hours into a session, or at retire time, is a
bug. Its absence is normal and means the wtc was already picked up.

Keep the scope file short — it is read in full at the start of every session
here — and keep it true: widening the scope later is a deliberate edit to it,
not a silent `add-repo.sh`.

## 3. Identify the work

```bash
git -C <repo> branch --show-current      # empty output = detached
```

**Detached is the normal resting state**, not a problem: the worktree sits at
the development tip and no work is in flight yet. The branch gets created at
your first commit (`git switch -c <issue-id>-<slug>`). The name it should get
is in `HANDOFF.md` or is the collection name.

On a branch, the name encodes the issue: `<issue-id>-<short-slug>` (e.g.
`api-foh7-paging-clamp`). A `<tracker-key>-<slug>` name means the linking issue
may not exist yet — create it, with `tracker: <KEY>` in the frontmatter. A
`<repo>-pr<n>` collection is a review wtc sitting on someone else's head
branch: read the PR, don't branch off it.

Read the issue before writing code. Read each sibling's own `AGENTS.md` too —
branch policy, working branch, and commit restrictions are **per repo**, and
`ops` in particular stays read-only-prod.

## 4. Check where you stand

```bash
git -C <repo> log --oneline origin/<working-branch>..HEAD   # ahead: your work
git -C <repo> rev-list --count HEAD..origin/<working-branch> # behind: staleness
```

The working branch is that repo's `default_ref` in
`harness/.harness-repos.yml` (`origin/main` or `origin/develop`).

- **Detached, 0 behind** → at the tip, ready. Start working.
- **Detached, N behind** → the tip moved since this wtc was made. Run
  `wtc-catch-up` before writing code; it costs seconds and saves a rebase.
- **On a branch with commits ahead** → live work; continue on it.
- **On a branch with nothing ahead**, or whose PR is merged → finished. Do not
  commit onto it. `wtc-catch-up` returns the worktree to the tip and prunes
  the local ref; the remote branch stays as the record.

Switching to a different issue mid-session means finishing the current branch
first — or at minimum returning to the tip before starting.

## 5. Load the collection env

`.env.collection` at the collection root carries `WTC_COLLECTION`,
`WTC_AGENT_NAME`, `COLLECTION_PORT_BASE`, `WTC_CONFIG_ROOT`, and a
`<REPO>_PORT` per serving repo. A mise-activated shell already has them;
otherwise:

```bash
set -a; . <collection>/.env.collection; set +a
```

Ports are emitted for every registry repo with an offset, present or not — so
a frontend can always resolve the API port even when that sibling isn't
checked out here. Point absent services at a shared dev instance.

Do **not** diagnose `mise trust` / `mise exec` / `mise where ruby` as a first
step. Agent shells get sibling toolchain bins on PATH from `.env.toolchain`
(via a PreToolUse hook, `.envrc`, and herdr). If `ruby -v` is macOS 2.6,
`eval "$(harness/tools/agent-env.sh)"` once and continue — full rule in
`harness/instructions/hooks-and-env.md` → Agent shells and PATH.

## Resume delivery ownership

For work assigned to this session, read the PR/issue continuation record and
use [wtc-follow](../wtc-follow/SKILL.md) to resume outstanding review, main-build
or delivery gates. A merged branch is finished but its task may still need a
main check or a downstream PR. Reuse any existing follower and fresh status
snapshot. Do not start mutating other listed PRs during a status-only request.

## 6. Report, then work

State in one short paragraph: collection, issue (and tracker key if any), branch
and whether it is live, which siblings are checked out, whether a PR is open,
and what the next concrete step is. Then start.

If the wtc looks stale — worktrees behind their remotes, or you are unsure
what landed since — run the `wtc-catch-up` skill first.

---
Canon: `harness/AGENTS.md` (State lives in git),
`harness/instructions/collection-context.md`,
`harness/instructions/development-workflows.md`.
