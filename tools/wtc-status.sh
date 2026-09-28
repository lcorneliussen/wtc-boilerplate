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
# shellcheck source=wtc-status-common.sh
. "$script_dir/wtc-status-common.sh"
if [ "$WTC_STATUS_UI" = tui ]; then
  wtc_status_main_tui
else
  wtc_status_main_oneshot
fi
