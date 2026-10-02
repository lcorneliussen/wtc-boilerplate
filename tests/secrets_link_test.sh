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
printf 'PWD=%s %s\n' "$PWD" "$*" >> "$WTC_FAKE_LOG"
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
assert_contains "$(cat "$log")" "PWD=$ws/main"

it "an explicit target collection selects its own mise context"
mkdir -p "$ws/other"
out="$(PATH="$fake_bin:$PATH" WTC_FAKE_LOG="$log" "$tool" --collection "$ws/other" --repo widget --dry-run 2>&1)"
assert_eq "native secret linker" "$out"
assert_contains "$(cat "$log")" "PWD=$ws/other secrets link --collection $ws/other --repo widget --dry-run"

it "a pre-install fallback refuses configured production paths"
printf '\n[secrets]\nprod_paths = ["widget/.env.prod"]\n' >> "$ws/main/harness/wtc.toml"
out="$(PATH="$fake_bin:$PATH" WTC_FAKE_LOG="$log" WTC_FAKE_AVAILABLE=no "$tool" --repo widget 2>&1)"
assert_neq "0" "$?"
assert_contains "$out" "wtc v0.1.5 is required to enforce prod_paths"

it 'shell fallback decodes a native single-quoted control root'
quoted_ws="$(make_workspace)"
quoted_root="$quoted_ws/quoted store"
mkdir -p "$quoted_root"
printf "WTC_CONFIG_ROOT='%s'\n" "$quoted_root" > "$quoted_ws/main/.env.collection"
out="$(env -u WTC_CONFIG_ROOT PATH="$fake_bin:$PATH" WTC_FAKE_LOG="$log" WTC_FAKE_AVAILABLE=no \
  "$quoted_ws/main/harness/tools/link-secrets.sh" --dry-run 2>&1)"
assert_contains "$out" "control root: $quoted_root"
assert_not_contains "$out" 'nothing to link'
