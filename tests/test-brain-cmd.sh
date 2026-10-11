#!/usr/bin/env bash
# Tests for brain.sh, the script behind the /brain command:
#   brain.sh                          list the registered brains, mark the one this window uses
#   brain.sh <name> | none            pick a brain (or none) for this Claude Code window
#   brain.sh new <name> [--at <folder>]   create a brain (default folder <config>/brains/<name>) with
#                                     init-brain.sh, register it and attach it to this window
#   brain.sh add <name> <folder|STATUS file>   register an existing brain; with no path, the brain an old
#                                     .claude/brain pointer in the current folder names (migration)
#   brain.sh rename <old> <new> | remove <name>     the registry (rename also moves the compaction logs); the
#                                     brain's own files are never touched
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
check "list with no registry: says there are none yet, how to make or register one, exit 0" \
  eval '[ $rc = 0 ] && has "$out" "No brains yet" && has "$out" "/brain add <name>" && has "$out" "/brain new <name> [--at <folder>]"'
check "list with no registry and no folder brain: says this window uses no brain" has "$out" "This window uses no brain"

# --- add: an existing brain, by its folder or its STATUS file ------------------------------------------------------
before_a=$(tree "$HM/a")
bc "$HM/plain" add alpha "$HM/a"
check "add alpha <folder>: registers <folder>/STATUS.md, exit 0" \
  eval '[ $rc = 0 ] && has "$out" "Registered brain \"alpha\"" && has "$out" "/brain alpha"'
check "registry: version 2, alpha -> its folder and its STATUS file's name" \
  reg "d['version'] == 2 and b['alpha'] == {'dir': '$HM/a', 'status': 'STATUS.md'}"
check "add left the brain's files untouched" [ "$(tree "$HM/a")" = "$before_a" ]
bc "$HM/plain" add beta "$HM/b/notes/STATUS.md"
check "add beta <STATUS file>: dir is the file's folder, status its name" \
  reg "b['beta'] == {'dir': '$HM/b/notes', 'status': 'STATUS.md'}"
bc "$HM" add gamma c
check "add with a relative folder: resolved from the current folder" reg "b['gamma']['dir'] == '$HM/c'"
cp "$REG" "$T/reg.before"
bc "$HM/plain" add alpha "$HM/a"
check "add the same brain under the same name again: says so, registry unchanged" \
  eval '[ $rc = 0 ] && has "$out" "already registered" && cmp -s "$REG" "$T/reg.before"'
bc "$HM/plain" add alpha "$HM/b/notes"
check "add a name taken by another brain: refused (exit 0), registry unchanged" \
  eval '[ $rc = 0 ] && has "$out" "brain: " && has "$out" "alpha" && cmp -s "$REG" "$T/reg.before"'
for n in Bad_Name -x "$(printf 'x%.0s' $(seq 1 33))" none auto add new rename remove help list; do
  bc "$HM/c" add "$n" "$HM/c"
  check "add with name '${n:0:12}': refused (not a name, or reserved), registry unchanged" \
    eval '[ $rc = 0 ] && has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'
done
bc "$HM/plain" add delta "$HM/b"
check "add <folder> with no STATUS.md in it: refused, says to name the file or use /brain new --at" \
  eval 'has "$out" "brain: " && has "$out" "STATUS.md" && has "$out" "--at" && cmp -s "$REG" "$T/reg.before"'
bc "$HM/plain" add delta "$HM/nowhere"
check "add with a missing path: refused" eval 'has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'
printf 'A\000B\n' > "$HM/c/bin.md"
bc "$HM/plain" add delta "$HM/c/bin.md"
check "add a STATUS file the hooks would refuse (binary): refused with the reason" \
  eval 'has "$out" "brain: " && has "$out" "not text" && cmp -s "$REG" "$T/reg.before"'
printf 'home status\n' > "$HM/HOME-STATUS.md"
bc "$HM/plain" add delta "$HM/HOME-STATUS.md"
check "add a STATUS file directly in \$HOME: refused (the folder may not be \$HOME)" \
  eval 'has "$out" "brain: " && has "$out" "home folder" && cmp -s "$REG" "$T/reg.before"'
