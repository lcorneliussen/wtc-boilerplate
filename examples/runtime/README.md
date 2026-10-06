# Synthetic runtime onboarding trial

Copy this directory into a disposable application repository. Its ordinary
`./bin/dev` starts a web server on port 3000 using Python's standard library;
`PORT=0 ./bin/dev` chooses a free port. No WTC, dekit or mise is required for
that standalone path. The command caches its synthetic build and hosts a child
web process, so shutdown exercises a nested launcher.

For the WTC trial, enable the candidate CLI and dekit as described in
[the onboarding guide](../../instructions/runtime.md). Use a worktree of this
fixture repo in a disposable collection. Before `wtc up`, set unused ports in
that collection's `.env.collection.local`, for example:

```sh
PORT=43131
RELAY_PORT=43132
RUNTIME_DEMO_URL='http://127.0.0.1:43131'
RUNTIME_DEMO_TUNNEL_URL='http://127.0.0.1:43132'
```

Replace `fixture` below with the worktree directory name:

```sh
wtc up fixture/web
wtc status --local
wtc logs fixture/web/server
wtc restart fixture/web
wtc down
wtc logs fixture/web/server
wtc runtime teardown
```

The relay is loopback-only. It tests grouped lifecycle and dependency behavior,
not connectivity between machines. Replace it with the repo's foreground tunnel
command when testing a real endpoint.

Provision creates an ignored `.runtime-data` folder with a collection ownership
receipt and a synthetic database file. `down` keeps it; teardown removes it only
if the receipt matches. Set `RUNTIME_TEARDOWN_FAIL=1` in the local collection env
to exercise cleanup failure; `wtc runtime teardown` and retirement must fail
without deleting the receipt/worktrees. Remove that override and retry. Place a
synthetic shared marker outside the owned folder to verify it survives.

Do not use the fixture hook as a real database/cloud provider implementation.
Real hooks must record and verify the exact provider scope and resource ID.
