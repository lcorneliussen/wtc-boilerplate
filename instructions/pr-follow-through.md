# Follow the work through shipment

Catch-up brings changes from outside this session into the collection.
Follow-through carries work this session initiated or was assigned through
review, integration, and the task's agreed delivery outcome. It calls catch-up
when the base moves or a merged worktree needs returning to the tip.

A push, a green PR, and a merge are milestones. Completion means the required
main/default-branch checks have passed and any deployment, downstream port,
or other delivery step required by this task has been verified. For a library
or harness without deployment, main checks may be the final delivery gate.
Read the task and repository workflows to establish which gates apply.

## Ownership and resumption

The session that opens or advances a review-ready PR owns its follow-through
unless ownership is explicitly handed off. Resume it after a push, a relevant
status/check/review/merge update, and when returning to the collection. Do not
require the user to keep saying “follow PR”. A status-only request remains
read-only; seeing someone else's PR in a table is not ownership or permission
to change it. Work stays within the assigned collection and task.

Use one follower per PR and one writer per branch. Reuse a running follower
instead of starting another on every notification. Identify work by forge,
repository, PR number and current head SHA; after merge also record the merge
SHA and default branch. Re-read those facts before a mutation. Stop writes to
an old branch as soon as its PR is merged or closed.

The PR/issue is the durable record: keep the intended delivery outcome,
required follow-up PR links, completed gates, outstanding checkpoint and next
action there at meaningful transitions. `.wtc-prs` and status snapshots are
local indexes/caches, not the sole record. A restarted session must be able to
reconstruct what remains without the old process or chat history. Do not
unlist or retire work merely because its PR merged or its status row aged into
the archive; first finish or explicitly hand off the delivery obligations.

## Use status updates without repeating all the forge calls

Read this collection's `.wtc-status.json` (`generated_at` is UTC), or the age
shown by `harness/tools/wtc-status.sh --cached`, before requesting a new table.
Default freshness limits for a follower are **2 minutes in the foreground**
and **10 minutes in the background**. Unknown focus uses foreground. These
are agent scheduling defaults, separate from the TUI render interval and
forge cache TTL; they do not create a timer by themselves.

- Reuse a valid, complete snapshot within the limit for triage. Refresh this
  collection once with `harness/tools/wtc-status.sh --json --no-fetch` when
  it is missing, malformed, older, or has an invalid/future timestamp. Do not
  widen to `--all` without explicit scope.
- A push, review, check completion or merge notification invalidates the
  affected PR's facts immediately. Query that PR/run directly; do not wait
  for the table's age limit or refresh unrelated rows.
- A fresh table can contain cached or unknown forge answers. Before fixing a
  build, replying/resolving, or presenting a human checkpoint, fetch current
  PR identity, checks, reviews and conversations from the forge. After a
  local push, only checks for the new head count. A rollup cannot prove that
  reviewers reported or that all conversations were addressed.
- Rate limits and auth failures mean unknown, not “no findings”. Honor retry
  timing, reuse existing evidence with its age stated, and report the missing
  verification. Do not refresh every pane or rerun a failed API call in a tight
  loop. REST can supply checks/reviews when GraphQL is unavailable, but cannot
  establish whether review threads are resolved.

Prefer check/review completion notifications. Use a background job or an
available event monitor that actually delivers completion to the initiating
session. Where polling is necessary, use the freshness cadence above and
avoid duplicating a live TUI's refresh. Stop polling when no automated work
remains, ownership is transferred, or the task is cancelled. Authentication
failures and unavailable reviewers should become explicit blockers after a
bounded retry, not infinite re-requests.

An ordinary detached shell process does **not** necessarily wake the agent.
Before reporting “following automatically”, establish the host's notification
or scheduled-resumption mechanism and its lifetime. If none is available,
perform the current pass, preserve the next action in the PR, and state that
continued observation needs another session invocation. Instructions alone
cannot schedule work while no agent is running.

## Advance every actionable gate

For each owned PR, use `wtc-pr` for forge commands and review mechanics:

1. **Base moved:** catch up the affected worktree, merge the default branch
   into live work, resolve routine conflicts within the task, validate and
   push. Coordinate with any existing writer. Large semantic decisions become
   a concrete checkpoint; do not silently choose product behavior.
2. **Checks failed:** read the logs, diagnose, fix and push. A supported
   transient infrastructure failure may justify one rerun. Repeated identical
   failure needs investigation, not repeated retries. Wait for checks on the
   resulting head before calling it green.
3. **Review pending:** verify that expected reviewers actually ran on the
   current changes. A successful bot job is not an approval. Read review
   bodies, suppressed findings, top-level conversation and every inline thread;
   paginate API results. An old review or an errored bot is not a clean round.
4. **Feedback present:** fix valid findings and reply with the commit; explain
   disagreements. Resolve only conversations actually settled. Outdated
   threads still need checking. Answer actionable top-level comments too,
   without inventing a “resolved” state where the forge has none. Verify that
   prior replies/resolutions already exist before repeating them. Re-request
   review after a changed round and confirm the request took effect; if a
   reviewer repeatedly fails, surface it rather than requesting forever.
5. **Ready for a human:** finish the work possible under existing authority
   before asking. Present PR URL, head/base SHA, current checks, review state,
   remaining conversations and the concrete decision (merge, release, scope).
   Name any unverified gate. “No findings” and “approved” are different states.
   Preserve authorization already given; do not ask again for the same action.
6. **Merged:** follow the main/default-branch build for the exact merge SHA.
   A green PR build or an unrelated later main build is insufficient. If CI
   coalesces or supersedes it, verify a tested descendant contains the merge
   and say which commit supplied the evidence. Check the configured workflow
   before interpreting an absent run as either success or failure.
7. **Integration or delivery failed:** inspect the failure. Prepare a fix on
   a new branch from the current default tip and link its follow-up PR to the
   original; never append commits to the merged branch. Follow that PR through
   the same gates. Unrelated failures need attribution and a named owner or
   explicit handoff, not an endless expansion of this task.
8. **Delivery remains:** verify the deployment/release artifact and target
   environment if the task requires them. A successful build is not proof of
   production deployment. Prepare required downstream ports, docs or release
   PRs in dependency order, and follow their checks/reviews. Additional repos
   go through `wtc-add-repo` and the collection scope rules. Prepare any manual
   release action fully before its human checkpoint; do not infer permission
   to deploy from permission to open/follow a PR.
9. **Delivered:** catch this collection up, verify the agreed outcome, and
   record the merge/build/delivery evidence and any explicitly handed-off
   follow-ups in the PR/issue. Stop its follower. Retiring the collection still
   requires the user's request.

Merge with a merge commit only when authorized, retain remote branches, and
respect repository rules. Waiting for a human is a checkpoint, not shipment;
report the action and why that decision remains theirs. If a human merges
while a review is still running, finish reading it and route valid late
findings to a new follow-up branch.