bc "$HM/plain/x" add delta
check "add <name> with no path in a folder with no old pointer: refused, says to name the folder or STATUS file" \
  eval 'has "$out" "brain: " && has "$out" "/brain add delta <folder|STATUS file>" && has "$out" "/brain new" && cmp -s "$REG" "$T/reg.before"'
bc "$HM/a" add
check "add without a name: usage, exit 0" eval '[ $rc = 0 ] && has "$out" "usage" && has "$out" "add <name> <folder|STATUS file>"'

# --- add <name> with no path: migrate an old .claude/brain pointer in the current folder ---------------------------
mkdir -p "$HM/m/.claude" "$HM/m/phase-a" "$HM/m/src"; printf 'status-of-m\n' > "$HM/m/phase-a/STATUS.md"
echo phase-a/STATUS.md > "$HM/m/.claude/brain"; before_m=$(tree "$HM/m")
bc "$HM/m" add em
check "add em in a folder with an old pointer: registers the STATUS it names (dir: that file's folder)" \
  eval '[ $rc = 0 ] && has "$out" "Registered brain \"em\"" && reg "b[\"em\"] == {\"dir\": \"$HM/m/phase-a\", \"status\": \"STATUS.md\"}"'
check "... and says the pointer is no longer read and can be deleted, leaving it in place" \
  eval 'has "$out" "$HM/m/.claude/brain" && has "$out" "no longer read" && has "$out" "delete" && [ "$(tree "$HM/m")" = "$before_m" ]'
bc "$HM/m/src" add em2
check "add with no path in a subfolder of it: refused (only the current folder's pointer is used)" \
  eval 'has "$out" "brain: " && ! reg "\"em2\" in b"'
mkdir -p "$HM/bad/.claude"; echo /etc/hosts > "$HM/bad/.claude/brain"
cp "$REG" "$T/reg.before"
bc "$HM/bad" add delta
check "add with no path, old pointer the hooks would have refused: refused with the reason" \
  eval 'has "$out" "brain: " && has "$out" "relative" && cmp -s "$REG" "$T/reg.before"'
# The pointer is untrusted (a cloned repo's): read as the hooks used to read it, only its first 4,096 bytes.
PT="$HM/pt"; mkdir -p "$PT/.claude"; printf 'status-of-pt\n' > "$PT/STATUS.md"
writef() { python3 -I -c 'import sys; open(sys.argv[1], "w").write(eval(sys.argv[2]))' "$PT/.claude/brain" "$1"; }
printf '\357\273\277STATUS.md\r\n' > "$PT/.claude/brain"; bc "$PT" add pt1
check "old pointer with a UTF-8 BOM and CRLF: read" reg "b['pt1'] == {'dir': '$PT', 'status': 'STATUS.md'}"
writef '"a" * 1000000'
start=$(python3 -I -c 'import time; print(time.time())'); bc "$PT" add pt2
ms=$(python3 -I -c "import time; print(int((time.time() - $start) * 1000))")
check "old pointer with a 1 MB path line: refused as naming no file, in ${ms} ms (limit 2,000)" \
  eval 'has "$out" "names no file" && ! reg "\"pt2\" in b" && [ "$ms" -lt 2000 ]'
writef '"a" * 1025 + "\n"'; bc "$PT" add pt2
check "old pointer path line of 1,025 bytes: refused" eval 'has "$out" "names no file" && ! reg "\"pt2\" in b"'
writef '"#\n" * 2100 + "STATUS.md\n"'; bc "$PT" add pt2
check "old pointer path line after 4,096 bytes of comments: not read" eval 'has "$out" "names no file" && ! reg "\"pt2\" in b"'
writef '"#" * 4086 + "\nSTATUS.md.old\n"'; bc "$PT" add pt2
check "old pointer path line cut at byte 4,096: refused, never read as the shorter path" \
  eval 'has "$out" "names no file" && ! reg "\"pt2\" in b"'
