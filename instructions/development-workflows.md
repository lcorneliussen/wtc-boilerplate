# Development workflows

Canonical branch/PR/merge policy for issue-tracked work across every repo in
the workspace. Each repo's `AGENTS.md` should mirror a short version and link
here — one policy, stated once, referenced everywhere.

## The resting state is the tip, not a branch

A worktree that is not actively carrying work sits **detached at the
development tip** (`default_ref`). Branches are created when work earns an
identity — at the first commit — and not before:

- A branch can only be checked out in **one** worktree. Branch-per-collection
  made the development tip a resource collections queued for; detached HEADs
  let every collection sit on it at once.
- A branch created before the work has an identity gets the wrong name, and
  the name **is** the issue mapping.
- A repo brought into a collection only for context never grows a branch at
  all, and never has to be cleaned up.

`branch-off.sh` and `add-repo.sh` therefore create detached worktrees; the
collection name is the branch the work is *expected* to get, recorded in the
launch note.

## Branch lifecycle

1. **Create the branch at the first commit**, named `<issue-id>-<short-slug>`
   (e.g. `ops-yhzi-port-call-logic`), off the working branch:
   `git switch -c <issue-id>-<short-slug>`. Working branches per repo:
   `default_ref` in `.harness-repos.yml`; release-cut branches (`release_ref`)
   deploy to production on merge — only touch them when intentionally
   shipping, and confirm in the target repo's `AGENTS.md`.
2. **Do all the issue's code work on that branch.** Multiple commits are fine
   and encouraged — they are the per-issue story.
3. **Open a PR to the working branch.** Reference the issue ID in the title;
   describe the work in the body.
4. **Merge with "Create a merge commit"** — never squash, never rebase.
5. **After merge, the branch is finished:** no new commits on it, ever. The
   **remote** branch is never deleted — it is the per-issue record, and
   GitHub's "Delete branch on merge" stays off. The **local** ref is a
   working artifact: catch-up returns the worktree to the tip and prunes it
   (`git branch -d`, which refuses anything not genuinely merged). Nothing is
   lost — the record is `origin/<issue-id>-<slug>`, the merge commit, and the
   PR.

Housekeeping work without an issue still gets a short branch
(e.g. `setup/branch-policy-docs`) → PR → working branch, same merge and
retention rules. Narrow exceptions are reasonable and should be written down
per repo in its own `AGENTS.md` — issue-file-only edits committing straight to
the working branch, or harness bring-up using ordinary commits on `main` while
the workspace is still being stood up.

## Catch-up

Treat "catch up" as: reconcile this collection with development outside it.

1. Fetch/prune every sibling owner (`.bare/` and unmanaged `ext.*` clones).
2. Worktrees detached at tip → fast-forward to current `default_ref`. If
   dirty, stash (including untracked), move HEAD, then stash pop. Already at
   the tip is left alone regardless of dirty state — there is nothing to move.
3. Active unmerged branches → merge the tip in; same stash-around-the-move;
   push the merge when the branch has a PR (open or draft); abort and report
   on conflicts rather than resolving them.
4. Merged PRs → stash if dirty; detach at tip; prune the local branch when
   `git branch -d` allows it; `tools/wtc-pr.sh unlist <repo> <n>` for an
   enlisted row that landed.
5. Re-run `tools/link-skills.sh`, `tools/link-mcp.sh`, `tools/refresh-env.sh`
   and `tools/link-secrets.sh`.

Do not skip a dirty sibling that is behind — stash, move, pop. Mid-merge or
mid-rebase is still a skip; that is someone else's in-progress operation.

### Local PR enlistment

Which PRs belong to a collection is **local**, not a forge label:

```bash
tools/wtc-pr.sh enlist <repo> <n> --branch <working-branch>
tools/wtc-pr.sh list
tools/wtc-pr.sh unlist <repo> <n>
```

File: `<collection>/.wtc-prs` (dies with `retire.sh`). Catch-up's "has this
PR merged?" check reads it first; `gh` only enriches state/title when asked,
and is the fallback for a branch that was never enlisted.

Procedure: skill `wtc-catch-up`. Script: `tools/catch-up.sh`.

## Ownership after push and merge

