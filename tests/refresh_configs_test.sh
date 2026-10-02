#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"

ws="$(make_workspace)"
tool="$ws/main/harness/tools/refresh-configs.sh"
fake_bin="$(mktemp_dir fake-wtc)"
log="$fake_bin/calls"
cat > "$fake_bin/wtc" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WTC_FAKE_LOG"
case "$*" in
  'registry refresh --help') exit 0 ;;
  *) printf 'native registry refresh\n' ;;
esac
MOCK
chmod +x "$fake_bin/wtc"

it "the compatibility entry point dispatches to native registry refresh"
out="$(PATH="$fake_bin:$PATH" WTC_FAKE_LOG="$log" "$tool")"
assert_eq "native registry refresh" "$out"
assert_contains "$(cat "$log")" "registry refresh --collection $ws/main"

it "help does not write the local registry"
rm -f "$ws/main/harness/.harness-repos"
out="$(PATH="$fake_bin:$PATH" WTC_FAKE_LOG="$log" "$tool" --help)"
assert_contains "$out" "Usage: tools/refresh-configs.sh"
assert_neq "0" "$(test -e "$ws/main/harness/.harness-repos"; echo $?)"
