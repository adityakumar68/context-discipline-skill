#!/usr/bin/env bash
# Tests for brain-hook.sh: which STATUS files it will print for a registered brain (containment), how it keeps its
# output under Claude Code's 10,000-character hook cap, and that it never reads a folder's .claude/brain pointer.
# Usage: bash tests/test-hook.sh
# Self-contained: works in a mktemp folder with HOME pointed into it, so nothing outside it is read or written.

set -u
unset CD_BRAIN CD_HOOKS CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR   # no brain choice from the calling window
H=$(cd "$(dirname "$0")/../context-discipline/scripts" && pwd -P)/brain-hook.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/cd-tests.XXXXXX") && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
T=$(cd "$T" && pwd -P) || exit 1    # resolve symlinks (macOS /var -> /private/var) so paths compare equal
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name"; fi; }

HM="$T/home"; mkdir -p "$HM/.claude"   # the fake home; every brain below lives under it
REG="$HM/.claude/brains.json"
# use <dir> <status>: register brain "p" as <dir> and <status> (the registry holds only it).
use() {
  python3 -I -c 'import json, sys
json.dump({"version": 2, "brains": {"p": {"dir": sys.argv[2], "status": sys.argv[3]}}}, open(sys.argv[1], "w"))' \
    "$REG" "$1" "$2"
}
# run_hook <cwd>: run the hook for a session in <cwd> with CD_BRAIN=p, the fake home and no CLAUDE_PROJECT_DIR.
run_hook() { printf '{"cwd": "%s", "source": "startup"}' "$1" | env -u CLAUDE_PROJECT_DIR HOME="$HM" CD_BRAIN=p bash "$H"; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }
lines() { printf '%s\n' "$1" | grep -c ''; }
# refused <output>: one warning line that names brain p, and none of the secret text.
refused() { [ "$(lines "$1")" = 1 ] && has "$1" "not loaded" && has "$1" 'brain "p"' && ! has "$1" SECRET; }

# Secrets outside any brain, and a brain folder with a normal STATUS.
mkdir -p "$HM/.ssh" "$HM/.aws" "$HM/outside" "$HM/p/docs" "$HM/work/src"
echo "SECRET-KEY-MATERIAL" > "$HM/.ssh/id_ed25519"
echo "aws_secret_access_key = SECRET-AWS" > "$HM/.aws/credentials"
echo "SECRET-OUTSIDE-STATUS" > "$HM/outside/STATUS.md"
printf '# STATUS\nproject-p-status\n' > "$HM/p/STATUS.md"
P="$HM/p"
point() { use "$P" "$1"; }   # point <status>: brain p's STATUS, relative to its folder

# --- containment: what a registered STATUS may name ---------------------------------------------------------------
point STATUS.md; out=$(run_hook "$HM/work/src"); rc=$?
check "STATUS inside the brain folder: printed, whatever folder the session is in, exit 0" \
  eval '[ $rc = 0 ] && has "$out" project-p-status'

point "$HM/.ssh/id_ed25519"; out=$(run_hook "$HM/work"); rc=$?
check "absolute path to a file outside: refused with one warning line, exit 0" eval '[ $rc = 0 ] && refused "$out"'

point "$P/STATUS.md"; out=$(run_hook "$HM/work")
check "absolute path even inside the folder: refused (status is relative to dir)" \
  eval 'refused "$out" && ! has "$out" project-p-status'

point '~/.aws/credentials'; out=$(run_hook "$HM/work")
check "~/ path: refused" refused "$out"

point '../.aws/credentials'; out=$(run_hook "$HM/work")
check "../ escape: refused" refused "$out"

point 'docs/../../outside/STATUS.md'; out=$(run_hook "$HM/work")
check "escape hidden after a subfolder (docs/../../): refused" refused "$out"

point 'docs/../STATUS.md'; out=$(run_hook "$HM/work")
check ".. that stays inside the folder: allowed" has "$out" project-p-status

