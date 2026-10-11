#!/usr/bin/env bash
# Tests for brain.sh, the script behind the /brain command:
#   brain.sh                          list the registered brains, mark the one this window uses
#   brain.sh <name> | none            pick a brain (or none) for this Claude Code window
#   brain.sh add <name> [folder]      register an existing brain (default: the current folder's)
#   brain.sh new <name> <folder>      init-brain.sh on the folder, then register it
#   brain.sh rename <old> <new> | remove <name>     registry only; project files are never touched
# It always exits 0 (a failing command would abort the /brain skill before Claude sees the message).
# Usage: bash tests/test-brain-cmd.sh
# Self-contained: works in a mktemp folder with HOME pointed into it, so nothing outside it is read or written.

set -u
unset CD_BRAIN CD_HOOKS CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR CLAUDE_PROJECT_DIR
S=$(cd "$(dirname "$0")/../context-discipline/scripts" && pwd -P)
B="$S/brain.sh"; H="$S/brain-hook.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/cd-tests.XXXXXX") && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
T=$(cd "$T" && pwd -P) || exit 1    # resolve symlinks (macOS /var -> /private/var) so paths compare equal
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name"; fi; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }
hasline() { printf '%s\n' "$1" | grep -Eq -- "$2"; }   # hasline <text> <ERE>: some line matches

HM="$T/home"; CFG="$HM/.claude"; REG="$CFG/brains.json"; SES="$CFG/brain-sessions"
mkdir -p "$CFG" "$HM/a/.claude" "$HM/a/src" "$HM/b/.claude" "$HM/b/notes" "$HM/plain/x" "$HM/c/.claude" "$HM/c/sub"
printf '# STATUS\nstatus-of-a\n' > "$HM/a/STATUS.md"; echo STATUS.md > "$HM/a/.claude/brain"
printf '# STATUS\nstatus-of-b\n' > "$HM/b/notes/STATUS.md"; echo notes/STATUS.md > "$HM/b/.claude/brain"
printf '# STATUS\nstatus-of-c\n' > "$HM/c/STATUS.md"; echo STATUS.md > "$HM/c/.claude/brain"
TODAY=$(date +%Y-%m-%d)

# bc <cwd> [VAR=value...] [--] <args...>: run brain.sh in <cwd> as the window CLAUDE_PID=$$, with the fake home.
# Sets out and rc.
bc() {
  local cwd="$1"; shift
  local envs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      [A-Z]*=*) envs+=("$1"); shift ;;
      *) break ;;
    esac
  done
  out=$(cd "$cwd" && env HOME="$HM" CLAUDE_PID=$$ ${envs[@]+"${envs[@]}"} perl -e 'alarm shift; exec @ARGV' 30 \
    bash "$B" "$@" 2>&1 < /dev/null); rc=$?
}
# reg <python expression>: true if it holds for the registry (d = the parsed file, b = d["brains"]).
reg() { python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); b = d.get("brains", {})
sys.exit(0 if eval(sys.argv[2]) else 1)' "$REG" "$1" 2>/dev/null; }
# tree <dir>: one checksum over every file below <dir> (to show project files were not touched).
tree() { (cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r f; do
  if [ -f "$f" ]; then printf '%s ' "$f"; cksum < "$f"; else printf '%s\n' "$f"; fi; done) | cksum; }
# hookout <cwd> [VAR=value...]: what the SessionStart hook prints for window $$ in <cwd>.
hookout() { local cwd="$1"; shift; printf '{"cwd": "%s", "session_id": "s1"}' "$cwd" | env HOME="$HM" CLAUDE_PID=$$ "$@" bash "$H" 2>&1; }

# --- empty start -----------------------------------------------------------------------------------------------------
bc "$HM/plain/x"
check "list with no registry: says there are none yet, how to add one, exit 0" \
  eval '[ $rc = 0 ] && has "$out" "No named brains yet" && has "$out" "/brain add <name>" && has "$out" "/brain new <name> <folder>"'
check "list with no registry and no folder brain: says this window uses no brain" has "$out" "This window uses no brain"

# --- add ---------------------------------------------------------------------------------------------------------------
before_a=$(tree "$HM/a")
bc "$HM/a/src" add alpha
check "add alpha in a subfolder of a brain project: registered, exit 0" \
  eval '[ $rc = 0 ] && has "$out" "Registered brain \"alpha\"" && has "$out" "/brain alpha"'
check "registry: version 1, alpha -> absolute root and STATUS path" \
  reg "d['version'] == 1 and b['alpha'] == {'root': '$HM/a', 'status': '$HM/a/STATUS.md'}"
