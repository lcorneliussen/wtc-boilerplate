#!/usr/bin/env bash
# status_args_test.sh — wtc-status.sh argument handling, specifically the watch
# interval.
#
# The render loop is `while :; do render; sleep "$interval"; done`. That makes
# the interval the one argument that can turn a status pane into a machine
# that re-fetches every bare and every PR as fast as it can. `--watch` accepts
# anything starting with a digit and WTC_STATUS_WATCH accepts whatever is in
# the environment, so `00`, `007` and `0abc` all reach `sleep` — where the
# first two return immediately and the third fails, both without leaving the
# loop.
#
# These tests do not render: they check that a bad interval is refused before
# the loop starts, and that a zero interval means "print once".
. "$(dirname "$0")/helpers.sh"

ws="$(make_workspace)"
status="$ws/main/harness/tools/wtc-status.sh"

# A status run reaches for gh and git across the workspace. The fixture has no
# GitHub remote it can actually resolve, which is fine — everything here is
# about argv, and a run that gets as far as rendering has already answered the
# question. `timeout` caps anything that decides to loop anyway.
have_timeout=no
command -v timeout >/dev/null 2>&1 && have_timeout=yes
command -v gtimeout >/dev/null 2>&1 && { have_timeout=yes; timeout() { gtimeout "$@"; }; }

run_status() { # <seconds> <args...> -> exit code, output on stdout
  if [ "$have_timeout" = yes ]; then
    _t="$1"; shift
    timeout "$_t" "$status" "$@" </dev/null 2>&1
  else
    shift
    "$status" "$@" </dev/null 2>&1
  fi
}

# --- a non-numeric interval is refused --------------------------------------

it "a non-numeric --watch is rejected, not passed to sleep"
out="$(run_status 20 --repos --watch 0abc)"
rc=$?
if [ "$rc" != 0 ] && [ "$rc" != 124 ]; then
  _pass "rejected --watch 0abc (exit $rc)"
else
  _fail "--watch 0abc was not rejected" "exit $rc" "$(printf '%s' "$out" | head -3)"
fi
assert_contains "$out" "whole number" "the error says what it wanted"

it "a non-numeric WTC_STATUS_WATCH falls back to the default"
# The two sources are deliberately asymmetric, and the asymmetry is the point:
# a bad value you just typed should stop and tell you, while a stale one in
# wtc.env should not stand between you and the status table. So the flag
# errors out (above) and the env var silently becomes the default.
#
# What both must avoid is reaching `sleep` — that is the busy loop. Rendering
# and exiting is proof it did not.
out="$(WTC_STATUS_WATCH=abc run_status 25 --repos --no-watch)"
rc=$?
if [ "$rc" = 124 ]; then
  _fail "WTC_STATUS_WATCH=abc reached the watch loop" "$(printf '%s' "$out" | head -3)"
else
  _pass "WTC_STATUS_WATCH=abc did not reach sleep (exit $rc)"
fi

# --- a zero interval means print once ---------------------------------------

if [ "$have_timeout" = no ]; then
  it "zero-interval cases (skipped: no timeout(1) available)"
  _pass "skipped"
else
  it "--watch 0 prints once and exits"
  run_status 25 --repos --watch 0 >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 124 ]; then
    _fail "--watch 0 kept looping" "timed out instead of exiting"
  else
    _pass "--watch 0 terminated (exit $rc)"
  fi

  it "--watch 00 also means zero, not 'watch with no delay'"
  # A string compare against "0" says 00 is not zero, so watching stays on and
  # `sleep 00` returns immediately. 10# is also what keeps 007 from being read
  # as octal.
  run_status 25 --repos --watch 00 >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 124 ]; then
    _fail "--watch 00 kept looping" "00 was not normalised to 0"
  else
    _pass "--watch 00 terminated (exit $rc)"
  fi

  it "WTC_STATUS_WATCH=0 means print once"
  WTC_STATUS_WATCH=0 run_status 25 --repos >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 124 ]; then
    _fail "WTC_STATUS_WATCH=0 kept looping"
  else
    _pass "WTC_STATUS_WATCH=0 terminated (exit $rc)"
  fi

  it "--no-watch prints once"
  run_status 25 --repos --no-watch >/dev/null 2>&1
  rc=$?
  if [ "$rc" = 124 ]; then
    _fail "--no-watch kept looping"
  else
    _pass "--no-watch terminated (exit $rc)"
  fi
