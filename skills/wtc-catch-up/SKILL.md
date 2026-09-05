---
name: wtc-catch-up
description: Bring a worktree collection up to date with its remotes — fetch and prune every worktree owner (bare, or an unmanaged sibling's external clone), move detached worktrees onto the new development tip, return worktrees whose PR has merged to the tip and prune the local branch, merge the tip into live branches so they stop drifting and push that merge to any open PR, re-link secrets and harness skills, and refresh the collection env. Use when a collection looks stale or shows ↓ in the status table, after a PR merges, before opening a PR, after being away from a wtc, or when the user asks to sync, update, pull, or refresh the workspace.
---

# Catch a wtc up

Catch-up integrates work from outside this session. For the session's owned
PRs, [wtc-follow](../wtc-follow/SKILL.md) carries review, main builds and delivery
to completion. After catch-up pushes a live branch merge or returns a merged
branch to the tip, hand those new checks/remaining delivery gates back to its
existing follower. Catch-up alone does not establish that the task shipped.

Worktrees share bare owners, so "pull" is the wrong mental model: you fetch
the **bares**, then move each worktree individually under rules that differ by
what it is checked out on. Catch-up is also not git-only — files and skills
that reached the harness or the control root after this collection was created
never arrive on their own.

Prefer `tools/catch-up.sh`: it does everything in this file in one pass, per
collection or `--all`, and is what the rest of this skill documents.

```bash
harness/tools/catch-up.sh                 # this collection
harness/tools/catch-up.sh --all           # every collection under the workspace root
harness/tools/catch-up.sh --dry-run       # report only; touch nothing
```

Safe by construction: nothing here rewrites history or force-pushes. Dirty
trees are **not** skipped — a worktree that actually has a move to make is
stashed (including untracked files) around it, then the stash is popped. A
worktree that is already current is left alone regardless of dirty state,
since there is nothing to move it past.

## 1. Fetch every owner

```bash
harness/tools/refresh-configs.sh          # prints the bare list; regenerates .harness-repos
```

Then, for each bare (or loop over `.harness-repos`, which is `name=path`):

```bash
git --git-dir=<bare> fetch --prune origin
```

Fetching the bare updates every worktree's view of `origin/*` at once,
including collections other than this one.

`.bare/` is not the whole list. Unmanaged `ext.` siblings are owned by an
ordinary clone elsewhere on disk (`instructions/worktree-workspace.md`), so
fetch them from the worktree side — this form works for every sibling,
registry or not, and needs no lookup:

```bash
for wt in <collection>/*/; do
  git --git-dir="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" \
    fetch --prune origin
done
```

## 2. Where "merged" comes from: `.wtc-prs`, then `gh`

Whether a branch's PR has merged decides which row of the table below
applies, and that check reads this collection's **local PR enlistment**
first — not a `wtc:<label>` search on GitHub:

```bash
harness/tools/wtc-pr.sh list
```

A branch enlisted there is asked about directly
(`gh pr view --repo <slug> <n> --json state,isDraft,title`); an OPEN or DRAFT
state anywhere in the enlistment wins over anything else recorded, since a
worktree with two enlisted numbers on the same branch is rare and "still
live" is the safer read. A **merged** enlistment is pruned from `.wtc-prs`
once the worktree is returned to the tip (§2.1) — the file only ever lists
work still in flight.

A branch with **no enlistment** (never enlisted, or the enlistment predates
the PR) falls back to asking GitHub for that one branch, in every state:

```bash
gh pr list --repo <slug> --head <branch> --state all --json state --jq '.[0].state'
```

That fallback is what catches a PR that merged without ever being enlisted —
the branch would otherwise look "still live" forever, since nothing else
records that its PR is gone.

## 3. Move each worktree, by what it is

The resting state of a worktree is **detached at the development tip**, not a
branch (`harness/instructions/development-workflows.md`). Catch-up's job is to
move the tip forward under it, and to return worktrees to that state once
their work has landed.

For every worktree:

```bash
git -C <worktree> status --short                       # clean?
git -C <worktree> symbolic-ref -q HEAD || echo detached
git -C <worktree> rev-list --count HEAD..<default_ref>  # how stale
```

`<default_ref>` per repo is in `harness/.harness-repos.yml` (`origin/main` or
another working branch, if the registry names one).

| The worktree is | Do |
|---|---|
| **Detached**, behind the tip | Stash if dirty (incl. untracked); `git -C <wt> checkout --detach <ref>`; pop the stash. |
| **Detached**, already at the tip | Nothing — there is no move to make, dirty or not. |
| On a branch, **PR merged** (§2), clean, nothing beyond the base | §3.1 — return to tip, prune the local ref, unlist. |
| On a branch, **PR merged**, but dirty or with post-merge commits | §3.2 — that is follow-up work; give it a branch of its own first. |
| On a **live** branch (no PR, or PR open/draft), behind the tip | §3.3 — merge the tip in; §3.3.1 pushes it when a PR exists. |
| On a **live** branch, already current | Nothing. |
| Mid-merge / mid-rebase / mid-cherry-pick | Nothing. Report it — someone is in the middle of something. |
| On a repo's default **branch** (legacy shape) | `git -C <wt> merge --ff-only @{u}` if clean, and suggest detaching so the branch stops being pinned to this collection. |

**Never rebase, never force-push.** Merging a base forward either
fast-forwards or creates a merge commit; rebasing a live branch would rewrite
the per-issue record, which is the one thing catch-up must not do.

### 3.1 A merged branch: back to the tip, prune the local ref

```bash
git -C <wt> rev-list --count <default_ref>..HEAD   # must be 0
git -C <wt> checkout --detach <default_ref>
git -C <wt> branch -d <branch>
harness/tools/wtc-pr.sh unlist <repo> <n>           # if it was enlisted
```

`git branch -d` (never `-D`) is the safety net: it refuses to delete anything
not genuinely merged, and since this policy merges with merge commits rather than
squashing, it can tell. If it refuses, **stop and report** — the branch has
something the base does not.

The **remote** branch stays. It is the per-issue record, and
`git branch -r | grep <issue-id>` is how anyone finds what was done for an issue
later. Never delete it, and leave GitHub's "Delete branch on merge" off.

### 3.2 Carrying work off a merged branch

Uncommitted changes, or commits made after the merge, are follow-up work that
never belonged on a finished branch:

```bash
# post-merge commits: keep them, rename the line of work
git -C <wt> switch -c <issue-id>-<slug>-followup
git -C <wt> branch -d <old-branch>      # the old ref, now redundant

# uncommitted changes only: they follow you across
git -C <wt> checkout --detach <default_ref>
```

Uncommitted changes survive a `checkout --detach` as long as they don't
conflict; if git refuses, leave the worktree alone and report it. Pick a
follow-up name that says what the work is — and say in your report that you
renamed it, since nobody asked you to name anything.

### 3.3 A live branch: merge the base forward

A branch that is still being worked on drifts from its base every time
something lands. Left alone it drifts until the next PR is a conflict
resolution rather than a review, so catch-up brings the base to it:

```bash
git -C <wt> status --porcelain            # must be empty (or stashed)
git -C <wt> merge --no-edit <default_ref>
```

Merge, never rebase — the branch may already be pushed and under review, and
rebasing detaches review comments as well as rewriting history.

**Conflicts are where this stops.** Abort and hand it back rather than
resolving them mid-catch-up; the branch owner knows which side wins, and a
catch-up is not the moment to be making that call:

```bash
git -C <wt> merge --abort
```

Report the conflicting paths to the branch owner. For work this session owns,
return to `wtc-follow` / `wtc-pr` to resolve routine conflicts, validate and
push. Ask the user only for a semantic or scope decision the task does not
already settle; catch-up itself does not choose sides for another owner.

### 3.3.1 If the branch has a PR (open or draft), push the merge

A branch with a PR is already public, and a merge that sits unpushed leaves
reviewers (or CI, for a draft) reading the change against a base nobody is on
any more. That is the stale-base review round this whole section exists to
prevent, so do not be hesitant here — push it:

```bash
git -C <wt> push
```

Yes, this reruns the PR's checks. That is the point: a green build against a
base two weeks old is not information. Re-running against current code is what
makes the check mean something.

Two things this is not licence for. **Never force-push** — it detaches existing
review comments, and a base merge never needs one anyway. And if `push` refuses
because the upstream is wrong or the remote has commits you don't, stop and
report rather than reaching for `--force`; someone else may be pushing to the
same branch.

A branch with **no PR yet** is a different case: leave the merge local. Its
first push is `wtc-pr`'s (or `wtc-draft-pr`'s), together with opening the PR.

