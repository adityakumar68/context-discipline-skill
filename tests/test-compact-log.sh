#!/usr/bin/env bash
# Tests for compact-log.sh (PostCompact hook): it saves the compaction summary to
# <config>/brain-logs/<brain name>/<YYYY-MM-DD-HHMMSS>-<first 8 of session id>.md (<config> being $CLAUDE_CONFIG_DIR
# or ~/.claude), only when the session has a brain, never in the brain's folder, and never fails the session.
# Usage: bash tests/test-compact-log.sh
# Self-contained: works in a mktemp folder with HOME pointed into it, so nothing outside it is read or written.

set -u
unset CD_BRAIN CD_HOOKS CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR   # no brain choice from the calling window
S=$(cd "$(dirname "$0")/../context-discipline/scripts" && pwd -P)
L="$S/compact-log.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/cd-tests.XXXXXX") && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
T=$(cd "$T" && pwd -P) || exit 1    # resolve symlinks (macOS /var -> /private/var) so paths compare equal
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name"; fi; }

HM="$T/home"; CFG="$HM/.claude"; LOGS="$CFG/brain-logs"
SID="abcdef12-3456-7890-abcd-ef1234567890"
# input <cwd> [summary] [session_id]: a PostCompact hook input, JSON-encoded by python.
input() {
  python3 -I -c 'import json, sys
d = {"session_id": sys.argv[3], "transcript_path": "/nonexistent.jsonl", "cwd": sys.argv[1],
     "hook_event_name": "PostCompact", "trigger": "auto", "compact_summary": sys.argv[2]}
if sys.argv[3] == "-": del d["session_id"]
print(json.dumps(d))' "$1" "${2-Summary of the compacted conversation.}" "${3-$SID}"
}
# run <json> [VAR=value...]: run the hook with the fake home, brain p (CD_BRAIN=p unless overridden). Sets out, rc.
run() { local in="$1"; shift; out=$(printf '%s' "$in" | env -u CLAUDE_PROJECT_DIR HOME="$HM" CD_BRAIN=p "$@" bash "$L" 2>&1); rc=$?; }
logs() { ls "$LOGS/$1" 2>/dev/null | grep -c '' ; }   # number of files in brain <name>'s log folder

# Brain p (its folder is $P), brain q, a folder with an old pointer, and a plain folder.
P="$HM/p"; Q="$HM/q"; mkdir -p "$CFG" "$P" "$Q" "$HM/old/.claude" "$HM/plain/x"
printf '# STATUS\n' > "$P/STATUS.md"; printf '# STATUS\n' > "$Q/STATUS.md"
printf '# STATUS\n' > "$HM/old/STATUS.md"; echo STATUS.md > "$HM/old/.claude/brain"
python3 -I -c 'import json, sys
json.dump({"version": 2, "brains": {"p": {"dir": sys.argv[2], "status": "STATUS.md"},
                                    "q": {"dir": sys.argv[3], "status": "STATUS.md"}}}, open(sys.argv[1], "w"))' \
  "$CFG/brains.json" "$P" "$Q"

