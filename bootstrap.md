# Bootstrap — install the harness in an empty folder

This is the empty-folder path: a new machine, or a new workspace root
with nothing in it yet. The workspace root is **not** a git repo. Do not
`git init` it. Do not `git clone` the harness into it as a normal
checkout — that points `origin` at the wrong thing. Bare owners live
under `.bare/`; collections are worktrees hanging off those bares.

Day-to-day geometry after this: `instructions/worktree-workspace.md`.

```text
<workspace-root>/                 # plain folder, e.g. ~/Code/<org>/workspace
  .bare/
    agent-harness.git             # the only bare you must create by hand
    …                             # others clone on demand
  main/                           # first collection — day-to-day tip
    AGENTS.md                     # entry point -> harness/collection-AGENTS.md
    WTC-SCOPE.md                  # what this collection is for
    harness/                      # agent-harness worktree
    <repo>/                       # siblings, added when you need them
```

---

## Dependencies

### Required

| Tool | Why |
|---|---|
| **git** | Bares, worktrees, everything |
| **bash** 3.2+ | The tools (macOS `/bin/bash` is fine) |
| **Forge SSH** | Clone from `git@github.com:<org>/…` |
| **`gh`** | Auth check, PR review wtcs (`--pr`), `wtc-status` PR cells, `wtc-pr` |

```bash
git --version
gh auth status --hostname github.com
```

You need write access to the org (or at least to the harness repo and
whichever product repos you will add).

### Recommended

