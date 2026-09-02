#!/usr/bin/env bash
# wtc-status.sh — one-shot collection status for agents and scripts (always
# fresh). Ported from the Steep reference implementation
# (harness/tools/steep-status.sh, port/status-from-steep) for side-by-side
# testing; the previous boilerplate-native implementation is preserved as
# wtc-status-legacy.sh / wtc-status-legacy-tui.sh (unwired from wtc-open.sh
# and retire.sh — run those by hand to compare).
set -euo pipefail
WTC_STATUS_UI=oneshot
# --tui is a compatibility shim: wtc-status-tui.sh, and anyone who still
# types `wtc-status.sh --tui` out of boilerplate-legacy habit, gets the live
# pane without this file needing its own copy of the dispatch below. Consumed
# here rather than left for wtc-status-common.sh's own flag parser, which
# would otherwise reject it as unknown.
args=()
for a in "$@"; do
  case "$a" in
    --tui) WTC_STATUS_UI=tui ;;
    *) args+=("$a") ;;
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
