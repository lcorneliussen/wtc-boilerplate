# Opt-in service runtime with dekit

Services and tunnels are available in released WTC **v0.1.40 or later**.
The runtime remains experimental. This reference pins 0.1.40 as its minimum
supported baseline, not as a claim about the latest stable release. Test runtime
onboarding in a disposable collection before enabling it for a project.

## Enable a harness

Merge these tables into the harness's committed `wtc.toml`:

```toml
[runtime]
backend = "dekit"

[mise.tools]
"github:pvolok/dekit" = "0.10.0"
```

TOML cannot repeat a table. Run `wtc env setup`, then `mise install` to install
the pinned dekit tool. The adapter supports dekit 0.10.x; test a newer version
before changing the pin. Enabling the backend starts nothing automatically.

Use an exact published CLI pin in `.wtc-cli-version` and keep the compatibility
range in sync. When choosing a newer stable release, read its target binary's
`wtc release-notes --since <old-pin>` and validate the upgrade before changing
these files. The runtime feature minimum is v0.1.40; it does not require a
locally built CLI.

## Use the CLI's versioned instructions

Run `wtc docs instructions/runtime.md` to read the runtime contract embedded in
the CLI you are using. The [v0.1.40 runtime instructions](https://github.com/lcorneliussen/wtc-cli/blob/v0.1.40/internal/wtc/defaults/instructions/runtime.md)
cover repository task fragments, foreground launch commands, services and
tunnels, readiness, logs, resource ownership, strict teardown, and bootstrap
acceptance checks. Use `/wtc-svc` for service work after enabling the backend
and rendering skills with `wtc skills render`.

Keep repositories' existing standalone launch commands working with WTC env
unset. WTC supervises those commands; their build/cache/watch behavior stays
inside the repository. `wtc down` keeps logs and collection data; teardown and
retirement clean only resources with verified collection ownership. A failed
stop or teardown must retain the collection and its ownership receipts.

Start with the [synthetic onboarding example](../examples/runtime/README.md).
Then follow the CLI's acceptance checks for each real launch command and
provider, including two independent collections and deliberate teardown failure.
No sample hook establishes safe ownership for a real cloud or database service.
