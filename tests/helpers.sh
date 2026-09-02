#!/usr/bin/env bash
# helpers.sh — assertions and fixtures for the harness test suite.
# Sourced by every tests/*_test.sh; never executed directly.
#
# Bash 3.2-safe (macOS default), like the tools under test: no mapfile, no
# associative arrays, no ${var,,}. A suite that needs bash 4 to check that the
# tools do not need bash 4 would be a poor joke.
#
# Tests run with `set -u` but NOT `set -e`: a failed assertion has to record
# itself and let the rest of the file run, otherwise one break hides the other
# twenty. run.sh reads the counts back out of TEST_FAILED.

set -u

TEST_PASSED=0
TEST_FAILED=0
TEST_CURRENT=""

# Every fixture directory made this run, removed by trap on exit. Tests create
# real trees on disk — a wtc harness is filesystem-shaped, and asserting on
# mocks would assert on the mocks.
TEST_TMPDIRS=""

_test_cleanup() {
  for _d in $TEST_TMPDIRS; do
    # Refuse anything that is not clearly ours, even though we made the name:
    # these are rm -rf targets and the suite creates them from $TMPDIR, which
    # a caller can set.
    case "$_d" in
      */wtc-test-*) [ -d "$_d" ] && rm -rf "$_d" ;;
    esac
  done
  # The tally is the contract with run.sh and must be the last stdout line.
  # Emitting it from the trap rather than from each file means a test that
  # dies early still reports what it managed to run, instead of looking like
  # a file that ran nothing.
  printf 'TALLY %s %s\n' "$TEST_PASSED" "$TEST_FAILED"
}
trap _test_cleanup EXIT

# --- output -----------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _c_red=$'\033[31m'; _c_green=$'\033[32m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'
else
  _c_red=""; _c_green=""; _c_dim=""; _c_off=""
fi

# it <name> — name the assertion group that follows. Purely for the report.
it() { TEST_CURRENT="$1"; }

_pass() {
  TEST_PASSED=$((TEST_PASSED + 1))
  [ -n "${TEST_VERBOSE:-}" ] && printf '  %sok%s   %s\n' "$_c_green" "$_c_off" "$1"
  return 0
}

_fail() { # <summary> [detail ...]
  TEST_FAILED=$((TEST_FAILED + 1))
  printf '  %sFAIL%s %s — %s\n' "$_c_red" "$_c_off" "$TEST_CURRENT" "$1" >&2
  shift
  for _line in "$@"; do
    printf '       %s%s%s\n' "$_c_dim" "$_line" "$_c_off" >&2
  done
  return 0
}

# --- assertions -------------------------------------------------------------

assert_eq() { # <expected> <actual> [label]
  if [ "$1" = "$2" ]; then
    _pass "${3:-$TEST_CURRENT}"
  else
    _fail "${3:-values differ}" "expected: [$1]" "actual:   [$2]"
  fi
}

assert_neq() { # <unexpected> <actual> [label]
  if [ "$1" != "$2" ]; then
    _pass "${3:-$TEST_CURRENT}"
  else
    _fail "${3:-values should differ}" "both were: [$1]"
  fi
}

assert_empty() { # <actual> [label]
  if [ -z "$1" ]; then
    _pass "${2:-$TEST_CURRENT}"
  else
    _fail "${2:-expected empty}" "actual: [$1]"
  fi
}

assert_contains() { # <haystack> <needle> [label]
  case "$1" in
    *"$2"*) _pass "${3:-$TEST_CURRENT}" ;;
    *) _fail "${3:-substring missing}" "wanted to find: [$2]" "in: [$1]" ;;
  esac
}

assert_not_contains() { # <haystack> <needle> [label]
  case "$1" in
    *"$2"*) _fail "${3:-substring present}" "did not want: [$2]" "in: [$1]" ;;
    *) _pass "${3:-$TEST_CURRENT}" ;;
  esac
}

# assert_status <expected-code> <command...> — runs the command, compares $?.
# Output is captured so a noisy tool does not corrupt the report; on failure
# the captured output is what gets printed, which is when you want it.
assert_status() {
  _want="$1"; shift
  _out="$("$@" 2>&1)"; _got=$?
  if [ "$_got" = "$_want" ]; then
    _pass "${TEST_CURRENT:-$1}"
  else
    _fail "exit $_got, wanted $_want: $*" "$_out"
  fi
}

assert_ok()   { assert_status 0 "$@"; }
assert_fails() { # any nonzero
  _out="$("$@" 2>&1)"; _got=$?
  if [ "$_got" != 0 ]; then
    _pass "${TEST_CURRENT:-$1}"
  else
    _fail "expected nonzero, got 0: $*" "$_out"
  fi
}

assert_file() { # <path> [label]
  if [ -e "$1" ]; then
    _pass "${2:-$1 exists}"
  else
    _fail "${2:-missing file}" "expected to exist: $1"
  fi
}

assert_no_file() { # <path> [label]
  if [ ! -e "$1" ]; then
    _pass "${2:-$1 absent}"
  else
    _fail "${2:-file should be gone}" "still present: $1" "$(ls -ld "$1" 2>&1)"
  fi
}

# --- fixtures ---------------------------------------------------------------

