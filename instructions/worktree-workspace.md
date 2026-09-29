# Worktree-collection workspace

This workspace organizes multi-repo work as **worktree
collections** (**wtc**) — named folders of git worktrees that all share bare
clones. One layout, no modes. Standing this up in an empty folder:
`bootstrap.md` at the harness repo root.

## Geometry

```text
<workspace-root>/              # plain folder, NOT a git repo
  .bare/
    agent-harness.git          # bare owners, cloned from the forge
    api.git
    …                          # product repos added when needed
  main/                        # a collection: day-to-day tip work
    harness/                   # agent-harness worktree
    api/                       # sibling worktrees, one per repo in scope
    console/
  <task>/                      # another collection, scoped to one task
    harness/
    ext.<repo>/                # unmanaged sibling, owner lives elsewhere
    …
```

| Concept | Meaning |
|---|---|
| **Bare owner** | `.bare/<repo>.git` — the single local clone; all worktrees hang off it |
| **Workspace root** | The folder holding every collection plus `.bare/`. Not a git repo |
| **Collection** (collection root, wtc) | Named folder with `harness/` + its repo siblings, for **one** task or purpose. This is what you open |
| **Repo siblings** | The repo worktrees inside one collection — the working set |
| **Collection siblings** | The other collections under the workspace root — other tasks, off-limits unless the user names one ([collection-context.md](collection-context.md)) |
| **Development tip** | Per-repo `default_ref` in `.harness-repos.yml` (`origin/main` / `origin/develop`) |
| **Branch-off** | Create a new collection with selected repos (`tools/branch-off.sh`) |
| **Catch-up** | Fetch/prune bares, fast-forward clean tip worktrees (rules in `AGENTS.md`) |

## Rules

1. **Always clone bares from GitHub** (`git@github.com:<org>/…`). Never seed
   a bare from another local tree, and never `git clone` a bare into a
   collection (that would point `origin` at the local bare instead of GitHub).
2. Worktrees are created **from the bare**:
   `git --git-dir=<workspace>/.bare/<repo>.git worktree add …`
3. The workspace root is not a git repo; collections are disposable, bares
   are not.
4. Add product-repo bares lazily — only when a collection actually needs them.

## Adding a bare owner

```bash
cd <workspace-root>
git clone --bare git@github.com:<org>/<repo>.git .bare/<repo>.git
git --git-dir=.bare/<repo>.git config remote.origin.fetch \
  '+refs/heads/*:refs/remotes/origin/*'
git --git-dir=.bare/<repo>.git fetch --all --prune
```

Then add the repo to `.harness-repos.yml` (tracked) and rerun
`tools/refresh-configs.sh` to update the local `.harness-repos`.

## Unmanaged siblings (`ext.`)

Sometimes a collection needs a repo the workspace should **not** adopt: a
third-party checkout, a spike, or a project deliberately kept unconnected to
this one. Registering it would imply a relationship that does not exist —
`.harness-repos.yml` is the statement "this is one of ours".

Such a repo gets no registry entry and no bare in `.bare/`. Its owner is an
ordinary clone anywhere on disk, and the collection holds a worktree of it
named with an **`ext.` prefix**:

```bash
git -C <path-to-owner-clone> worktree add --detach <collection>/ext.<repo>
```

The prefix is the whole convention. It marks the sibling as outside the
registry at a glance, and it cannot collide with a real repo name (those are
plain kebab-case). Prefer `ext.` over anything starting with a digit —
`port_var_for` upcases directory names into env vars, and `3RDPARTY_…` is not
a valid identifier.

This works because the tools are worktree-driven, not registry-driven:

- `owner_of` (`tools/lib.sh`) resolves any worktree to its real owner via
  `git rev-parse --git-common-dir`, so fetching and teardown reach `ext.`
  siblings on the same path as registry repos — status refreshes them and
  retire prunes them, with no `.bare/` entry to look up.
- `wtc-status.sh` walks the collection's directories and only requires a
  `.git` entry, so the sibling appears in the table like any other.
- `write_collection_env` iterates the registry, so an unmanaged repo simply
  gets no port — which is correct; it has no `port_offset` to claim.

