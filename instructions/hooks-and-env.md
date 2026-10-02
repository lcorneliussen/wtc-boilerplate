# Lifecycle hooks and collection env

Collections have a lifecycle git knows nothing about: worktrees get created
(`branch-off.sh`, `add-repo.sh`) and torn down (`retire.sh`). Repos can hook
into that, and every collection carries a small shared environment (ports
etc.) that all siblings inherit.

Design principle: **no tool is load-bearing.** [mise](https://mise.jdx.dev)
is the recommended runner (it also pins toolchains and layers env), but
everything works with bare git + bash; mise only makes it nicer.

## Hook contract

When a repo's worktree is created, the harness tools run its **init** hook;
before it is removed, its **teardown** hook. Resolution order per repo:

1. The repo's checked-in `mise.toml` defines a task named `harness:init` /
   `harness:teardown` **and** mise is installed → `mise run harness:<hook>`.
2. An executable `.harness/init.sh` / `.harness/teardown.sh` exists in the
   repo → run it (cwd = the worktree).
3. Neither → no-op.

Because hooks are checked into each repo, a repo brought into a collection
later (via `add-repo.sh`) carries its own setup with it. Hooks must be
idempotent and must not assume which siblings exist — check
`../<repo>`/`$<REPO>_PORT` and degrade gracefully.

**A hook must not fail its caller.** Report what went wrong on stderr and
exit 0; a nonzero exit from work that merely did not complete is not worth
aborting a collection over. The harness enforces this from its side too —
`run_hook` warns and continues rather than propagating the status — but hooks
should not lean on that: an older harness will still abort, and a hook that
exits nonzero because a *sub-tool* it called failed (a linker refusing a bad
path, say) is reporting an operator-fixable condition, not a reason to leave
a half-built collection on disk.

Typical init-hook work: restore dependencies, template a local `.env` from
the collection env, link secrets from the machine's control root
(`$WTC_CONFIG_ROOT` — see `secrets.md`). Typical teardown: stop
containers, deregister local services. Keep hooks fast.

For secrets, hooks **call `tools/link-secrets.sh --repo <name>`** rather than
writing their own `ln` lines — one implementation, so the ignore-check and
prod-path rules cannot drift per repo. The hook locates the harness worktree
as a sibling and degrades to a printed note when there is none (a repo cloned
outside a collection has no control root to link from).

Note the lifecycle gap this leaves on its own: hooks run at worktree
**creation**, so a control-root file added later never reaches collections
that already exist. Catch-up closes it by re-running the same tool
(`AGENTS.md` → Catch-up rules).

`.env.collection` has the same gap for the same reason — it is generated at
collection creation and never revisited, so a variable the generator learned
afterwards reaches new collections only. `tools/refresh-env.sh` is that file's
version of the same "run it again" tool, and catch-up runs it too.

## Collection env and ports

`branch-off.sh` allocates each collection a **port block** — the lowest free
`42000 + 100·n` across existing collections — and writes two generated,
uncommitted files at the collection root:

- `.env.collection` — `WTC_COLLECTION`, `WTC_AGENT_NAME`
  (`<herdr-session>--<collection>`, what `wtc-open` passes to
  `herdr agent start`), `WTC_CONFIG_ROOT`, `COLLECTION_PORT_BASE`, and one
  `<REPO>_PORT` per registry repo with a `port_offset` (e.g. `api` offset 1 →
  `API_PORT=42001`). Ports are emitted for *all* such repos, present or not,
  so a frontend can always resolve the API port — point absent services at a
  shared dev instance or start them on demand. It also carries the optional
  tool-identity variables (`GH_CONFIG_DIR` and friends) when the workspace has
  opted into them — `secrets.md` → Tool identity.
- `mise.toml` — loads `.env.collection` via `[env] _.file` and, when the
  harness commits `.wtc-cli-version`, pins that exact `wtc` GitHub release
  through `[tools]`. mise treats the
  collection root as a parent config, so **every sibling repo worktree
  inherits these variables automatically** in any mise-activated shell or
  `mise run` task. The harness tools run `mise trust` on generated
  collection configs and on each created worktree's checked-in `mise.toml`
  (worktrees come from <org> remotes, so their configs are as trusted as
  the code itself); manual `mise trust` is only needed for files you create
  by hand.

Without mise: `set -a; . ../.env.collection; set +a` from inside a repo, or
source it in the shell/IDE run configuration.

Port offsets live in `.harness-repos.yml` (`port_offset:`); keep them unique
and stable — they are the contract between repos.

## Agent shells and PATH

Agent CLIs spawn non-login shells. They do not run `mise activate`, so
`/usr/bin/env ruby` on a shebang (`bin/rails`, `bin/rake`) falls through to
macOS system Ruby 2.6, and `mise exec` from the **collection root** uses the
global pin rather than a sibling's. That is not an untrusted `mise.toml` and
not a reason to prepend `mise where ruby` by hand.

The harness injects the union of each sibling's `mise bin-paths` so every
agent shell command sees repo-pinned tools on PATH, independent of cwd:

| Surface | What it does |
|---|---|
| `tools/agent-env.sh` | dispatches to `wtc agent-env` when installed; its bootstrap fallback trusts sibling `mise.toml` files, caches bins as `.env.toolchain`, and prints shell exports |
| `hooks/agent-env.json` | SessionStart refreshes the cache; PreToolUse wraps `Bash` / `run_terminal_command` with `eval "$(agent-env.sh)"` and refuses a raw `gh pr ready` / `bb pr ready` (`hooks/guard-pr-ready.py`) |
| collection-root `.envrc` | Grok `load_envrc` (and direnv) prepend PATH without needing project hook trust |
| `wtc-open.sh` | new herdr workspaces get `WTC_TOOLCHAIN_PATH` and `BASH_ENV` at create time |

### Why none of these sets PATH directly

Anything that sets `PATH` *before* a login shell starts loses on macOS.
`/etc/zprofile` and `/etc/profile` run `path_helper`, which rebuilds `PATH`
from `/etc/paths` and `/etc/paths.d` and appends whatever was already there —
so an injected prefix comes out **below** `/usr/bin`, and `ruby` resolves to
system 2.6. Measured: a prefix passed at position 1 lands at position 18, with
`/usr/bin` at 6. An injection done that way achieves the exact opposite of its
purpose, silently.

So the harness passes `WTC_TOOLCHAIN_PATH` — an ordinary variable `path_helper`
does not touch — and every surface that turns it into a `PATH` runs *after* the
profile:

* `BASH_ENV` — bash sources it for every **non-interactive** shell, which is
  precisely what an agent CLI spawns. `agent-env.sh` detects being sourced and
  applies to the calling shell silently. This is the surface that needs no hook
  trust and no per-CLI config.

  It has one hole, found by the test suite. When **stdin is a socket**, bash
  decides it was started by a remote shell daemon and sources `~/.bashrc`
  instead of `$BASH_ENV` — silently, so the prefix simply never arrives. An
  agent CLI that talks to its host over a socket on fd 0 is exactly that case.
  This is why `BASH_ENV` is one of four surfaces rather than the answer: the
  PreToolUse hook wraps the command itself and does not care what stdin is.
* the PreToolUse hook — wraps the agent's own tool calls.
* `.envrc` — direnv and Grok `load_envrc`.

Interactive human panes never needed this: a login shell that runs `mise
activate` from `.zshrc` already resolves per-directory pins correctly. The
problem was only ever the non-login shells agents spawn.

`link-skills.sh` installs the hook JSON at `.grok/hooks/`, `.claude/settings.json`,
and `.cursor/hooks.json` (symlinks; a real file there is left as a local
override) and regenerates `.envrc` / `.env.toolchain`. Catch-up re-runs it.
Grok skips project hooks until `/hooks-trust`; `.envrc` and herdr PATH still
apply.

`mise exec` remains correct **inside a sibling**. It is not required to dodge
system interpreters once PATH is injected.

## Optional mise extras (never required)

- Repos may pin toolchains in their `mise.toml` (`[tools]` — node, python,
  gradle…) so collections don't drift per machine.
- Humans with `mise activate` in their shell can add `enter` hooks (e.g.
  print catch-up status when cd-ing into a collection). Convenience only —
  nothing in the harness may depend on shell activation.

## What runs what

| Event | Tool | Hooks run |
|---|---|---|
| Collection created | `tools/branch-off.sh` | `init` for every included repo (after env is written and skills are linked) |
| Repo added later | `tools/add-repo.sh` | `init` for the new repos only |
| Collection retired | `wtc retire` (`tools/retire.sh` compatibility entry) | `teardown` for every repo, then worktrees removed (pre-flight refuses on dirty/unpushed work unless `--force`; branches are never deleted) |
| Generator or registry changed | `tools/refresh-env.sh` | none — regenerates `.env.collection`, preserving the port base |
