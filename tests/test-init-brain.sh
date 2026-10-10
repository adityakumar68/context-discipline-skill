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
if [ "$(id -u)" != 0 ]; then   # root can write to a read-only folder, so this case means nothing there
  mkdir -p "$HM/ro"; chmod 555 "$HM/ro"
  out=$(init "$HM/ro"); rc=$?
  chmod 755 "$HM/ro"
  check "read-only root: reports NOT created and exits non-zero" eval '[ $rc != 0 ] && has "$out" "NOT created"'
fi

# --- the project name goes into the templates as typed ------------------------------------------------------------
P3="$HM/proj\tname"; mkdir -p "$P3"; init "$P3" >/dev/null
check "backslashes in the folder name are kept in the STATUS heading" grep -qF 'proj\tname — STATUS' "$P3/STATUS.md"

# --- files a cloned repo already has are untrusted: never hang, never read much, never write through a symlink -----
# init_t: init with a 10-second alarm (rc 142 if it hangs).
init_t() { env HOME="$HM" perl -e 'alarm shift; exec @ARGV' 10 bash "$I" "$@" 2>&1; }
# unblock <fifo>: release anything still blocked opening <fifo> (a hung run killed by the alarm leaves it waiting).
unblock() { perl -MFcntl -e 'sysopen(my $f, $ARGV[0], O_WRONLY | O_NONBLOCK) and close($f)' "$1" 2>/dev/null; }
# Output goes to a file, not $(...): a reader left blocked on the FIFO would keep a $(...) pipe open forever.
mkdir -p "$HM/f1/.claude"; mkfifo "$HM/f1/.claude/brain"
init_t "$HM/f1" > "$T/f1.out"; rc=$?; unblock "$HM/f1/.claude/brain"; out=$(cat "$T/f1.out")
check "existing pointer that is a FIFO: not read, no hang, left untouched, exit 0" \
  eval '[ $rc = 0 ] && has "$out" "not a regular file" && [ -p "$HM/f1/.claude/brain" ]'
mkdir -p "$HM/f2/.claude"; python3 -I -c 'import sys; open(sys.argv[1], "w").write("a" * 2000000)' "$HM/f2/.claude/brain"
out=$(init_t "$HM/f2"); rc=$?
check "existing 2 MB one-line pointer: only its start is read, short summary, exit 0" \
  eval '[ $rc = 0 ] && has "$out" "exists, left untouched" && [ "${#out}" -lt 4000 ]'
mkdir -p "$HM/f3/.claude"; echo docs/STATUS.md > "$HM/f3/.claude/brain"
out=$(init_t "$HM/f3"); rc=$?
check "existing pointer the hook would refuse: the summary says so and why" \
  eval '[ $rc = 0 ] && has "$out" "exists, left untouched" && has "$out" "names a missing file"'
mkdir -p "$HM/f4/.claude"; ln -s "$HM/outside/planted-brain" "$HM/f4/.claude/brain"
out=$(init_t "$HM/f4"); rc=$?
check "pointer that is a symlink to a missing file outside: not written through" \
  eval '[ ! -e "$HM/outside/planted-brain" ] && has "$out" "left untouched"'
mkdir -p "$HM/f5"; ln -s "$HM/outside/planted-overview" "$HM/f5/00-Project-Overview.md"
out=$(init_t "$HM/f5"); rc=$?
check "overview that is a symlink to a missing file outside: not written through" \
  eval '[ ! -e "$HM/outside/planted-overview" ] && has "$out" "left untouched"'
mkdir -p "$HM/f6" "$HM/outside/dot-claude"; ln -s "$HM/outside/dot-claude" "$HM/f6/.claude"
out=$(init_t "$HM/f6"); rc=$?
check ".claude that is a symlink out of the project: no pointer written there, NOT created, exit 1" \
  eval '[ $rc = 1 ] && [ ! -e "$HM/outside/dot-claude/brain" ] && has "$out" "NOT created"'
