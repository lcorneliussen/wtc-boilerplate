# MCP servers

Agents reach some systems through an **MCP server** rather than a CLI. Which
servers exist is declared once, in this repo, and rendered into each
collection's per-agent config — the same tracked-source / generated-output
split the repo registry uses.

```text
harness/.mcp-servers.yml          # tracked: WHAT servers exist
      │  wtc mcp render
      ├─> <collection>/.mcp.json              (Claude Code, project scope)
      ├─> <collection>/.cursor/mcp.json       (Cursor)
      └─> <collection>/.codex/config.toml     (Codex, trusted projects only)
```

Rendered rather than symlinked, unlike skills: the three CLIs want two
serialisations (JSON and TOML) of the same facts, so one file cannot serve
all three. They sit at the **collection root** because it is not a git repo —
the files are invisible to git and no repo needs an ignore rule for them
(same reasoning as `wtc skills render`), and it is where `AGENTS.md` says
to start an agent.

## Credentials are named, never valued

`.mcp-servers.yml` is tracked. A token in it is a committed token. So the
registry names the **variables** a server needs and the renderer emits
references, not values:

| Agent | Rendered as | Value arrives from |
|---|---|---|
| Claude Code, Cursor | `"JIRA_API_TOKEN": "${JIRA_API_TOKEN}"` | shell env at launch |
| Codex | `env_vars = ["JIRA_API_TOKEN"]` | forwarded from ambient env |

The environment is the collection's own, which `mise.toml` composes from
`.env.collection` (generated non-secrets) and `.env.collection.local`
(hand-authored secrets, 600, dies with the collection). See `secrets.md` for
which tier a given credential belongs in.

This is what makes the credential **per collection** rather than per machine:
two collections can point the same server at two different accounts, and
neither can read the other's. A server configured in a machine-global agent
config cannot do that, which is the reason this file exists at all.

`wtc mcp render` prints `note: unset in this shell: …` for any named variable the
environment lacks. Rendering config before creating the credential is a normal
ordering — the note exists so the failure surfaces there rather than as an
opaque auth error inside an agent later.

## Adding one

```yaml
  - name: <key the agent sees>
    transport: stdio          # or http
    command: uvx              # stdio only
    args: some-server --flag  # stdio only, whitespace-separated
    url: https://…            # http only
    env: VAR_A VAR_B          # variable NAMES, never values
    token_env: SOME_TOKEN     # http only — bearer token variable NAME
    agents: claude codex cursor   # default: all three
    enabled: yes              # no = registered but not rendered
    role: one line, for humans reading the file
```

Then run `wtc mcp render` in this collection, or add `--all` to render every
collection. For arguments containing spaces, set `args` to a quoted JSON
string array, for example `args: '["one argument", "--flag"]'`. The CLI
validates the registry before writing output files.

## What is deliberately not an MCP server

**`gh` stays a CLI.** The GitHub MCP server was considered and rejected for
this harness, for reasons worth not relitigating:

1. `gh` is already a CLI that both humans and agents use alongside `wtc`.
   An MCP path would duplicate the same operations and credentials.
2. Four `gh api graphql` calls have no MCP equivalent; the official server
   exposes no arbitrary-GraphQL tool. `resolveReviewThread` (`wtc-pr` §6.4)
   is one of them.
3. `gh pr checks | awk` filters outside the model. The MCP form puts every
   check into context and asks the model to filter, and its tool schemas are
   resident in every session whether used or not.

The general rule: **a CLI that both a human and a script can run beats a
server only an agent can reach.** Reach for MCP where no such CLI exists, or
where the CLI cannot express what an agent needs.

**Atlassian stopped qualifying**, and the reversal is instructive. It was
briefly registered here as a community `mcp-atlassian` server needing a
`JIRA_API_TOKEN`. Then the Teamwork Graph CLI (`twg`) turned out to be
first-party, browser-OAuth, and to ship *both* a CLI and agent skills — so the
rule above answers it directly, and a second Atlassian path would only have
meant two credentials for one system. See `jira.md`.

That leaves the registry empty, which is a working state rather than a gap:
`wtc mcp render` renders empty configs from it, and that is how a server removed
from the registry gets pruned out of every collection.

## Per-agent caveats

- **Codex** loads a project-scoped `.codex/config.toml` only for projects
  marked **trusted**. An untrusted project ignores it silently — if servers
  do not appear, trust is the first thing to check.
- **Claude Code** expands `${VAR}` in `.mcp.json` in the CLI. Two known gaps:
  the macOS desktop app does not expand it, and `${VAR}` inside `headers` for
  http-transport servers is not substituted on some platforms. Prefer a
  stdio server with `env:` over an http server with `token_env:` where both
  are on offer — Codex's `bearer_token_env_var` has no such gap, but Claude's
  header path does.
- **Cursor** reads `.cursor/mcp.json`; it is rendered identically to Claude's.

## Where this is wired in

Same lifecycle as `wtc skills render`, and for the same reason — a collection is
generated and disposable, so it is re-rendered rather than maintained:

- `wtc new` and `wtc add-repo` call it at creation, before the init hooks
- `wtc-catch-up` §4.1 re-renders, picking up registry changes since
- `--all` rolls a landed registry change across every caught-up collection
