---
name: wtc-browse
description: Open LazyVim on a worktree collection with one vim tab per sibling so git integrations work. Use when the user wants to look around a collection, browse its files, or open the wtc in nvim. From a terminal it opens in this window; from an agent inside herdr it goes to the browse pane and a gh-dash pr tab. For a text snapshot of branches and PRs, use wtc-status instead.
---

# Browse a wtc in neovim

One LazyVim, one vim tab per sibling (`:tcd`). Git plugins then see a real
repo. The multi-repo map is `wtc status`, not this buffer. If you need to
*say* what is in flight, run `wtc status`.

## 1. Confirm you are in a collection

A `harness/` next to the siblings, or `harness/AGENTS.md` one level up. The
collection root is the directory holding `harness/`.

## 2. Open it

```bash
wtc browse                  # this collection
wtc browse <collection>     # a named one under the workspace root
```

From a terminal (including the herdr `shell` pane) this opens nvim **in
this window**. From an agent pane it sends nvim to the workspace `browse`
pane — never into the agent itself — and opens a `pr` herdr tab with
`gh dash` if that extension is installed. `--here` forces this terminal.
The installed `wtc browse` command opens the browser directly.

Do not pass `--here` from an agent pane unless the user asked to take it over.

## 3. Leave it alone

nvim uses the alternate screen. Do not `herdr pane read` it to answer a
question, and do not scrape the TUI. The human reads it; you keep working
in your own pane. gt / gT (or the tabline) switches siblings.

---
Canon: `harness/instructions/herdr.md`.
