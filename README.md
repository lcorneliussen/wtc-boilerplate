# Worktree Collections — Multi-repo agent harness

A change worth making rarely fits in one repository. The API moves, the
console follows, the mobile client catches up. Coding agents handle that
badly for a dull reason: they are pointed at a single checkout, and the work
is not in a single checkout.

**Worktree collections** are the answer this repository documents. A
collection is a named folder holding one git worktree per repository in
scope, all hanging off shared bare clones. An agent started at the collection
root sees every repository the task touches, at the right revision, at once —
and a second collection alongside it sees the same repositories at a
different revision, with no clone duplication and no branch contention.

```text
<workspace-root>/          # plain folder, NOT a git repo
  .bare/
    <repo>.git             # bare owners, cloned from the forge
  <collection>/            # one folder per task
    AGENTS.md              # entry point, linked from harness/collection-AGENTS.md
    WTC-SCOPE.md           # what THIS collection is for
    harness/               # this repo's worktree — tools + instructions
    <repo>/                # repo siblings, one per repo in scope
    ext.<repo>/            # unmanaged sibling, owner lives elsewhere
```

## The load-bearing decisions

- **Bare owners are durable; collections are disposable.** A collection holds
  no state that is not in git. Deleting one loses nothing, which is what makes
  it cheap to create one per task.
- **Siblings rest detached at the development tip.** A branch can only be
  checked out in one worktree, so branch-per-collection turns the tip into a
  resource collections queue for. Detached heads let every collection sit on
  it simultaneously.
- **The branch is created at the first commit.** A branch named before the
  work has an identity gets the wrong name — and the name is how work maps
  back to its issue.
- **The harness travels inside the collection.** Instructions and tools are a
  worktree like any other, so the agent's rules are versioned with the code
  they govern.

## Reading order

- **`bootstrap.md`** — stand the whole thing up in an empty folder, from the
  first bare clone to the first collection. Start here.
- **`instructions/worktree-workspace.md`** — the geometry above, in full: bare
  owners, unmanaged `ext.` siblings, the registry.
- **`instructions/development-workflows.md`** — detached tips, when a branch
  gets created, how an issue ID reaches a branch name.
- **`instructions/hooks-and-env.md`** — the per-repo lifecycle hooks, the
  collection env (ports, `WTC_CONFIG_ROOT`), and how agent shells get
  sibling toolchains on PATH without `mise activate`.
- **`instructions/secrets.md`** — the control root, the collection-scoped
  tier, and how to stop `gh`/`twg`/`jira` sharing one machine-global identity
  across unrelated projects.
- **`instructions/skills.md`**, **`instructions/herdr.md`**,
  **`instructions/collection-context.md`** — how agents are told the rules,
  and how a collection gets a session.
- **`instructions/mcp.md`** — the MCP registry, why credentials are named
  and never valued there, and what is deliberately *not* an MCP server.
- **`instructions/jira.md`** — a worked example of wiring one external
  tracker; ignore it if yours is not Atlassian.
- **`skills/`** — the agent-facing procedures (`wtc-new`, `wtc-open`,
  `wtc-catch-up`, `wtc-pr`, …), each one a skill file an agent loads on demand.
- **`tests/`** — `tests/run.sh` runs the lot. No dependencies beyond bash and
  git, no network, and it builds its own throwaway workspace rather than
  touching yours. `tests/coverage.sh` reports line coverage for `tools/`
  and `hooks/`. `tests/README.md` covers what is asserted and why.

## What this repository is

A **reference implementation of the concept**, not a library. There is
nothing to install and nothing to depend on. The pattern has been built more
than once, in separate codebases, each time carried over by hand and adapted
to what that project happened to need. It works; re-deriving it every time
does not. This repository is where the idea gets maintained in one place
instead. Read it, take the parts that fit, adapt the rest — the shell tools
demonstrate the geometry, they are not an API anyone should build against.

Status: seeding. Content is being extracted from a set of working
implementations, and generalized where they disagree.
