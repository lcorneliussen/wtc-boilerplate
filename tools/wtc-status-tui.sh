#!/usr/bin/env bash
# wtc-status-tui.sh — the live status pane.
#
# A two-line exec onto `wtc-status.sh --tui`, and deliberately nothing more.
# The split that matters is collect/render inside wtc-status.sh, not one script
# per mode: two implementations of the same table drift, and a mode flag says
# the same thing to `ps` that a second filename does.
#
# It exists for the name at the point it is *typed*: wtc-open puts this in the
# pane, so shell history and the pane's own command read as what the pane is
# rather than as a flag on something else.
#
# It does not change what `ps` shows — a plain exec keeps argv[0] as the
# wtc-status.sh path, and that is deliberate: retire.sh finds a running status
# pane by matching that path, so `exec -a` to dress up the process name would
# hide the pane from the thing whose job is to kill it.
#
# Flags after it still win.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
exec "$script_dir/wtc-status.sh" --tui --repos "$@"
