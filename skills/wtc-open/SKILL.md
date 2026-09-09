---
name: wtc-open
description: Open or reshape a worktree collection in herdr — ensure the agent/browse/shell/status layout, switch wide ↔ narrow, and start an agent only when the agent pane is empty. Use when the user says wtc-open, open the collection in herdr, switch to narrow/wide layout, or fill missing panes after starting an agent first.
---

# Open a collection in herdr

Mechanism: `harness/tools/wtc-open.sh`. Canon: `harness/instructions/herdr.md`.

A workspace is ergonomics only — worktrees already exist. Opening is
idempotent: reuse the workspace, keep a live agent, fill idle panes, and
only reshape when asked (or when the layout is still partial).

## 1. Run it

From the collection root (or name the collection):

```bash
harness/tools/wtc-open.sh                 # this collection; auto layout
harness/tools/wtc-open.sh --narrow        # stacked tabs; switch if needed
harness/tools/wtc-open.sh --wide          # stacked columns; switch if needed
harness/tools/wtc-open.sh --list          # pane-by-pane report; change nothing
harness/tools/wtc-open.sh --dry-run       # plan only
```

Bare args after flags are collection names under the workspace root. `--all`
is always something you typed.

### Narrow vs wide

| | Wide | Narrow |
|---|---|---|
| Shape | `[ agent \| browse ]` / `[ shell \| status ]` | tab `main`: agent/status; tab `tools`: browse/shell |
| Heights | shell 20%, status 35% | same ratios, stacked full-width |
| When | default when the session is wide enough | `--narrow`, or `WTC_LAYOUT=narrow` / auto under `WTC_LAYOUT_NARROW_AT` |

`--narrow` / `--wide` **switch** an existing workspace. The agent pane is
preserved; status is recreated (cheap). Auto never flips a complete wide ↔
narrow on its own.

## 2. Agent-first is normal

Often the human (or you) starts the agent in a bare workspace, then opens:

1. `wtc-open` detects a **partial** layout and builds wide or narrow around
   the existing agent pane.
2. If the agent pane already has a live agent, it is left alone.
3. If that pane is empty (or the agent exited), `wtc-open` starts one —
   unless `--no-agent`.

Do not restart a working agent to "apply" a layout. Do not close panes to
force a reshape — pass `--narrow` or `--wide` and let the script move panes.

## 3. What to report

The script prints one line per collection (`layout switched (narrow)`,
`agent live`, `browse started`, …). Prefer that over re-probing. `--list`
is the read-only check.

## 4. Stay out of the way

- Do not `herdr session stop` or close the workspace to change layout.
- Do not type browse/status commands into a pane that is already running them.
- Attach is the human's job: `herdr --session <project>`.

---
Canon: `harness/instructions/herdr.md`.