writef '"#" * 4085 + "\nSTATUS.md\n"'; bc "$PT" add pt2
check "old pointer path line whose newline is byte 4,096: read" reg "'pt2' in b"
rm -f "$PT/.claude/brain"; mkfifo "$PT/.claude/brain"; bc "$PT" add pt3
check "old pointer that is a FIFO: not opened, no hang, refused" eval '[ $rc = 0 ] && has "$out" "brain: " && ! reg "\"pt3\" in b"'
rm -f "$PT/.claude/brain"

# --- list --------------------------------------------------------------------------------------------------------------
bc "$HM/plain/x"
check "list: one row per brain with its folder, STATUS file, size and date" \
  eval 'hasline "$out" "^  alpha +$HM/a +STATUS.md, 21 bytes, changed $TODAY\$" && hasline "$out" "^  beta +$HM/b/notes +STATUS.md, 21 bytes, changed $TODAY\$"'
check "list in a plain folder: this window uses no brain, nothing marked" \
  eval 'has "$out" "This window uses no brain" && ! hasline "$out" "^\* "'
bc "$HM/a"
check "list in a folder whose old pointer names a registered brain: nothing marked, no brain, no pointer line" \
  eval '! hasline "$out" "^\* " && has "$out" "This window uses no brain" && ! has "$out" "pointer"'
mkdir -p "$HM/d/.claude" "$HM/d/deep"; printf 'status-of-d\n' > "$HM/d/STATUS.md"; echo STATUS.md > "$HM/d/.claude/brain"
bc "$HM/d"
check "list in a folder with an old pointer to an unregistered brain: says it is no longer read, and /brain add <name>" \
  eval 'has "$out" "$HM/d/.claude/brain" && has "$out" "no longer read" && has "$out" "/brain add <name>" && ! hasline "$out" "^\* "'
bc "$HM/d/deep"
check "list in a subfolder of it: no pointer line (only the current folder is looked at)" eval '! has "$out" "pointer"'
bc "$HM/plain" CD_BRAIN=beta
check "list with CD_BRAIN=beta: beta marked, says it was chosen with CD_BRAIN" \
  eval 'hasline "$out" "^\* beta " && has "$out" "This window uses brain \"beta\" (chosen with CD_BRAIN)"'
python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); d["brains"]["gone"] = {"dir": sys.argv[2], "status": "STATUS.md"}
json.dump(d, open(sys.argv[1], "w"))' "$REG" "$HM/gone"
bc "$HM/plain"
check "list: a brain the hooks would refuse is shown with the reason" \
  hasline "$out" "^  gone +$HM/gone +not usable: names a missing folder"
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
check "another window is not affected (it has no brain)" \
  eval 'o=$(hookout "$HM/a" CLAUDE_PID=1); ! has "$o" status-of && has "$o" "No brain attached"'
bc "$HM/a"
check "list after /brain beta: beta marked, chosen with /brain" \
  eval 'hasline "$out" "^\* beta " && has "$out" "This window uses brain \"beta\" (chosen with /brain)"'
bc "$HM/a" none
check "/brain none: says so, exit 0" eval '[ $rc = 0 ] && has "$out" "This window now uses no project brain"'
check "/brain none: the hooks print only the no-brain hint, even in a folder with a pointer" \
  eval 'o=$(hookout "$HM/a"); ! has "$o" status-of && has "$o" "No brain attached"'
bc "$HM/a"
check "list after /brain none: says no brain, chosen with /brain none" has "$out" "This window uses no brain (chosen with /brain none)"
# The recorded start time must not depend on the locale or time zone of whoever writes or reads it.
LOC=$(locale -a 2>/dev/null | grep -m1 -E '^(fr_FR|de_DE)\.(UTF-8|utf8)$')
bc "$HM/a" ${LOC:+LC_ALL=$LOC} TZ=Pacific/Kiritimati -- none
check "/brain none written under another locale (${LOC:-none found}) and time zone: the hooks still honour it" \
  eval 'o=$(hookout "$HM/a" CD_BRAIN=beta); ! has "$o" status-of'
bc "$HM/a" ${LOC:+LC_ALL=$LOC} TZ=Pacific/Kiritimati -- alpha
check "/brain alpha written under another locale and time zone: the hooks load alpha" \
  eval 'has "$(hookout "$HM/a" TZ=UTC)" "(brain \"alpha\", chosen with /brain)"'
