#!/usr/bin/env bash
# wtc-status-tui.sh — live herdr status pane (watch, click, background refresh).
# Sets the mode and sources the shared implementation in wtc-status-common.sh.
set -euo pipefail
WTC_STATUS_UI=tui
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wtc-status-common.sh
. "$script_dir/wtc-status-common.sh"
wtc_status_main_tui