check "add left the project's files untouched" [ "$(tree "$HM/a")" = "$before_a" ]
bc "$HM/plain" add beta "$HM/b"
check "add beta <folder>: registers that folder's brain (STATUS from its pointer)" \
  reg "b['beta'] == {'root': '$HM/b', 'status': '$HM/b/notes/STATUS.md'}"
bc "$HM" add gamma c/sub
check "add with a relative folder: resolved from the current folder" reg "b['gamma']['root'] == '$HM/c'"
cp "$REG" "$T/reg.before"
bc "$HM/a" add alpha
check "add the same brain under the same name again: says so, registry unchanged" \
  eval '[ $rc = 0 ] && has "$out" "already registered" && cmp -s "$REG" "$T/reg.before"'
bc "$HM/b" add alpha
check "add a name taken by another brain: refused (exit 0), registry unchanged" \
  eval '[ $rc = 0 ] && has "$out" "brain: " && has "$out" "alpha" && cmp -s "$REG" "$T/reg.before"'
for n in Bad_Name -x "$(printf 'x%.0s' $(seq 1 33))" none add new rename remove help list; do
  bc "$HM/c" add "$n"
  check "add with name '${n:0:12}': refused (not a name, or reserved), registry unchanged" \
    eval '[ $rc = 0 ] && has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'
done
bc "$HM/plain/x" add delta
check "add in a folder with no brain: refused, points to /brain new" \
  eval 'has "$out" "brain: " && has "$out" "/brain new" && cmp -s "$REG" "$T/reg.before"'
mkdir -p "$HM/bad/.claude"; echo /etc/hosts > "$HM/bad/.claude/brain"
bc "$HM/bad" add delta
check "add where the hooks refuse the pointer: refused with the reason" \
  eval 'has "$out" "brain: " && has "$out" "relative" && cmp -s "$REG" "$T/reg.before"'
bc "$HM/plain" add delta "$HM/nowhere"
check "add with a missing folder: refused" eval 'has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'
bc "$HM/a" add
check "add without a name: usage, exit 0" eval '[ $rc = 0 ] && has "$out" "usage" && has "$out" "add <name> [folder]"'

# --- list --------------------------------------------------------------------------------------------------------------
bc "$HM/plain/x"
check "list: one row per brain with root, STATUS path, size and date" \
  eval 'hasline "$out" "^  alpha +$HM/a +STATUS.md, 21 bytes, changed $TODAY\$" && hasline "$out" "^  beta +$HM/b +notes/STATUS.md, 21 bytes, changed $TODAY\$"'
check "list in a plain folder: this window uses no brain, nothing marked" \
  eval 'has "$out" "This window uses no brain" && ! hasline "$out" "^\* "'
bc "$HM/a/src"
check "list inside a registered folder brain: its row is marked, says it was found from the folder" \
  eval 'hasline "$out" "^\* alpha " && has "$out" "This window uses the folder brain $HM/a" && ! has "$out" "not registered"'
mkdir -p "$HM/d/.claude" "$HM/d/deep"; printf 'status-of-d\n' > "$HM/d/STATUS.md"; echo STATUS.md > "$HM/d/.claude/brain"
bc "$HM/d/deep"
check "list inside an unregistered folder brain: shows it with the hint /brain add <name>" \
  eval 'has "$out" "Folder brain here, not registered: $HM/d" && has "$out" "/brain add <name>"'
bc "$HM/plain" CD_BRAIN=beta
check "list with CD_BRAIN=beta: beta marked, says it was chosen with CD_BRAIN" \
  eval 'hasline "$out" "^\* beta " && has "$out" "This window uses brain \"beta\" (chosen with CD_BRAIN)"'
python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); d["brains"]["gone"] = {"root": sys.argv[2], "status": sys.argv[2] + "/STATUS.md"}
json.dump(d, open(sys.argv[1], "w"))' "$REG" "$HM/gone"
bc "$HM/plain"
check "list: a brain the hooks would refuse is shown with the reason" \
  hasline "$out" "^  gone +$HM/gone +not usable: names a missing project folder"
cp "$REG" "$T/reg.good"; printf '{"version": 1, "brains": ' > "$REG"
bc "$HM/plain"
check "list with a broken registry: says so, exit 0" eval '[ $rc = 0 ] && has "$out" "$REG" && has "$out" "not valid JSON"'
cp "$T/reg.good" "$REG"

# --- pick: /brain <name> and /brain none -------------------------------------------------------------------------------
bc "$HM/a/src" beta
check "/brain beta: says so and prints beta's STATUS with the hook's closing line" \
  eval '[ $rc = 0 ] && has "$out" "This window now uses brain \"beta\"" && has "$out" status-of-b && has "$out" "(brain \"beta\", chosen with /brain)"'