The initiating or assigned session follows review-ready work through its
agreed delivery outcome. Catch-up integrates incoming changes; follow-through
resumes on relevant status/review/check events, settles feedback and builds,
prepares human checkpoints, and verifies main and required delivery after
merge. Follow [pr-follow-through.md](pr-follow-through.md) for the lifecycle,
cache freshness and actual notification requirements; use the `wtc-follow`
skill to execute it. A green table row or merged branch alone does not establish
shipment, and none of this grants permission to merge or deploy.

## Why

- **Branch name as issue-mapping** — the name encodes which issue the commits
  belong to; post-merge commits break that mapping, and so would deleting the
  remote ref that carries the name.
- **Branch as record** — the point of per-issue branches is a durable record
  of everything done for the issue. The record lives on the **remote**;
  `git branch -r | grep <issue-id>` answers "what was done for this issue"
  from any checkout, which is why local refs can be disposable and the
  remote cannot.
- **Merge commits preserve granular history** — individual commits stay
  queryable via `git log <working-branch>`, merges-only via
  `git log --first-parent <working-branch>`.

## Start-of-session checklist (agent or human)

- **Detached at the tip is the normal, healthy state** — it means no work is
  in flight here, not that something is broken. Start work by committing;
  create the branch at that moment.
- On a branch: decode the issue ID from its name. If that issue is completed or
  the PR is merged, do not commit onto it — catch up (which returns the
  worktree to the tip) and start the next piece of work from there.
- Switching issues mid-session: finalize/merge the current branch first, or at
  minimum return to the tip before starting.
- `git log --oneline origin/<working-branch>..HEAD` — no commits ahead means
  the branch is merged/stale: treat it as read-only.
- Fetch early and often. Working on a base that moved days ago is how you get
  a PR that conflicts on arrival; the tools fetch on their own, but a manual
  `git fetch --prune` before starting costs nothing.

## The issue record

Branch names encode an **issue ID**, so something has to mint those IDs. This
harness assumes a **git-based issue tracker**: issues are files in the repo,
created and moved by commits, and therefore visible to an agent with nothing
but a checkout. [beads][beads] works this way, as does *beans*, the scheme
this harness was extracted from; any convention where an issue is a tracked
file with an ID and a prefix will do.

That choice is not incidental. An agent that can read the backlog from the
worktree it already has needs no credentials, no network, and no tool call to
answer "what is this branch for" — and the issue moves through review in the
same PR as the code it describes.

Issues route to the repo that owns the change, by prefix:

| Prefix | Repo | Scope |
|---|---|---|
| `ops-` | ops | Findings, infra, cross-repo ops/SDLC initiatives |
| `api-` | api | Server-side code and API behavior |
| `console-` | console | Console code and browser behavior |
| `device-` | device | Device app code and on-device behavior |

(The repo names above are examples — substitute your own; the registry's
`issues_prefix` field is what actually binds a prefix to a repo.) Repos
without their own issues config borrow the ops prefix for cross-repo
initiatives. File code issues in the repo that owns the change.

[beads]: https://github.com/gastownhall/beads

## Linking an external tracker

A **cloud tracker** — Jira, GitHub Issues, Linear — is the company-facing
layer above the in-repo record, and it is optional. Where one exists, keep it
one link away rather than woven through:

- Record its key in the issue's frontmatter (`tracker: <KEY>`), and mention
  the key in PR titles and bodies.
- Update the external ticket only at meaningful transitions — started,
  blocked, shipped. It is a reporting surface, not a work log.
- **Branch names stay issue-based** (`<issue-id>-<slug>`). The issue file
  carries the link, so the chain tracker → issue → branch/PR stays navigable
  without encoding vendor keys into git refs — which matters the day the
  vendor changes and the refs do not.

`tools/branch-off.sh --tracker <KEY>` is a worked example of accepting a tracker
key at collection-creation time; adapt it to whichever tracker you run.

## Mirroring in product repos

Each repo's `AGENTS.md` should carry a short **Branch convention** section:
working branch, the lifecycle rules in one short list, and a link to this
document (`agent-harness/instructions/development-workflows.md`). Pair
it with the worktree-collection snippet from `collection-context.md`.
