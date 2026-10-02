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
fi
