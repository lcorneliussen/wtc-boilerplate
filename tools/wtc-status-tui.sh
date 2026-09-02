#!/usr/bin/env bash
# wtc-status-tui.sh — the live status pane.
#
# Ported from the Steep reference (harness/tools/steep-status-tui.sh,
# port/status-from-steep): sets the mode and sources the shared
# implementation directly, rather than exec-ing into wtc-status.sh the way
# the boilerplate-native wtc-status-legacy-tui.sh does.
#
# Kept as its own file purely for the name at the point it is *typed*:
# wtc-open.sh puts this path in the pane, so shell history and the pane's own
# command read as what the pane is. retire.sh matches a running pane by that
# same path (tools/retire.sh's status_needle) — note that this only works
# because there is no exec here: `ps` shows a sourced script's own path, not
# whatever it sources, so retire.sh's needle had to move from wtc-status.sh
# to wtc-status-tui.sh when this stopped being an exec wrapper. If this file
# is ever turned back into an exec (`exec wtc-status.sh --tui "$@"`), move
# the needle back.
set -euo pipefail
WTC_STATUS_UI=tui
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wtc-status-common.sh
. "$script_dir/wtc-status-common.sh"
wtc_status_main_tui