ln -s "$HM/.ssh/id_ed25519" "$P/link-out.md"; point link-out.md; out=$(run_hook "$HM/work")
check "symlink inside the folder to a file outside: refused" refused "$out"

ln -s "$HM/outside" "$P/notes"; point notes/STATUS.md; out=$(run_hook "$HM/work")
check "path through a symlinked folder that leaves the brain folder: refused" refused "$out"

ln -s STATUS.md "$P/link-in.md"; point link-in.md; out=$(run_hook "$HM/work")
check "symlink inside the folder to a file inside it: allowed" has "$out" project-p-status

point docs; out=$(run_hook "$HM/work")
check "status naming a folder: one warning line, no output otherwise" refused "$out"

point missing.md; out=$(run_hook "$HM/work")
check "status naming a missing file: one warning line" refused "$out"

printf 'A\000B SECRET\n' > "$P/binary.md"; point binary.md; out=$(run_hook "$HM/work")
check "status naming a binary file (NUL bytes): refused" refused "$out"

ln -s "$P" "$HM/p-link"; use "$HM/p-link" STATUS.md; out=$(run_hook "$HM/work")
check "brain folder registered through a symlinked path: STATUS printed" has "$out" project-p-status

use "$HM" .aws/credentials; out=$(run_hook "$HM/work")
check "brain folder = \$HOME: refused" refused "$out"
mkdir -p "$T/realhome/x"; ln -s "$T/realhome" "$T/homelink"; echo HOME-STATUS > "$T/realhome/STATUS.md"
use "$T/realhome" STATUS.md
out=$(printf '{"source": "startup"}' | env HOME="$T/homelink" CD_BRAIN=p CLAUDE_CONFIG_DIR="$HM/.claude" bash "$H")
check "brain folder = \$HOME reached through a symlinked HOME: refused" \
  eval 'has "$out" "not loaded" && ! has "$out" HOME-STATUS'
use "$T/realhome/x/.." STATUS.md
out=$(printf '{"source": "startup"}' | env HOME="$T/realhome" CD_BRAIN=p CLAUDE_CONFIG_DIR="$HM/.claude" bash "$H")
check "brain folder with '..' that lands on \$HOME: refused" eval 'has "$out" "not loaded" && ! has "$out" HOME-STATUS'
use / etc/hosts; out=$(run_hook "$HM/work")
check "brain folder = /: refused" eval 'refused "$out" && ! has "$out" localhost'
use relative/dir STATUS.md; out=$(run_hook "$HM/work")
check "brain folder named by a relative path: refused" refused "$out"

# --- size: Claude Code replaces hook output over 10,000 characters (JS string length) with a 2,000-char preview ---
# units: the trimmed output's length as Claude Code measures it (UTF-16 units); fails if the bytes are not UTF-8.
units() { python3 -I -c 'import sys; s = sys.stdin.buffer.read().decode("utf-8").strip(); print(len(s.encode("utf-16-le")) // 2)' 2>/dev/null; }
# count <char>: how many times <char> occurs in stdin.
count() { python3 -I -c 'import sys; print(sys.stdin.buffer.read().decode("utf-8", "replace").count(sys.argv[1]))' "$1"; }
# make_status <dir> <python expression for the text>: brain p becomes <dir>, with a STATUS.md holding that text.
make_status() {
  mkdir -p "$1"; use "$1" STATUS.md
  python3 -I -c 'import sys; open(sys.argv[1], "w", encoding="utf-8").write(eval(sys.argv[2]))' "$1/STATUS.md" "$2"
}

make_status "$HM/cjk" '"状" * 4000 + "END-MARKER\n"'     # 4,011 characters, 12,011 bytes
out=$(run_hook "$HM/work")
check "4,011-char CJK STATUS (12,011 bytes) printed whole: counted in characters, not bytes" \
  eval 'has "$out" END-MARKER && ! has "$out" "characters,"'