One consequence remains: `default_ref_for` is name-keyed and falls back to
`origin/main` for anything unregistered, so the `↓ behind` column measures
against `main` regardless of the repo's actual working branch. An `ext.`
sibling that develops on `develop` will read as behind when it is not.

## Creating a collection

A wtc can start from a plain slug, an issue, a tracker ticket, or a PR:

```bash
tools/branch-off.sh fix-login-flow api        # slug
tools/branch-off.sh --issue api-foh7 paging-clamp       # issue (owning repo auto-included)
tools/branch-off.sh --tracker PROJ-123 rate-limits api
tools/branch-off.sh --pr api#41               # review wtc on the PR's head branch
tools/add-repo.sh  <collection> <repo> […]             # bring repos in later
```

`wtc new` accepts the same collection-creation options. With a matching
v0.1.10 or newer pin installed, `branch-off.sh` selects that native command
from the creating collection; the shell path remains available for bootstrap.
For a PR review collection, the native command verifies the exact head and
records the appropriate push command in `HANDOFF.md`, including when another
worktree already has the PR branch checked out.

Naming follows the source: `<slug>`, `<issue-id>-<slug>`, `<tracker-key>-<slug>`,
or `<repo>-pr<n>`. That name is the branch the work is *expected* to get — it
goes into the launch note, and a tracker wtc's linking issue is created while
consuming that note.

**Siblings are created detached at their `default_ref`**, with no branch. A
branch can only be checked out in one worktree, so branch-per-collection made
the development tip a resource collections queued for; detached HEADs let
every collection sit on it at once, and the branch is created at the first
commit, when its name is actually known
(`development-workflows.md` → "The resting state is the tip"). `--pr` is the
exception: review work pushes to the PR's head, so that one branch is checked
out for real. `--tip` is accepted and ignored — it is the default now.

Both tools clone missing bare owners on demand, write the collection env
(ports), link the harness `wtc-*` skills into the collection root so the agent
CLIs discover them (`skills.md`), and run each repo's init hook — see
`hooks-and-env.md`.

## Opening a collection

- **Several collections at once**: `tools/wtc-open.sh [<collection> …]` opens
  each as a workspace in the workspace root's herdr session — agent + shell at
  the collection root, collection env preloaded. This is the way to keep
  multiple wtcs in flight without a pile of terminal windows; see
  `instructions/herdr.md`. Optional, like mise.
- **Whole collection**: `tools/wtc-browse.sh` opens one LazyVim with a vim
  tab per sibling — in this window from a terminal, in the herdr `browse`
  pane when an agent launches it. Or open the
  collection root in VS Code (or Cursor —
  currently not part of this tooling, but works the same) as a multi-root
  folder, or run an agent CLI (e.g. `claude`) from the collection root so it
  sees all siblings.
- **Per-repo IDEs**: for focused work inside one sibling, open whichever IDE
  suits that repo's language on that repo alone — a heavyweight IDE is
  happier with one project than with a multi-root workspace. Launch it from
  the collection (e.g. `open -na <IDE> <collection>/<repo>`) so the checkout
  you open is the collection worktree, not some other clone of the same repo.
- Mixing is normal: an agent at the collection root orchestrating cross-repo
  work, plus JetBrains IDEs per repo for human editing.

Repos opened individually can detect the surrounding collection — see
`collection-context.md` (and copy its snippet into product repo `AGENTS.md`
files).

## Retiring a collection

```bash
tools/retire.sh <collection>        # from a different collection's harness
```

Runs teardown hooks, refuses if any sibling has uncommitted or unpushed work
(`--force` overrides), removes the worktrees, closes the collection's herdr
workspace if one is open, and deletes the folder.
Remote branches are never deleted (per-issue record); local refs go with the
worktrees, which is why the pre-flight refuses on anything unpushed. Merged
work lives on GitHub
and in the bares; the collection folder itself carries **no durable state by
design** — see `AGENTS.md` → "State lives in git". A `HANDOFF.md` still
present at retire time is a smell: it should have been consumed and deleted
by the first agent launched on the wtc.
