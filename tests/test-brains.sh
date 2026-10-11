#!/usr/bin/env bash
# Tests for named brains as the hooks see them (brain-lib.sh's cd_select_brain, through brain-hook.sh): which brain
# a session uses, first match wins:
#   1. the choice made with /brain in this Claude Code window (<config>/brain-sessions/<key>; the key is
#      pid-$CLAUDE_PID, else sid-<session id>);
#   2. CD_BRAIN=<name> or CD_BRAIN=none in the environment;
#   3. the folder walk-up to .claude/brain (the default, unchanged).
# Named brains come from the registry <config>/brains.json, <config> being $CLAUDE_CONFIG_DIR or ~/.claude.
# Usage: bash tests/test-brains.sh
# Self-contained: works in a mktemp folder with HOME pointed into it, so nothing outside it is read or written.

set -u
unset CD_BRAIN CD_HOOKS CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR CLAUDE_PROJECT_DIR
S=$(cd "$(dirname "$0")/../context-discipline/scripts" && pwd -P)
H="$S/brain-hook.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/cd-tests.XXXXXX") && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
T=$(cd "$T" && pwd -P) || exit 1    # resolve symlinks (macOS /var -> /private/var) so paths compare equal
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name"; fi; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }
lines() { printf '%s\n' "$1" | grep -c ''; }
# refused <output> <subject>: one warning line that names <subject>, and no STATUS text.
refused() { [ "$(lines "$1")" = 1 ] && has "$1" "not loaded" && has "$1" "$2" && ! has "$1" status-of-; }

HM="$T/home"; CFG="$HM/.claude"; REG="$CFG/brains.json"
mkdir -p "$CFG" "$HM/a/.claude" "$HM/a/src" "$HM/b/.claude" "$HM/b/notes" "$HM/plain/x"
printf '# STATUS\nstatus-of-a\n' > "$HM/a/STATUS.md"; echo STATUS.md > "$HM/a/.claude/brain"
printf '# STATUS\nstatus-of-b\n' > "$HM/b/notes/STATUS.md"; echo notes/STATUS.md > "$HM/b/.claude/brain"

# registry <file> [<name> <root> <status>]...: write a version 1 registry.
registry() {
  python3 -I - "$@" <<'PY'
import json, sys
f, r = sys.argv[1], sys.argv[2:]
json.dump({"version": 1, "brains": {r[i]: {"root": r[i + 1], "status": r[i + 2]} for i in range(0, len(r), 3)}},
          open(f, "w"))
PY
}
registry "$REG" a "$HM/a" "$HM/a/STATUS.md" b "$HM/b" "$HM/b/notes/STATUS.md"

# choose <key> <name> [start]: what /brain <name> leaves for a window: <config>/brain-sessions/<key>.
choose() { mkdir -p "$CFG/brain-sessions"; printf '%s\n%s\n' "$2" "${3-}" > "$CFG/brain-sessions/$1"; }
unchoose() { rm -rf "$CFG/brain-sessions"; }
# hook <cwd> [VAR=value...]: run brain-hook.sh for session sess-1 in <cwd>, with the fake home. Sets out.
hook() {
  local cwd="$1"; shift
  out=$(printf '{"cwd": "%s", "session_id": "sess-1", "source": "startup"}' "$cwd" \
    | env HOME="$HM" "$@" perl -e 'alarm shift; exec @ARGV' 10 bash "$H" 2>&1)
}

# --- the folder walk-up stays the default -------------------------------------------------------------------------
hook "$HM/a/src"
check "no choice, no CD_BRAIN: the walk-up loads the folder's brain, closing line unchanged" \
  eval 'has "$out" status-of-a && has "$out" "(Project brain loaded from $HM/a/STATUS.md. Working rules"'
hook "$HM/a" CD_BRAIN=
check "CD_BRAIN set but empty: same as unset" has "$out" status-of-a

# --- CD_BRAIN -------------------------------------------------------------------------------------------------------
hook "$HM/a/src" CD_BRAIN=b
check "CD_BRAIN=b inside project a: loads b, not a" eval 'has "$out" status-of-b && ! has "$out" status-of-a'
check "CD_BRAIN=b: the closing line names the brain and how it was chosen" \
  has "$out" "(Project brain loaded from $HM/b/notes/STATUS.md (brain \"b\", chosen with CD_BRAIN). Working rules"
hook "$HM/plain/x" CD_BRAIN=b
check "CD_BRAIN=b in a folder with no brain: loads b" has "$out" status-of-b
hook "$HM/a/src" CD_BRAIN=none
check "CD_BRAIN=none inside project a: prints nothing" [ -z "$out" ]
hook "$HM/a" CD_BRAIN=zzz
check "CD_BRAIN names an unregistered brain: one warning line naming it and the registry, nothing loaded" \
  eval 'refused "$out" "brain \"zzz\" (chosen with CD_BRAIN)" && has "$out" "$REG"'
