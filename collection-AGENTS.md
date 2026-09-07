# You are in a worktree collection

This directory is one **wtc** — a worktree collection: several repos checked
out side by side for **one task**, plus `harness/`, which carries the tooling
and the instructions.

They are git **worktrees**, not clones. Each hangs off a shared bare owner in
the workspace root, so a fetch there serves every collection at once, and most
sit *detached at their repo's development tip* until your first commit creates
a branch.

```text
<workspace-root>/            every collection lives here; not a git repo
  .bare/<repo>.git           shared owners — the worktrees hang off these
  <other-collection>/        a COLLECTION SIBLING: someone else's task
  <this-collection>/         the COLLECTION ROOT — you are here
    AGENTS.md                this file (linked from harness/collection-AGENTS.md)
    WTC-SCOPE.md             what THIS collection is for — read it next
    harness/                 tools, instructions, skills
    <repo>/                  REPO SIBLINGS: worktrees in scope for this task
    HANDOFF.md               only on a fresh collection — /wtc-start, then gone
```

Four words, because two of them get confused: the **workspace root** holds
everything; a **collection root** is one task; its **repo siblings** are the
worktrees inside it; its **collection siblings** are the neighbouring
collections — other tasks, not your working set.

## Public and private audiences

Before publishing any issue, PR, reply, commit or artifact, follow
`harness/instructions/publication-privacy.md`. Keep private project identities,
adoption relationships and delivery links out of public upstream records. This
also applies to delegated agents and to explanations of a privacy cleanup.

## Read in this order

1. **`WTC-SCOPE.md`** — the task, the repos that belong to it, what is
   deliberately out. If it is missing, the collection has not been started
   yet: run `/wtc-start`.
2. **`harness/AGENTS.md`** if this harness has one — the domain rules for your
   project. Then each sibling's own `AGENTS.md`: branch policy and commit
   restrictions are per repo.
3. **`harness/instructions/`** — geometry, branch policy, secrets, skills.

## Stay in this collection

Your working set is this collection root: `harness/` and the repo siblings
beside it. The collection siblings — every other directory under the workspace
root — are **other people's tasks**, even when they are your own from
yesterday. Crossing into one is a major barrier: read-only reference is fine,
acting there is not, unless the user **explicitly** names that collection and
asks you to act in it.

Do not "also fix" a collection sibling for convenience. The `.bare/` owners and
`$WTC_CONFIG_ROOT` are shared infrastructure, not another collection — reading
and fetching there is normal. Tools that span collections (`--all` sweeps,
`retire <other>`, a new branch-off) run only when the user asked for that
explicitly. Full rule: `harness/instructions/collection-context.md`.

## Skills, config, secrets — the short version

- **Skills** are the procedures for recurring collection actions —
  `/wtc-status`, `/wtc-catch-up`, `/wtc-pr`, `/wtc-add-repo`, `/wtc-retire`,
  and `/wtc-start` on a fresh one. They are authored in `harness/skills/` and
  exposed at this root by `link-skills.sh`. Prefer one over ad hoc shell when
  it exists.
- **MCP servers** are declared once in `harness/.mcp-servers.yml` and
  rendered into `.mcp.json`, `.cursor/mcp.json` and `.codex/config.toml` at
  this root by `link-mcp.sh`. The rendered files name credentials and never
  hold one; the values come from the collection env.
- **Config** is `.env.collection` (generated: ports, `$WTC_CONFIG_ROOT`) plus
  `.env.collection.local` (yours, never regenerated, dies with the
  collection). herdr panes and mise load both, so a tool run from a pane
  already has them.
- **Toolchain PATH** is injected for agent shells that never ran `mise
  activate`. Do not spend turns on `mise trust`, `mise exec`, or prepending
  `mise where ruby` — a SessionStart/PreToolUse hook, `.envrc`, and herdr
  workspace env all prepend sibling bins so `/usr/bin/env ruby` cannot fall
  through to macOS system Ruby. If `ruby -v` still shows 2.6, once:
  `eval "$(harness/tools/agent-env.sh)"`. Grok project hooks need `/hooks-trust`
  the first time you open a collection.
- **Secrets** are never in git and never committed. One canonical copy lives
  in the control root at `$WTC_CONFIG_ROOT/<repo>/<repo-relative-path>` and is
  **symlinked** into the worktrees by `harness/tools/link-secrets.sh`, so a
  rotated credential is current everywhere at once.

Details in `harness/instructions/` — secrets.md, hooks-and-env.md, skills.md.

## Follow the work this session owns

After opening or advancing a review-ready PR, use `/wtc-follow` on relevant
status/check/review updates and when resuming this task. Carry owned work
through review, main builds and required delivery steps, preparing human
checkpoints before actions that still need authorization. Reuse fresh status
snapshots instead of repeatedly querying every PR. `/wtc-catch-up` brings
outside changes in; `/wtc-follow` carries this session's work to its outcome.
A status-only request remains read-only. Procedure and resumption limits:
`harness/skills/wtc-follow/SKILL.md`.

## Widening the scope is a decision

Needing another repo, another system, another service is normal — doing it
silently is not. Bring the repo in with `harness/tools/add-repo.sh` and write
down in `WTC-SCOPE.md` why it is here. A collection whose scope file no longer
describes it has stopped being one task.

## Nothing durable lives in this folder

`WTC-SCOPE.md`, `HANDOFF.md`, `.env.collection.local` are local and disposable
— `retire.sh` deletes the whole directory when the work lands, and that must
cost nothing. Durable state goes to **git and the forge**: commits and branches
in the repo siblings, PRs, and the issue that the branch name points at.

---
Source: `harness/collection-AGENTS.md` — edit it there, not through the link.
(It is named for its destination rather than called `AGENTS.md` in the harness:
a file by that name would be read as instructions for the folder it sits in,
and "you are in a worktree collection" is the wrong thing to tell someone
editing the harness.)
