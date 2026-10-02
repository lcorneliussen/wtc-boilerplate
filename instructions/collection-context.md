# Detecting and using the collection from inside a repo

Work is often driven from one repo — e.g. a backend task in `api`
that also needs console or device changes — with the agent or IDE opened
on that repo alone. Repos should therefore *detect* when they sit inside a
worktree collection and use the siblings instead of inventing their own
multi-repo setup.

## Detection

A collection worktree's git dir lives under the workspace `.bare/`:

```bash
common="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$common" in
  */.bare/*.git) echo "inside a worktree collection" ;;
esac
```

Cheaper heuristic (no git needed): a sibling `../harness/AGENTS.md` exists →
you are in a collection; the collection root is `..`.

## Tool scope

Every `tools/*.sh` acts on **this** collection — the one holding the harness
worktree it was run from — when you give it no scope. Widening is always
something you typed: `--all`, or a collection name. So a bare
`./harness/tools/wtc-xyz.sh` is the safe command to reach for, and it is also
the useful one.

| Tool | Bare run | Wider |
|---|---|---|
| `wtc-status.sh` | this collection | `--all`, `<collection>` |
| `wtc-open.sh` | this collection's workspace | `--all`, `<collection> …` |
| `wtc-browse.sh` | this collection in nvim | `<collection>` |
| `add-repo.sh` | this collection | `--collection <name>` |
| `link-skills.sh`, `link-secrets.sh`, `refresh-configs.sh` | this collection | `--collection <name>`, `--all` (link-skills) |

Two tools are outside the rule by nature: `branch-off.sh` creates a new
collection, and `retire.sh` needs a target to destroy. With a matching CLI pin,
`retire.sh .` delegates self-retirement to a separate Herdr cleanup workspace.
The older-pin shell fallback still requires an external collection.

A default you want changed on this machine belongs in `$WTC_CONFIG_ROOT/wtc.env`
([secrets.md](secrets.md)), not in flags you have to remember every time.

## The two files at the root

| File | Kind | Says |
|---|---|---|
| `AGENTS.md` | symlink to `harness/collection-AGENTS.md`, versioned | What a collection is, stay inside it, where the instructions live, that nothing durable lives in this folder |
| `WTC-SCOPE.md` | local copy of `harness/collection-SCOPE.md`, ephemeral | What **this** collection is for: the task, the repos in it, what is deliberately out |

`AGENTS.md` is the only file an agent reads by itself when it opens the
collection root, which is why the shared guidance lives there rather than in a
per-tool rule file. It is linked, so a catch-up updates it everywhere.

`WTC-SCOPE.md` is seeded — by `branch-off.sh`, or by `/wtc-start` on a
collection that predates it (`tools/link-skills.sh --seed-scope`) — and then
filled from `HANDOFF.md` as that note is consumed. It is never linked and
never overwritten: it is this collection's own answer, and it dies with the
folder.

**Widening the scope is a deliberate edit.** Pulling in another repo
(`add-repo.sh`) or taking on an area the scope file does not mention means
saying so in `WTC-SCOPE.md` first. A collection whose scope file no longer
describes it has quietly become two tasks, which is how work leaks into a
collection sibling.

## Using the collection

Once detected:

- **Collection root** is the parent directory. `../HANDOFF.md`, if present,
  is an **ephemeral launch note**: read it, convert anything durable into
  issues/commits, then delete it (first agent's first action — see
  `../harness/AGENTS.md` → "State lives in git"). Its absence is normal;
  ongoing context lives in branch state and issues.
- **Repo siblings** are sibling directories named after the repo
  (`../api`, `../console`, …). Check existence before use —
  collections only contain the repos in scope. The full inventory is
  `../harness/.harness-repos.yml`.
- **Harness instructions** (workspace pattern, workflows, catch-up):
  `../harness/AGENTS.md` and `../harness/instructions/`.
- **Collection env**: `../.env.collection` holds shared variables —
  `WTC_COLLECTION`, `WTC_AGENT_NAME`, `COLLECTION_PORT_BASE`, and
  `<REPO>_PORT` for serving repos (e.g. `API_PORT`). mise-activated shells
  inherit it automatically via the collection-root `mise.toml`; otherwise
  `set -a; . ../.env.collection; set +a`. Details and the init/teardown hook
  contract (`harness:init` mise task or `.harness/init.sh`):
  `../harness/instructions/hooks-and-env.md`.
- Orchestrating from here into siblings is fine (edit, branch, PR per each
  repo's own conventions), but **respect each sibling's `AGENTS.md`** —
  branch policy, working branch, and any commit/push restrictions are per
  repo. In particular `ops` remains read-only-prod ops with
  its own rules.
- Outside a collection (standalone checkout): do not guess at `../` paths;
  work single-repo, or set up / open a collection first.

## Snippet for product repo AGENTS.md files

Copy-paste (adjust nothing):

```markdown
## Worktree collection

If `../harness/AGENTS.md` exists, this checkout is part of a worktree
collection (wtc): sibling repos are at `../<repo-name>`, and multi-repo
conventions live in `../harness/AGENTS.md` (repo: <org>/agent-harness)
— including the rule that durable state lives in git, not in sessions, and
that a `../HANDOFF.md` launch note is consumed and deleted. Cross-repo work
should use those siblings rather than separate clones. Outside a collection,
treat this as a standalone checkout and do not assume `../` layout.
```
