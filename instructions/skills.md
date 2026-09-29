# Skills — `wtc-*` procedures across agent CLIs

The recurring collection actions are packaged as **skills**: `SKILL.md`
procedure files the agent CLIs discover on their own and load only when a task
matches. They live in this repo under `skills/`, and are exposed at each
collection root by symlink.

Design principle, as everywhere else here: **no tool is load-bearing.** A
skill is a procedure written for a reader — an agent whose CLI never heard of
skills still finds them, because `AGENTS.md` lists them and they are plain
markdown at a stable path.

## Division of labour

| Lives in | Holds |
|---|---|
| `instructions/*.md` | **Canon** — the rule, the geometry, the rationale. One source of truth. |
| `skills/wtc-*/SKILL.md` | **Procedure** — what to do, in order, with the judgement calls named. Links to canon rather than restating it. |
| `tools/*.sh` | **Mechanism** — the steps a script should own. |

A skill that only wraps one script invocation is not worth a file; the value
is the surrounding judgement (which flag, what to check first, what to do with
the result). When a skill and an instruction disagree, the instruction wins
and the skill is the bug.

## Discovery: what each CLI actually reads

| CLI | Reads | Traversal |
|---|---|---|
| Claude Code | `.claude/skills/<name>/SKILL.md` | cwd **and every parent up to the repository root**; follows symlinked skill dirs |
| Codex | `.agents/skills/` | `$CWD`, `$CWD/..`, `$REPO_ROOT`, `$HOME`, `/etc/codex/skills`; follows symlinks |
| Cursor | `.agents/skills/`, `.cursor/skills/`, plus `.claude/skills/` and `.codex/skills/` for back-compat | each skills root recursively, plus nested project subdirs |

So **two directory names cover all three**: `.claude/skills` and
`.agents/skills`. `tools/link-skills.sh` selects the collection's pinned
`wtc skills render` when available and retains a shell bootstrap path. Both
create one symlink per skill at the collection root:

```text
<collection>/AGENTS.md              -> harness/collection-AGENTS.md
<collection>/.claude/skills/wtc-pr  -> ../../harness/skills/wtc-pr
<collection>/.agents/skills/wtc-pr  -> ../../harness/skills/wtc-pr
<collection>/.grok/hooks/wtc-agent-env.json -> ../../harness/hooks/agent-env.json
<collection>/.claude/settings.json  -> ../harness/hooks/agent-env.json
<collection>/.cursor/hooks.json     -> ../harness/hooks/agent-env.json
```

The hook JSON prepends sibling toolchain bins on PATH for agent shells that
never activated mise (`instructions/hooks-and-env.md` → Agent shells and PATH).
`.envrc` and `.env.toolchain` at the collection root are generated, not linked.
The CLI includes default `wtc-*` skills under generated `.wtc/skills/`. A
complete skill in `harness/skills/<name>/SKILL.md` replaces an embedded default;
`harness/overlays/skills/<name>/SKILL.md` takes precedence over both. Local
real directories in the destination skill roots are preserved. See
`wtc customize` for the override and lifecycle hook contract.

The same tool installs the collection's **entry point**, `AGENTS.md`: the file
every one of those CLIs reads on its own when it opens the collection, which
makes it the one place shared guidance lands without a per-tool rule file. It
is authored as `harness/collection-AGENTS.md`, named for where it goes — a
file actually called `AGENTS.md` in the harness would be read as instructions
for whoever is editing that folder. Its companion `WTC-SCOPE.md` says what the
individual collection is for; see
[collection-context.md](collection-context.md).

Why the collection root: it is where agents are meant to start (cross-repo
context lives in the siblings), and it is **not a git repo**, so the link
directories are invisible to git and no product repo needs an ignore rule for
them. Why symlinks and not copies: one authored copy, versioned in this repo;
collections stay disposable and carry no durable state.

The tool runs at collection creation (`branch-off.sh`, `add-repo.sh`) and
again at catch-up, which is how a collection created before a skill existed
picks it up.

### Across collections

Every collection is linked against **its own** `harness/` worktree — the links
are relative, so that is what they resolve against. This is deliberate: a
collection working on the harness itself gets its own in-progress skills, and
retiring one collection can never break another's.

The consequence is an ordering rule. A new skill reaches another collection
only once that collection's harness worktree has it **in git** — so the
sequence is merge → catch that worktree up → link, never the other way round.
`link-skills.sh` reports `(none)` rather than inventing links a stale worktree
cannot back.

```sh
tools/link-skills.sh                        # this collection
tools/link-skills.sh --collection ../billing
tools/link-skills.sh --all --dry-run        # what every collection would get
tools/link-skills.sh --all                  # roll a landed skill out everywhere
```

`--all` re-execs per collection, so each target selects its own CLI pin and
one collection mid-rebase cannot take the sweep down with it; a nonzero exit
means at least one collection failed.

### The one gap

An agent started **inside a sibling worktree** rather than at the collection
root:

- **Codex** sees the skills anyway — it scans `$CWD/..`.
- **Claude Code** does not: its upward walk stops at the repository root,
  which in a worktree is that worktree. Start it at the collection root (the
  documented default), or pass `--add-dir ..` — `.claude/skills` inside an
  added directory is loaded.
- **Cursor** sees them when the collection root is the opened workspace root.

This is a reason to keep opening collections at the root, not a reason to
scatter links into every worktree — that would need a gitignore rule in each
product repo, which is exactly the coupling this layout avoids.

## Authoring rules

1. **Frontmatter is `name` and `description`, nothing else.** That pair is the
   intersection all three CLIs accept. Richer fields — `allowed-tools`,
   `disable-model-invocation`, `context:` — are specific to one or two of them
   and become validation errors in the others. Anything else the agent needs
   goes in the body.
2. **`name` must equal the directory name**, lowercase with hyphens. Cursor
   requires the match; Claude Code takes the command name from the directory
   either way, so identical costs nothing.
3. **The `description` is the entire discovery surface.** All three match on
   it and nothing else before loading the body. Say what the skill does *and*
   when to reach for it, in the words a user would actually type, and name the
   sibling skill to use instead when there is a near neighbour (`wtc-pr` vs.
   `wtc-draft-pr`).
4. **No CLI-specific interpolation in the body.** `${CLAUDE_SKILL_DIR}` and
   friends are substituted by one CLI only. Reference paths from the
   collection root (`harness/tools/…`, `harness/instructions/…`), which is
   stable and readable everywhere.
5. **Open with orientation, not action.** A skill may be loaded by an agent
   that has no idea where it is; the first step is establishing that it is in
   a collection at all.
6. **Name the judgement calls, and where they stop.** The parts worth writing
   down are the ones with a decision in them — and the point at which the
   decision stops being the agent's (merging, force-pushing, killing a live
   pane).
7. **Keep the `wtc-` prefix.** It groups them in `/`-autocomplete and keeps
   them from colliding with skills a product repo defines for itself.

## Adding one

```bash
mkdir -p skills/wtc-<name>
$EDITOR skills/wtc-<name>/SKILL.md     # frontmatter: name + description
tools/link-skills.sh                   # link it into this collection
```

Then add it to the table in `AGENTS.md`. Other collections pick it up at their
next catch-up, once the change has merged — or in one pass with
`tools/link-skills.sh --all` after those worktrees are current. Removing a
skill is the reverse: delete the directory, and `link-skills.sh` prunes the
dangling links on its next run.

Live reload varies by CLI — Claude Code picks up edits within the session, but
a skills directory that did not exist at startup needs a restart.