bc "$HM/a" none
cp "$SES/pid-$$" "$T/choice.before"
bc "$HM/a" zzz
check "/brain <unregistered name>: refused, lists the names, choice unchanged" \
  eval '[ $rc = 0 ] && has "$out" "brain: " && has "$out" "alpha" && cmp -s "$SES/pid-$$" "$T/choice.before"'
bc "$HM/a" gone
check "/brain <brain the hooks refuse>: refused with the reason, choice unchanged" \
  eval 'has "$out" "names a missing folder" && cmp -s "$SES/pid-$$" "$T/choice.before"'
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

# --- /brain auto is gone: there is no folder default to go back to ------------------------------------------------
cp "$SES/pid-$$" "$T/choice.before"
bc "$HM/a" auto
check "/brain auto: says it is gone and points to /brain none and /brain <name>, choice unchanged, exit 0" \
  eval '[ $rc = 0 ] && has "$out" "brain: " && has "$out" "/brain none" && has "$out" "/brain <name>" && cmp -s "$SES/pid-$$" "$T/choice.before"'
bc "$HM/plain" help
check "help no longer shows /brain auto" eval '! has "$out" "/brain auto"'
bc "$HM/plain"
check "the list's closing line no longer names /brain auto" eval '! has "$out" "/brain auto"'
bc "$HM/a" beta

# --- rename and remove: the registry (rename also moves the compaction logs) ---------------------------------------
before_b=$(tree "$HM/b")
mkdir -p "$CFG/brain-logs/beta"; echo log > "$CFG/brain-logs/beta/2026-01-01-000000-abcdef12.md"
bc "$HM/plain" rename beta bravo
check "rename beta bravo: registry entry renamed, same paths" \
  eval '[ $rc = 0 ] && reg "\"beta\" not in b and b[\"bravo\"][\"dir\"] == \"$HM/b/notes\""'
check "rename: this window's choice of beta now reads bravo" eval '[ "$(head -n 1 "$SES/pid-$$")" = bravo ]'
check "rename: its compaction logs move to brain-logs/bravo, and it says so" \
  eval '[ -f "$CFG/brain-logs/bravo/2026-01-01-000000-abcdef12.md" ] && [ ! -e "$CFG/brain-logs/beta" ] && has "$out" "$CFG/brain-logs/bravo"'
check "rename: the hooks still load the brain in this window" eval 'has "$(hookout "$HM/a")" "(brain \"bravo\", chosen with /brain)"'
check "rename: the brain's files untouched" [ "$(tree "$HM/b")" = "$before_b" ]
cp "$REG" "$T/reg.before"
bc "$HM/plain" rename alpha bravo
check "rename to a name in use: refused, registry unchanged" eval 'has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'
bc "$HM/plain" rename nope x1
check "rename an unregistered name: refused" eval 'has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'
bc "$HM/plain" rename alpha none
check "rename to a reserved name: refused" eval 'has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'
mkdir -p "$CFG/brain-logs/gamma" "$CFG/brain-logs/gamma9"; echo old > "$CFG/brain-logs/gamma/x.md"
bc "$HM/plain" rename gamma gamma9
check "rename when brain-logs/<new> already exists: the logs stay under the old name, and it says so" \
  eval '[ -f "$CFG/brain-logs/gamma/x.md" ] && has "$out" "$CFG/brain-logs/gamma" && has "$out" "already exists"'
bc "$HM/plain" rename gamma9 gamma
bc "$HM/plain" remove bravo
check "remove bravo: entry gone, others kept" eval '[ $rc = 0 ] && reg "\"bravo\" not in b and \"alpha\" in b"'
check "remove: says its files and its compaction logs stay" \
  eval 'has "$out" "$HM/b/notes" && has "$out" "$CFG/brain-logs/bravo" && [ -f "$CFG/brain-logs/bravo/2026-01-01-000000-abcdef12.md" ]'
