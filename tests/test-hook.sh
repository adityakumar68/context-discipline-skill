#!/usr/bin/env bash
# Tests for brain-hook.sh: which STATUS files it will print (containment) and how it keeps its output under
# Claude Code's 10,000-character hook cap.
# Usage: bash tests/test-hook.sh
# Self-contained: works in a mktemp folder with HOME pointed into it, so nothing outside it is read or written.

set -u
H=$(cd "$(dirname "$0")/../context-discipline/scripts" && pwd -P)/brain-hook.sh
T=$(mktemp -d) && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
T=$(cd "$T" && pwd -P) || exit 1    # resolve symlinks (macOS /var -> /private/var) so paths compare equal
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name"; fi; }

HM="$T/home"          # the fake home; every project below lives under it
# run_hook <cwd>: run the hook for a session in <cwd>, with the fake home and no CLAUDE_PROJECT_DIR.
run_hook() { printf '{"cwd": "%s", "source": "startup"}' "$1" | env -u CLAUDE_PROJECT_DIR HOME="$HM" bash "$H"; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }
lines() { printf '%s\n' "$1" | grep -c ''; }
# refused <output> <pointer>: one warning line that names the pointer, and none of the secret text.
refused() { [ "$(lines "$1")" = 1 ] && has "$1" "not loaded" && has "$1" "$2" && ! has "$1" SECRET; }

# Secrets outside any project, and a project with a normal brain.
mkdir -p "$HM/.ssh" "$HM/.aws" "$HM/outside" "$HM/p/.claude" "$HM/p/docs" "$HM/p/src/deep"
echo "SECRET-KEY-MATERIAL" > "$HM/.ssh/id_ed25519"
echo "aws_secret_access_key = SECRET-AWS" > "$HM/.aws/credentials"
echo "SECRET-OUTSIDE-STATUS" > "$HM/outside/STATUS.md"
printf '# STATUS\nproject-p-status\n' > "$HM/p/STATUS.md"
P="$HM/p"; PTR="$P/.claude/brain"
point() { printf '%s\n' "$1" > "$PTR"; }   # point <line>: rewrite project p's pointer

# --- containment: what the pointer may name ---------------------------------------------------------------------
point STATUS.md; out=$(run_hook "$P/src/deep"); rc=$?
check "relative path inside the project: STATUS printed, exit 0" eval '[ $rc = 0 ] && has "$out" project-p-status'

point "$HM/.ssh/id_ed25519"; out=$(run_hook "$P/src"); rc=$?
check "absolute path to a file outside: refused with one warning line, exit 0" eval '[ $rc = 0 ] && refused "$out" "$PTR"'

point "$P/STATUS.md"; out=$(run_hook "$P")
check "absolute path even inside the project: refused" eval 'refused "$out" "$PTR" && ! has "$out" project-p-status'

point '~/.aws/credentials'; out=$(run_hook "$P")
check "~/ path: refused" refused "$out" "$PTR"

point '../.aws/credentials'; out=$(run_hook "$P/src")
check "../ escape: refused" refused "$out" "$PTR"

point 'docs/../../outside/STATUS.md'; out=$(run_hook "$P")
check "escape hidden after a subfolder (docs/../../): refused" refused "$out" "$PTR"

point 'docs/../STATUS.md'; out=$(run_hook "$P")
check ".. that stays inside the project: allowed" has "$out" project-p-status

ln -s "$HM/.ssh/id_ed25519" "$P/link-out.md"; point link-out.md; out=$(run_hook "$P")
check "symlink inside the project to a file outside: refused" refused "$out" "$PTR"

ln -s "$HM/outside" "$P/notes"; point notes/STATUS.md; out=$(run_hook "$P")
check "path through a symlinked folder that leaves the project: refused" refused "$out" "$PTR"

ln -s STATUS.md "$P/link-in.md"; point link-in.md; out=$(run_hook "$P")
check "symlink inside the project to a file inside it: allowed" has "$out" project-p-status

point docs; out=$(run_hook "$P")
check "pointer naming a folder: one warning line, no output otherwise" refused "$out" "$PTR"

point missing.md; out=$(run_hook "$P")
check "pointer naming a missing file: one warning line" refused "$out" "$PTR"

printf 'A\000B SECRET\n' > "$P/binary.md"; point binary.md; out=$(run_hook "$P")
check "pointer naming a binary file (NUL bytes): refused" refused "$out" "$PTR"

# A project reached through a symlinked path still loads (the root is compared after resolving links).
point STATUS.md; ln -s "$P" "$HM/p-link"; out=$(run_hook "$HM/p-link/src")
check "project reached through a symlinked path: STATUS printed" has "$out" project-p-status

# A pointer in a parent folder (say ~/Downloads) cannot reach files beside that folder.
mkdir -p "$HM/Downloads/.claude" "$HM/Downloads/other/x"; echo '../.aws/credentials' > "$HM/Downloads/.claude/brain"
out=$(run_hook "$HM/Downloads/other/x")
check "parent-folder pointer reaching outside its folder: refused" refused "$out" "$HM/Downloads/.claude/brain"

echo "== hook tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
