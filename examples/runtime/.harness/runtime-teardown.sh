#!/bin/sh
set -eu
: "${WTC_COLLECTION:?this hook only runs in a collection}"
if [ "${RUNTIME_TEARDOWN_FAIL:-0}" = 1 ]; then
  echo 'deliberate fixture teardown failure' >&2
  exit 8
fi
[ -d .runtime-data ] || exit 0
if [ ! -f .runtime-data/owner ] || [ "$(cat .runtime-data/owner)" != "$WTC_COLLECTION" ]; then
  echo 'refusing unowned resource cleanup' >&2
  exit 1
fi
rm -rf .runtime-data
printf 'synthetic collection resource removed\n'
