#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
if python3 -I tests/publication_guard_test.py; then
  echo 'TALLY 1 0'
else
  echo 'TALLY 0 1'
  exit 1
fi
