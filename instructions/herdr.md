# Driving collections with herdr

herdr is a terminal multiplexer for coding agents: panes survive detach, and
it reports whether the agent in a pane is working, idle, or blocked. That is
how several wtcs stay in flight at once. Optional, like mise — every other
tool works without it.

It is **ergonomics only**. A workspace is a view onto worktrees that already
exist; closing it must cost nothing (`AGENTS.md` → "State lives in git").

## Shape

```text
session "<project>"                one server + socket per workspace root
└─ workspace "<collection>"   one per wtc; cwd = collection root, .env.collection loaded
   ├─ pane "agent"            coding agent (full-height left)
   ├─ pane "browse"           LazyVim / lazygit — empty = a shell
   ├─ pane "shell"            working prompt, under browse
   └─ pane "status"           wtc-status.sh, beside the shell
```

```text
[ agent | browse        ]
[       | shell | status]
```

`browse` is the slot for something a human should look at. An agent that
wants to open neovim sends it there and keeps talking in `agent`. A command
typed at a prompt — herdr shell or a plain terminal — runs in that window;
it does not bounce into `browse`.

## Reaching a collection's agent from your phone

`wtc-open.sh` starts claude with **Remote Control** by default, so every
collection's agent shows up in the Claude mobile app and on claude.ai under
`<session>--<collection>`. A wtc agent is meant to keep working while you are
elsewhere; one you can only reach by walking back to this machine gives up
half of that.

The catch worth knowing before you need it: **Claude only accepts
`--remote-control` at start time.** There is no in-session toggle, so an agent
already running without it cannot be attached to your phone — it has to be
restarted, resuming its conversation:

```bash
cd <collection>
claude --remote-control "$WTC_AGENT_NAME" --dangerously-skip-permissions --continue
```

`--no-remote-control` opts out for one open; passing `--agent-args` replaces the
default arguments entirely and so drops it too.

Re-running `wtc-open.sh` inspects every pane and only (re)starts what is
sitting at a bare prompt — that is how a session restored after a reboot gets
its commands back. A workspace that already grew extra panes (a second agent,
a one-off split) is left alone, and browse tools fall back to `shell` rather
than inserting another column.

A session is a separate server with its own workspace list, so other work on
the machine never shows up here. The name defaults to the workspace-root
folder minus a trailing `-wtc` or `-harness` — so `<project>-wtc/` → session
**`<project>`**; override with `--session` or `$HARNESS_HERDR_SESSION`.

```bash
tools/wtc-open.sh [<collection> …]    # this collection, or the named ones
tools/wtc-open.sh --all --list        # open everything / show agent states
herdr --session <project>                  # attach
```

Opening is idempotent and repairs a wtc whose agent exited. The session starts
headless on demand, so opening never steals a terminal. `branch-off.sh` joins
a **running** session automatically (`--open` starts one, `--no-open` skips),
and `retire.sh` closes the workspace with the collection.

Claude panes start with `--dangerously-skip-permissions`: a wtc is an isolated
worktree on its own branch with no production credentials. `--agent-args`
overrides, `--no-agent` skips the agent.

## Status

`tools/wtc-status.sh` prints each collection's branch, open PR with its check
rollup (`✓ ✗ ● —`), and working-tree state, then the processes running under
the session with CPU and memory.

`wtc-open.sh` puts a `status` pane in every wtc, scoped to that collection —
including wtcs opened before the pane existed, so re-running adds it without
disturbing the agent. For the process view, run it wherever you want it:

```bash
tools/wtc-status.sh --procs --watch 5
tools/wtc-status.sh --repos --watch 120   # all collections at once
```

The collection table is **clickable** wherever it has a terminal on both
ends (`--no-click` turns that off, `--click` forces it on):

| Click | Does |
|---|---|
| the `REPO` cell | focuses that sibling in the browse nvim (vim tab + neo-tree) |
| the `PR` cell | `:Octo pr edit` in that tab, or the pull request in the browser |
| the `TREE` cell | neo-tree git status in that tab; `lazygit` in a `diff:<repo>` herdr tab if nvim is not up |

`r` redraws, `q` quits. Clickable cells are underlined. The pane captures
the mouse while it runs, so herdr's own selection and wheel scrolling in that
pane give way to the table — close the diff tabs yourself when done; the
status pane never closes anything.

## Browse

`tools/wtc-browse.sh` opens **one** LazyVim with **one vim tab per sibling**
(`:tcd` so gitsigns / neo-tree / Octo / lazygit see that repo). Tabs are
LazyVim **bufferline** in `tabs` mode (click a tab, or `gt` / `gT`).
`<leader><space>` / `<leader>ff` and `<leader>/` / `<leader>sg` search
**every sibling**; `<leader>fF` / `<leader>sG` stay in the current repo.
`<leader>fp` picks a repo tab. Tab 1 is a **live change tree** (changed
files only, fully expanded) of every sibling vs its PR base / `default_ref`.
It refreshes every 2s and, with follow on (`f` to toggle), peeks the
file the agent just wrote. `<CR>` peeks, `o` opens in the repo tab.
`<leader>gd` returns to the index; `]f`/`[f` walk files; `<leader>gD`
is Diffview side-by-side. The multi-repo map stays in the `status` pane.