hook "$HM/a" CD_BRAIN=Bad_Name
check "CD_BRAIN that is not a brain name: one warning line" refused "$out" 'CD_BRAIN="Bad_Name"'
hook "$HM/a" CD_BRAIN=$'x\ny\033[2J'
check "CD_BRAIN with control characters: still one warning line, characters replaced" \
  eval 'refused "$out" "CD_BRAIN=\"x?y?[2J\""'
hook "$HM/a" CD_BRAIN=b CD_HOOKS=off
check "CD_HOOKS=off wins over CD_BRAIN: prints nothing" [ -z "$out" ]

# --- the window's choice (/brain) wins over CD_BRAIN and the walk-up ---------------------------------------------
choose "pid-$$" b
hook "$HM/a" CLAUDE_PID=$$
check "/brain b in this window (CLAUDE_PID): loads b inside project a" \
  eval 'has "$out" status-of-b && has "$out" "(brain \"b\", chosen with /brain)"'
hook "$HM/a" CLAUDE_PID=$$ CD_BRAIN=a
check "the /brain choice wins over CD_BRAIN" has "$out" status-of-b
out=$(printf '{"cwd": "%s", "session_id": "new-after-clear", "source": "clear"}' "$HM/a" \
  | env HOME="$HM" CLAUDE_PID=$$ bash "$H" 2>&1)
check "after /clear (new session id, same window): the choice still holds" has "$out" status-of-b
hook "$HM/a" CLAUDE_PID=1
check "another window (other CLAUDE_PID): the choice is not used" eval 'has "$out" status-of-a && ! has "$out" status-of-b'
hook "$HM/a" CLAUDE_PID=12x
check "CLAUDE_PID that is not a number: ignored" has "$out" status-of-a
choose "pid-$$" none
hook "$HM/a" CLAUDE_PID=$$ CD_BRAIN=b
check "/brain none: prints nothing, even inside a brain project with CD_BRAIN set" [ -z "$out" ]
choose "pid-$$" 'Not A Name'
hook "$HM/a" CLAUDE_PID=$$
check "a choice file that holds no valid name: ignored (walk-up)" has "$out" status-of-a

# The choice records when its window started, so a later process that gets the same PID does not inherit it.
choose "pid-$$" b "Mon Jan 1 00:00:00 2001"
hook "$HM/a" CLAUDE_PID=$$
check "choice recorded for an older process with the same PID: ignored" eval 'has "$out" status-of-a && ! has "$out" status-of-b'
start=$(. "$S/brain-lib.sh"; cd_process_start $$)
choose "pid-$$" b "$start"
hook "$HM/a" CLAUDE_PID=$$
check "choice recorded with this process's start time ($start): used" eval '[ -n "$start" ] && has "$out" status-of-b'

# Without CLAUDE_PID (older Claude Code), the key is the session id.
unchoose; choose sid-sess-1 b
hook "$HM/a"
check "no CLAUDE_PID: the choice is keyed by the input's session_id" has "$out" status-of-b
out=$(printf '{"cwd": "%s", "session_id": "sess-2"}' "$HM/a" | env HOME="$HM" bash "$H" 2>&1)
check "no CLAUDE_PID, another session id: not used" has "$out" status-of-a
out=$(printf '{"cwd": "%s"}' "$HM/a" | env HOME="$HM" CLAUDE_CODE_SESSION_ID=sess-1 bash "$H" 2>&1)
check "no session_id in the input: \$CLAUDE_CODE_SESSION_ID is the key" has "$out" status-of-b
unchoose

# A choice file that is not a regular file (a FIFO here) is skipped without blocking.
mkdir -p "$CFG/brain-sessions"; mkfifo "$CFG/brain-sessions/pid-$$"
hook "$HM/a" CLAUDE_PID=$$; rc=$?
check "choice file is a FIFO: skipped, no hang (walk-up)" eval '[ $rc = 0 ] && has "$out" status-of-a'
unchoose

# --- what a registered brain may name -----------------------------------------------------------------------------
mkdir -p "$HM/c/.claude" "$HM/bin/.claude"; printf 'status-of-c\n' > "$HM/c/STATUS.md"
printf 'A\000B status-of-bin\n' > "$HM/bin/STATUS.md"
registry "$REG" gone "$HM/gone" "$HM/gone/STATUS.md" nofile "$HM/c" "$HM/c/MISSING.md" \
  outside "$HM/c" "$HM/b/notes/STATUS.md" home "$HM" "$HM/c/STATUS.md" rel "$HM/c" STATUS.md \
  relroot c "$HM/c/STATUS.md" binary "$HM/bin" "$HM/bin/STATUS.md" folder "$HM/c" "$HM/c/.claude" \
  c "$HM/c" "$HM/c/STATUS.md"
hook "$HM/plain" CD_BRAIN=c
check "registered brain with a STATUS inside its root: loaded" has "$out" status-of-c
for n in gone nofile outside home rel relroot binary folder; do
  hook "$HM/plain" CD_BRAIN=$n
  check "registered brain '$n' that the hooks must not load: one warning line, exit 0" \
    eval 'refused "$out" "brain \"$n\""'
