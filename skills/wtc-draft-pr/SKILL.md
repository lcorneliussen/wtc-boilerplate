---
name: wtc-draft-pr
description: Open or update a draft pull request for work in progress in a worktree collection — branch correctly, catch up against the remote, push, and publish a draft PR without summoning reviewers or review bots. Use when the user wants work visible, wants CI to run on it, or wants to park a branch for later without asking anyone to review it yet. When the change is ready for actual review, use wtc-pr instead.
---


Before any external write, apply [publication privacy](../../instructions/publication-privacy.md)
to the exact payload and destination. Public upstream records must not identify
private downstream projects or link to their delivery records. Keep that tracking
private, and pass the same restriction to every delegated follower.
# Open or advance a draft PR

Same machinery as `wtc-pr`, one difference that matters: **a draft does not
summon anyone.** Reviewers aren't notified, review bots stay quiet, and the
PR is not a claim that the change is finished. Use it to make work visible, to
get CI running against the branch, or to park a branch so it survives the
session.

Resumable — run it whenever, it does the outstanding part.

## Procedure

Follow **`harness/skills/wtc-pr/SKILL.md` §1 through §5.1**, unchanged:

1. §1 — read the branch, tree, and any existing PR; resolve the base from
   `default_ref` in `harness/.harness-repos.yml`.
2. §2 — route on state. Same table, with one substitution: an **open ready
   PR** is *not* demoted to draft on your own initiative. Converting a PR back
   to draft retracts a review request people may already be acting on — ask
   the user first, then `gh pr ready --undo <n>`.
3. §2.1 — create the branch as `<issue-id>-<short-slug>` if the worktree is
   still detached at the tip, or if the branch it is on has merged.
4. §3 — catch up: fetch, and merge (never rebase) the working branch in if
   behind. Worth doing even for a draft, so its CI result means something.
5. §4 — push.

Then create it as a draft:

```bash
gh pr create --draft --base <working-branch> --title "<issue-id>: <what changed>"
```

Title carries the issue ID (and the tracker key if there is one), exactly as for a
ready PR. The body can be thinner — but say what the change is for and what is
still missing, since "what's left" is the whole reason it's a draft. A
checklist of remaining work is a good body for a draft.

### Enlist it

```bash
gh pr view --json number --jq .number   # the number gh just created
tools/wtc-pr.sh enlist <repo> <n> --branch <working-branch>
```

This — not a label — is how `wtc-catch-up` and `wtc-status` find the PR later.
A label is optional and secondary now: add one only if the repo's own
conventions want it, never as a substitute for enlisting.

If a draft already exists, just push; there is nothing else to do. Check
`tools/wtc-pr.sh list` first — if it was never enlisted (an older draft, or one
opened by hand), enlist it now rather than leaving it invisible to catch-up.

## What this skill deliberately does not do

- **No `gh pr ready`**, no reviewer assignment, no review-bot triggering.
  Promoting to ready is `wtc-pr`'s §5.2 and belongs to a separate decision.
- **No comment-chasing loop.** A draft may still collect CI failures and drive-
  by comments; report them, and fix red checks if the user wants green, but
  don't run the full review round — that is `wtc-pr` §6.
- **No merging**, under any circumstances. A draft PR cannot merge, and
  making it mergeable is the promotion decision again.

## After

Note the draft's URL in the issue. Do **not** transition the tracker ticket on a
draft — a draft PR is not a meaningful transition; "shipped" is.

Report the URL, what still has to happen before it can go to review, and
whether CI is green on it.

---
Canon: `harness/skills/wtc-pr/SKILL.md`,
`harness/instructions/development-workflows.md`.