make_status "$HM/fits" '"x" * 8999 + "\n"'                    # exactly 9,000 characters
out=$(run_hook "$HM/work")
check "9,000-char STATUS printed whole, no trim notice" eval 'has "$out" "loaded from" && ! has "$out" "characters,"'

make_status "$HM/ascii" '"x" * 12000'
out=$(run_hook "$HM/work")
check "12,000-char STATUS: notice gives the real count and the limit" \
  has "$out" "[STATUS.md is 12,000 characters, over the 9,000 limit, so only the first 9,000 are shown here."
check "12,000-char STATUS: 9,000 shown, whole output under 10,000 characters" \
  eval '[ "$(printf "%s\n" "$out" | head -n 1 | units)" = 9000 ] && [ "$(printf "%s" "$out" | units)" -le 10000 ]'

make_status "$HM/cjkbig" '"状" * 10000'
out=$(run_hook "$HM/work")
check "10,000-char CJK STATUS: cut on a character boundary to 9,000 characters" \
  eval '[ "$(printf "%s" "$out" | count "$(printf "\347\212\266")")" = 9000 ] && has "$out" "is 10,000 characters"'

make_status "$HM/emoji" '"\U0001F600" * 5000'                  # 5,000 emoji = 10,000 UTF-16 units
out=$(run_hook "$HM/work")
check "emoji STATUS: counted as Claude Code counts them (2 each), valid UTF-8, output under 10,000" \
  eval 'has "$out" "is 10,000 characters" && [ "$(printf "%s" "$out" | units)" -le 10000 ]'

make_status "$HM/mixed" '"a" + "€" * 9500'
out=$(run_hook "$HM/work")
check "odd byte offset (a + euro signs): the cut never splits a character" eval '[ "$(printf "%s" "$out" | units)" -le 10000 ]'

