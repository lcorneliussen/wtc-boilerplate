---
id: backwards-compat
title: Backwards compatibility with downstream
tier: strong
applies: always
needs: downstream
---
Deployments of this repo and its consumers are not coordinated: either side may
reach production first and run for a while against the other side's old code.
`downstream/<repo>/old/` is the consumer as it runs in production,
`downstream/<repo>/new/` is its PR head when one is enlisted (`REFS` says
which). `related/` holds the other PRs of this change set.

Identify every contract the diff touches, then find its consumers in the
snapshots (grep for the names, do not guess):

- CLI flags, entrypoints, subcommands, exit codes
- environment variables and config keys (added, renamed, removed, default
  changed)
- file, path, table, column, view, dataset, topic, queue names
- schemas: types, nullability, grain, keys, ordering, enum values
- image names and tags, package versions, artifact paths
- API routes and payloads, event shapes, selectors/tags used to address units

For each contract answer explicitly:

1. **New upstream, old downstream** — does the code in `downstream/*/old/` still
   work once this change is deployed? Missing name, changed type, removed
   field, stricter validation?
2. **New downstream, old upstream** — if `new/` exists and can deploy first,
   does it work against the upstream as it is in production today (the base of
   this diff)?
3. **Rollout** — if neither order is safe, does the PR description state the required
   order, the transition (dual-write, alias, deprecation window), and any
   manual step? Is that order actually sufficient?

Record in `notes` which contracts you checked and which consumers you found,
including "no consumer found".

Severities:

- **blocker** — a production consumer breaks in an order that can actually
  happen, and the PR neither prevents it nor states a safe rollout
- **major** — breakage is avoided only by a rollout order or manual step that is
  stated but insufficient, or not stated but required
- **minor** — a behavioural change consumers tolerate today but that is
  undocumented (new nulls, new enum value, widened type)
- **nit** — a deprecation or transition note worth adding