check "remove: the brain's files untouched" [ "$(tree "$HM/b")" = "$before_b" ]
check "remove: a window that chose it gets one warning line from the hook, no STATUS" \
  eval 'o=$(hookout "$HM/a"); has "$o" "not loaded" && has "$o" "bravo" && ! has "$o" status-of'
cp "$REG" "$T/reg.before"
bc "$HM/plain" remove bravo
check "remove an unregistered name: refused, registry unchanged" eval 'has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'

# --- writes keep the registry safe -----------------------------------------------------------------------------------
python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); d["note"] = "kept"; d["brains"]["odd"] = {"root": 5}
json.dump(d, open(sys.argv[1], "w"))' "$REG"
bc "$HM/d" add delta "$HM/d"
check "add keeps other keys and entries it does not understand" eval 'reg "d[\"note\"] == \"kept\" and b[\"odd\"] == {\"root\": 5} and \"delta\" in b"'
printf '{"version": 1, "brains": ' > "$REG"; cp "$REG" "$T/reg.broken"
bc "$HM/c" add echo "$HM/c"
check "add with a broken registry: refused, file left as it was" \
  eval '[ $rc = 0 ] && has "$out" "brain: " && cmp -s "$REG" "$T/reg.broken"'
rm -f "$REG"; mkfifo "$REG"
bc "$HM/c" add echo "$HM/c"
check "add when the registry is a FIFO: refused without blocking" eval '[ $rc = 0 ] && has "$out" "brain: " && [ -p "$REG" ]'
rm -f "$REG"
CD2="$T/other config"
bc "$HM/c" CLAUDE_CONFIG_DIR="$CD2" add echo "$HM/c"
check "CLAUDE_CONFIG_DIR: the registry is written there" \
  eval '[ -f "$CD2/brains.json" ] && [ ! -e "$REG" ] && grep -q echo "$CD2/brains.json"'

# --- new: create a brain, register it, attach it to this window -----------------------------------------------------
bc "$HM/plain" new fresh
check "new fresh: STATUS and overview in <config>/brains/fresh, registered there, exit 0" \
  eval '[ $rc = 0 ] && [ -f "$CFG/brains/fresh/STATUS.md" ] && [ -f "$CFG/brains/fresh/00-Project-Overview.md" ] && reg "b[\"fresh\"] == {\"dir\": \"$CFG/brains/fresh\", \"status\": \"STATUS.md\"}"'
check "new: nothing written in the current folder, no pointer anywhere" \
  eval '[ -z "$(ls -A "$HM/plain" | grep -v "^x$")" ] && [ ! -e "$CFG/brains/fresh/.claude" ]'
check "new: attached to this window, its STATUS printed" \
  eval '[ "$(head -n 1 "$SES/pid-$$")" = fresh ] && has "$out" "This window now uses brain \"fresh\"" && has "$out" "fresh — STATUS"'
check "the hooks now load it in this window" eval 'has "$(hookout "$HM/plain")" "fresh — STATUS"'
mkdir -p "$HM/repo"
bc "$HM/plain" new atb --at "$HM/repo/brain"
check "new <name> --at <folder>: made there (folder created inside an existing parent), registered, attached" \
  eval '[ -f "$HM/repo/brain/STATUS.md" ] && reg "b[\"atb\"][\"dir\"] == \"$HM/repo/brain\"" && [ "$(head -n 1 "$SES/pid-$$")" = atb ]'
bc "$HM/plain" new atb2 --at '~/repo2'
check "new --at with a ~/ folder: taken from \$HOME" eval '[ -f "$HM/repo2/STATUS.md" ] && reg "\"atb2\" in b"'
cp "$SES/pid-$$" "$T/choice.before"
bc "$HM/plain" new fresh --at "$HM/fresh2"
check "new with a name in use: refused before anything is made" \
  eval 'has "$out" "brain: " && [ ! -e "$HM/fresh2" ] && cmp -s "$SES/pid-$$" "$T/choice.before"'
bc "$HM/plain" new fresh3 --at "$HM/missing/deep"
check "new --at a folder whose parent is missing: refused, nothing registered or attached" \
  eval '! reg "\"fresh3\" in b" && [ ! -e "$HM/missing" ] && cmp -s "$SES/pid-$$" "$T/choice.before"'
