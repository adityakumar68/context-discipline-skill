#!/usr/bin/env bash
# Tests for brain-hook.sh: which STATUS files it will print (containment) and how it keeps its output under
# Claude Code's 10,000-character hook cap.
# Usage: bash tests/test-hook.sh
# Self-contained: works in a mktemp folder with HOME pointed into it, so nothing outside it is read or written.

set -u
H=$(cd "$(dirname "$0")/../context-discipline/scripts" && pwd -P)/brain-hook.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/cd-tests.XXXXXX") && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
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

# --- size: Claude Code replaces hook output over 10,000 characters (JS string length) with a 2,000-char preview ---
# units: the trimmed output's length as Claude Code measures it (UTF-16 units); fails if the bytes are not UTF-8.
units() { python3 -I -c 'import sys; s = sys.stdin.buffer.read().decode("utf-8").strip(); print(len(s.encode("utf-16-le")) // 2)' 2>/dev/null; }
# count <char>: how many times <char> occurs in stdin.
count() { python3 -I -c 'import sys; print(sys.stdin.buffer.read().decode("utf-8", "replace").count(sys.argv[1]))' "$1"; }
# make_status <dir> <python expression for the text>: a project with a STATUS.md holding that text.
make_status() {
  mkdir -p "$1/.claude"; echo STATUS.md > "$1/.claude/brain"
  python3 -I -c 'import sys; open(sys.argv[1], "w", encoding="utf-8").write(eval(sys.argv[2]))' "$1/STATUS.md" "$2"
}

make_status "$HM/cjk" '"\u72b6" * 4000 + "END-MARKER\n"'     # 4,011 characters, 12,011 bytes
out=$(run_hook "$HM/cjk")
check "4,011-char CJK STATUS (12,011 bytes) printed whole: counted in characters, not bytes" \
  eval 'has "$out" END-MARKER && ! has "$out" "characters,"'

make_status "$HM/fits" '"x" * 8999 + "\n"'                    # exactly 9,000 characters
out=$(run_hook "$HM/fits")
check "9,000-char STATUS printed whole, no trim notice" eval 'has "$out" "loaded from" && ! has "$out" "characters,"'

make_status "$HM/ascii" '"x" * 12000'
out=$(run_hook "$HM/ascii")
check "12,000-char STATUS: notice gives the real count and the limit" \
  has "$out" "[STATUS.md is 12,000 characters, over the 9,000 limit, so only the first 9,000 are shown here."
check "12,000-char STATUS: 9,000 shown, whole output under 10,000 characters" \
  eval '[ "$(printf "%s\n" "$out" | head -n 1 | units)" = 9000 ] && [ "$(printf "%s" "$out" | units)" -le 10000 ]'

make_status "$HM/cjkbig" '"\u72b6" * 10000'
out=$(run_hook "$HM/cjkbig")
check "10,000-char CJK STATUS: cut on a character boundary to 9,000 characters" \
  eval '[ "$(printf "%s" "$out" | count "$(printf "\347\212\266")")" = 9000 ] && has "$out" "is 10,000 characters"'

make_status "$HM/emoji" '"\U0001F600" * 5000'                  # 5,000 emoji = 10,000 UTF-16 units
out=$(run_hook "$HM/emoji")
check "emoji STATUS: counted as Claude Code counts them (2 each), valid UTF-8, output under 10,000" \
  eval 'has "$out" "is 10,000 characters" && [ "$(printf "%s" "$out" | units)" -le 10000 ]'

make_status "$HM/mixed" '"a" + "\u20ac" * 9500'
out=$(run_hook "$HM/mixed")
check "odd byte offset (a + euro signs): the cut never splits a character" eval '[ "$(printf "%s" "$out" | units)" -le 10000 ]'

