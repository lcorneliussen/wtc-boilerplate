#!/usr/bin/env bash
# Shared matching-pin lookup for the two status entry points.

wtc_status_native_supported() { # v0.1.16 first shipped native status
  awk -v version="$1" 'BEGIN {
    if (version !~ /^[0-9]+\.[0-9]+\.[0-9]+$/) exit 1
    split(version, part, ".")
    exit !((part[1] + 0) > 0 || (part[2] + 0) > 1 ||
           ((part[2] + 0) == 1 && (part[3] + 0) >= 16))
  }'
}

wtc_status_native_command() { # harness path; sets WTC_STATUS_NATIVE
  local source_harness="$1" source_collection cli_pin cli_version
  source_collection="$(dirname "$source_harness")"
  WTC_STATUS_NATIVE=()
  [ -f "$source_harness/.wtc-cli-version" ] || return 1
  cli_pin="$(tr -d '[:space:]' < "$source_harness/.wtc-cli-version")"
  wtc_status_native_supported "$cli_pin" || return 1
  if command -v mise >/dev/null 2>&1; then
    cli_version="$(cd "$source_collection" && mise exec -- wtc --version 2>/dev/null)" || cli_version=""
    if [ "$cli_version" = "wtc version $cli_pin" ] &&
        (cd "$source_collection" && mise exec -- wtc status --help >/dev/null 2>&1); then
      WTC_STATUS_NATIVE=(mise exec -- wtc)
      return 0
    fi
  fi
  if command -v wtc >/dev/null 2>&1; then
    cli_version="$(cd "$source_collection" && wtc --version 2>/dev/null)" || cli_version=""
    if [ "$cli_version" = "wtc version $cli_pin" ] &&
        (cd "$source_collection" && wtc status --help >/dev/null 2>&1); then
      WTC_STATUS_NATIVE=(wtc)
      return 0
    fi
  fi
  return 1
}

# Keep the script as the foreground process that catch-up and retire identify.
# Forward termination to the native child when a pane is restarted or closed.
wtc_status_native_tui() {
  local status_child status_rc
  "${WTC_STATUS_NATIVE[@]}" status "$@" <&0 &
  status_child=$!
  trap 'kill "$status_child" 2>/dev/null || true' TERM INT HUP
  status_rc=0
  wait "$status_child" || status_rc=$?
  trap - TERM INT HUP
  return "$status_rc"
}
