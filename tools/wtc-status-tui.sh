#!/usr/bin/env bash
# wtc-status-tui.sh — the live status pane.
#
# A two-line exec onto `wtc-status.sh --tui`, and deliberately nothing more.
# The split that matters is collect/render inside wtc-status.sh, not one script
# per mode: two implementations of the same table drift, and a mode flag says
# the same thing to `ps` that a second filename does.
#
# It exists for the name. wtc-open types this into the status pane, so shell
# history and a process list read as what the pane is rather than as a flag
# on something else, and retire.sh's kill-needle has a stable string to match.
# Flags after it still win.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
exec "$script_dir/wtc-status.sh" --tui --repos "$@"