# mktemp_dir [suffix] — a scratch dir registered for cleanup.
#
# `pwd -P` matters more than it looks. On macOS $TMPDIR is under /var, which is
# a symlink to /private/var, and it carries a trailing slash that mktemp turns
# into a double one. Git always reports the physical path, so any assertion
# comparing a fixture path against something git printed fails on the spelling
# rather than the substance.
mktemp_dir() {
  _d="$(mktemp -d "${TMPDIR:-/tmp}/wtc-test-${1:-x}.XXXXXX")"
  _d="$(cd "$_d" && pwd -P)"
  TEST_TMPDIRS="$TEST_TMPDIRS $_d"
  printf '%s\n' "$_d"
}

# HARNESS_SRC — the harness worktree under test: the parent of tests/.
HARNESS_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HARNESS_SRC

# make_local_repo <path> [file] — a real git repo with one commit, no remote.
# Used to seed .bare/ owners so nothing in the suite touches the network.
make_local_repo() {
  _p="$1"
  mkdir -p "$_p"
  git -C "$_p" init -q -b main
  printf '%s\n' "${2:-seed}" > "$_p/README.md"
  git -C "$_p" add -A
  git -C "$_p" \
    -c user.name=wtc-test -c user.email=wtc-test@example.invalid \
    commit -qm "seed"
  printf '%s\n' "$_p"
}

# make_workspace — a workspace root with .bare/ and a harness worktree, wired
# so the tools run fully offline. Echoes the root.
#
# Shape (mirrors instructions/worktree-workspace.md):
#   <root>/.bare/<repo>.git         bare owners, seeded locally
#   <root>/main/harness             the harness worktree tools run from
#
# The harness is *copied*, not symlinked: tools resolve ROOT by walking up to
# the folder holding .bare/, and a symlink would walk up into the real
# workspace and operate on live collections.
make_workspace() {
  _root="$(mktemp_dir ws)"
  mkdir -p "$_root/.bare"

  # The harness source repo carries the real harness tree, so a worktree cut
  # from it has skills/, hooks/ and collection-AGENTS.md — the things
  # link-skills.sh looks for. Seeding it with a bare README instead would make
  # every tool take its "nothing to link" branch and the round trip would
  # assert almost nothing.
  _hsrc="$(mktemp_dir src-harness)"
  # -R over the whole tree then remove what must not travel: the real .git
  # (its worktrees and remotes point at the developer's workspace) and tests/
  # (a suite that ships itself into its own fixture recurses).
  cp -R "$HARNESS_SRC/." "$_hsrc/"
  rm -rf "$_hsrc/.git" "$_hsrc/tests" "$_hsrc/.harness-repos"

  cat > "$_hsrc/.harness-repos.yml" <<'YML'
repos:
  - name: agent-harness
    remote: git@github.com:example/agent-harness.git
    default_ref: origin/main

  - name: widget
    remote: https://github.com/example/widget.git
    default_ref: origin/main
    port_offset: 1
    issues_prefix: wid-

  - name: gadget
    remote: git@gitlab.com:example/gadget.git
    default_ref: origin/develop

  - name: sprocket
    remote: git@bitbucket.org:example/sprocket.git
    default_ref: origin/main

  - name: cog
    remote: https://bitbucket.org/example/cog.git
    default_ref: origin/main
YML

  git -C "$_hsrc" init -q -b main
  git -C "$_hsrc" add -A
  git -C "$_hsrc" \
    -c user.name=wtc-test -c user.email=wtc-test@example.invalid \
    commit -qm "harness fixture"

  _wsrc="$(mktemp_dir src-widget)"
  make_local_repo "$_wsrc" widget >/dev/null

  # Built as init-bare + fetch rather than `clone --bare`, because the two
  # produce different ref layouts and only one matches a real workspace. A
  # bare clone puts branches in refs/heads, so `origin/main` — which every
  # default_ref names, and which add_worktree resolves against — does not
  # exist. Fetching into refs/remotes/origin/* gives the real shape.
  for _pair in "agent-harness $_hsrc" "widget $_wsrc"; do
    set -- $_pair
    git init -q --bare "$_root/.bare/$1.git"
    git --git-dir="$_root/.bare/$1.git" remote add origin "$2"
    git --git-dir="$_root/.bare/$1.git" \
      fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
  done

  # The control collection, holding the harness worktree tools run from — the
  # same shape as the real `main/harness`.
  mkdir -p "$_root/main"
  git --git-dir="$_root/.bare/agent-harness.git" \
    worktree add -q --detach "$_root/main/harness" origin/main

  printf '%s\n' "$_root"
}

# load_lib <workspace-root> — source lib.sh the way a tool does.
load_lib() {
  HARNESS_DIR="$1/main/harness"
  export HARNESS_DIR
  WTC_HARNESS_REPO=agent-harness
  export WTC_HARNESS_REPO
  . "$HARNESS_DIR/tools/lib.sh"
  harness_lib_init
}

# add_fixture_worktree <workspace-root> <repo> <dest> — a real worktree off the
# fixture bare, the way add_worktree makes them. `git clone` would give a main
# working tree instead, which `git worktree remove` refuses, so a fixture built
# that way cannot exercise retire at all.
add_fixture_worktree() {
  git --git-dir="$1/.bare/$2.git" worktree add -q --detach "$3" origin/main
}
