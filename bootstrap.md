# Bootstrap a WTC workspace

Use the CLI's [released bootstrap guide](https://github.com/lcorneliussen/wtc-cli/blob/minimal-harness-docs/docs/released-bootstrap.md)
for the first bare owner and collection. That guide is compatible with the
populated reference harness and v0.1.38; it lives on the documentation candidate
branch while this transition is reviewed.

Adapt this reference into your own harness repository. Commit your repository
registry, exact CLI pin, project configuration, and deliberate policy overrides.
Publish that harness to your own remote before cloning its shared bare owner.
The workspace root remains a plain folder, and collections are worktrees.

The [minimal-harness path](https://github.com/lcorneliussen/wtc-cli/blob/minimal-harness-docs/docs/getting-started.md)
is being tested separately. It scaffolds project configuration and supplies
standard instructions from the CLI. It is not included in v0.1.38, so do not
switch a stable harness pin merely to follow the candidate examples.

After bootstrap, read `wtc customize` for configuration and hooks. Keep
ordinary project development commands usable outside WTC.
