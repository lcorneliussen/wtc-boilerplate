---
name: wtc-harness-backport
description: Extract a generic downstream harness improvement and contribute it upstream through a privacy-checked pull request.
---

# Backport a harness improvement

Use this when a change made in a harness also belongs in the public reference harness or CLI. Work in an upstream collection with a separate branch. Read the upstream repository's publication rules before preparing any outgoing text or code.

## 1. Isolate the generic behavior

Read the source change and identify the behavior, its boundary, and the tests that prove it. Separate local names, paths, forge URLs, issue references, policies, and configuration from the reusable implementation. Re-express examples and fixtures with synthetic names. Prefer a small extension point over a copied downstream convention.

Choose the owning upstream repository: the CLI for generic commands and bundled defaults, or the reference harness for bootstrap and compatibility shell behavior. Record the source and adoption links only in a private downstream issue or PR.

## 2. Implement and verify upstream

Create a branch at the first commit using the upstream policy. Reimplement or cherry-pick only the generic portion, then inspect the full diff and commit message for identifying text. Run the relevant unit and contract tests. Include a regression test for the behavior where it is meaningful.

Before every push, issue, PR, or review reply, establish the destination audience and inspect the exact outgoing title, body, diff, comments, fixtures, and attachments. For a public or unknown audience, remove private identities, repository slugs and URLs, issue references, internal commit IDs, local paths, hostnames, logs, and screenshots. Use `instructions/publication-privacy.md` and the publication guard where available. A keyword scan is useful but does not replace reading the payload.

## 3. Publish and follow

Open an upstream PR that explains the generic problem, change, and tests, without a backlink to the source harness. Follow checks and review, then record the upstream PR and release in the private downstream tracker. Upgrade the downstream through `wtc-harness-upgrade`; do not add private delivery tracking to the public upstream PR.
