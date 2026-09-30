#!/usr/bin/env bash
# Published-binary contract for section overlays and base drift.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_SRC="$(dirname "$TESTS_DIR")"
. "$TESTS_DIR/helpers.sh"

if [ -z "${WTC_TEST_RELEASE_BINARY:-}" ]; then
  echo 'set WTC_TEST_RELEASE_BINARY to run the published-binary section contract'
  exit 0
fi

cli="$WTC_TEST_RELEASE_BINARY"
it 'published CLI has the release version'
assert_eq 'wtc version 0.1.25' "$("$cli" --version)"

collection="$(mktemp -d "${TMPDIR:-/tmp}/wtc-test-skill-overlay.XXXXXX")"
TEST_TMPDIRS="$TEST_TMPDIRS $collection"
base_dir="$collection/harness/skills/wtc-customize"
overlay="$collection/harness/overlays/skills/wtc-customize"
mkdir -p "$base_dir" "$overlay/sections"
cat > "$collection/harness/.harness-repos.yml" <<'REGISTRY'
repos:
  - name: widget
    remote: https://example.invalid/widget.git
    default_ref: origin/main
REGISTRY
cat > "$base_dir/SKILL.md" <<'BASE'
---
name: wtc-customize
description: Synthetic local skill.
---

# Customize

## Setup

Old setup.

## Keep

Keep this.
BASE
cat > "$overlay/sections/setup.md" <<'PATCH'
## Setup

New setup.
PATCH
python3 - "$base_dir/SKILL.md" "$overlay/.wtc-base.sha256" <<'PY'
import hashlib, pathlib, sys
pathlib.Path(sys.argv[2]).write_text(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() + '\n')
PY

it 'released binary reports the reviewed patch and its changed lines'
report="$("$cli" skills diff --collection "$collection" --changes)"
assert_contains "$report" 'wtc-customize: reviewed (overlays/skills/wtc-customize/sections)' 'reviewed base'
assert_contains "$report" '-Old setup.' 'removed base line'
assert_contains "$report" '+New setup.' 'added patch line'

it 'released binary renders the patch and preserves another section'
assert_ok "$cli" skills render --collection "$collection"
generated="$collection/.wtc/skills/wtc-customize/SKILL.md"
assert_file "$generated" 'generated skill exists'
assert_contains "$(cat "$generated")" 'New setup.' 'patch rendered'
assert_contains "$(cat "$generated")" 'Keep this.' 'other section preserved'
assert_not_contains "$(cat "$generated")" 'Old setup.' 'old section removed'

it 'a content-only base change is visible and blocks rendering on the stale digest'
sed 's/Old setup\./Upstream setup changed./' "$base_dir/SKILL.md" > "$base_dir/changed"
mv "$base_dir/changed" "$base_dir/SKILL.md"
report="$("$cli" skills diff --collection "$collection" --changes)"
assert_contains "$report" 'wtc-customize: drifted (overlays/skills/wtc-customize/sections)' 'base drift reported'
assert_not_contains "$report" 'cannot apply:' 'heading remains applicable'
assert_fails "$cli" skills render --collection "$collection" --dry-run
assert_fails "$cli" skills render --collection "$collection"
assert_contains "$(cat "$generated")" 'New setup.' 'failed render kept previous output'

it 'reviewing the new base digest allows rendering again'
python3 - "$base_dir/SKILL.md" "$overlay/.wtc-base.sha256" <<'PY'
import hashlib, pathlib, sys
pathlib.Path(sys.argv[2]).write_text(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest() + '\n')
PY
report="$("$cli" skills diff --collection "$collection")"
assert_contains "$report" 'wtc-customize: reviewed (overlays/skills/wtc-customize/sections)' 'new base reviewed'
assert_ok "$cli" skills render --collection "$collection"
assert_contains "$(cat "$generated")" 'New setup.' 'patch still rendered'

it 'a renamed heading remains visible as drift and cannot render'
sed 's/## Setup/## Renamed setup/' "$base_dir/SKILL.md" > "$base_dir/changed"
mv "$base_dir/changed" "$base_dir/SKILL.md"
report="$("$cli" skills diff --collection "$collection" --changes)"
assert_contains "$report" 'wtc-customize: drifted (overlays/skills/wtc-customize/sections)' 'renamed base drift reported'
assert_contains "$report" 'cannot apply: setup.md: heading "## Setup" not found' 'renamed heading reported'
assert_fails "$cli" skills render --collection "$collection" --dry-run
assert_fails "$cli" skills render --collection "$collection"
assert_contains "$(cat "$generated")" 'New setup.' 'failed render kept previous output'