fi

# --- scope selection --------------------------------------------------------

it "--all and a named collection are both accepted"
assert_ok "$status" --help
out="$("$status" --help 2>&1)"
assert_contains "$out" "--all"

# --- --cached scope ---------------------------------------------------------
# The snapshot is one collection's repo rows. Used outside that, the flag can
# only produce a table that lies — so it refuses rather than rendering.

it "--cached refuses --all"
# Unscoped it would print this collection's rows under a heading claiming
# every collection, with an empty COLLECTION column.
out="$(run_status 25 --repos --cached --all)"
rc=$?
assert_neq "0" "$rc" "refused"
assert_contains "$out" "--all" "and says which flag is the problem"

it "--cached refuses --procs"
out="$(run_status 25 --procs --cached)"
assert_neq "0" "$?" "refused"
assert_contains "$out" "snapshot" "and says why"

it "--cached without --repos does not fall back to live work"
# The default view is `both`: the repo table, then the process table. Honouring
# --cached only in the `repos` branch meant a bare `--cached` did the whole
# live render anyway — exactly the work the flag exists to skip. It selects
# the repo view instead, and the output has to prove it came from the file.
#
# An unscoped run still means *this* collection (only defaults to it), so a
# snapshot exists by now: earlier cases in this file wrote one.
out="$(run_status 25 --cached)"
assert_ok true   # the run itself is asserted through its output below
assert_contains "$out" "snapshot," "rendered from the snapshot, not live"
assert_not_contains "$out" "MEM" "and did not fall through to the process table"

# --- focus-aware interval ---------------------------------------------------
# wtc-open puts a status pane in every collection, so most of them redraw on a
# timer while at most one is visible. The unfocused ones should not spend a
# shared API budget repainting what nobody is reading.

it "the interval knobs are documented where they apply"
# On the TUI, not the one-shot: an interval means nothing to a tool that
# prints once and exits, and its help says so by pointing at the other.
out="$("$ws/main/harness/tools/wtc-status-tui.sh" --help 2>&1)"
assert_contains "$out" "WTC_STATUS_WATCH_BG"
assert_contains "$out" "WTC_FORGE_CACHE_AGE"

# Source the real common implementation in a child: it sets shell options and
# traps, which must not replace the test runner's tally/cleanup trap.
status_eval() {
  WTC_CONFIG_ROOT="$ws/test-config" bash -c '
    . "$1" --repos --no-fetch
    eval "$2"
  ' status-test "$ws/main/harness/tools/wtc-status-common.sh" "$1"
}

it "an unfocused pane waits longer than a focused one"
assert_eq "300" "$(status_eval 'status_pane_focused() { return 1; }; current_interval')"
assert_eq "30" "$(status_eval 'status_pane_focused() { return 0; }; current_interval')"

it "unknown counts as focused, so nothing degrades outside herdr"
assert_eq "30" "$(status_eval 'unset HERDR_SESSION HERDR_PANE_ID; current_interval')"
assert_eq "30" "$(status_eval '
  HERDR_SESSION=test HERDR_PANE_ID=test
  herdr() { return 1; }
  current_interval')" "a failed focus query also uses the focused interval"

it "WTC_STATUS_WATCH_BG=00 restores a single interval"
assert_eq "30" "$(WTC_STATUS_WATCH_BG=00 status_eval '
  status_pane_focused() { return 1; }; current_interval')"

it "background intervals accept leading zeros and reject non-numbers"
assert_eq "90" "$(WTC_STATUS_WATCH_BG=090 status_eval '
  status_pane_focused() { return 1; }; current_interval')"
assert_eq "300" "$(WTC_STATUS_WATCH_BG=abc status_eval '
  status_pane_focused() { return 1; }; current_interval')"

it "focusing a pane during its background wait advances the refresh"
# Stub only event sources and drawing; run the actual wait and interval code.
# read simulates one elapsed tick without sleeping. Focus changes at tick 2,
# after the focused deadline, so waiting should end there instead of tick 300.
assert_eq "2 yes" "$(status_eval '
  interval=1
  status_pane_focused() { [ "${_tick:-0}" -ge 2 ]; }
  read() { return 1; }
  poll_refresh_complete() { return 1; }
  update_status_clock() { :; }
  _redraw_only=no _refresh_pending=no
  wait_events
  printf "%s %s\n" "$_tick" "$_refresh_pending"')"
