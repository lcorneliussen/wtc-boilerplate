# Opt-in service runtime with dekit

This integration is experimental and requires the CLI implementation tracked in
[wtc-cli #65](https://github.com/lcorneliussen/wtc-cli/issues/65). Existing stable
CLI pins do not provide these commands yet. Test a locally built candidate in a
disposable collection before updating a downstream harness's release pin.

WTC owns collection identity, repository association, generated configuration,
logs and retirement. [dekit 0.10](https://dekit.run/docs/start/runners) owns an
independent runner, process trees, dependency ordering and restart behavior.
Closing an agent or terminal does not stop the services. Mise remains the
repository's toolchain and task runner.

## Enable a downstream harness

Add to its committed `wtc.toml`:

```toml
[runtime]
backend = "dekit"

[mise.tools]
"github:pvolok/dekit" = "0.10.0"
```

Merge these tables with existing ones; TOML cannot repeat a table. Regenerate the
collection environment using the candidate CLI's `wtc env setup`, then install
the pinned tool with mise. The adapter accepts dekit 0.10.x; test a newer release
before changing that constraint. A legacy mprocs binary named `dekit` is rejected.
An optional `[runtime] binary = "/absolute/path/to/dekit"` selects an isolated
trial binary. Relative binary paths resolve from the harness directory.

For an unreleased trial, build the CLI checkout with `go build -o /tmp/wtc-runtime
./cmd/wtc` and use that executable explicitly for every runtime command. Keep the
harness's stable `.wtc-cli-version` until a tested release includes the adapter.
Enabling the backend alone starts nothing. Neither `wtc new`, env generation,
`wtc status` nor repository initialization starts this runtime.

## Onboard an application repository

Keep the existing launch entry point: `bin/dev`, a Procfile runner, `mise run
dev`, `npx`, or a .NET/Mono host. The build/cache/watch cycle stays in that
command. Add an **opt-in** `.harness/dekit.tasks.yaml` alongside it:

```yaml
tasks:
  web/server:
    cmd: [mise, run, dev]
    autostart: true
    ready:
      cmd: [sh, -c, 'curl -fsS "http://127.0.0.1:${PORT:?}/health" >/dev/null']
      timeout: 60s
    x-wtc:
      url_env: WEB_LOCAL_URL
  web/tunnel:
    label: named development tunnel
    cmd: [mise, run, dev:tunnel]
    deps: [web/server]
    autostart: true
    tags: [endpoint]
    ready:
      cmd: [sh, -c, 'curl -fsS "${WEB_PUBLIC_URL:?}/health" >/dev/null']
      timeout: 60s
    x-wtc:
      url_env: WEB_PUBLIC_URL
```

`dev:tunnel` is the repo's chosen foreground tunnel command, for example an SSH,
Tailscale or named Cloudflare tunnel. Do not start it in the background or exit
while the tunnel remains alive. For a randomly assigned public URL, omit
`url_env` initially and read the assigned URL from the task log. For a known
endpoint, put its URL in the collection environment before `up`.

The repository might use `WIDGET_PORT` from its registry's `port_offset`. An
`env.post.sh` harness hook can supply aliases:

```sh
# After loading the generated environment, append these shell assignments.
printf 'PORT=%s\nWEB_LOCAL_URL=http://127.0.0.1:%s\n' "$WIDGET_PORT" "$WIDGET_PORT" >> .env.collection
```

Keep your chosen tunnel endpoint in `.env.collection.local`, or generate it
idempotently from collection identity. For example:

```sh
WEB_PUBLIC_URL='https://widget-demo.example.test'
```

Do not put credentials in endpoint URLs. WTC accepts HTTP(S) endpoint metadata
without user information, a query or a fragment, and stores that public address
in the manifest for read-only status. `x-wtc.url` can instead hold a literal
address. Only `url` and `url_env` are supported in `x-wtc`; WTC strips that
metadata before passing the task to dekit. Actual dynamic readiness checks use
`ready.cmd`, which inherits the launch environment; dekit does not expand shell
variables in argv or a literal `ready.http` string.

WTC prefixes paths with the worktree directory: `widget/web/server` and
`widget/web/tunnel`. The first local path component groups the service with its
endpoint in status. A task's cwd defaults to its repo root. Explicit relative
cwd and script paths are rebased from that root. Dependencies are local to the
repo; `/other-repo/db/server` explicitly names a task in another sibling.
Only checked-out opted-in repositories participate. A missing dependency is an
error; WTC never adds repositories or starts a host runner implicitly.

All other task fields follow the [native dekit task contract](https://dekit.run/docs/config/tasks).
The fragment has only a top-level `tasks` map. Task `add_path` entries should be
absolute; use mise for repo-relative toolchain resolution. Use argv arrays and
an explicit shell for variable expansion or shell operators. WTC supplies
persistent append logs and the collection's env. Do not embed credentials in
committed task definitions or command arguments.

For an existing Ruby stack runner, supervise its ordinary foreground `bin/dev`
as **one task**. Its child logs appear in that task's log; WTC does not invent
per-child status. Split tasks only when separate control and status are useful.
For Node or .NET, use the existing `npm run dev`, `npx` build-and-serve wrapper,
`dotnet run`, or Mono launcher in the same way. Disable self-daemonization.

## Preserve standalone development

The new fragment and hooks are consumed only by WTC. Do not replace the repo's
README quick start, make its default task call `wtc up`, require dekit in its
ordinary dependency install, or assume `WTC_COLLECTION` is always set.

Accept a port/data-path override while retaining the current local default:

```sh
PORT="${PORT:-3000}" exec ./bin/server
```

A WTC-only hook may insist on a collection identity, because standalone users
never invoke it. Normal launch commands must still work with all WTC env unset.
A nested Procfile manager is fine if it stays in the foreground and stops its
children when its process group receives SIGTERM. Confirm this for the real
runner; a detached child is outside dekit's process-group guarantee.

## Resources, Docker and cloud services

Long-running accessories can be ordinary native tasks tagged `accessory`. For a
collection-owned Docker stack, supervise `docker compose up` in the foreground,
use a **collection-specific Compose project name**, and supply a native stop
command that stops only that project. Test container shutdown explicitly: a
runner being absent alone does not prove containers have stopped.

A shared Docker Postgres server or Azure service is external. Do not start a
second instance just to fit the process tree. Provision only the collection's
DB/schema/container/prefix through executable repo-owned hooks:

```text
.harness/runtime-provision.sh
.harness/runtime-teardown.sh
```

Both run from the repo root with `.env.collection` then
`.env.collection.local` loaded. The hooks can call existing mise tasks and
provider CLIs. A provision hook requires a teardown hook. They must be
idempotent and return nonzero on failure. They run under the collection runtime
lock: call provider commands or mise tasks, rather than nested WTC runtime
commands. Avoid starting long-lived background
processes from them.

Before provisioning, record the owned resource's exact identifier and provider
scope in an ignored collection-local receipt. Use `WTC_COLLECTION` and repo
identity, with provider-safe sanitization and a collision-resistant suffix.
Check that ownership on teardown. Drop only that collection's database or
Azure resource, never the shared database server, account or resource group.
An external resource with no cleanup rights needs an explicit contract, rather
than a success-returning fake teardown. Back up/export valuable data before
retirement; collection-owned data is disposable.

WTC records **the owner before calling provision**, including failed attempts,
and retains it across config changes. Status shows `provision-attempted`,
`provision-hook-completed`, or `teardown-failed`. These are hook outcomes, not
live provider health. A native accessory task can expose a provider's log
stream or an explicit observer if ongoing visibility is needed. Keep receipts
and hook logs until cleanup succeeds; never store credentials in the receipt.

## Daily lifecycle and agent access

From the collection root:

```sh
wtc runtime render --dry-run   # ownership preview; no tool required or writes
wtc runtime render            # render only; no hooks or service startup
wtc runtime provision         # provision only, no service startup
wtc up                        # provision, then start saved/autostart tasks
wtc up widget/web             # start the service/tunnel group and dependencies
wtc restart widget/web        # restart the whole group
wtc status --no-watch          # repo summary and grouped task/resource facts
wtc runtime status --json      # machine-readable state; never starts a runner
wtc logs widget/web/server --tail 100
wtc logs widget/web/tunnel -f
wtc down widget/web            # veto group; also stops its dependents
wtc down                       # stop runner; keep logs, data, and saved tasks
wtc runtime teardown           # stop runner, discard saved tasks, strict cleanup
```

`up` and `restart` wait up to 30 seconds for startup readiness; `--wait 60s`
changes this, and `--wait 0` returns immediately. Untargeted `up` checks
autostart tasks; explicitly name a group to wait for all its tasks. `restart`
requires a running runner. A readiness failure remains visible in status and
logs. **Ready means a startup probe passed**, not continuous health checking.
No `wtc start` runtime command is introduced; the session orientation skill
keeps its existing meaning.

Service logs are append files under `.wtc/runtime/logs/<repo>/<task>.log`,
available after `down`. Hook logs live under
`.wtc/runtime/hook-logs/<repo>/provision.log` and `teardown.log`; agents can read
those files directly. They can contain application secrets, so keep them local.
For the native interactive console, from the collection root run:

```sh
dekit -C "$PWD/.wtc/runtime" attach
```

Use the pinned binary when a machine-global `dekit` is older. Native `why` and
`screen --json` also work at that root. The screen is a bounded terminal buffer,
not the persistent log. Tasks dynamically added through native dekit commands
are controlled by the runner but are not yet represented in WTC's configured
task list.

Edit repo fragments rather than generated `dekit.yaml`. If definitions or
endpoint metadata change, first `wtc down`, then render or `up`. WTC refuses to
replace live definitions and clears dekit's saved snapshot before applying
changed definitions. An existing runner keeps its launch environment; use a
full `down`/`up` after changing ports or credentials.

`wtc retire` verifies the target runner stopped, clears its saved definitions,
and runs strict resource teardown **before removing any worktree**. An
unconfirmed stop or failed teardown keeps the collection and ownership record,
even with `--force`. Fix the hook and retry. Removing the harness opt-in does not
bypass cleanup of an already recorded runtime. Ordinary repo init/teardown hooks
continue to serve their separate worktree lifecycle.

## Bootstrap acceptance test

Use a synthetic fixture first, then each real repo's existing launch command:

1. Run the normal repo command with WTC env unset. Check its existing default
   port/data location and build behavior.
2. Create two disposable collections; assign distinct ports and resource
   identities. `up` both, exit the launching shell/agent, and check both endpoints.
3. Inspect repo association, service/tunnel grouping, hook facts, JSON state and logs.
   A status query before `up` must create no runtime or resource.
4. Restart one group. Confirm the other collection is unaffected and builds use
   the existing cache. Break a readiness probe and confirm `up` fails visibly.
5. `down` one. Check its ports, child processes and any owned containers stop;
   the second keeps serving. Logs and collection data remain available.
6. Make teardown fail deliberately in the fixture. Retirement must retain its
   worktrees and receipt. Restore the hook, retry, and confirm owned resources
   disappear while a synthetic shared resource stays intact.
7. Check changes into the repo/harness. Adopt a published CLI pin only after
   these checks pass; leave standalone developers' dependency setup unchanged.
