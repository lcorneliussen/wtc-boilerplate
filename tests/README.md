# Tests

```bash
tests/run.sh                 # everything
tests/run.sh lib retire      # only files whose name contains lib or retire
TEST_VERBOSE=1 tests/run.sh  # print passing assertions too, not just failures
```

No dependencies beyond `bash`, `git` and the coreutils already required to run
the harness. Nothing here reaches the network, and nothing touches the
workspace you are standing in.

## What is covered

| File | Covers |
|---|---|
| `cli_contract_test.sh` | Promises every tool makes: it parses, it runs on bash 3.2, `--help` exits 0, an unknown flag does not |
| `lib_test.sh` | The pure lookups in `lib.sh` — registry parsing, remote slugs, port allocation |
| `agent_env_test.sh` | `agent-env.sh`: sourced mode, PATH hygiene, the cache, the PreToolUse wrapper |
| `status_args_test.sh` | `wtc-status.sh` watch-interval handling — the argument that can turn a status pane into a busy loop |
| `retire_test.sh` | The one tool whose job is deletion: generated paths go, authored files survive |
| `collection_test.sh` | `branch-off` → `add-repo` → `retire` end to end, on a real workspace |
| `review_tools_test.sh` | Local review bundle, headless run, posted summary, and the ready gate |

## The rules the fixtures follow

**Never run a tool from the source tree.** Tools locate the workspace by
walking up from their own path, not from `$PWD`, so
`$HARNESS_SRC/tools/foo.sh` reaches the real `.bare/` and the real collections
however carefully you `cd` first. An early draft of `cli_contract_test.sh` had
`refresh-configs.sh` rewriting the developer's live `.harness-repos`. Anything
that executes runs the fixture's copy; only static scans read the source.

**Fixtures are real, not mocked.** A worktree collection is filesystem-shaped —
its correctness *is* which files exist where, which bare owns which checkout,
what survives a delete. `make_workspace` builds an actual workspace root with
real bares and real worktrees, seeded from local repos so it stays offline.
Asserting against mocks here would assert against the mocks.

**Bares are `init --bare` + fetch, not `clone --bare`.** The two produce
different ref layouts and only one matches a real workspace: a bare clone puts
branches in `refs/heads`, so `origin/main` — which every `default_ref` names —
does not exist.

**Temp paths are resolved with `pwd -P`.** On macOS `$TMPDIR` lives under
`/var`, a symlink to `/private/var`, and carries a trailing slash. Git always
reports the physical path, so an unresolved fixture path fails assertions on
spelling rather than substance.

## CI

`.github/workflows/tests.yml` runs the suite on **ubuntu-latest and
macos-latest**, for different reasons. macOS is the platform the tools target
and the only one giving real bash 3.2 at `/bin/bash` — without it the "no bash
4 constructs" rule is a claim nothing checks. Ubuntu catches GNU/BSD
divergence (`stat -c` vs `stat -f`, `date` flags); the tools carry fallbacks
for both, and an unexercised fallback is one that has already rotted.

The runner closes stdin (`tests/run.sh < /dev/null`). When stdin is a socket,
bash decides it was started by a remote shell daemon and sources `~/.bashrc`
*instead of* `$BASH_ENV`, which silently turns the BASH_ENV coverage into a
no-op. The tests redirect individually as well; this is the belt to those
braces.

The macOS leg installs coreutils for `gtimeout`. Without it,
`status_args_test.sh` skips its zero-interval cases — the ones that catch a
status pane re-fetching every bare as fast as the machine allows — and it
skips them on the platform the tools actually target. The skip exists so the
suite still runs on a bare machine; CI has no excuse to take it. A green run
that reports fewer assertions than the other platform is worth reading twice.

## Coverage

```bash
tests/coverage.sh              # a table
tests/coverage.sh --markdown   # for a CI job summary
tests/coverage.sh --min 30     # also fail under a floor
```

Line coverage for `tools/` and `hooks/`, measured by pointing `BASH_ENV` at a
stub that turns on `set -x` with `PS4='@@${BASH_SOURCE}:${LINENO}@@ '`. Every
tool is a `#!/usr/bin/env bash` script, so its shell sources `BASH_ENV` on
startup and traces itself. **Nothing on disk is modified** — injecting a
preamble would shift every line number, and `agent-env.sh --help` prints its
own header by line range.

It runs the suite twice: once clean, which is the truth about whether the
tests pass, and once instrumented, which is only a measurement. `set -x`
perturbs three assertions that match on captured output, so the report states
that delta rather than hiding it. **CI gates on the clean run**; the coverage
job only measures, with no floor — the number is there to be read and to make
a regression visible in a diff, not to be gamed upward.

Two limits worth knowing. It needs **bash ≥ 4.1** for `BASH_XTRACEFD`, so it
cannot run on macOS (3.2) — which means the platform the tools target is the
one that cannot measure them; run it in a container there. And `env -i` wipes
`BASH_ENV`, so `agent_env_test.sh`'s deliberately controlled shells are not
traced: read `tools/agent-env.sh` as a floor (26% here, 52% when measured by
file injection instead).

Today's picture: **29% overall**, and the distribution matters more than the
total. The paths that can destroy something are the best covered — `retire.sh`
67%, `add-repo.sh` 57%, `link-skills.sh` 57%. The uncovered mass is terminal
orchestration and network: `wtc-open.sh` at 3% is almost all herdr pane
layout, and of `lib.sh`'s 62 functions the 34 unentered ones want a running
multiplexer, an nvim socket, or GitHub. `hooks/invoke.sh` at 0% is the one
genuinely easy gap — 14 lines, no excuse.

A shellcheck job runs advisory-only (`continue-on-error`). Promote it to
gating once its existing findings are dealt with — a check that is red on
arrival teaches people to ignore it.

## Writing a test

Source `helpers.sh`, use `it` to name a group, and assert. Files run under
`set -u` but deliberately **not** `set -e`: a failed assertion records itself
and execution continues, so one break does not hide the twenty after it.

```bash
. "$(dirname "$0")/helpers.sh"

ws="$(make_workspace)"
load_lib "$ws"

it "registry_field does not leak a field across blocks"
assert_eq "1" "$(registry_field widget port_offset)"
assert_empty "$(registry_field gadget port_offset)"
```

Assertions: `assert_eq`, `assert_neq`, `assert_empty`, `assert_contains`,
`assert_not_contains`, `assert_ok`, `assert_fails`, `assert_status`,
`assert_file`, `assert_no_file`.

Fixtures: `make_workspace`, `load_lib`, `mktemp_dir`, `make_local_repo`,
`add_fixture_worktree`. Every `mktemp_dir` is removed on exit.

The tally on the last stdout line is the contract with `run.sh`; `helpers.sh`
emits it from an `EXIT` trap, so a file that dies early still reports what it
managed to run rather than looking like a file that ran nothing.

## What a test here is for

Most of these encode a bug that shipped. `agent-env.sh` ending in `exit 0`
killed the shell that sourced it — silently, so under `BASH_ENV` every command
in the session became a no-op. `retire.sh`'s cleanup list went stale twice.
`repo_slug_for` turned an HTTPS remote into something `gh` could not resolve,
and every PR cell rendered a `NOT_FOUND` blob.

None of those were caught by reading the diff. Prefer a test that would have
caught the specific thing over a test that describes what the function is for.