# --- writes the summary to <config>/brain-logs/<name>/ ---------------------------------------------------------------
SUMMARY=$'## Summary\nDecision D3: keep the cache.\nPrices in $USD, a back\\slash, quotes "x" and été.\n'
run "$(input "$HM/plain/x" "$SUMMARY")"
f=$(ls "$LOGS/p"/*.md 2>/dev/null | head -n 1)
check "brain p, session in an unrelated folder: exit 0, prints nothing" eval '[ $rc = 0 ] && [ -z "$out" ]'
check "one file in <config>/brain-logs/p/" [ "$(logs p)" = 1 ]
check "nothing written in the brain's folder or the session's folder" \
  eval '[ "$(ls -A "$P")" = STATUS.md ] && [ -z "$(ls -A "$HM/plain/x")" ]'
check "file name is <YYYY-MM-DD-HHMMSS>-<first 8 of session id>.md" \
  eval 'basename "$f" | grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}-abcdef12\.md$"'
check "file holds the summary byte for byte (newlines, \$, backslash, quotes, UTF-8)" \
  python3 -I -c 'import sys; t = open(sys.argv[1], encoding="utf-8").read(); sys.exit(0 if sys.argv[2] in t else 1)' "$f" "$SUMMARY"
check "file starts with a heading naming the trigger" eval 'head -n 1 "$f" | grep -q "^# Compaction summary.*auto"'
check "file is readable by its owner only (mode 600)" eval '[ "$(ls -l "$f" | cut -c1-10)" = "-rw-------" ]'
check "the log folders are private (mode 700)" \
  eval '[ "$(ls -ld "$LOGS" | cut -c1-10)" = drwx------ ] && [ "$(ls -ld "$LOGS/p" | cut -c1-10)" = drwx------ ]'

run "$(input "$P" "second summary")"; run "$(input "$P" "third summary")"
check "two more compactions in the same second: two more files, nothing overwritten" \
  eval '[ "$(logs p)" = 3 ] && grep -q "Decision D3" "$f" && grep -lq "second summary" "$LOGS/p"/* && grep -lq "third summary" "$LOGS/p"/*'
run "$(input "$P" "for q")" CD_BRAIN=q
check "another brain: its own log folder" eval '[ "$(logs q)" = 1 ] && grep -lq "for q" "$LOGS/q"/* && [ "$(logs p)" = 3 ]'

# --- does nothing without a brain --------------------------------------------------------------------------------------
before=$(ls -R "$CFG" "$HM/old" | cksum)
run "$(input "$HM/old" "no brain summary")" CD_BRAIN=
check "no brain, session in a folder with an old .claude/brain pointer: exit 0, nothing written anywhere" \
  eval '[ $rc = 0 ] && [ -z "$out" ] && [ "$(ls -R "$CFG" "$HM/old" | cksum)" = "$before" ] && [ ! -e "$HM/old/.claude/compactions" ]'
run "$(input "$P" "none summary")" CD_BRAIN=none
check "CD_BRAIN=none: nothing written" eval '[ $rc = 0 ] && [ -z "$out" ] && ! grep -rq "none summary" "$LOGS"'
run "$(input "$P" "unknown summary")" CD_BRAIN=nope
check "CD_BRAIN names an unregistered brain: exit 0, no output, nothing written" \
  eval '[ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$LOGS/nope" ] && ! grep -rq "unknown summary" "$LOGS"'

# --- bad or missing input ------------------------------------------------------------------------------------------
before=$(logs p)
run "$(input "$P" "")"
check "empty compact_summary: nothing written" eval '[ $rc = 0 ] && [ "$(logs p)" = "$before" ]'
run "$(printf '{"cwd": "%s", "session_id": "%s", "trigger": "manual"}' "$P" "$SID")"
check "no compact_summary field: nothing written" eval '[ $rc = 0 ] && [ "$(logs p)" = "$before" ]'
run "$(printf '{"cwd": "%s", "compact_summary": 42}' "$P")"
check "compact_summary that is not a string: nothing written" eval '[ $rc = 0 ] && [ "$(logs p)" = "$before" ]'
out=$(cd "$P" && printf '{bad json' | env -u CLAUDE_PROJECT_DIR HOME="$HM" CD_BRAIN=p bash "$L" 2>&1); rc=$?
check "malformed JSON: exit 0, no output, nothing written" eval '[ $rc = 0 ] && [ -z "$out" ] && [ "$(logs p)" = "$before" ]'
out=$(cd "$P" && env -u CLAUDE_PROJECT_DIR HOME="$HM" CD_BRAIN=p bash "$L" < /dev/null 2>&1); rc=$?
check "empty input: exit 0, nothing written" eval '[ $rc = 0 ] && [ "$(logs p)" = "$before" ]'

run "$(input "$Q" "no session" -)" CD_BRAIN=q
check "no session_id: still saved, named ...-unknown.md" eval 'ls "$LOGS/q" | grep -Eq "^[0-9-]{17}-unknown\.md$"'
run "$(input "$Q" "odd session" "../../e/vil")" CD_BRAIN=q
check "session_id with path characters: kept inside the brain's log folder (unsafe characters dropped)" \
  eval '[ "$(logs q)" = 3 ] && [ ! -e "$HM/e" ] && [ ! -e "$LOGS/e" ] && [ "$(ls "$LOGS")" = "$(printf "p\nq")" ]'

# --- the log folder is never written through a symlink, a file or a read-only folder -------------------------------
mkdir -p "$HM/elsewhere" "$HM/y"; printf 's\n' > "$HM/y/STATUS.md"
python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1])); d["brains"]["y"] = {"dir": sys.argv[2], "status": "STATUS.md"}
d["brains"]["z"] = {"dir": sys.argv[2], "status": "STATUS.md"}; json.dump(d, open(sys.argv[1], "w"))' "$CFG/brains.json" "$HM/y"
ln -s "$HM/elsewhere" "$LOGS/y"
run "$(input "$HM/y")" CD_BRAIN=y
check "brain-logs/<name> is a symlink: nothing written through it, exit 0" eval '[ $rc = 0 ] && [ -z "$(ls -A "$HM/elsewhere")" ]'
rm "$LOGS/y"; echo "not a folder" > "$LOGS/y"
run "$(input "$HM/y")" CD_BRAIN=y
check "brain-logs/<name> is a file: left alone, exit 0" eval '[ $rc = 0 ] && [ "$(cat "$LOGS/y")" = "not a folder" ]'
if [ "$(id -u)" != 0 ]; then   # root can write to a read-only folder, so this case means nothing there
  chmod 555 "$LOGS"
  run "$(input "$HM/y")" CD_BRAIN=z
  check "read-only brain-logs folder: exit 0, no output (the session is never failed)" eval '[ $rc = 0 ] && [ -z "$out" ]'
  chmod 700 "$LOGS"
fi

# --- without jq, python3 reads the input ---------------------------------------------------------------------------
NOJQ="$T/bin-without-jq"; mkdir -p "$NOJQ"
for c in bash cat dirname basename readlink tr wc head date mkdir chmod mv rm python3; do ln -s "$(command -v "$c")" "$NOJQ/$c"; done
out=$(input "$P" "python path summary" | env -u CLAUDE_PROJECT_DIR PATH="$NOJQ" HOME="$HM" CD_BRAIN=p "$NOJQ/bash" "$L" 2>&1); rc=$?
check "no jq on PATH: python3 reads the input, summary saved" \
  eval '[ $rc = 0 ] && grep -lq "python path summary" "$LOGS/p"/*.md'

# --- the brain chosen with /brain in this window, as the SessionStart hook picks it -------------------------------
mkdir -p "$CFG/brain-sessions"; printf 'q\n\n' > "$CFG/brain-sessions/pid-$$"
run "$(input "$HM/plain/x" "window summary")" CLAUDE_PID=$$
check "/brain q in this window (CD_BRAIN=p too): saved under q" \
  eval '[ $rc = 0 ] && grep -lq "window summary" "$LOGS/q"/*.md 2>/dev/null && ! grep -rq "window summary" "$LOGS/p"'
printf 'none\n\n' > "$CFG/brain-sessions/pid-$$"
run "$(input "$HM/plain/x" "window none")" CLAUDE_PID=$$
check "/brain none in this window: nothing written, even with CD_BRAIN set" eval '[ $rc = 0 ] && ! grep -rq "window none" "$LOGS"'
rm -rf "$CFG/brain-sessions"

# $CLAUDE_CONFIG_DIR moves the logs with the rest of Claude Code's config.
CD2="$T/other config"; mkdir -p "$CD2"; cp "$CFG/brains.json" "$CD2/brains.json"
run "$(input "$P" "moved config")" CLAUDE_CONFIG_DIR="$CD2"
check "CLAUDE_CONFIG_DIR set: the log goes to <it>/brain-logs/p" \
  eval 'grep -lq "moved config" "$CD2/brain-logs/p"/*.md 2>/dev/null && ! grep -rq "moved config" "$LOGS"'

# CD_HOOKS=off turns all three hooks off (headless runs, benchmarks): nothing is written.
before=$(logs p)
run "$(input "$P")" CD_HOOKS=off
check "CD_HOOKS=off: exit 0, nothing printed, no log written" eval '[ $rc = 0 ] && [ -z "$out" ] && [ "$(logs p)" = "$before" ]'

echo "== compact-log tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
