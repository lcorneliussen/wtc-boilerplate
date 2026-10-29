# WTC reference harness

An optional starter for a project using [worktree collections](https://github.com/lcorneliussen/wtc-cli).
A collection puts the repositories needed for one task beside each other as
Git worktrees, with a shared environment and agent entry point.

**Start with [wtc-cli](https://github.com/lcorneliussen/wtc-cli)** for the product
overview, commands, and demos. This repository is a reference you can adapt;
it is not where your project's repository list or credentials belong.

## Use this starter

Follow [bootstrap.md](bootstrap.md) with a published CLI release. Supply your
own repository registry, exact CLI pin, and project configuration. Customize
the policies and hooks your project needs. Existing harnesses keep their authored
entry points, skills, and instructions.

- [Configuration and hooks](https://github.com/lcorneliussen/wtc-cli/blob/main/internal/wtc/defaults/instructions/customize.md)
- [Workspace geometry](instructions/worktree-workspace.md)
- [Project workflow and branches](instructions/development-workflows.md)
- [Environment and ports](instructions/hooks-and-env.md)
- [Secrets](instructions/secrets.md)
- [Agent guidance](instructions/skills.md)
- [Validation](tests/README.md)

## Toward a smaller harness

Most standard guidance ships with `wtc-cli`. The config-only harness scaffold
and embedded instruction rendering shipped in v0.1.39; optional services and
resources shipped in v0.1.40 and remain experimental. See the
[CLI harness design](https://github.com/lcorneliussen/wtc-cli/blob/v0.1.40/docs/harness-design.md)
and [recorded demos](https://github.com/lcorneliussen/wtc-cli/blob/v0.1.40/docs/demos/README.md).

The intended ownership is simple: WTC supplies common operations and guidance;
your harness owns the registry, pins, project policy, and integration hooks.
A new harness should not need to copy every default just to get started.

This populated starter and the minimal path are both available with the tested
v0.1.40 baseline. That runtime minimum is separate from the latest stable
release; see [bootstrap.md](bootstrap.md) before choosing a newer exact pin.
Remove redundant files from existing project harnesses through reviewed changes,
while preserving deliberate overrides.

## Runtime trial

The [onboarding guide](instructions/runtime.md) and
[synthetic example](examples/runtime/README.md) exercise services, grouped
endpoints, logs, and safe resource teardown. The ordinary `bin/dev` command
continues to work without WTC. The trial uses a loopback relay; real tunnels and
cloud resources use project-owned commands and hooks.
