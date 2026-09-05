---
name: wtc-pr
description: Open or advance a review-ready pull request for work in a worktree collection — catch up against the remote, branch correctly if needed, push, open or un-draft the PR, request review, then follow its checks, wait for the review bots to actually report, and address what they find with fixes, replies, and resolved threads. Use when the user asks to open a PR, mark one ready, ship or land a change, chase a red build, or answer review feedback. For ongoing ownership through main builds and delivery, use wtc-follow. For work in progress that should not summon reviewers yet, use wtc-draft-pr instead.
---

# Open or advance a review-ready PR

This skill opens and advances review-ready PRs. Opening or advancing one starts
[wtc-follow](../wtc-follow/SKILL.md) ownership for this session: resume on its
status/check/review updates and carry it through main builds and the task's
required delivery steps. Nothing actionable before a human checkpoint is a
valid outcome; it is not a claim that the work has shipped.

Work per repo. In a cross-repo wtc, run it once per sibling that has changes,
newest dependency first; each repo gets its own branch and its own PR under
its own conventions.

## 1. Read the ground

```bash
cd <collection>/<repo>
git branch --show-current
git status --short
gh pr view --json number,state,isDraft,url,baseRefName,headRefName,\
reviewDecision,mergeStateStatus,statusCheckRollup 2>/dev/null
```

The **base** is that repo's `default_ref` in `harness/.harness-repos.yml`,
minus the `origin/` prefix (`main` or `develop`). Never target a `release_ref`
— merging one deploys to production; that is a deliberate release action, not
a PR flow, and it needs the repo's `AGENTS.md` consulted and a human's say-so.

Check the repo's own `AGENTS.md` before pushing anything: some repos restrict
what may be committed from where.

## 2. Route on the PR state

| State | Do |
|---|---|
| No PR, on an issue branch with commits | §3 → §4 → §5 (create) |
| **Detached at the tip** (the resting state) | §2.1 — create the branch, that is what this moment is for |
| **Merged** PR | The branch is finished. Resume `wtc-follow` for main checks and required delivery/follow-ups, then catch up. Never commit onto it. |
| **Closed, unmerged** PR | Stop branch writes and determine whether the task was abandoned or superseded. Record/handoff remaining work; do not silently reopen it. |
| Open **draft** | §3 → §4, then §5.2 (mark ready) → §6 |
| Open, ready for review | §3 → §4 (push anything outstanding) → §6 |

### 2.1 Create the branch — here, not earlier

Worktrees rest **detached at the development tip**; the branch is created at
the first commit, which is this moment, because now the work has a name:

```bash
git switch -c <issue-id>-<short-slug>
```

Uncommitted changes follow you onto the new branch. If the worktree is instead
sitting on an old branch whose PR merged, detach to the tip first
(`git checkout --detach <default_ref>`) so the new branch starts from current
code rather than from finished work.

The name encodes the issue — that mapping is the whole point, so keep it exact
(`api-foh7-paging-clamp`). Housekeeping with no issue still gets a short
descriptive branch (`setup/branch-policy-docs`). Then commit; multiple commits
are encouraged, they are the per-issue story.

## 3. Catch up before you open it

A PR raised against a stale base wastes a review round. Bring the base
forward first — run the `wtc-catch-up` skill, or at minimum:

```bash
git fetch --prune origin
git log --oneline HEAD..origin/<working-branch>   # what you are behind by
```

If the branch is behind and the tree is clean, **merge** the working branch
in — do not rebase. This policy keeps branch history intact; rebasing rewrites the
per-issue record:

```bash
git merge origin/<working-branch>
```

Conflicts are yours to resolve on the branch, then commit. If the tree is
dirty, commit or stash first — never merge into a dirty tree. If the merge is
large or the conflicts are semantic rather than textual, stop and tell the
user before proceeding.

## 4. Push

```bash
git push -u origin HEAD
```

