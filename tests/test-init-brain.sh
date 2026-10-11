#!/usr/bin/env bash
# Tests for init-brain.sh <brain-folder> [name], the template copier behind /brain new: it writes STATUS.md and
# 00-Project-Overview.md into the brain folder and nothing else (no .claude/brain pointer, no .gitignore line),
# never overwrites, never writes through a symlink, and refuses $HOME and / as the folder.
# Usage: bash tests/test-init-brain.sh
# Self-contained: works in a mktemp folder with HOME pointed into it, so nothing outside it is read or written.

set -u
unset CD_BRAIN CD_HOOKS CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR   # no brain choice from the calling window
S=$(cd "$(dirname "$0")/../context-discipline/scripts" && pwd -P)
H="$S/brain-hook.sh"; I="$S/init-brain.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/cd-tests.XXXXXX") && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
T=$(cd "$T" && pwd -P) || exit 1    # resolve symlinks (macOS /var -> /private/var) so paths compare equal
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name"; fi; }

HM="$T/home"; mkdir -p "$HM/.claude"
init() { env HOME="$HM" perl -e 'alarm shift; exec @ARGV' 10 bash "$I" "$@" 2>&1; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }
# only_templates <dir>: the folder holds exactly STATUS.md and 00-Project-Overview.md.
only_templates() { [ "$(ls -A "$1" | LC_ALL=C sort | paste -sd, -)" = "00-Project-Overview.md,STATUS.md" ]; }

# --- what it writes ---------------------------------------------------------------------------------------------------
mkdir -p "$HM/p1"; out=$(init "$HM/p1" phd); rc=$?
check "writes STATUS.md and 00-Project-Overview.md, nothing else (no pointer, no .gitignore), exit 0" \
  eval '[ $rc = 0 ] && only_templates "$HM/p1"'
check "the name goes into the headings" eval 'grep -qF "phd — STATUS" "$HM/p1/STATUS.md" && grep -qF "phd — Project Overview" "$HM/p1/00-Project-Overview.md"'
check "summary names both files and gives the STATUS limit in characters (9,000)" \
  eval 'has "$out" "$HM/p1/STATUS.md (created)" && has "$out" "$HM/p1/00-Project-Overview.md (created)" && has "$out" "9,000 characters"'
echo edit >> "$HM/p1/STATUS.md"; before=$(cat "$HM/p1/STATUS.md" "$HM/p1/00-Project-Overview.md" | cksum)
out=$(init "$HM/p1" phd); rc=$?
check "second run: overwrites nothing, says both exist, exit 0" \
  eval '[ $rc = 0 ] && [ "$(cat "$HM/p1/STATUS.md" "$HM/p1/00-Project-Overview.md" | cksum)" = "$before" ] && [ "$(printf "%s\n" "$out" | grep -c "exists, left untouched")" = 2 ]'
mkdir -p "$HM/My Folder"; init "$HM/My Folder" >/dev/null
check "no name given: the folder's name goes into the headings" grep -qF "My Folder — STATUS" "$HM/My Folder/STATUS.md"
P3="$HM/proj\tname"; mkdir -p "$P3"; init "$P3" >/dev/null
check "backslashes in the folder name are kept in the STATUS heading" grep -qF 'proj\tname — STATUS' "$P3/STATUS.md"
mkdir -p "$HM/rel"; out=$(cd "$HM/rel" && init "$HM/p2x" docs/STATUS.md); rc=$?
check "a second argument that is not a brain name (the old STATUS path): refused, nothing written" \
  eval '[ $rc != 0 ] && [ ! -e "$HM/p2x" ] && has "$out" "brain name"'
out=$(init "$HM/a" b c); rc=$?
check "three arguments: usage, exit 2" eval '[ $rc = 2 ] && has "$out" usage'

# --- the folder: created if its parent exists ------------------------------------------------------------------------
out=$(init "$HM/newbrain" nb); rc=$?
check "missing folder whose parent exists: created, templates written" eval '[ $rc = 0 ] && only_templates "$HM/newbrain"'
out=$(init "$HM/no/such/place" nb); rc=$?
check "missing folder whose parent is missing too: refused (exit 1), nothing made" \
  eval '[ $rc = 1 ] && [ ! -e "$HM/no" ] && has "$out" "init-brain:"'
echo x > "$HM/afile"; out=$(init "$HM/afile" nb); rc=$?
check "a file in place of the folder: refused" eval '[ $rc = 1 ] && [ "$(cat "$HM/afile")" = x ]'

# --- $HOME and / are never a brain folder -----------------------------------------------------------------------------
nothing_in() { [ ! -e "$1/STATUS.md" ] && [ ! -e "$1/00-Project-Overview.md" ]; }
out=$(init "$HM"); rc=$?
check "folder = \$HOME: refused (exit 1) with a message, nothing written" eval '[ $rc = 1 ] && has "$out" "home folder" && nothing_in "$HM"'
ln -s "$HM" "$T/home-link"
out=$(env HOME="$T/home-link" bash "$I" "$HM" 2>&1); rc=$?
check "folder = \$HOME reached through a symlinked HOME: refused too" eval '[ $rc = 1 ] && nothing_in "$HM"'
out=$(init /); rc=$?
check "folder = /: refused (exit 1) with a message" eval '[ $rc = 1 ] && has "$out" "refus"'

# --- never writes through a symlink, never fails silently -------------------------------------------------------------
mkdir -p "$HM/f5" "$HM/outside"; ln -s "$HM/outside/planted-overview" "$HM/f5/00-Project-Overview.md"
out=$(init "$HM/f5"); rc=$?
check "overview that is a symlink to a missing file outside: not written through" \
  eval '[ ! -e "$HM/outside/planted-overview" ] && has "$out" "left untouched"'
mkdir -p "$HM/f6"; ln -s "$HM/outside/planted-status" "$HM/f6/STATUS.md"
out=$(init "$HM/f6"); rc=$?
check "STATUS that is a symlink to a missing file outside: not written through" \
  eval '[ ! -e "$HM/outside/planted-status" ] && has "$out" "left untouched"'
if [ "$(id -u)" != 0 ]; then   # root can write to a read-only folder, so this case means nothing there
  mkdir -p "$HM/ro"; chmod 555 "$HM/ro"
  out=$(init "$HM/ro"); rc=$?
  chmod 755 "$HM/ro"
  check "read-only folder: reports NOT created and exits non-zero" eval '[ $rc != 0 ] && has "$out" "NOT created"'
fi

# --- whatever init-brain sets up, the hook loads once it is registered ------------------------------------------------
python3 -I -c 'import json, sys
json.dump({"version": 2, "brains": {"phd": {"dir": sys.argv[2], "status": "STATUS.md"}}}, open(sys.argv[1], "w"))' \
  "$HM/.claude/brains.json" "$HM/p1"
out=$(printf '{"source": "startup"}' | env -u CLAUDE_PROJECT_DIR HOME="$HM" CD_BRAIN=phd bash "$H" | tail -n 1)
check "the hook loads the STATUS it wrote" has "$out" "loaded from $HM/p1/STATUS.md"

echo "== init-brain tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
