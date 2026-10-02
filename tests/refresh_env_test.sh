#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
ws="$(make_workspace)"
mkdir -p "$ws/bin" "$ws/config/gh"
cat > "$ws/bin/mise" <<'MISE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MISE_CALL_LOG"
MISE
chmod +x "$ws/bin/mise"
export MISE_CALL_LOG="$ws/mise-calls" WTC_CONFIG_ROOT="$ws/config"
export PATH="$ws/bin:$PATH"
printf 'COLLECTION_PORT_BASE=42700\n' > "$ws/main/.env.collection"
printf '# existing mise configuration\n' > "$ws/main/mise.toml"
# Pin an older CLI so the entry point stays on the shell reference path
# instead of probing mise for a native binary.
printf '0.1.8\n' > "$ws/main/harness/.wtc-cli-version"
printf '# local overrides\n' > "$ws/main/.env.collection.local"
it 'environment preview neither changes target files nor invokes mise'
assert_ok "$ws/main/harness/tools/refresh-env.sh" --dry-run
assert_eq 'COLLECTION_PORT_BASE=42700' "$(cat "$ws/main/.env.collection")"
assert_eq '# existing mise configuration' "$(cat "$ws/main/mise.toml")"
assert_eq '# local overrides' "$(cat "$ws/main/.env.collection.local")"
assert_fails test -e "$MISE_CALL_LOG"
it 'real environment refresh still registers mise trust'
assert_ok "$ws/main/harness/tools/refresh-env.sh"
assert_contains "$(cat "$MISE_CALL_LOG")" 'trust'
assert_contains "$(cat "$ws/main/.env.collection")" 'COLLECTION_PORT_BASE=42700'
assert_eq '# local overrides' "$(cat "$ws/main/.env.collection.local")"

it 'a collection in another workspace defaults to that workspace'"'"'s control root'
other_ws="$(mktemp_dir other-ws)"
mkdir -p "$other_ws/coll"
cp -R "$ws/main/harness" "$other_ws/coll/harness"
cat > "$other_ws/coll/harness/.harness-repos.yml" <<'YML'
repos:
  - name: remote-widget
    remote: https://github.com/example/remote-widget.git
    default_ref: origin/main
    port_offset: 7
YML
printf 'COLLECTION_PORT_BASE=42800\n' > "$other_ws/coll/.env.collection"
(unset WTC_CONFIG_ROOT; "$ws/main/harness/tools/refresh-env.sh" --collection "$other_ws/coll" >/dev/null)
assert_eq 0 "$?" "cross-workspace refresh succeeded"
assert_contains "$(cat "$other_ws/coll/.env.collection")" "WTC_CONFIG_ROOT=$other_ws/.config"
assert_not_contains "$(cat "$other_ws/coll/.env.collection")" "WTC_CONFIG_ROOT=$ws/"
assert_contains "$(cat "$other_ws/coll/.env.collection")" 'COLLECTION_PORT_BASE=42800'
assert_contains "$(cat "$other_ws/coll/.env.collection")" 'REMOTE_WIDGET_PORT=42807'
assert_not_contains "$(cat "$other_ws/coll/.env.collection")" $'\nWIDGET_PORT='
