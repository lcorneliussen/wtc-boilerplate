#!/usr/bin/env bash
# run.sh — run the harness test suite.
#
#   tests/run.sh                 every tests/*_test.sh
#   tests/run.sh lib retire      only those (substring match on the file name)
#   TEST_VERBOSE=1 tests/run.sh  print every passing assertion, not just failures
#
# Each file runs in its own bash process, so a test that leaves the shell in a
# strange state — and several here deliberately try to — cannot take the rest
# of the suite with it. The child reports its counts on the last line of
# stdout; anything else it prints is passed through.
#
# Exit status is the number of failed files, capped at 125 (126/127 mean
# something else to a shell, and 128+ is a signal).
set -u

# Tests construct their own collection and control root. Agent shell hooks and
# machine-local settings must not change child test processes. Keep deliberate
# BASH_ENV instrumentation from coverage.sh.
case "${BASH_ENV:-}" in */agent-env.sh) unset BASH_ENV ;; esac
unset CLAUDE_PROJECT_DIR WTC_CONFIG_ROOT WTC_HARNESS_REPO

tests_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$tests_dir"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  red=$'\033[31m'; green=$'\033[32m'; bold=$'\033[1m'; dim=$'\033[2m'; off=$'\033[0m'
else
  red=""; green=""; bold=""; dim=""; off=""
fi

# Select files. With no arguments, all of them.
files=""
for f in *_test.sh; do
  [ -e "$f" ] || continue
  if [ $# -eq 0 ]; then
    files="$files $f"
  else
    for want in "$@"; do
      case "$f" in *"$want"*) files="$files $f"; break ;; esac
    done
  fi
done

if [ -z "$files" ]; then
  echo "no test files matched${*:+ ($*)}" >&2
  exit 1
fi

started=$(date +%s)
total_pass=0 total_fail=0 failed_files=0 ran=0

for f in $files; do
  ran=$((ran + 1))
  printf '%s%s%s\n' "$bold" "$f" "$off"

  # The child prints its own failures to stderr as it goes; the last stdout
  # line is the machine-readable tally.
  out="$(bash "$f" 2>&1)"
  rc=$?
  tally="$(printf '%s\n' "$out" | tail -n1)"
  body="$(printf '%s\n' "$out" | sed '$d')"
  [ -n "$body" ] && printf '%s\n' "$body"

  case "$tally" in
    TALLY\ *)
      p="$(printf '%s' "$tally" | cut -d' ' -f2)"
      q="$(printf '%s' "$tally" | cut -d' ' -f3)"
      ;;
    *)
      # No tally means the file died before it could report — a syntax error,
      # or an `exit` somewhere it should not be. That is a failure of the file,
      # not zero tests.
      printf '  %sFAIL%s %s exited (%s) without reporting a tally\n' \
        "$red" "$off" "$f" "$rc" >&2
      [ -n "$tally" ] && printf '       %s%s%s\n' "$dim" "$tally" "$off" >&2
      p=0; q=1
      ;;
  esac

  total_pass=$((total_pass + p))
  total_fail=$((total_fail + q))
  [ "$q" -gt 0 ] && failed_files=$((failed_files + 1))
done

elapsed=$(( $(date +%s) - started ))

printf '\n'
if [ "$total_fail" -eq 0 ]; then
  printf '%sok%s  %s passed  %s files  (%ss)\n' "$green" "$off" "$total_pass" "$ran" "$elapsed"
  exit 0
fi
printf '%sFAILED%s  %s passed, %s failed  in %s of %s files  (%ss)\n' \
  "$red" "$off" "$total_pass" "$total_fail" "$failed_files" "$ran" "$elapsed"
[ "$failed_files" -gt 125 ] && failed_files=125
exit "$failed_files"
