---
id: scope-and-hygiene
title: Scope and hygiene
tier: fast
applies: always
---
Is the diff only what the PR says it is, and is it clean to merge?

Check `diff.patch`, `changed-files.txt`, `log.txt` against the PR description:

- unrelated changes: files or hunks outside the stated purpose, drive-by
  refactors, reformat-only churn mixed into logic changes
- leftovers: debug prints, commented-out code, TODOs added by this change,
  temporary files, local paths, hard-coded personal or test values
- committed secrets, credentials, `.env`-style files, large or binary files,
  generated artefacts, lockfile churn without a dependency change
- merge-conflict markers, accidental mode changes, broken whitespace in files
  where it matters
- the PR description's title and body describe the diff (nothing major missing,
  nothing described that is not there)

Severities:

- **blocker** — committed secret, conflict marker, or a stray change that
  alters behaviour outside the PR's purpose
- **major** — the description misstates what the PR changes; large unrelated
  change that should be its own PR
- **minor** — debug leftovers, small unrelated edits, generated files
- **nit** — trivial cleanup
