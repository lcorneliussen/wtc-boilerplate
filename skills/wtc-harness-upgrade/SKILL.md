---
name: wtc-harness-upgrade
description: Upgrade a harness from its upstream implementation through a reviewable pull request, preserving local configuration and overlays.
---

# Upgrade a harness

Use this for a downstream harness that pins `wtc` or ports the shell-era reference harness. Work in the downstream's own collection and follow its branch and review policy. Read that harness's instructions before changing files.

## 1. Establish the versions

Read the downstream's recorded upstream version or commit and the target release or upstream ref. Confirm the target exists. If no machine-readable pin exists in the shell era, use merge commits, port trailers, and the last upgrade PR to establish the base; record any uncertainty in the private upgrade PR. Do not guess from file timestamps.

Check the target changelog and list the commands, skills, instructions, registry schema, and hook contracts that changed. Compare each local override with the corresponding new default. The upgrade is a single version transition, not a series of unrelated cherry-picks.

## 2. Prepare the branch

Create a branch at the first commit, following the harness policy. For a CLI release, bump the mise tool pin and the harness compatibility range together. Update the recorded upstream version/ref. Re-render shipped skills and instructions, then reconcile only the affected local overlays. When a CLI release is not yet available, port the shell implementation and record the upstream commit or merge range.

Keep local content in config, hooks, providers, and overlays. If the upgrade needs a new extension point, open a generic upstream change first, then take its released version. Do not silently edit a generated file to carry a permanent customization.

## 3. Verify and open the PR

Run the upstream contract suite against the harness profile, plus the harness's own tests. Exercise changed hooks and generated content in a disposable collection. Record exact test results and any intentional skips.

Open a downstream PR with the old and new pins, relevant changelog, overlay changes, tests, and rollout effects. This PR is the durable record of what the harness adopted. Follow its checks and review under the harness's normal procedure. Keep private adoption and delivery links in the downstream PR; public upstream records only describe generic technical changes.
