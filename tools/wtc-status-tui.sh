#!/usr/bin/env bash
# wtc-status-tui.sh — live herdr status pane (watch, click, background refresh).
# Sets the mode and sources the shared implementation in wtc-status-common.sh.
#
# Defaults to the repos table (what wtc-open.sh starts). Explicit --procs /
# --repos after this still win — the common parser applies flags in order.
set -euo pipefail
WTC_STATUS_UI=tui
set -- --repos "$@"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wtc-status-common.sh
. "$script_dir/wtc-status-common.sh"
wtc_status_main_tui