bc "$HM/plain" new fresh3 --at "$HM"
check "new --at the home folder: init-brain refuses, nothing registered" eval '! reg "\"fresh3\" in b"'
mkdir -p "$HM/has"; printf 's\n' > "$HM/has/STATUS.md"; before=$(tree "$HM/has")
bc "$HM/plain" new has --at "$HM/has"
check "new --at a folder that already holds a STATUS.md: refused, points to /brain add, nothing changed" \
  eval 'has "$out" "brain: " && has "$out" "/brain add has" && [ "$(tree "$HM/has")" = "$before" ] && ! reg "\"has\" in b"'
bc "$HM/plain" new fresh3 "$HM/x"
check "new <name> <folder> without --at: usage" eval '[ $rc = 0 ] && has "$out" "usage" && has "$out" "new <name> [--at <folder>]"'
out=$(cd "$HM/plain" && env -u CLAUDE_PID HOME="$HM" bash "$B" new outside 2>&1)
check "new outside Claude Code (no window): made and registered, says it could not attach it" \
  eval '[ -f "$CFG/brains/outside/STATUS.md" ] && reg "\"outside\" in b" && has "$out" "brain: " && has "$out" CLAUDE_PID'

# --- an entry is its folder: add updates it for the same folder or a folder that is gone ---------------------------
mkdir -p "$HM/mv"; printf 'status-of-mv\n' > "$HM/mv/STATUS.md"
bc "$HM/plain" add mv "$HM/mv"
bc "$HM/plain" mv
printf 'status-of-mv-next\n' > "$HM/mv/NEXT.md"
bc "$HM/plain" add mv "$HM/mv/NEXT.md"
check "add mv again for the same folder, another STATUS file: updates the entry's STATUS instead of refusing" \
  eval '[ $rc = 0 ] && has "$out" "Updated brain \"mv\"" && reg "b[\"mv\"] == {\"dir\": \"$HM/mv\", \"status\": \"NEXT.md\"}"'
# A brain folder that moved: the messages say how to fix it, and add points the entry at the new place.
mv "$HM/mv" "$HM/mv2"
bc "$HM/plain"
check "list: a brain whose folder is gone says how to fix it" \
  eval 'has "$out" "names a missing folder" && has "$out" "/brain add mv <folder>"'
check "hook in a window that chose it: the warning says how to fix it too" \
  eval 'has "$(hookout "$HM/plain")" "/brain add mv <folder>"'
bc "$HM/plain" add mv "$HM/mv2/NEXT.md"
check "add mv <its STATUS in the new folder> when its old folder is gone: the entry moves there" \
  eval 'has "$out" "Updated brain \"mv\"" && reg "b[\"mv\"] == {\"dir\": \"$HM/mv2\", \"status\": \"NEXT.md\"}"'
mkdir -p "$HM/mv3"; printf 's\n' > "$HM/mv3/STATUS.md"
cp "$REG" "$T/reg.before"
bc "$HM/plain" add mv "$HM/mv3"
check "add mv <another folder> while its own folder still exists: refused, registry unchanged" \
  eval 'has "$out" "brain: " && has "$out" "$HM/mv2" && cmp -s "$REG" "$T/reg.before"'

# --- --args: the raw argument string from the /brain skill, split by the script itself --------------------------
# bca <cwd> <raw>: run brain.sh --args with <raw> on stdin, as the skill's quoted heredoc passes $ARGUMENTS.
bca() { out=$(cd "$1" && printf '%s\n' "$2" | env HOME="$HM" CLAUDE_PID=$$ perl -e 'alarm shift; exec @ARGV' 30 \
  bash "$B" --args 2>&1); rc=$?; }
mkdir -p "$HM/My Proj"; printf 'status-of-space\n' > "$HM/My Proj/STATUS.md"
bca "$HM/plain" "add sp '~/My Proj'"
check "--args: a quoted ~/path with a space is one argument, ~ expanded" \
  eval '[ $rc = 0 ] && has "$out" "Registered brain \"sp\"" && reg "b[\"sp\"][\"dir\"] == \"$HM/My Proj\""'