check "/brain beta: the choice file is pid-<CLAUDE_PID>, holding the name and the process start" \
  eval '[ "$(head -n 1 "$SES/pid-$$")" = beta ] && [ "$(sed -n 2p "$SES/pid-$$")" = "$(. "$S/brain-lib.sh"; cd_process_start $$)" ]'
check "the choices folder is private (mode 700)" eval '[ "$(ls -ld "$SES" | cut -c1-10)" = drwx------ ]'
check "the hooks now use beta in this window, even inside project a" eval 'has "$(hookout "$HM/a")" status-of-b'
check "another window is not affected" eval 'has "$(hookout "$HM/a" CLAUDE_PID=1)" status-of-a'
bc "$HM/a"
check "list after /brain beta: beta marked, chosen with /brain" \
  eval 'hasline "$out" "^\* beta " && has "$out" "This window uses brain \"beta\" (chosen with /brain)"'
bc "$HM/a" none
check "/brain none: says so, exit 0" eval '[ $rc = 0 ] && has "$out" "This window now uses no project brain"'
check "/brain none: the hooks print nothing in project a" eval '[ -z "$(hookout "$HM/a")" ]'
bc "$HM/a"
check "list after /brain none: says no brain, chosen with /brain none" has "$out" "This window uses no brain (chosen with /brain none)"
cp "$SES/pid-$$" "$T/choice.before"
bc "$HM/a" zzz
check "/brain <unregistered name>: refused, lists the names, choice unchanged" \
  eval '[ $rc = 0 ] && has "$out" "brain: " && has "$out" "alpha" && cmp -s "$SES/pid-$$" "$T/choice.before"'
bc "$HM/a" gone
check "/brain <brain the hooks refuse>: refused with the reason, choice unchanged" \
  eval 'has "$out" "names a missing project folder" && cmp -s "$SES/pid-$$" "$T/choice.before"'
bc "$HM/a" Bad_Name
check "/brain <not a name>: refused" eval 'has "$out" "brain: " && cmp -s "$SES/pid-$$" "$T/choice.before"'
bc "$HM/a" alpha extra
check "/brain <name> <extra>: usage" eval '[ $rc = 0 ] && has "$out" "usage"'
out=$(cd "$HM/a" && env -u CLAUDE_PID HOME="$HM" bash "$B" alpha 2>&1); rc=$?
check "no CLAUDE_PID nor session id (not inside Claude Code): refused, says why, exit 0" \
  eval '[ $rc = 0 ] && has "$out" "brain: " && has "$out" "CLAUDE_PID"'
out=$(cd "$HM/a" && env -u CLAUDE_PID HOME="$HM" CLAUDE_CODE_SESSION_ID=abc-123 bash "$B" alpha 2>&1)
check "no CLAUDE_PID but CLAUDE_CODE_SESSION_ID: the choice is keyed by the session" \
  eval '[ "$(head -n 1 "$SES/sid-abc-123" 2>/dev/null)" = alpha ]'

# Choices older than 7 days are pruned when a choice is written, unless their window still runs.
old() { python3 -I -c 'import os, sys, time; t = time.time() - 8 * 86400; os.utime(sys.argv[1], (t, t))' "$1"; }
printf 'alpha\nMon Jan 1 00:00:00 2001\n' > "$SES/pid-1"; old "$SES/pid-1"
printf 'alpha\n\n' > "$SES/sid-old"; old "$SES/sid-old"
printf 'alpha\n\n' > "$SES/sid-recent"
printf 'alpha\n%s\n' "$(. "$S/brain-lib.sh"; cd_process_start $PPID)" > "$SES/pid-$PPID"; old "$SES/pid-$PPID"
bc "$HM/a" beta
check "writing a choice prunes 8-day-old choices of finished windows" eval '[ ! -e "$SES/pid-1" ] && [ ! -e "$SES/sid-old" ]'
check "... and keeps recent ones, and old ones whose window still runs" eval '[ -e "$SES/sid-recent" ] && [ -e "$SES/pid-$PPID" ]'

# --- rename and remove: registry only --------------------------------------------------------------------------------
before_b=$(tree "$HM/b")
bc "$HM/plain" rename beta bravo
check "rename beta bravo: registry entry renamed, same paths" \
  eval '[ $rc = 0 ] && reg "\"beta\" not in b and b[\"bravo\"][\"root\"] == \"$HM/b\""'