mkdir -p "$HM/f7"; python3 -I -c 'import sys; open(sys.argv[1], "w").write("x" * 2000000)' "$HM/f7/.gitignore"
cp "$HM/f7/.gitignore" "$T/f7-orig"; out=$(init_t "$HM/f7"); rc=$?
check ".gitignore over 1 MB: not read or changed, summary says to add the line by hand, exit 0" \
  eval '[ $rc = 0 ] && cmp -s "$HM/f7/.gitignore" "$T/f7-orig" && has "$out" "NOT changed"'

# --- whatever init-brain sets up, the hook loads ------------------------------------------------------------------
mkdir -p "$HM/p4/sub"
init "$HM/p4" docs/brain/STATUS.md >/dev/null
out=$(printf '{"cwd": "%s"}' "$HM/p4/sub" | env -u CLAUDE_PROJECT_DIR HOME="$HM" bash "$H" | tail -n 1)
check "nested custom STATUS path: the hook loads it" has "$out" "loaded from $HM/p4/docs/brain/STATUS.md"

# --- .claude/compactions/ (compact-log.sh's summaries) is kept out of git -------------------------------------------
IGN='.claude/compactions/'
ignores() { grep -c -x -F -- "$IGN" "$1/.gitignore" 2>/dev/null || true; }   # lines that are exactly the entry
mkdir -p "$HM/g1"; out=$(init "$HM/g1"); rc=$?
check "no .gitignore: created with the .claude/compactions/ line, summary says so" \
  eval '[ $rc = 0 ] && [ "$(ignores "$HM/g1")" = 1 ] && has "$out" "$HM/g1/.gitignore" && has "$out" "$IGN"'
out=$(init "$HM/g1"); rc=$?
check "second run: the line is not added twice" eval '[ $rc = 0 ] && [ "$(ignores "$HM/g1")" = 1 ] && has "$out" "already"'

mkdir -p "$HM/g2"; printf 'node_modules/\n*.log' > "$HM/g2/.gitignore"    # no final newline on purpose
init "$HM/g2" >/dev/null
check "existing .gitignore without a final newline: kept, line added on its own line" \
  eval '[ "$(sed -n 1p "$HM/g2/.gitignore")" = node_modules/ ] && [ "$(sed -n 2p "$HM/g2/.gitignore")" = "*.log" ] && [ "$(sed -n 3p "$HM/g2/.gitignore")" = "$IGN" ]'

mkdir -p "$HM/g3"; printf 'build/\r\n' > "$HM/g3/.gitignore"; init "$HM/g3" >/dev/null
check "CRLF .gitignore: the added line ends in CRLF too" \
  eval '[ "$(tr -cd "\r" < "$HM/g3/.gitignore" | wc -c | tr -d " ")" = 2 ] && grep -q "^\.claude/compactions/.$" "$HM/g3/.gitignore"'

mkdir -p "$HM/g4"; printf '/.claude/compactions\n' > "$HM/g4/.gitignore"; cp "$HM/g4/.gitignore" "$T/g4-orig"
init "$HM/g4" >/dev/null
check "an equivalent entry (/.claude/compactions) already there: .gitignore left as it was" cmp -s "$HM/g4/.gitignore" "$T/g4-orig"

mkdir -p "$HM/g5" "$HM/shared"; echo 'x/' > "$HM/shared/ignore"; ln -s "$HM/shared/ignore" "$HM/g5/.gitignore"
out=$(init "$HM/g5"); rc=$?
check "symlinked .gitignore: not edited, summary says to add the line by hand, exit 0" \
  eval '[ $rc = 0 ] && [ "$(cat "$HM/shared/ignore")" = x/ ] && has "$out" "NOT changed"'

if command -v git >/dev/null 2>&1; then
  mkdir -p "$HM/g6"; git -C "$HM/g6" init -q 2>/dev/null; init "$HM/g6" >/dev/null
  mkdir -p "$HM/g6/.claude/compactions"; echo s > "$HM/g6/.claude/compactions/2026-01-01-000000-abcdef12.md"
  check "in a git repo: compaction logs are ignored, the brain pointer is not" \
    eval 'git -C "$HM/g6" check-ignore -q .claude/compactions/2026-01-01-000000-abcdef12.md && ! git -C "$HM/g6" check-ignore -q .claude/brain'
fi

echo "== init-brain tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
