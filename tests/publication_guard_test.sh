#!/usr/bin/env bash
source "$(dirname "$0")/helpers.sh"

it 'publication guard Python suite'
assert_ok python3 -I "$HARNESS_SRC/tests/publication_guard_test.py"
exit "$TEST_FAILED"
