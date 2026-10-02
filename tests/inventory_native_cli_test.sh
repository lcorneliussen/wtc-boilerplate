#!/usr/bin/env bash
# Inventory contracts against the exact published CLI pin.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$TESTS_DIR/helpers.sh"

if [ -n "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  it 'published binary inventories shared files and collection-local names without values'
  assert_eq "wtc version $(cat "$HARNESS_SRC/.wtc-cli-version")" \
    "$("$WTC_TEST_RELEASE_BINARY" --version)" 'binary matches harness pin'
  root="$(make_workspace)"
  TEST_TMPDIRS="$TEST_TMPDIRS $root"
  mkdir -p "$root/main/widget" "$root/control/widget"
  add_fixture_worktree "$root" widget "$root/main/widget"
  printf '.env*\n' > "$root/main/widget/.gitignore"
  printf 'SHARED_TOKEN=synthetic_shared_value\n' > "$root/control/widget/.env"
  printf 'AVAILABLE_TOKEN=synthetic_available_value\n' > "$root/control/widget/.env.local"
  printf 'LOCAL_TOKEN=synthetic_local_value\n' > "$root/main/widget/.env"
  printf 'OVERRIDE_KEY=synthetic_local_value\n' > "$root/main/.env.collection.local"
  printf 'WTC_CONFIG_ROOT=%s\nOVERRIDE_KEY=synthetic_generated_value\n' "$root/control" \
    > "$root/main/.env.collection"
  printf 'MACHINE_KEY=synthetic_machine_value\n' > "$root/control/wtc.env"
  WTC_CONFIG_ROOT="$root/control" "$WTC_TEST_RELEASE_BINARY" secrets list \
    --collection "$root/main" --json > "$root/secrets.json"
  WTC_CONFIG_ROOT="$root/control" "$WTC_TEST_RELEASE_BINARY" env list \
    --collection "$root/main" --json > "$root/env.json"
  assert_ok python3 - "$root/secrets.json" "$root/env.json" <<'PY'
import json, sys
secret_text = open(sys.argv[1]).read()
env_text = open(sys.argv[2]).read()
assert 'synthetic_shared_value' not in secret_text
assert 'synthetic_available_value' not in secret_text
assert 'synthetic_local_value' not in secret_text
assert 'synthetic_generated_value' not in env_text
assert 'synthetic_local_value' not in env_text
assert 'synthetic_machine_value' not in env_text
secrets = json.loads(secret_text)['data']['files']
shared = next(row for row in secrets if row['path'] == 'widget/.env')
assert shared['scope'] == 'all collections with this repository'
assert shared['state'] == 'local-override'
available = next(row for row in secrets if row['path'] == 'widget/.env.local')
assert available['state'] == 'available'
local = next(row for row in secrets if row['path'] == '.env.collection.local')
assert local['scope'] == 'this collection (local secret variables)'
keys = json.loads(env_text)['data']['variables']
assert any(row['name'] == 'MACHINE_KEY' and 'all collections' in row['scope'] for row in keys)
assert any(row['name'] == 'OVERRIDE_KEY' and row.get('overrides') and
           'local override' in row['scope'] for row in keys)
PY
  it 'published binary separates environment help from setup'
  help="$(cd "$root/main" && "$WTC_TEST_RELEASE_BINARY" env)"
  assert_contains "$help" 'list' 'bare env lists its subcommands'
  assert_contains "$help" 'setup' 'bare env lists explicit setup'
  assert_no_file "$root/main/mise.toml" 'bare env did not regenerate files'
  it 'published binary fits interactive inventories and honors one-shot flags'
  assert_ok python3 - "$WTC_TEST_RELEASE_BINARY" "$root/main" "$root/control" <<'PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios, time

binary, collection, control = sys.argv[1:]
for group in ('secrets', 'env'):
    for flags, interactive in (([], True), (['--tui=false'], False)):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 12, 42, 0, 0))
        proc = subprocess.Popen([binary, group, 'list', '--collection', collection, *flags],
                                stdin=slave, stdout=slave, stderr=slave, cwd=collection,
                                env={**os.environ, 'TERM': 'xterm-256color',
                                     'WTC_CONFIG_ROOT': control})
        os.close(slave)
        chunks = []
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if not select.select([master], [], [], 0.1)[0]:
                    if proc.poll() is not None:
                        break
                    continue
                try:
                    part = os.read(master, 65536)
                except OSError:
                    break
                if not part:
                    break
                chunks.append(part)
                if interactive and b'q quit' in b''.join(chunks):
                    os.write(master, b'q')
                    break
            assert proc.wait(timeout=5) == 0, (group, flags)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            os.close(master)
        output = b''.join(chunks)
        assert (b'\x1b[?1049h' in output) == interactive, (group, flags)
        for value in (b'synthetic_shared_value', b'synthetic_local_value',
                      b'synthetic_available_value', b'synthetic_generated_value'):
            assert value not in output, (group, flags)
PY
fi
