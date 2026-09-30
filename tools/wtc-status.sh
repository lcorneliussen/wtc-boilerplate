#!/usr/bin/env bash
# wtc-status.sh — one-shot collection status for agents and scripts (always
# fresh). `--tui [seconds]` is a compatibility shim to the live pane.
set -euo pipefail
WTC_STATUS_UI=oneshot
# `--tui` (optional refresh interval) is consumed here rather than left for
# wtc-status-common.sh's flag parser, which would otherwise reject it as
# unknown. A bare number after `--tui` becomes `--watch N` for the TUI.
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --tui)
      WTC_STATUS_UI=tui
      shift
      case "${1:-}" in
        [0-9]*) args+=(--watch "$1"); shift ;;
      esac
      ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_harness="$(dirname "$script_dir")"
# --load-only is a private shell worker mode; keep it on the legacy path.
native_status=yes
for arg in "$@"; do
  [ "$arg" != --load-only ] || native_status=no
done
if [ "$native_status" = yes ]; then
  # shellcheck source=wtc-status-native-common.sh
  . "$script_dir/wtc-status-native-common.sh"
  if wtc_status_native_command "$source_harness"; then
    # In the shell view, --repos keeps the PR section; native --repos hides it.
    # Drop that selector and preserve the shell's last-selector-wins rule.
    cli_args=()
    status_mode=repos
    for arg in "$@"; do
      case "$arg" in
        --repos) status_mode=repos ;;
        --procs) status_mode=procs ;;
        *) cli_args+=("$arg") ;;
      esac
    done
    [ "$status_mode" != procs ] || cli_args=(--procs "${cli_args[@]+"${cli_args[@]}"}")
    # The shell selector retains PR rows, including when configured in wtc.env.
    export WTC_STATUS_REPOS=no
    cd "$(dirname "$source_harness")"
    if [ "$WTC_STATUS_UI" = tui ]; then
      wtc_status_native_tui --tui "${cli_args[@]+"${cli_args[@]}"}"
      exit $?
    fi
    exec "${WTC_STATUS_NATIVE[@]}" status "${cli_args[@]+"${cli_args[@]}"}"
  fi
fi
# shellcheck source=wtc-status-common.sh
. "$script_dir/wtc-status-common.sh"
if [ "$WTC_STATUS_UI" = tui ]; then
  wtc_status_main_tui
else
  wtc_status_main_oneshot
fi