check "rename: this window's choice of beta now reads bravo" eval '[ "$(head -n 1 "$SES/pid-$$")" = bravo ]'
check "rename: the hooks still load the brain in this window" eval 'has "$(hookout "$HM/a")" "(brain \"bravo\", chosen with /brain)"'
check "rename: project files untouched" [ "$(tree "$HM/b")" = "$before_b" ]
cp "$REG" "$T/reg.before"
bc "$HM/plain" rename alpha bravo
check "rename to a name in use: refused, registry unchanged" eval 'has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'
bc "$HM/plain" rename nope x1
check "rename an unregistered name: refused" eval 'has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'
bc "$HM/plain" rename alpha none
check "rename to a reserved name: refused" eval 'has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'
bc "$HM/plain" remove bravo
check "remove bravo: entry gone, others kept" eval '[ $rc = 0 ] && reg "\"bravo\" not in b and \"alpha\" in b"'
check "remove: project files untouched" [ "$(tree "$HM/b")" = "$before_b" ]
check "remove: a window that chose it gets one warning line from the hook, no STATUS" \
  eval 'o=$(hookout "$HM/a"); has "$o" "not loaded" && has "$o" "bravo" && ! has "$o" status-of'
cp "$REG" "$T/reg.before"
bc "$HM/plain" remove bravo
check "remove an unregistered name: refused, registry unchanged" eval 'has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'

# --- writes keep the registry safe -----------------------------------------------------------------------------------
python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); d["note"] = "kept"; d["brains"]["odd"] = {"root": 5}
json.dump(d, open(sys.argv[1], "w"))' "$REG"
bc "$HM/d" add delta
check "add keeps other keys and entries it does not understand" eval 'reg "d[\"note\"] == \"kept\" and b[\"odd\"] == {\"root\": 5} and \"delta\" in b"'
printf '{"version": 1, "brains": ' > "$REG"; cp "$REG" "$T/reg.broken"
bc "$HM/c" add echo
check "add with a broken registry: refused, file left as it was" \
  eval '[ $rc = 0 ] && has "$out" "brain: " && cmp -s "$REG" "$T/reg.broken"'
rm -f "$REG"; mkfifo "$REG"
bc "$HM/c" add echo
check "add when the registry is a FIFO: refused without blocking" eval '[ $rc = 0 ] && has "$out" "brain: " && [ -p "$REG" ]'
rm -f "$REG"
CD2="$T/other config"
bc "$HM/c" CLAUDE_CONFIG_DIR="$CD2" add echo
check "CLAUDE_CONFIG_DIR: the registry is written there" \
  eval '[ -f "$CD2/brains.json" ] && [ ! -e "$REG" ] && grep -q echo "$CD2/brains.json"'

# --- new ---------------------------------------------------------------------------------------------------------------
mkdir -p "$HM/fresh"
bc "$HM/plain" new fresh "$HM/fresh"
check "new fresh <folder>: init-brain ran (STATUS, overview, pointer) and the brain is registered" \
  eval '[ $rc = 0 ] && [ -f "$HM/fresh/STATUS.md" ] && [ -f "$HM/fresh/00-Project-Overview.md" ] && [ -f "$HM/fresh/.claude/brain" ] && reg "b[\"fresh\"][\"status\"] == \"$HM/fresh/STATUS.md\""'
check "new: shows init-brain's summary and the registration" eval 'has "$out" "Project brain for $HM/fresh" && has "$out" "Registered brain \"fresh\""'
mkdir -p "$HM/fresh2"
bc "$HM/plain" new fresh "$HM/fresh2"
check "new with a name in use: refused before init-brain runs (no files made)" \
  eval 'has "$out" "brain: " && [ -z "$(ls -A "$HM/fresh2")" ]'
bc "$HM/plain" new fresh3 "$HM/missing"
check "new with a missing folder: refused, nothing registered" eval 'has "$out" "not a directory" && ! reg "\"fresh3\" in b"'
bc "$HM/plain" new fresh3 "$HM"
check "new in the home folder: init-brain refuses, nothing registered" eval '! reg "\"fresh3\" in b"'
bc "$HM/plain" new fresh3
check "new without a folder: usage" eval '[ $rc = 0 ] && has "$out" "usage" && has "$out" "new <name> <folder>"'

# --- help and unknown words ------------------------------------------------------------------------------------------
bc "$HM/plain" help
all_in() { local t="$1"; shift; for w in "$@"; do has "$t" "$w" || return 1; done; }
check "help: shows every form, exit 0" eval '[ $rc = 0 ] && all_in "$out" "/brain <name>" "/brain none" "add <name> [folder]" "new <name> <folder>" "rename <old> <new>" "remove <name>"'
bc "$HM/plain" remove
check "remove without a name: usage, exit 0" eval '[ $rc = 0 ] && has "$out" "usage"'

echo "== brain command tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
