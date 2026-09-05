---
name: wtc-follow
description: Follow work initiated or assigned to this session from a review-ready PR through checks, conversations, merge, main builds and required delivery follow-ups. Use for follow PR, follow-through, or relevant status/check/review updates for owned work. Use wtc-catch-up to bring outside changes into the collection, and wtc-status for read-only status requests.
---

# Follow owned work through delivery

Locate the collection via `WTC-SCOPE.md` and its `harness/`, read the affected
repo's instructions, and identify the assigned PRs. If ownership or the
intended delivery outcome is missing, reconstruct it from the task and PR
before changing anything. An enlisted PR may be reference material, so its
presence alone is not authorization to advance it.

Read [the follow-through policy](../../instructions/pr-follow-through.md).
It defines freshness, automatic resumption, human checkpoints, post-merge
verification and the stopping condition. Use it for every follow pass.

## Resume from evidence

1. Reuse this collection's status snapshot if fresh (2 minutes foreground,
   10 background); otherwise refresh it once without fetching git remotes. Events about
   one PR go directly to that PR's current facts. See the policy for invalid
   snapshots, rate limits and authoritative checks before actions.
2. Reuse any existing follower. Determine current head/base, PR state, checks,
   reviews and conversations; after merge, find the exact merge SHA's main
   build and the required delivery steps. Check the PR/issue's continuation
   record so completed actions are not repeated.
3. Advance what is actionable using
   [wtc-pr](../wtc-pr/SKILL.md#6-follow-it) for checks, review replies and
   resolution, and [wtc-catch-up](../wtc-catch-up/SKILL.md) when incoming
   changes need integrating. A merged branch is finished; further changes
   get a new branch and linked follow-up PR.
4. If only asynchronous work remains, use a notification-capable background
   mechanism that is available in this host. Keep the conversation responsive
   and continue independent work. Do not claim automatic continuation from
   an ordinary shell job or from this skill alone.
5. At a human checkpoint, give the concrete decision with current evidence
   and the source of any authorization boundary. Once the human acts, resume
   the remaining gates instead of declaring the task complete at merge.

## Report the remaining gate

Give the PR URL and current SHA, checks and reviewer results, conversations
addressed versus left open (and why), main/deployment evidence if applicable,
and required follow-up links. End with the next actor/action or the verified
completion outcome. Distinguish a running follower, a prepared human
checkpoint, and a handoff that needs another invocation.

Keep durable continuation details in the PR/issue at meaningful transitions.
A local snapshot or disappearing worktree must not erase the delivery plan.
