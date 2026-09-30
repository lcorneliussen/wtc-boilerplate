#!/usr/bin/env bash
# wtc-status-tui.sh — live herdr status pane (watch, click, background refresh).
# Sets the mode and sources the shared implementation in wtc-status-common.sh.
#
# Defaults to the repos table (what wtc-open.sh starts). Explicit --procs /
# --repos after this still win — the common parser applies flags in order.
set -euo pipefail
WTC_STATUS_UI=tui
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_harness="$(dirname "$script_dir")"
# The shell help still documents legacy focus and forge-cache settings.
native_status=yes
mode=repos
cli_args=()
for arg in "$@"; do
  case "$arg" in
    --help|-h) native_status=no ;;
    --repos) mode=repos ;;
    --procs) mode=procs ;;
    *) cli_args+=("$arg") ;;
  esac
done
if [ "$native_status" = yes ]; then
  # shellcheck source=wtc-status-native-common.sh
  . "$script_dir/wtc-status-native-common.sh"
  if wtc_status_native_command "$source_harness"; then
    cd "$(dirname "$source_harness")"
    exec "${WTC_STATUS_NATIVE[@]}" status --tui "--$mode" "${cli_args[@]+"${cli_args[@]}"}"
  fi
fi
set -- --repos "$@"
# shellcheck source=wtc-status-common.sh
. "$script_dir/wtc-status-common.sh"
wtc_status_main_tui
