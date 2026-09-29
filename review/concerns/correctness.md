---
id: correctness
title: Correctness
tier: strong
applies: always
---
Does the change do what the PR description says it does, and does it keep doing what the
code did before where it was not meant to change?

Check, reading the surrounding code and not just the hunks:

- logic errors: wrong condition, inverted check, off-by-one, wrong variable,
  unreachable or dead branch, missing `return`/`break`
- data handling: nulls/empties, types and units, duplicates, ordering,
  time zones, integer vs float, join fan-out or row loss in queries
- error paths: failures swallowed, partial writes, retries that are not
  idempotent, resources not released
- every caller of a changed function, query, or config key still matches its
  new behaviour (grep the repo)
- concurrency and ordering where the code runs more than once or in parallel
- the change is complete: renamed or removed things have no leftover references

Severities:

- **blocker** — wrong results, data loss/corruption, crash or failed run on a
  path that will execute in normal use
- **major** — wrong on a realistic edge case, or an error path that hides
  failures
- **minor** — wrong only on an unlikely input, or a latent bug not reachable
  today
- **nit** — do not use for this concern except for a misleading name or
  comment that will cause a future bug
