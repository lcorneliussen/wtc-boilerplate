# Reference harness checks

The released `wtc` CLI owns collection operations and tests them in its own
repository. This reference repository checks its remaining hook and publication
boundary code, and verifies that the agent instructions use commands provided
by its pinned CLI release.

Run locally:

```bash
python3 tests/native_reference_test.py  # requires the pinned wtc on PATH
python3 tests/agent_hook_test.py
python3 tests/publication_guard_test.py
```

CI downloads the exact version in `.wtc-cli-version`, verifies the release
archive checksum, and runs all three checks on macOS and Linux. The generic CLI
behavior is tested in the CLI repository's Go suite.