Already-pushed and nothing new is fine — say "nothing to push" and move on.
Never force-push a branch that has an open PR unless the user asks: it
detaches existing review comments.

**Pushing to a fork** — when the PR goes to a sibling's upstream and the
branch has to live on your fork — push it under **the same name it has here**:

```bash
git push https://github.com/<you>/<repo>.git HEAD:refs/heads/$(git branch --show-current)
```

`wtc-status` looks a branch's PR up by that name on both the sibling's origin
and its upstream, so a fork branch named something else leaves the row blank
for work that is in review. Renaming it afterwards does not repair this:
GitHub **closes** a cross-fork PR when its head branch is renamed rather than
retargeting it, and a closed PR cannot be reopened onto the new name.

## 5. Open the PR

```bash
gh pr create --base <working-branch> --fill --title "<issue-id>: <what changed>"
```

- **Title** carries the issue ID, and the tracker key too when one exists
  (`api-foh7 / PROJ-123: clamp paging at 500`) — that is what makes the chain
  visible from GitHub.
- **Body** says what changed and why, what was verified, and anything a
  reviewer should look at hardest. Link the issue and the tracker ticket. If this
  is one of several PRs for one wtc, link the siblings.

### 5.1 Enlist it

```bash
gh pr view --json number --jq .number   # the number gh just created
tools/wtc-pr.sh enlist <repo> <n> --branch <working-branch>
```

This is how `wtc-catch-up` and `wtc-status` find this PR later — a local
mapping in `<collection>/.wtc-prs`, not a forge label.
It survives everything a label would, for the one thing that actually matters
here: this collection's own tools reading it back. `tools/wtc-pr.sh list`
shows what is currently enlisted. Keep merged PRs enlisted while main checks
or required delivery steps remain; returning the worktree to the tip does not
end those obligations. Recent merged rows can age into the status archive.
Use `unlist` for a mistaken enlistment, or after delivery is verified or its
remaining obligations are explicitly handed off in the PR/issue.

A `wtc:<collection>` **label is optional now**, not how anything finds the PR.
Add one only if a repo's own conventions want it (a team dashboard filtering
on labels, say):

```bash
gh label create "wtc:$WTC_COLLECTION" --color ededed \
  --description "Opened from the $WTC_COLLECTION worktree collection" 2>/dev/null || true
gh pr edit <n> --add-label "wtc:$WTC_COLLECTION"
```

If enlisting fails for some reason, **open the PR anyway** and say so. A PR
missing from local bookkeeping is a smaller problem than a PR that was never
opened — `tools/wtc-pr.sh enlist` afterwards fixes it.

### 5.2 Ready for review

```bash
gh pr ready <n>                       # if it exists as a draft
gh pr edit <n> --add-reviewer <who>   # only if the repo doesn't auto-assign
```

Marking ready is what summons reviewers and the review bots. Do it only when
the change is genuinely reviewable — otherwise this is a `wtc-draft-pr` job.

## 6. Follow it

This is the part that makes the skill worth invoking twice.

### 6.0 Resume without blocking the conversation

Follow [wtc-follow](../wtc-follow/SKILL.md) and its
[policy](../../instructions/pr-follow-through.md) for status freshness,
notifications, ownership and stopping conditions. Reuse fresh snapshots for
triage and query the affected PR directly after a new event. A cached green
rollup does not replace current checks, reviews and conversations.

Use an available completion-notification mechanism for waits; verify that it
really wakes this session. `Bash(run_in_background)` and `Monitor` are options
only in hosts that expose them, not portable guarantees. An ordinary detached
shell process is not evidence of automatic continuation. Continue independent
work while waiting, and report the actual continuation mechanism or its absence.

### 6.0.1 When a subagent is the right answer

Delegate when the work *after* the wait is substantial and its noise does not
belong here — a red build whose diagnosis means reading a 3000-line job log, or
a review round with several threads to answer. The agent keeps the log dumps in
its own context and reports the conclusion.