## 4. Re-link the harness skills

```bash
harness/tools/link-skills.sh
```

Picks up `wtc-*` skills added to the harness since the collection was created
and prunes ones removed since. Also installs agent toolchain hooks
(`.grok/hooks`, `.claude/settings.json`, `.cursor/hooks.json`) and refreshes
`.env.toolchain` so agent shells keep sibling toolchains on PATH. Idempotent.

Order matters here: this links whatever **this collection's** `harness/`
worktree has in git, so it must run *after* §3 moved that worktree. If it
reports `(none)`, the harness worktree is behind rather than the tool being
broken. To roll a newly landed skill out across every collection at once —
each of which must be caught up first — `harness/tools/link-skills.sh --all`.

## 5. Re-render the MCP servers

```bash
harness/tools/link-mcp.sh
```

Same lifecycle and the same ordering rule as the skills above: it renders
**this collection's** `harness/.mcp-servers.yml` into `.mcp.json`,
`.cursor/mcp.json` and `.codex/config.toml` at the collection root, so a
server added to the registry since reaches this collection, and one removed
or disabled since stops being offered. `--all` rolls a registry change across
every (already caught-up) collection.

It prints `note: unset in this shell: …` when a rendered server names a
credential the environment does not supply. That is information, not a
failure — the config is correct and the credential is missing. Fix it where
the variable belongs (`instructions/secrets.md`), not by editing the rendered
file, which is overwritten on the next run.