bca "$HM/plain" 'add sp2 ~/My\ Proj'
check "--args: a backslash-escaped space works too" reg "b['sp2']['dir'] == '$HM/My Proj'"
bca "$HM/plain" "add sp3 \"$HM/My Proj\""
check "--args: a double-quoted absolute path" reg "b['sp3']['dir'] == '$HM/My Proj'"
cp "$REG" "$T/reg.before"
bca "$HM/a" 'add tick `touch '"$T"'/pwned1`'
check "--args: a backtick is plain text: no command runs, the current folder is not registered" \
  eval '[ ! -e "$T/pwned1" ] && has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'
bca "$HM/a" 'zzz; touch '"$T"'/pwned2'
check "--args: ; is plain text: nothing runs, usage shown" eval '[ ! -e "$T/pwned2" ] && has "$out" "usage"'
bca "$HM/a" 'alpha $(touch '"$T"'/pwned3) | tee '"$T"'/pwned4'
check "--args: \$(...) and | are plain text" eval '[ ! -e "$T/pwned3" ] && [ ! -e "$T/pwned4" ] && has "$out" "usage"'
bca "$HM/plain" "add x Bob's"
check "--args: an unmatched quote: one clear error, exit 0" \
  eval '[ $rc = 0 ] && has "$out" "brain: " && has "$out" "quote" && cmp -s "$REG" "$T/reg.before"'
bca "$HM/plain" ""
check "--args with nothing: the list" has "$out" "Brains (registry"
bca "$HM/plain" "  help  "
check "--args: surrounding spaces ignored" has "$out" "usage: /brain"
bca "$HM/plain" "$(printf 'x%.0s' $(seq 1 5000))"
check "--args over 4,096 bytes: refused" eval 'has "$out" "brain: " && has "$out" "too long"'
cp "$REG" "$T/reg.before"
bca "$HM/plain" "--upgrade-registry 20260101-000000"
check "--args: the installer's --upgrade-registry is not reachable from /brain" \
  eval 'has "$out" "brain: " && cmp -s "$REG" "$T/reg.before"'
bc "$HM/plain" add sp4 '~/My Proj'
check "argv form: a folder starting with ~/ is expanded too" reg "b['sp4']['dir'] == '$HM/My Proj'"

# --- a version 1 registry: read as version 2, written as version 2 at the next change -----------------------------
cp "$REG" "$T/reg.keep"
python3 -I -c 'import json, sys
json.dump({"version": 1, "note": "kept", "brains": {"old": {"root": sys.argv[2], "status": sys.argv[2] + "/STATUS.md"},
           "half": {"root": "/x"}}}, open(sys.argv[1], "w"))' "$REG" "$HM/c"
cp "$REG" "$T/reg.v1"
bc "$HM/plain"
check "list on a version 1 registry: an entry shows its STATUS file's folder as its folder" \
  hasline "$out" "^  old +$HM/c +STATUS.md, "
check "list never rewrites the registry" cmp -s "$REG" "$T/reg.v1"
bc "$HM/plain" old
check "/brain <name> on a version 1 registry: attaches it" has "$out" 'This window now uses brain "old"'
check "attaching never rewrites the registry" cmp -s "$REG" "$T/reg.v1"
bc "$HM/d" add v1new "$HM/d"
check "add on a version 1 registry: written as version 2, entries converted, unknown keys and unusable entries kept" \
  reg "d['version'] == 2 and d['note'] == 'kept' and b['old'] == {'dir': '$HM/c', 'status': 'STATUS.md'} and b['half'] == {'root': '/x'} and 'v1new' in b"
cp "$T/reg.keep" "$REG"; bc "$HM/plain" none

# --- messages and edge cases -------------------------------------------------------------------------------------
cp "$REG" "$T/reg.keep"
printf '{"version": 1, "brains": ' > "$REG"
bc "$HM/plain" paper
check "pick with a broken registry: the problem is named once, no bogus 'Registered:' list" \
  eval 'has "$out" "not valid JSON" && ! has "$out" "Registered:"'