Where it opens:

| Launched from | Goes |
|---|---|
| a terminal, including a herdr `shell` pane | this window |
| a coding agent inside herdr | the `browse` pane (or `shell`, if the workspace is off-template), plus a sibling herdr tab `pr` running `gh dash` if that extension is installed |

The browse nvim listens on `/tmp/wtc-browse-<workspace>-<collection>.nvim`,
where `<workspace>` is the basename of the workspace root — keyed by it too,
because every workspace tends to have a `main` and one shared socket left the
second workspace's browse pane unable to start. A pair too long for a socket
path (104 bytes on macOS) is cut to fit and given a checksum. Status-pane
clicks talk to it:

| Click | Does |
|---|---|
| `REPO` | switch to that sibling's vim tab |
| `TREE` | that tab, neo-tree git status (lazygit tab if nvim is down) |
| `PR` | `:Octo pr edit` in that tab, else the PR in the browser |

```bash
tools/wtc-browse.sh              # this collection
tools/wtc-browse.sh --here       # this terminal, even from an agent pane
```

A status pane opened before clicking existed keeps running the old command
(nothing here restarts a live pane). Re-run the command in that pane when you
want it, or open a new wtc.

For an interactive look at what the agents are actually running, bind a
process monitor to a popup — full screen, closes on exit, layout untouched:

```toml
[[keys.command]]                 # ~/.config/herdr/config.toml
key = "prefix+alt+t"
type = "popup"
command = "btop"
```

## What to run in a pane

`herdr pane run` is not a better `bash`: a pane gives screen text, not an exit
code, and alternate-screen programs read back badly. Anything whose *result*
you act on — tests, builds, git — runs directly in the agent's own shell.

Panes are for processes that outlive the turn or that a human should watch:
dev servers, `docker compose up`, watch-mode runners, log tails, and TUIs
(`wtc-browse.sh`, lazygit) which belong in `browse`. A dev server in a pane is
also findable via `herdr pane list`, so the next agent doesn't start a
second copy on the same port.

### Write it relative

Every command a tool types into a pane is **relative to the collection root**,
which is that pane's cwd: `./harness/tools/wtc-status.sh --repos`,
`./harness/tools/wtc-browse.sh --here`, a bare `lazygit` in a pane opened at
the worktree. No absolute paths, and no collection argument where the tool
already defaults to the collection it runs from. A pane's shell history is
then a set of commands anyone can re-run in any collection, rather than a
record of one machine's directory layout.

### Agent names

An agent is named **`<session>--<collection>`** — `wtc--billing-api`. That
string is emitted as `WTC_AGENT_NAME` in `.env.collection` (and injected into
every pane); `wtc-open` starts with `herdr agent start "$WTC_AGENT_NAME" …`,
so the command shape is the same across collections and only the env differs.
herdr caps names at 32 characters (`[a-z][a-z0-9_-]{0,31}`, unique among live
agents); past that the collection half is trimmed and the session prefix
stays, because the prefix is what keeps two sessions on one machine from
colliding. A collection named for a GitHub issue (`239-timeline-…`) is fine:
the session half starts with a letter, and if the session itself does not it
gets a `w` prefix. One string then reads the same in the collection env, in
`herdr agent list`, in Claude's Remote Control list, and on the phone.
`--session` overrides recompute the name when it would no longer match.

Commands that address a running agent (`agent prompt`, `agent wait`) take a
name **or a pane id** — prefer the pane id. A name only exists while the agent
herdr started is still that pane's occupant.

## Subagents vs. herdr agents

Subagents are ephemeral workers inside one task — shared context, structured
results, cheap. They stay the default for parallel work inside a wtc.

A herdr agent is a separate full session with its own context and wtc. Start
one only when the work is genuinely separate. **The prompt is ignition, not
the record:** put the assignment in an issue, branch, or `HANDOFF.md` first and
let the prompt point at it, so a dead agent costs nothing.

```bash
tools/branch-off.sh --issue api-1234 paging-clamp --open
herdr --session <project> agent prompt api-1234-paging-clamp \
  "Read HANDOFF.md at the wtc root, then start." --wait
```

## Never kill running state

Panes hold live work — an agent mid-task, a server, a test run — and an agent
conversation that dies is not recoverable from git. So: **no closing panes or
workspaces, no `session stop`, no restarting an agent, to apply a change.**
Add non-destructively and let re-running `wtc-open.sh` heal the workspace; it
is written to repair in place for exactly this reason. If something genuinely
cannot be fixed without killing a running pane, **ask the person first** —
it is their session, and "it was only idle" is not yours to judge.

## Traps

- **Panes inherit the server's environment.** A server started from inside an
  agent's shell hands that agent's env to every pane — a claude pane then
  inherits `CLAUDE_CODE_CHILD_SESSION` and runs with transcript saving off.
  `herdr_ensure_session` strips agent variables at server start; an already
  polluted server needs `herdr session stop`, and its panes must be recreated
  (restore reuses each pane's original environment).
- **Agent state accuracy** needs `herdr integration install claude` once per
  machine; without it, `blocked`/`done` are guesses.
