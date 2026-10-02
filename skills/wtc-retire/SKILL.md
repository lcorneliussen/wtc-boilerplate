---
name: wtc-retire
description: Retire a finished worktree collection — verify nothing durable would be lost, run teardown hooks, remove the worktrees, close its herdr workspace, and delete the folder while every remote branch is kept as the record. Use when work in a collection is merged or abandoned and the user asks to clean up, remove, tear down, or retire a wtc or workspace.
---

# Retire a wtc

A collection carries **no durable state by design** — merged work lives on
GitHub and in the bare owners, the record lives in issues and branches. So
retiring is meant to be boring. The whole job is confirming that "by design"
actually held for this one.

You can retire a different collection directly. From inside the collection
being retired, run `wtc retire .` in its Herdr workspace. The CLI checks the
worktrees first, then delegates deletion to a `--cleanup--` workspace in the
same Herdr session. That workspace stays open with the result after the target
workspace closes. Outside Herdr, run from another collection.

## 1. Confirm it is finished

- The PR(s) are merged or deliberately closed — check, don't assume.
- The issue records the outcome and the PR link.
- The tracker ticket, if any, has been transitioned and commented at the shipped
  or blocked transition.

If the work was abandoned rather than shipped, say so in the issue before
retiring. An abandoned branch with no explanation is a trap for whoever finds
it in six months.

## 2. Look for state that should not be there

```bash
ls <collection>/HANDOFF.md 2>/dev/null
git -C <collection>/<repo> status --short
git -C <collection>/<repo> log --oneline @{u}..HEAD
```

- **A `HANDOFF.md` still present is a smell**, not a blocker: it means the
  first agent never consumed it. Read it before deleting the collection —
  anything durable in it still needs to become an issue or a commit.
- **Uncommitted or unpushed work** blocks the retire, and should. Commit and
  push it, or establish deliberately that it is disposable.
- Anything else at the collection root that isn't generated
  (`.env.collection`, `mise.toml`, `.harness-backups/`, the skill link dirs)
  deserves a look before it disappears. `.env.collection.local` is removed
  with the collection on purpose — those secrets were scoped to this wtc.

`.harness-backups/` holds hand-made copies of files that `link-secrets.sh`
replaced. If anything in there matters, it belongs in the control root — copy
it there first.

## 3. Retire

```bash
wtc retire <collection>
# Or, from the target collection's Herdr workspace:
wtc retire .
```

It runs teardown hooks for every repo, refuses on dirty or unpushed work,
removes the worktrees, closes the collection's herdr workspace if one is open,
and deletes the folder when it contains no other files. It leaves unexpected
files visible for inspection. A self-retire waits for the initiating agent to
finish its turn. After a final pane check, it closes the source workspace
before running hooks or removing worktrees; another live agent pane blocks
the handoff. Inspect the `--cleanup--` pane for the final result. Its post hook
runs after product teardown and before the harness worktree is removed.
`harness/tools/retire.sh` is the compatibility entry point in older harnesses.

`--force` overrides the pre-flight refusal. Use it only when you have
established the work is genuinely disposable — and say in your report that you
used it and why. It is not the way past a refusal you haven't read.

## 4. What is never deleted

**Remote branches.** Merged or not, they are the per-issue record of work —
`git branch -r | grep <issue-id>` is how anyone finds what was done for an issue
later. `wtc retire` doesn't touch them and neither do you.

Local refs go with the worktrees, which is exactly why the pre-flight refuses
on anything unpushed: pushed work is safe on the remote, unpushed work only
exists here.

Bare owners are permanent too. Only the collection folder is disposable.

## 5. If a pane is running

herdr panes may hold live work — an agent mid-task, a dev server, a test run.
An agent conversation that dies is not recoverable from git.

If retiring would kill something running, **ask the person first.** It is
their session, and "it looked idle" is not yours to judge.

## 6. Report

What was retired, that the PRs were merged, that branches were kept, and
anything you rescued out of the collection on the way (handoff content,
backups) and where you put it.

---
Canon: `harness/instructions/worktree-workspace.md`,
`harness/instructions/herdr.md`, `harness/AGENTS.md` → State lives in git.
