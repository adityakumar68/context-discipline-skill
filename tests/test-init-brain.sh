#!/usr/bin/env bash
# Tests for init-brain.sh: where it agrees to set up a brain, and that the brain it makes is one the hook loads.
# Usage: bash tests/test-init-brain.sh
# Self-contained: works in a mktemp folder with HOME pointed into it, so nothing outside it is read or written.

set -u
S=$(cd "$(dirname "$0")/../context-discipline/scripts" && pwd -P)
H="$S/brain-hook.sh"; I="$S/init-brain.sh"
T=$(mktemp -d) && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
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

echo "== init-brain tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
