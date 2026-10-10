#!/usr/bin/env bash
# Tests for init-brain.sh: where it agrees to set up a brain, and that the brain it makes is one the hook loads.
# Usage: bash tests/test-init-brain.sh
# Self-contained: works in a mktemp folder with HOME pointed into it, so nothing outside it is read or written.

set -u
S=$(cd "$(dirname "$0")/../context-discipline/scripts" && pwd -P)
H="$S/brain-hook.sh"; I="$S/init-brain.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/cd-tests.XXXXXX") && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
T=$(cd "$T" && pwd -P) || exit 1    # resolve symlinks (macOS /var -> /private/var) so paths compare equal
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name"; fi; }

HM="$T/home"; mkdir -p "$HM"
init() { env HOME="$HM" bash "$I" "$@" 2>&1; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }

mkdir -p "$HM/p1"; out=$(init "$HM/p1"); rc=$?
check "summary gives the hook's STATUS limit in characters (9,000)" eval '[ $rc = 0 ] && has "$out" "9,000 characters"'

# nothing_in <dir>: init-brain wrote nothing there (no STATUS, overview or pointer).
nothing_in() { [ ! -e "$1/STATUS.md" ] && [ ! -e "$1/00-Project-Overview.md" ] && [ ! -e "$1/.claude/brain" ]; }

# --- roots the hook can never load: $HOME and / -------------------------------------------------------------------
out=$(init "$HM"); rc=$?
check "root = \$HOME: refused (exit 1) with a message, nothing written" \
  eval '[ $rc = 1 ] && has "$out" "home folder" && nothing_in "$HM"'
ln -s "$HM" "$T/home-link"
out=$(env HOME="$T/home-link" bash "$I" "$HM" 2>&1); rc=$?
check "root = \$HOME reached through a symlinked HOME: refused too" eval '[ $rc = 1 ] && nothing_in "$HM"'
out=$(init /); rc=$?
check "root = /: refused (exit 1) with a message" eval '[ $rc = 1 ] && has "$out" "refus"'

# --- STATUS paths the hook would refuse are refused here too, before anything is written --------------------------
mkdir -p "$HM/p2/docs" "$HM/outside"
for bad in '~/notes/STATUS.md' "$HM/p2/STATUS.md" '../STATUS.md' 'docs/../../STATUS.md' 'docs/' 'docs'; do
  out=$(cd "$HM/p2" && init "$HM/p2" "$bad"); rc=$?
  check "STATUS path '$bad': refused (exit 1), nothing written" \
    eval '[ $rc = 1 ] && nothing_in "$HM/p2" && [ ! -e "$HM/p2/~" ] && [ ! -e "$HM/p2/docs/STATUS.md" ]'
done
ln -s "$HM/outside" "$HM/p2/notes"
out=$(init "$HM/p2" notes/STATUS.md); rc=$?
check "STATUS path through a symlinked folder that leaves the project: refused" \
  eval '[ $rc = 1 ] && [ ! -e "$HM/outside/STATUS.md" ] && nothing_in "$HM/p2"'

# --- failures show in the exit code -------------------------------------------------------------------------------
mkdir -p "$HM/ro"; chmod 555 "$HM/ro"
out=$(init "$HM/ro"); rc=$?
chmod 755 "$HM/ro"
check "read-only root: reports NOT created and exits non-zero" eval '[ $rc != 0 ] && has "$out" "NOT created"'

# --- the project name goes into the templates as typed ------------------------------------------------------------
P3="$HM/proj\tname"; mkdir -p "$P3"; init "$P3" >/dev/null
check "backslashes in the folder name are kept in the STATUS heading" grep -qF 'proj\tname — STATUS' "$P3/STATUS.md"

# --- whatever init-brain sets up, the hook loads ------------------------------------------------------------------
mkdir -p "$HM/p4/sub"
init "$HM/p4" docs/brain/STATUS.md >/dev/null
out=$(printf '{"cwd": "%s"}' "$HM/p4/sub" | env -u CLAUDE_PROJECT_DIR HOME="$HM" bash "$H" | tail -n 1)
check "nested custom STATUS path: the hook loads it" has "$out" "loaded from $HM/p4/docs/brain/STATUS.md"

echo "== init-brain tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
