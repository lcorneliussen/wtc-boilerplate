#!/bin/sh
set -eu
: "${WTC_COLLECTION:?this hook only runs in a collection}"
if [ -f .runtime-data/owner ] && [ "$(cat .runtime-data/owner)" != "$WTC_COLLECTION" ]; then
  echo 'refusing another collection resource' >&2
  exit 1
fi
mkdir -p .runtime-data
printf '%s' "$WTC_COLLECTION" > .runtime-data/owner
touch .runtime-data/database
printf 'synthetic collection resource provisioned\n'