long="$HM"   # a 960-char project path (paths stay under 1,024, the macOS limit)
while [ $((${#long} + 101)) -le 960 ]; do long="$long/$(printf 'd%.0s' $(seq 1 100))"; done
pad=$((960 - ${#long} - 1)); [ "$pad" -gt 0 ] && long="$long/$(printf 'e%.0s' $(seq 1 "$pad"))"
make_status "$long" '"y" * 8999 + "\n"'
out=$(run_hook "$long")
check "very long project path (${#long} chars): STATUS line + notice still fit under 10,000" \
  eval '[ "$(printf "%s" "$out" | units)" -le 10000 ] && has "$out" "loaded from"'
printf '%s/STATUS.md\n' "$(printf 'x%.0s' $(seq 1 200))" > "$long/.claude/brain"
out=$(printf '{"cwd": "%s"}' "$long" | env -u CLAUDE_PROJECT_DIR HOME="$HM" bash "$H" 2>"$T/err")
check "project path + pointer path over 1,024 bytes: refused, nothing on stderr" \
  eval 'refused "$out" "$long/.claude/brain" && [ ! -s "$T/err" ]'


# --- finding the pointer ------------------------------------------------------------------------------------------
point STATUS.md
out=$(cd "$P/src" && echo '{bad json' | env -u CLAUDE_PROJECT_DIR HOME="$HM" bash "$H"); rc=$?
check "malformed JSON: prints nothing (no fallback to \$PWD), exit 0" eval '[ $rc = 0 ] && [ -z "$out" ]'
out=$(echo '{bad json' | env CLAUDE_PROJECT_DIR="$P" HOME="$HM" bash "$H")
check "malformed JSON: no fallback to \$CLAUDE_PROJECT_DIR either" [ -z "$out" ]
out=$(echo '{"source": "startup"}' | env CLAUDE_PROJECT_DIR="$P/src" HOME="$HM" bash "$H")
check "valid JSON without cwd: falls back to \$CLAUDE_PROJECT_DIR" has "$out" project-p-status

# Without jq the hook parses its input with python3; same results.
NOJQ="$T/bin-without-jq"; mkdir -p "$NOJQ"
for c in bash cat dirname basename readlink tr wc head tail od awk python3; do ln -s "$(command -v "$c")" "$NOJQ/$c"; done
out=$(printf '{"cwd": "%s"}' "$P/src" | env -u CLAUDE_PROJECT_DIR PATH="$NOJQ" HOME="$HM" "$NOJQ/bash" "$H")
check "no jq on PATH: python3 reads the cwd, STATUS printed" has "$out" project-p-status
out=$(cd "$P/src" && echo '[1, 2]' | env -u CLAUDE_PROJECT_DIR PATH="$NOJQ" HOME="$HM" "$NOJQ/bash" "$H")
check "no jq on PATH: input that is not a JSON object prints nothing" [ -z "$out" ]

printf '\357\273\277STATUS.md\r\n' > "$PTR"; out=$(run_hook "$P")
check "pointer with a UTF-8 BOM and CRLF: still read" has "$out" project-p-status
point STATUS.md

# Only the first 4,096 bytes of a pointer are read, and its path line may be at most 1,024 bytes: a cloned repo's
# pointer with a 1 MB line once took bash 3.2 about 20 s to trim (quadratic), at every session start.
# writef <python expression>: write that text to project p's pointer.
writef() { python3 -I -c 'import sys; open(sys.argv[1], "w").write(eval(sys.argv[2]))' "$PTR" "$1"; }
writef '"a" * 1000000'
start=$(python3 -I -c 'import time; print(time.time())')
out=$(printf '{"cwd": "%s"}' "$P" | env -u CLAUDE_PROJECT_DIR HOME="$HM" perl -e 'alarm shift; exec @ARGV' 10 \
  bash "$H" 2>"$T/err"); rc=$?
ms=$(python3 -I -c "import time; print(int((time.time() - $start) * 1000))")
check "1 MB path line: refused as naming no file, exit 0, in ${ms} ms (limit 2,000)" \
  eval '[ $rc = 0 ] && refused "$out" "$PTR" && has "$out" "names no file" && [ "$ms" -lt 2000 ]'
check "1 MB path line: nothing on stderr" eval '[ ! -s "$T/err" ]'
writef '"a" * 1025 + "\n"'; out=$(run_hook "$P")
check "path line of 1,025 bytes: refused as naming no file" eval 'refused "$out" "$PTR" && has "$out" "names no file"'
writef '"#\n" * 2100 + "STATUS.md\n"'; out=$(run_hook "$P")
check "path line after 4,096 bytes of comments: not read (names no file)" \
  eval 'refused "$out" "$PTR" && has "$out" "names no file"'
writef '"#" * 4086 + "\nSTATUS.md.old\n"'; out=$(run_hook "$P")
check "path line cut at byte 4,096 (STATUS.md|.old): refused, never read as the shorter path" \
  eval 'refused "$out" "$PTR" && has "$out" "names no file"'
writef '"#" * 4085 + "\nSTATUS.md\n"'; out=$(run_hook "$P")
check "path line whose newline is byte 4,096: read" has "$out" project-p-status
writef '"#" * 4086 + "\nSTATUS.md"'; out=$(run_hook "$P")
check "pointer of exactly 4,096 bytes ending in the path line (no newline): read" has "$out" project-p-status
point STATUS.md

# The walk stops before $HOME even when HOME is a symlink or the cwd contains "..", so a pointer in the
# home folder itself (where ~/.claude, the global config, lives) is never used.
mkdir -p "$T/realhome/.claude" "$T/realhome/proj/x"; ln -s "$T/realhome" "$T/homelink"
echo STATUS.md > "$T/realhome/.claude/brain"; echo HOME-STATUS > "$T/realhome/STATUS.md"
out=$(printf '{"cwd": "%s"}' "$T/realhome/proj/x" | env -u CLAUDE_PROJECT_DIR HOME="$T/homelink" bash "$H")
check "HOME is a symlink, cwd is the physical path: the home pointer is not used" [ -z "$out" ]
out=$(printf '{"cwd": "%s"}' "$T/realhome/proj/.." | env -u CLAUDE_PROJECT_DIR HOME="$T/realhome" bash "$H")
check "cwd with '..' that lands on \$HOME: the home pointer is not used" [ -z "$out" ]

echo "== hook tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