cp "$T/reg.keep" "$REG"
if [ "$(id -u)" != 0 ]; then   # root can write to a read-only folder
  chmod 500 "$CFG"
  bc "$HM/plain" add ro "$HM/c"
  check "add when the registry cannot be written: one clear line, no Python traceback" \
    eval '[ $rc = 0 ] && [ "$(printf "%s\n" "$out" | grep -c "")" = 1 ] && has "$out" "brain: cannot write $REG" && ! has "$out" Traceback'
  bc "$HM/plain" rename sp sp9
  check "rename when the registry cannot be written: one clear line" eval 'has "$out" "brain: cannot write" && ! has "$out" Traceback'
  bc "$HM/plain" remove sp
  check "remove when the registry cannot be written: one clear line" eval 'has "$out" "brain: cannot write" && ! has "$out" Traceback'
  chmod 755 "$CFG"
fi
NOPY="$T/bin-without-python"; mkdir -p "$NOPY"
for c in bash cat dirname basename readlink tr wc head tail od awk ps perl env date find sed cut paste mktemp mv rm \
         chmod mkdir sort grep xargs true; do p=$(command -v "$c") && ln -s "$p" "$NOPY/$c"; done
out=$(cd "$HM/plain" && env PATH="$NOPY" HOME="$HM" CLAUDE_PID=$$ "$NOPY/bash" "$B" 2>&1)
check "list without python3: says brains need python3, and does not blame the registry" \
  eval 'has "$out" "need python3" && ! has "$out" "fix it or move it aside"'
out=$(cd "$HM/plain" && env PATH="$NOPY" HOME="$T/empty-home" CLAUDE_PID=$$ "$NOPY/bash" "$B" 2>&1)
check "list without python3 and no registry: no python3 line" eval '! has "$out" "python3" && has "$out" "This window uses"'
python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
d["brains"].update({"half": {"dir": "/x"}, "Bad Name": {"dir": "/y", "status": "S.md"}, "nums": 5,
                    "tabbed": {"dir": "/a\tb", "status": "S.md"}})
json.dump(d, open(sys.argv[1], "w"))' "$REG"
bc "$HM/plain"
check "list shows entries it cannot use, flagged (no entry hidden)" \
  eval 'hasline "$out" "^  half +.*not usable" && hasline "$out" "^  Bad Name +.*not usable" && hasline "$out" "^  nums +.*not usable" && hasline "$out" "^  tabbed +.*not usable"'
cp "$T/reg.keep" "$REG"
bc "$HM/plain" rename sp sp
check "rename to the same name: says so, registry unchanged" \
  eval 'has "$out" "same name" && ! has "$out" "already used" && cmp -s "$REG" "$T/reg.keep"'
rm -f "$SES/pid-$$"; mkdir -p "$SES/pid-$$"
bc "$HM/a" none
check "a folder where the choice file goes: /brain none fails with a message, not a false success" \
  eval 'has "$out" "brain: " && ! has "$out" "now uses no project brain"'
rm -rf "$SES/pid-$$"
printf '4242 (a (b) c) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 987654 19 20\n' > "$T/fake-stat"
check "Linux start time: field 22 of /proc/<pid>/stat, read past a comm with spaces and parentheses" \
  eval '[ "$(. "$S/brain-lib.sh"; cd_stat_start "$T/fake-stat")" = 987654 ]'
if [ -r "/proc/$$/stat" ]; then
  check "on Linux the start time comes from /proc (ticks since boot, unmoved by clock changes)" \
    eval '(. "$S/brain-lib.sh"; cd_process_start $$) | grep -Eq "^boot\+[0-9]+$"'
fi

# --- help and unknown words ------------------------------------------------------------------------------------------
bc "$HM/plain" help
all_in() { local t="$1"; shift; for w in "$@"; do has "$t" "$w" || return 1; done; }
check "help: shows every form, exit 0" eval '[ $rc = 0 ] && all_in "$out" "/brain <name>" "/brain none" "add <name> <folder|STATUS file>" "new <name> [--at <folder>]" "rename <old> <new>" "remove <name>"'
bc "$HM/plain" remove
check "remove without a name: usage, exit 0" eval '[ $rc = 0 ] && has "$out" "usage"'

echo "== brain command tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