| Tool | Why | Without it |
|---|---|---|
| **herdr** | One session, one workspace per wtc; `wtc-open.sh`, status pane | Open collections as ordinary folders / terminals |
| **neovim** + [LazyVim](https://www.lazyvim.org/) | `wtc-browse.sh` — file tree + multi-repo change index | VS Code / Cursor on the collection root, or a JetBrains IDE per sibling |
| **mise** | Loads `.env.collection` (ports, `WTC_CONFIG_ROOT`) | Export those by hand |

### Optional

| Tool | Used by |
|---|---|
| **lazygit** | Optional terminal Git status and diff view |
| **gh-dash** (`gh extension install dlvhdr/gh-dash`) | `pr` herdr tab next to browse |
| **octo.nvim** | PR editing inside browse nvim |
| **unified.nvim** | Inline (Zed-style) overlay when browse opens a real file |
| **diffview.nvim** | Side-by-side from browse (`<leader>gD`) |
| **Nerd Font** | Icons in the browse tree |
| **`twg`** (Atlassian Teamwork Graph CLI) | Jira/Confluence from the CLI and from agents — `instructions/jira.md` |
| **`jira` CLI** | Legacy Atlassian CLI — prefer `twg`; see `instructions/jira.md` |
| A coding-agent CLI (Claude, Codex, Cursor, …) | The herdr `agent` pane |

None of the optional tools are needed to create collections, commit, or
open PRs.

Secrets for product repos live in a **control root** inside the
workspace (`<workspace-root>/.config` by default). You do not need it to stand the
harness up; add files there when a sibling actually needs them. See
`instructions/secrets.md`.

---

## 1. Empty folder + first bare

Pick a path. Example uses `~/Code/<org>/workspace`.

```bash
mkdir -p ~/Code/<org>/workspace/.bare
cd ~/Code/<org>/workspace

git clone --bare git@github.com:<org>/agent-harness.git \
  .bare/agent-harness.git
git --git-dir=.bare/agent-harness.git config remote.origin.fetch \
  '+refs/heads/*:refs/remotes/origin/*'
git --git-dir=.bare/agent-harness.git fetch --all --prune
```

Always clone bares from the forge. Never seed a bare from another local
tree.

## 2. First collection

The tools live *inside* a harness worktree, so the first one is added
by hand. `main/` is the day-to-day tip collection.

```bash
git --git-dir=.bare/agent-harness.git worktree add --detach \
  main/harness origin/main

cd main/harness
./tools/refresh-configs.sh     # writes local .harness-repos from .bare/
```

`refresh-configs.sh` walks up until it finds `.bare/`. If it errors
`no .bare/ found`, you are not under the workspace root.

Then author the **registry**, `.harness-repos.yml` — the tracked statement
of which repos are yours. This repository ships none, because the list is
yours; `refresh-configs.sh` only warns about it, but every other tool
refuses to run without one. Start with the harness itself:

```yaml
schema_version: 1

repositories:
  - name: agent-harness
    remote: git@github.com:<org>/agent-harness.git
    default_ref: origin/main
    role: Development harness — instructions, registry, collection tools.
```

One block per repo as you adopt it: `default_ref:` wherever the tip is not
`origin/main`, and `port_offset:` for anything that serves a port (the
collection env turns those into `<REPO>_PORT`). The name has to match the
bare in `.bare/`; if you renamed your fork, set `WTC_HARNESS_REPO` to it.
Commit it — it is the one file in this fork that is genuinely yours.

Now finish wiring the collection:

```bash
./tools/refresh-env.sh                # .env.collection + mise.toml
./tools/link-skills.sh --seed-scope   # AGENTS.md entry point, skills, WTC-SCOPE.md
```

To use a released `wtc` CLI, commit its exact version (without the `v` tag
prefix) in `harness/.wtc-cli-version`, then run `./tools/refresh-env.sh` and
`mise install` from the collection root. The refresh generates the CLI tool
entry in the collection-root `mise.toml`, inherited by every sibling. Upgrade
the checked-in version file to change the pin; edits to generated `mise.toml`
are replaced on the next refresh. Existing shell commands remain available
while their CLI equivalents are migrated.

`branch-off.sh` does both for every collection it creates; this first one is
by hand because the tools only exist once their own worktree does. Without
them the collection has no ports, no `WTC_CONFIG_ROOT`, and no `AGENTS.md`
for an agent opened at the collection root to read.

Worktrees rest **detached at the tip**. A branch is created at the first
commit (`git switch -c <issue-id>-<slug>`), not now.

## 3. Add siblings when you need them

```bash
# still from main/harness — collection name is the folder next to harness/
./tools/add-repo.sh --collection main api
./tools/add-repo.sh --collection main api console
```

Missing bares are cloned from the forge on demand. A repo added only for
context never needs a branch.

A *new* collection for a task, issue, or PR:

```bash
./tools/branch-off.sh fix-login-flow api
./tools/branch-off.sh --issue api-foh7 paging-clamp
./tools/branch-off.sh --tracker PROJ-123 rate-limits api
./tools/branch-off.sh --pr api#41
```

## 4. Open it

```bash
./tools/wtc-open.sh            # this collection, in herdr (if installed)
./tools/wtc-browse.sh          # LazyVim on the collection
./tools/wtc-status.sh          # branches, PRs, dirty trees
```

Or open the collection root (`main/`) in an editor. Agents should be
started from the **collection root**, not only `harness/`.

## 5. Ambient CLI credentials — decide once (optional)

`gh`, `twg` and `jira` each resolve one credential store per machine, so
by default **every project on this machine shares whichever account is
logged in**. If this workspace is the only thing you use those CLIs for,
that is fine and there is nothing to do here — skip to Check.

It stops being fine when you keep a second, unrelated project in
parallel: a collection here can then reach repositories and issues that
belong to the other one, and vice versa. The harness can give this
workspace its own store instead, keyed off the control root:

```bash
cd ..                                     # the collection root; mise loads .env.collection here
                                          # (no mise? set -a; . ./.env.collection; set +a)
mkdir -p "${WTC_CONFIG_ROOT:?load the collection environment first}"/gh
harness/tools/refresh-env.sh              # emits GH_CONFIG_DIR now that it exists
set -a; . ./.env.collection; set +a       # reload so GH_CONFIG_DIR reaches this shell
gh auth login                             # writes into the scoped store
gh auth status                            # confirm the identity is this workspace's
```

The mechanism, the per-tool levers, and what is *not* solved by it (a
scoped `jira-cli` token is still plaintext on disk) are in
`instructions/secrets.md` → "Tool identity". Two things worth knowing
before you turn it on:

- **It is opt-in by presence.** The generator emits `GH_CONFIG_DIR` only
  once `$WTC_CONFIG_ROOT/gh` exists, so a workspace that never creates
  the directory keeps the machine default. Nothing breaks by doing
  nothing.
- **Turning it on logs you out inside collections until you re-auth.**
  The scoped store starts empty. That one-time `gh auth login` is the
  whole cost; outside any collection the machine-global store is still
  what answers.

Agents running `wtc-catch-up` on a collection created before this
existed will offer the same choice, since that is when a workspace
usually discovers the option.

---

## Check

```text
<workspace-root>/.bare/agent-harness.git   exists, origin is the forge
<workspace-root>/main/harness/             detached at origin/main
<workspace-root>/main/harness/.harness-repos  lists the bares you have
<workspace-root>/main/AGENTS.md            -> harness/collection-AGENTS.md
```

`git -C main/harness status` is clean. `./tools/wtc-status.sh` from
`main/harness` prints the `main` collection.

Then `instructions/worktree-workspace.md` is the rest of the map.