Scope it explicitly, because a subagent cannot ask the user anything:

- **Give it the PR number, the repo, and the branch**, and tell it the branch is
  its to push to — but that it is the *only* one pushing there. Two followers on
  one branch is how you get a force-push over someone else's fix.
- **Say what it may decide alone**: rerunning a job, recording a flake,
  answering a review thread it can settle from the diff.
- **Say what it must hand back**: anything needing a product or scope decision,
  a fix that changes behaviour rather than tests, and merging — which is §6.5's
  call and never a subagent's.
- **Have it report back what §8 asks for**, so the answer arrives in the shape
  you would have reported it yourself.

One follower per PR. If one is already running, message it rather than starting
a second.

### 6.1 Checks

```bash
gh pr checks <n>            # snapshot; see §6.0 for waiting
```

Red check → read the failing job's log (`gh run view <id> --log-failed`),
fix on the branch, commit, push. A failure in code the branch didn't touch is
worth saying out loud rather than silently retrying — flaky infrastructure and
a real regression need different responses. Never merge on red.

**Twice on the same commit is not a flake.** A flake moves: different test,
different run. The same test failing the same way twice is a real failure, and
the next step is to find the mechanism, not to rerun a third time. If the
branch cannot plausibly have caused it, that narrows where to look — it does
not make the failure someone else's problem.

### 6.2 Have the reviewers actually reported yet?

The bots review on their own schedule, and a PR that looks unreviewed five
minutes after opening is usually a PR whose reviewers have not run yet. Check
before concluding anything about review state:

```bash
gh pr view <n> --json reviews --jq '[.reviews[] | {who: .author.login, state, at: .submittedAt}]'
gh pr view <n> --json statusCheckRollup \
  --jq '[.statusCheckRollup[] | select(.name | test("[Bb]ugbot|[Cc]opilot")) | {name, status, conclusion}]'
```

Three states worth telling apart, because they need different responses:

| What you see | What it means | Do |
|---|---|---|
| No review from a bot that reviews this repo | It has not run yet | Start a §6.0 wait and carry on — do not call the PR reviewed, and do not sit on it |
| `Copilot encountered an error and was unable to review` | It failed, silently | `gh pr edit <n> --add-reviewer copilot-pull-request-reviewer` to retrigger |
| A review exists | It reported | §6.3 |

Which bots review a repo is a property of the repo, not something to assume.
Look at what has reviewed recent merged PRs:

```bash
gh pr list --state merged --limit 5 --json number,reviews \
  --jq '[.[].reviews[].author.login] | unique'
```

Bugbot posts as `cursor[bot]`, Copilot as `copilot-pull-request-reviewer`.
Copilot also *suppresses* comments it is unsure about — they appear in the
review body under "Suppressed comments" rather than as inline threads. Read
them: they are real findings held back by a confidence threshold, not noise.
Act on the ones that hold up, and say which you are leaving.

### 6.3 Review comments

```bash
gh pr view <n> --comments                          # conversation
gh api repos/{owner}/{repo}/pulls/<n>/comments      # inline review comments
```

**Unresolved threads are the work list**, and they are a GraphQL concept — the
REST endpoint above cannot tell you which are still open:

```bash
gh api graphql -F owner={owner} -F name={repo} -F num=<n> -f query='
query($owner:String!,$name:String!,$num:Int!){
 repository(owner:$owner,name:$name){pullRequest(number:$num){
  reviewThreads(first:50){nodes{id isResolved isOutdated path line
   comments(first:10){nodes{databaseId author{login} body}}}}}}}' \
 --jq '.data.repository.pullRequest.reviewThreads.nodes[]
       | select(.isResolved | not) | "\(.path):\(.line) [\(.comments.nodes[0].author.login)]"'
```

For each unresolved comment, do **both** halves — a change without an answer
leaves the reviewer re-reading the diff to guess whether you agreed:

- **Agreed** → make the change in a normal commit on the branch, then reply
  pointing at the commit.
- **Disagreed** → reply with the reasoning, and leave the code alone. Do not
  quietly comply with a review you think is wrong.
- **Needs a decision that isn't yours** (scope, product behaviour, a breaking
  change) → surface it to the user rather than answering for them.

```bash
gh api repos/{owner}/{repo}/pulls/<n>/comments/<comment-id>/replies -f body='…'
gh pr comment <n> --body '…'      # for top-level conversation
```

Note the path: replies live under the **pull request**
(`/pulls/<n>/comments/<id>/replies`). The bare `/pulls/comments/<id>/replies`
form returns 404.

### 6.4 Resolve what you answered

A reply alone leaves the thread open, so the next person cannot tell answered
from ignored, and the count of open threads stops meaning anything. Resolve
each thread you have genuinely closed out:

```bash
gh api graphql -f query='
mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' \
  -F id='<thread-id-from-6.3>'
```

Resolve when **you** have answered it — a fix pushed, or reasoning given that
you stand behind. Do not resolve a thread whose answer is "that is the user's
call": leave it open and surface it, because resolving it hides a question
nobody answered. A bot's thread is resolvable like anyone else's; bots do not
come back to resolve their own.

Push once the round is addressed, then re-request review:

```bash
gh pr edit <n> --add-reviewer <who>
```

A re-review is also how you retrigger a bot that errored — Copilot in
particular reports failure as a review body rather than a failed check, so
nothing else will tell you it needs asking again.

### 6.5 Merging is a separate decision

When checks on the current head are green, feedback is settled, and required
approvals are present, prepare the merge checkpoint with the PR, head/base,
checks and reviewer evidence. Merge only when authorized by the user (including
authorization already given); otherwise report the remaining human action.
A clean bot review is not itself a human approval. When authorized:

```bash
gh pr merge <n> --merge     # merge commit — never --squash, never --rebase
```

Merge commits are policy: individual commits stay queryable via
`git log <working-branch>`, merges-only via `git log --first-parent`.

**After merge, the branch is done**: no new commits on it, ever. The **remote**
branch is never deleted — it is the permanent per-issue record, so leave
GitHub's "Delete branch on merge" off. The **local** ref is disposable;
`wtc-catch-up` returns the worktree to the tip and prunes it. Continue with
[wtc-follow](../wtc-follow/SKILL.md): verify main checks for the merge SHA and
any required deployment or downstream steps. A merged PR does not end that
ownership, including when the human merged it during a pending review.

## 7. Close the loop outside git

- **Issue**: record the PR link and the outcome. If it has a `tracker:` key and
  the work shipped, note that too.
- **Tracker**: comment only at meaningful transitions — started, blocked,
  shipped — referencing the issue ID and the PR. Never a running log; the
  detail lives in the issue and the PR. Transition the issue if the state
  actually changed.

## 8. Report

Say what you did, the PR URL, check status, how many review comments were
addressed vs. left open and why, and the one next thing that must happen —
including who has to do it if it isn't you.

Before calling a round finished, the three questions this skill exists to
stop you answering by assumption:

```bash
gh pr view <n> --json reviews --jq '[.reviews[].author.login] | unique'   # who has reviewed
gh pr checks <n> | awk -F'\t' '$2 != "pass"'                              # what is not green
# and the unresolved-thread query from §6.3
```

- **Has every reviewer reported?** A bot that has not run yet is not an
  approval, and "no comments" from a bot that errored is not a clean review.
- **Is every thread you answered resolved?** An answered-but-open thread reads
  as ignored by the next person to look.
- **Is anything left open on purpose?** Say which, and why — an open thread you
  chose to leave is a decision worth naming, not an oversight to hide.

---
Canon: `harness/instructions/development-workflows.md`,
`harness/.harness-repos.yml`.
