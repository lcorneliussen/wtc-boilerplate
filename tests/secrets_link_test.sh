#!/usr/bin/env bash
# The compatibility entry point uses the native command when it is available
# and refuses a production-path configuration before falling back to shell.
. "$(dirname "$0")/helpers.sh"

ws="$(make_workspace)"
tool="$ws/main/harness/tools/link-secrets.sh"
fake_bin="$(mktemp_dir fake-wtc)"
log="$fake_bin/calls"
cat > "$fake_bin/wtc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WTC_FAKE_LOG"
case "$*" in
  'secrets link --help') [ "${WTC_FAKE_AVAILABLE:-yes}" = yes ] ;;
  *) printf 'native secret linker\n' ;;
esac
MOCK
chmod +x "$fake_bin/wtc"

it "the shell entry point dispatches to the collection's CLI command"
out="$(PATH="$fake_bin:$PATH" WTC_FAKE_LOG="$log" "$tool" --repo widget --dry-run 2>&1)"
assert_eq "native secret linker" "$out"
assert_contains "$(cat "$log")" "secrets link --collection $ws/main --repo widget --dry-run"

it "a pre-install fallback refuses configured production paths"
printf '\n[secrets]\nprod_paths = ["widget/.env.prod"]\n' >> "$ws/main/harness/wtc.toml"
out="$(PATH="$fake_bin:$PATH" WTC_FAKE_LOG="$log" WTC_FAKE_AVAILABLE=no "$tool" --repo widget 2>&1)"
assert_neq "0" "$?"
assert_contains "$out" "wtc v0.1.5 is required to enforce prod_paths"
