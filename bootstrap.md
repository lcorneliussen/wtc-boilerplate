# Bootstrap a WTC workspace

Use the CLI's [released bootstrap guide](https://github.com/lcorneliussen/wtc-cli/blob/v0.1.40/docs/released-bootstrap.md)
for the first bare owner and collection with this populated reference harness.
This reference pins WTC v0.1.40 as its minimum supported baseline. For a newer
stable installation, choose an exact published release, read its upgrade notes,
and update the pin and compatibility range together after validation.

Adapt this reference into your own harness repository. Commit your repository
registry, exact CLI pin, project configuration, and deliberate policy overrides.
Publish that harness to your own remote before cloning its shared bare owner.
The workspace root remains a plain folder, and collections are worktrees.

The [minimal-harness path](https://github.com/lcorneliussen/wtc-cli/blob/v0.1.40/docs/getting-started.md#minimal-harness)
ships from v0.1.39. It scaffolds project configuration and supplies standard
instructions from the CLI; existing populated harnesses keep their authored
policy and hooks. It is an optional alternative to adapting this reference.

After bootstrap, read `wtc customize` for configuration and hooks. For optional
services and tunnels (released from v0.1.40, runtime still experimental), use
[instructions/runtime.md](instructions/runtime.md) and
[examples/runtime](examples/runtime/README.md). Projects keep their ordinary
local development commands when WTC is not in use.