## 6. Refresh the collection env

```bash
harness/tools/refresh-env.sh
```

`.env.collection` is written by `write_collection_env`, and only `branch-off`
(new collection) and `add-repo` (only when the file is missing) ever call it.
So a variable added to the generator since — a port for a newly registered
repo, `GH_CONFIG_DIR` — reaches new collections only, and every older
collection stays stale indefinitely. This is the missing half.

Same ordering rule as the skills above: it runs **this collection's**
`harness/` generator, so it must come *after* §3 moved that worktree.

It preserves the collection's port base, so ports do not move, and leaves
`.env.collection.local` alone. It regenerates `.env.collection` wholesale,
which is that file's documented contract — hand-authored values belong in
`.env.collection.local`, which wins on a conflicting key. `--dry-run` shows
the diff and writes nothing; `--all` sweeps every collection.

**Already-open herdr panes do not pick this up.** `wtc-open.sh` injects the
env at workspace *creation* and skips that block when reusing an open
workspace, so a pane keeps whatever it started with. Close and reopen the
workspace, or export by hand in the pane.

## 7. Re-link machine-local secrets

```bash
harness/tools/link-secrets.sh
```

Idempotent, and re-running is the point: init hooks ran at worktree creation
only, so a control-root file added since then has never reached this
collection. Last in the hook order — a repo's `.env.collection` and skills are
in place by the time this runs, so a secret that a hook needs on next launch
is already linked when that hook fires.

A **nonzero exit means it refused a target that is not gitignored** — that is
not a catch-up failure to shrug at. Add the ignore rule in the offending repo
first, then re-run. Never link a secret into a path git would offer to commit.

### 7.1 Ambient CLI credentials — ask, once, and only when it is new

`gh` and `jira` each resolve one credential store per machine, so by default
every project on the machine shares whichever account is logged in. The
harness can give this workspace its own store instead, opt-in by presence
(`harness/instructions/secrets.md` → Tool identity).

Catch-up is when a workspace usually *discovers* this option, because §6 just
regenerated `.env.collection` against whatever the generator currently knows.
So check whether the choice has been made:

```bash
ls -d "${WTC_CONFIG_ROOT:-$HOME/.config/wtc}"/gh 2>/dev/null   # opted in?
grep -c GH_CONFIG_DIR .env.collection 2>/dev/null              # in effect here?
```

- **Store exists** → nothing to ask. §6 already emitted the variables.
- **Store absent, and the collection is otherwise up to date** → nothing to
  ask either. Do not raise it on every catch-up; a workspace that has said no
  once should not be asked again.
- **Store absent, and §6 just moved this collection onto a generator that
  understands tool identity** → this is the one moment worth a question. Ask
  the user how they want ambient CLI creds handled, and offer the two answers
  plainly:

  | Answer | What you do |
  |---|---|
  | *Machine-global is fine — this is the only thing I use `gh` for* | Nothing. Say so in the report and move on. |
  | *Scope it to this workspace* | `mkdir -p "$WTC_CONFIG_ROOT"/gh`, re-run `refresh-env.sh`, then tell them to `gh auth login` from inside a collection |

**Do not run `gh auth login` for them, and do not create the store without
being asked.** Creating it *is* the opt-in, and turning it on logs them out
inside every collection until they re-auth — a surprise no catch-up should
spring on someone. Report the choice offered and the answer taken.

## 8. Local refs left over from earlier work

§3.1 prunes the branch of the worktree it moved. Other local branches in the
same repo may also be finished — merged, with no worktree on them:

```bash
git -C <wt> branch --merged <default_ref>
```

Those are prunable with `git branch -d`, which will refuse anything not
genuinely merged. **The remote is never touched.** A local ref costs nothing
to keep, so when in doubt leave it; the point of pruning is that a worktree
stops sitting on dead work, not tidiness for its own sake.

## 9. Report

Per repo: where the HEAD is now (tip or branch), whether it moved and why,
ahead/behind counts, and tree state. Call out explicitly anything you
**deleted, renamed, or unlisted** — a pruned local ref, a follow-up branch, a
`.wtc-prs` row removed — even though all are recoverable, because none was
asked for.

Then, in one line: anything that needs a human — dirty trees that could not be
moved, a merge that aborted on conflicts, a refused secret link, a
`branch -d` that refused, a repo mid-rebase.

For every live branch you merged into (§3.3), say so, and name the PR you
pushed the merge to (§3.3.1) — its checks are now rerunning because of you.
For a branch with no PR, give the unpushed count instead. A merge that
aborted on conflicts is the first thing a human needs to see.

If §6 changed `.env.collection`, say which variables moved — a port that
shifted or a tool-identity variable that appeared changes what an already-open
herdr pane is running with, and only a reopened workspace picks it up. If §7.1
asked about ambient credentials, report the question and the answer; if it did
not ask, say nothing about it.

---
Canon: `harness/instructions/development-workflows.md`,
`harness/instructions/secrets.md`, `harness/instructions/skills.md`.
