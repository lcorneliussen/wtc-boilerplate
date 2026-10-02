---
name: wtc-new
description: Create a new worktree collection (wtc) from a slug, an issue, a tracker ticket, or a pull request, with the right repos checked out and a launch note written. Use when the user asks to start a new task, branch off, spin up a workspace or worktrees for a ticket or issue, or set up a collection to review a PR.
---

# Create a wtc

One collection = one task. It holds a `harness/` worktree plus the sibling
repos that task actually touches. Collections are cheap and disposable —
prefer a new one over reusing an unrelated wtc.

Run from any existing collection's harness worktree.

## 1. Pick the source — it decides the name and the branch

| Source | Command | Collection / branch |
|---|---|---|
| Plain slug | `tools/branch-off.sh <slug> [repos…]` | `<slug>` |
| Issue | `tools/branch-off.sh --issue <issue-id> <slug> [repos…]` | `<issue-id>-<slug>` |
| tracker ticket | `tools/branch-off.sh --tracker <KEY> <slug> [repos…]` | `<key-lowercased>-<slug>` |
| PR review | `tools/branch-off.sh --pr <repo>#<n> [repos…]` | `<repo>-pr<n>`, on the PR's head branch |

Prefer `--issue` whenever an issue exists or should: it gives a
convention-correct `<issue-id>-<slug>` branch for free and pulls in the repo
owning that issue prefix automatically as the primary sibling. Prefixes:
`api-` → api, `console-` → console, `device-` → device,
`ops-` → ops.

With `--tracker`, the linking issue does **not** exist yet — create it while
consuming the launch note, with `tracker: <KEY>` in its frontmatter. Branch names
stay issue-based everywhere else; the issue carries the tracker link.

## 2. Pick the repos

Name only what the task touches — extra worktrees are extra catch-up. Names
come from `.harness-repos.yml`. `harness/` is always included; with `--issue`
the owning repo is too. Missing bare owners are cloned from GitHub on demand,
so naming a repo that has never been used here is fine.

Repos can be added later with the `wtc-add-repo` skill, so under-scoping is
the cheap mistake.

## 3. No branch is created — that is deliberate

Every sibling is checked out **detached at its `default_ref`**. Nothing to
decide here, but two consequences worth knowing:

- **Every collection can sit at the tip at once.** A branch can only be
  checked out in one worktree; a detached HEAD has no such limit, so there is
  no queueing for `develop` and no `--tip` flag to get wrong (it is accepted
  and ignored).
- **The branch is created at your first commit**, `git switch -c
  <issue-id>-<slug>` — by which point you know what the work actually is. The
  collection name is the expected name, recorded in `HANDOFF.md`.

A repo brought in only for context never grows a branch at all, and needs no
cleanup later.

`--pr` is the exception: it checks out the PR's head branch for real, because
review work pushes to it.

## 4. Run it

```bash
tools/branch-off.sh --issue api-foh7 paging-clamp
tools/branch-off.sh --tracker PROJ-123 rate-limits api console
tools/branch-off.sh --pr api#41
tools/branch-off.sh readonly-repro api
```

The tool then, in order: creates the worktrees, writes `.env.collection` +
`mise.toml` (allocating a free port block), links machine-local secrets and
the harness skills, runs each repo's init hook, and writes `HANDOFF.md`.

A failing init hook warns and continues by design — the collection is still
usable; fix the repo and re-run that hook's tool rather than recreating.

## 5. Write the launch note properly

`branch-off.sh` seeds `HANDOFF.md` with the mechanical facts. Replace the
goal line with what this wtc is actually for: the problem, the constraint,
the acceptance condition, links to the issue / tracker ticket / PR.

**The note is ignition, not the record.** Anything that must survive belongs
in an issue or a commit *before* an agent is launched — the first agent's first
action is to consume the note and delete it. A dead agent must cost nothing.

## 6. Open it

`branch-off.sh` joins a running herdr session automatically. `--open` starts
one; `--no-open` skips. Otherwise open the **collection root** — not just one
sibling — in the editor or agent CLI, so cross-repo context is visible.

The workspace agent needs no prompt from you: while `HANDOFF.md` is still
there, `wtc-open.sh` hands it `/wtc-start` as soon as it is ready and waits to
see it working on it (`--no-first-prompt` to skip). That is why the note has
to be right *before* the collection is opened.

To launch a separate agent on it, point the prompt at the durable record:

```bash
herdr --session <project> agent prompt api-foh7-paging-clamp \
  "Read HANDOFF.md at the wtc root, then start." --wait
```

---
Canon: `harness/instructions/worktree-workspace.md`,
`harness/instructions/hooks-and-env.md`, `harness/AGENTS.md`.