long="$HM"   # a 960-char brain folder path (paths stay under 1,024, the macOS limit)
while [ $((${#long} + 101)) -le 960 ]; do long="$long/$(printf 'd%.0s' $(seq 1 100))"; done
pad=$((960 - ${#long} - 1)); [ "$pad" -gt 0 ] && long="$long/$(printf 'e%.0s' $(seq 1 "$pad"))"
make_status "$long" '"y" * 8999 + "\n"'
out=$(run_hook "$HM/work")
check "very long folder path (${#long} chars): STATUS line + notice still fit under 10,000" \
  eval '[ "$(printf "%s" "$out" | units)" -le 10000 ] && has "$out" "loaded from"'
use "$long" "$(printf 'x%.0s' $(seq 1 200))/STATUS.md"
out=$(printf '{"source": "startup"}' | env -u CLAUDE_PROJECT_DIR HOME="$HM" CD_BRAIN=p bash "$H" 2>"$T/err")
check "folder path + status path over 1,024 bytes: refused, nothing on stderr" \
  eval 'refused "$out" && [ ! -s "$T/err" ]'

# The trim notice names the file, so a long file name must not push the output over the cap.
deep="$HM/c"; while [ ${#deep} -lt 560 ]; do deep="$deep/dddddddddddddddddddddddddddddd"; done
name="$(printf 'S%.0s' $(seq 1 247)).md"
mkdir -p "$deep"; use "$deep" "$name"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("a" * 12000)' "$deep/$name"
out=$(run_hook "$HM/work")
check "251-char file name under a ${#deep}-char folder, 12,000-char STATUS: notice shown, output under 10,000" \
  eval 'has "$out" "characters, over the" && [ "$(printf "%s" "$out" | units)" -le 10000 ]'

# --- the input --------------------------------------------------------------------------------------------------------
point STATUS.md
out=$(cd "$HM/work" && echo '{bad json' | env -u CLAUDE_PROJECT_DIR HOME="$HM" CD_BRAIN=p bash "$H"); rc=$?
check "malformed JSON: prints nothing, even with a brain chosen, exit 0" eval '[ $rc = 0 ] && [ -z "$out" ]'
out=$(echo '{"source": "startup"}' | env -u CLAUDE_PROJECT_DIR HOME="$HM" CD_BRAIN=p bash "$H")
check "valid JSON without cwd: the brain loads (the session's folder plays no part)" has "$out" project-p-status

# Without jq the hook parses its input with python3; same results.
NOJQ="$T/bin-without-jq"; mkdir -p "$NOJQ"
for c in bash cat dirname basename readlink tr wc head tail od awk python3 date mktemp mv rm mkdir chmod; do
  ln -s "$(command -v "$c")" "$NOJQ/$c"
done
out=$(printf '{"cwd": "%s"}' "$HM/work" | env -u CLAUDE_PROJECT_DIR PATH="$NOJQ" HOME="$HM" CD_BRAIN=p "$NOJQ/bash" "$H")
check "no jq on PATH: python3 reads the input, STATUS printed" has "$out" project-p-status
out=$(cd "$HM/work" && echo '[1, 2]' | env -u CLAUDE_PROJECT_DIR PATH="$NOJQ" HOME="$HM" CD_BRAIN=p "$NOJQ/bash" "$H")
check "no jq on PATH: input that is not a JSON object prints nothing" [ -z "$out" ]

# --- a folder's .claude/brain pointer is never read: brains belong to sessions, not folders -------------------------
mkdir -p "$HM/old/.claude" "$HM/old/src"; printf 'old-pointer-status\n' > "$HM/old/STATUS.md"
echo STATUS.md > "$HM/old/.claude/brain"
out=$(printf '{"cwd": "%s", "source": "startup"}' "$HM/old/src" | env -u CLAUDE_PROJECT_DIR HOME="$HM" bash "$H")
check "session inside a folder with an old .claude/brain pointer, no brain chosen: its STATUS is not loaded" \
  eval '! has "$out" old-pointer-status && has "$out" "No brain attached"'
out=$(printf '{"source": "startup"}' | env CLAUDE_PROJECT_DIR="$HM/old" HOME="$HM" bash "$H")
check "CLAUDE_PROJECT_DIR at a folder with a pointer: not loaded either" eval '! has "$out" old-pointer-status'
mkdir -p "$HM/fifo/.claude"; mkfifo "$HM/fifo/.claude/brain"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("a" * 1000000)' "$HM/old/.claude/brain"
start=$(python3 -I -c 'import time; print(time.time())')
out=$(printf '{"cwd": "%s", "source": "startup"}' "$HM/fifo" | env -u CLAUDE_PROJECT_DIR HOME="$HM" \
  perl -e 'alarm shift; exec @ARGV' 10 bash "$H" 2>"$T/err"); rc=$?
out2=$(printf '{"cwd": "%s", "source": "startup"}' "$HM/old" | env -u CLAUDE_PROJECT_DIR HOME="$HM" \
  perl -e 'alarm shift; exec @ARGV' 10 bash "$H" 2>>"$T/err")
ms=$(python3 -I -c "import time; print(int((time.time() - $start) * 1000))")
check "a FIFO or a 1 MB pointer in the session's folder: never opened, exit 0, ${ms} ms for both (limit 2,000)" \
  eval '[ $rc = 0 ] && [ "$ms" -lt 2000 ] && [ ! -s "$T/err" ] && has "$out" "No brain attached"'

# CD_HOOKS=off turns all three hooks off (headless runs, benchmarks); other values change nothing.
point STATUS.md
out=$(printf '{"cwd": "%s"}' "$HM/work" | env -u CLAUDE_PROJECT_DIR CD_HOOKS=off HOME="$HM" CD_BRAIN=p bash "$H" 2>&1); rc=$?
check "CD_HOOKS=off: prints nothing, exit 0" eval '[ $rc = 0 ] && [ -z "$out" ]'
out=$(printf '{"cwd": "%s"}' "$HM/work" | env -u CLAUDE_PROJECT_DIR CD_HOOKS=on HOME="$HM" CD_BRAIN=p bash "$H" 2>&1)
check "CD_HOOKS=on: STATUS printed as usual" has "$out" project-p-status

echo "== hook tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