done
ln -s "$HM/b/notes/STATUS.md" "$HM/c/link.md"; registry "$REG" link "$HM/c" "$HM/c/link.md"
hook "$HM/plain" CD_BRAIN=link
check "registered STATUS that is a symlink leaving its root: refused" refused "$out" 'brain "link"'

python3 -I -c 'import sys; open(sys.argv[1], "w").write("z" * 12000)' "$HM/c/STATUS.md"
registry "$REG" c "$HM/c" "$HM/c/STATUS.md"; hook "$HM/plain" CD_BRAIN=c
check "registered brain with a 12,000-char STATUS: cut to 9,000 with the usual notice" \
  has "$out" "[STATUS.md is 12,000 characters, over the 9,000 limit, so only the first 9,000 are shown here."

# --- the registry itself ------------------------------------------------------------------------------------------
regcheck() {   # regcheck <description>: CD_BRAIN=a must give one warning naming the registry, quickly
  local t0 ms; t0=$(python3 -I -c 'import time; print(time.time())')
  hook "$HM/plain" CD_BRAIN=a; rc=$?
  ms=$(python3 -I -c "import time; print(int((time.time() - $t0) * 1000))")
  check "$1: one warning naming the registry, exit 0, ${ms} ms (limit 3,000)" \
    eval '[ $rc = 0 ] && refused "$out" "brain \"a\"" && has "$out" "$REG" && [ "$ms" -lt 3000 ]'
}
rm -f "$REG"; regcheck "no registry"
printf '{"version": 1, "brains": ' > "$REG"; regcheck "registry that is not valid JSON"
printf '[1, 2]' > "$REG"; regcheck "registry that is not an object"
printf '{"version": 2, "brains": {"a": {"root": "%s", "status": "%s"}}}' "$HM/a" "$HM/a/STATUS.md" > "$REG"
regcheck "registry of an unknown version"
printf '{"version": 1, "brains": {"a": {"root": 5}}}' > "$REG"; regcheck "registry entry without paths"
rm -f "$REG"; mkfifo "$REG"; regcheck "registry is a FIFO (must not block)"
rm -f "$REG"; python3 -I -c 'import json, sys
d = {"version": 1, "brains": {"a": {"root": sys.argv[2], "status": sys.argv[3]}}, "pad": "x" * 1100000}
json.dump(d, open(sys.argv[1], "w"))' "$REG" "$HM/a" "$HM/a/STATUS.md"
regcheck "registry over 1 MB"
registry "$REG" a "$HM/a" "$HM/a/STATUS.md" b "$HM/b" "$HM/b/notes/STATUS.md"

# $CLAUDE_CONFIG_DIR moves the registry and the choices, as it moves the rest of Claude Code's config.
CD2="$T/other config"; mkdir -p "$CD2/brain-sessions"
registry "$CD2/brains.json" b2 "$HM/b" "$HM/b/notes/STATUS.md"
hook "$HM/a" CD_BRAIN=b2 CLAUDE_CONFIG_DIR="$CD2"
check "CLAUDE_CONFIG_DIR set: the registry is read there" has "$out" status-of-b
hook "$HM/a" CD_BRAIN=b2
check "CLAUDE_CONFIG_DIR unset: ~/.claude/brains.json is read, which lacks b2" refused "$out" 'brain "b2"'
printf 'none\n\n' > "$CD2/brain-sessions/pid-$$"
hook "$HM/a" CLAUDE_PID=$$ CLAUDE_CONFIG_DIR="$CD2"
check "CLAUDE_CONFIG_DIR set: the window's choice is read there too" [ -z "$out" ]

# Without python3 the registry cannot be read: a named brain is refused with a reason; the walk-up still works.
NOPY="$T/bin-without-python"; mkdir -p "$NOPY"
for c in bash cat dirname basename readlink tr wc head tail od awk jq ps perl env; do
  p=$(command -v "$c") && ln -s "$p" "$NOPY/$c"
done
# (cd into the project: without jq or python3 the hook cannot read the input's cwd and falls back to $PWD)
out=$(cd "$HM/a" && printf '{"cwd": "%s"}' "$HM/a" | env PATH="$NOPY" HOME="$HM" CD_BRAIN=b "$NOPY/bash" "$H" 2>&1)
check "no python3: CD_BRAIN=b gives one warning saying python3 is needed" \
  eval 'refused "$out" "brain \"b\"" && has "$out" python3'
out=$(cd "$HM/a" && printf '{"cwd": "%s"}' "$HM/a" | env PATH="$NOPY" HOME="$HM" "$NOPY/bash" "$H" 2>&1)
check "no python3, no choice: the walk-up still loads the folder's brain" has "$out" status-of-a

# --- speed: a chosen brain costs one small python3 run and one ps ------------------------------------------------
choose "pid-$$" b "$start"
t0=$(python3 -I -c 'import time; print(time.time())')
for i in 1 2 3 4 5; do hook "$HM/a" CLAUDE_PID=$$; done
ms=$(python3 -I -c "import time; print(int((time.time() - $t0) * 200))")
check "hook with a /brain choice: ~${ms} ms per run (limit 1,000)" eval '[ "$ms" -lt 1000 ] && has "$out" status-of-b'
unchoose

echo "== brains tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
