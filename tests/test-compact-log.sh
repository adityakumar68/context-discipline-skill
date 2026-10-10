#!/usr/bin/env bash
# Tests for compact-log.sh (PostCompact hook): it saves the compaction summary to
# <project root>/.claude/compactions/<YYYY-MM-DD-HHMMSS>-<first 8 of session id>.md, only in brain projects,
# and never fails the session.
# Usage: bash tests/test-compact-log.sh
# Self-contained: works in a mktemp folder with HOME pointed into it, so nothing outside it is read or written.

set -u
S=$(cd "$(dirname "$0")/../context-discipline/scripts" && pwd -P)
L="$S/compact-log.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/cd-tests.XXXXXX") && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
T=$(cd "$T" && pwd -P) || exit 1    # resolve symlinks (macOS /var -> /private/var) so paths compare equal
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT

pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name"; fi; }

HM="$T/home"
SID="abcdef12-3456-7890-abcd-ef1234567890"
# input <cwd> [summary] [session_id]: a PostCompact hook input, JSON-encoded by python.
input() {
  python3 -I -c 'import json, sys
d = {"session_id": sys.argv[3], "transcript_path": "/nonexistent.jsonl", "cwd": sys.argv[1],
     "hook_event_name": "PostCompact", "trigger": "auto", "compact_summary": sys.argv[2]}
if sys.argv[3] == "-": del d["session_id"]
print(json.dumps(d))' "$1" "${2-Summary of the compacted conversation.}" "${3-$SID}"
}
# run <json>: run the hook with the fake home and no CLAUDE_PROJECT_DIR. Sets out and rc.
run() { out=$(printf '%s' "$1" | env -u CLAUDE_PROJECT_DIR HOME="$HM" bash "$L" 2>&1); rc=$?; }
logs() { ls "$1/.claude/compactions" 2>/dev/null | grep -c '' ; }   # number of files in <root>'s log folder

# A brain project, and a plain folder without one.
P="$HM/p"; mkdir -p "$P/.claude" "$P/src/deep" "$HM/plain/x"
printf '# STATUS\n' > "$P/STATUS.md"; echo STATUS.md > "$P/.claude/brain"

# --- writes the summary in a brain project ------------------------------------------------------------------------
SUMMARY=$'## Summary\nDecision D3: keep the cache.\nPrices in $USD, a back\\slash, quotes "x" and été.\n'
run "$(input "$P/src/deep" "$SUMMARY")"
f=$(ls "$P/.claude/compactions"/*.md 2>/dev/null | head -n 1)
check "brain project, cwd in a subfolder: exit 0, prints nothing" eval '[ $rc = 0 ] && [ -z "$out" ]'
check "one file in <root>/.claude/compactions/" [ "$(logs "$P")" = 1 ]
check "file name is <YYYY-MM-DD-HHMMSS>-<first 8 of session id>.md" \
  eval 'basename "$f" | grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}-abcdef12\.md$"'
check "file holds the summary byte for byte (newlines, \$, backslash, quotes, UTF-8)" \
  python3 -I -c 'import sys; t = open(sys.argv[1], encoding="utf-8").read(); sys.exit(0 if sys.argv[2] in t else 1)' "$f" "$SUMMARY"
check "file starts with a heading naming the trigger" eval 'head -n 1 "$f" | grep -q "^# Compaction summary.*auto"'
check "file is readable by its owner only (mode 600)" eval '[ "$(ls -l "$f" | cut -c1-10)" = "-rw-------" ]'

run "$(input "$P" "second summary")"; run "$(input "$P" "third summary")"
check "two more compactions in the same second: two more files, nothing overwritten" \
  eval '[ "$(logs "$P")" = 3 ] && grep -q "Decision D3" "$f" && grep -lq "second summary" "$P/.claude/compactions"/* && grep -lq "third summary" "$P/.claude/compactions"/*'

# --- does nothing outside brain projects ---------------------------------------------------------------------------
run "$(input "$HM/plain/x")"
check "no brain pointer: exit 0, nothing written" \
  eval '[ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$HM/plain/.claude" ] && [ ! -e "$HM/plain/x/.claude" ]'

mkdir -p "$HM/.claude"; echo STATUS.md > "$HM/.claude/brain"; echo x > "$HM/STATUS.md"; mkdir -p "$HM/notes"
run "$(input "$HM/notes")"
check "pointer in \$HOME/.claude is not a brain: nothing written there" [ ! -e "$HM/.claude/compactions" ]
rm -f "$HM/.claude/brain"

R="$HM/refused"; mkdir -p "$R/.claude"; echo "$P/STATUS.md" > "$R/.claude/brain"
run "$(input "$R")"
check "pointer the SessionStart hook refuses (absolute path): nothing written, no output" \
  eval '[ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$R/.claude/compactions" ]'

# --- bad or missing input ------------------------------------------------------------------------------------------
before=$(logs "$P")
run "$(input "$P" "")"
check "empty compact_summary: nothing written" eval '[ $rc = 0 ] && [ "$(logs "$P")" = "$before" ]'
run "$(printf '{"cwd": "%s", "session_id": "%s", "trigger": "manual"}' "$P" "$SID")"
check "no compact_summary field: nothing written" eval '[ $rc = 0 ] && [ "$(logs "$P")" = "$before" ]'
run "$(printf '{"cwd": "%s", "compact_summary": 42}' "$P")"
check "compact_summary that is not a string: nothing written" eval '[ $rc = 0 ] && [ "$(logs "$P")" = "$before" ]'
out=$(cd "$P" && printf '{bad json' | env -u CLAUDE_PROJECT_DIR HOME="$HM" bash "$L" 2>&1); rc=$?
check "malformed JSON: exit 0, no output, nothing written" eval '[ $rc = 0 ] && [ -z "$out" ] && [ "$(logs "$P")" = "$before" ]'
out=$(cd "$P" && env -u CLAUDE_PROJECT_DIR HOME="$HM" bash "$L" < /dev/null 2>&1); rc=$?
check "empty input: exit 0, nothing written" eval '[ $rc = 0 ] && [ "$(logs "$P")" = "$before" ]'

Q="$HM/q"; mkdir -p "$Q/.claude"; echo x > "$Q/STATUS.md"; echo STATUS.md > "$Q/.claude/brain"
run "$(input "$Q" "no session" -)"
check "no session_id: still saved, named ...-unknown.md" eval 'ls "$Q/.claude/compactions" | grep -Eq "^[0-9-]{17}-unknown\.md$"'
run "$(input "$Q" "odd session" "../../e/vil")"
check "session_id with path characters: kept inside compactions/ (unsafe characters dropped)" \
  eval '[ "$(logs "$Q")" = 2 ] && [ ! -e "$HM/e" ] && ! ls "$Q/.claude" | grep -Eqv "^(compactions|brain)$"'

# --- containment: the log folder must stay inside the project --------------------------------------------------------
Y="$HM/y"; mkdir -p "$Y/.claude" "$HM/elsewhere"; echo x > "$Y/STATUS.md"; echo STATUS.md > "$Y/.claude/brain"
ln -s "$HM/elsewhere" "$Y/.claude/compactions"
run "$(input "$Y")"
check ".claude/compactions is a symlink out of the project: nothing written there, exit 0" \
  eval '[ $rc = 0 ] && [ -z "$(ls -A "$HM/elsewhere")" ]'
rm "$Y/.claude/compactions"; echo "not a folder" > "$Y/.claude/compactions"
run "$(input "$Y")"
check ".claude/compactions is a file: left alone, exit 0" eval '[ $rc = 0 ] && [ "$(cat "$Y/.claude/compactions")" = "not a folder" ]'

if [ "$(id -u)" != 0 ]; then   # root can write to a read-only folder, so this case means nothing there
  Z="$HM/z"; mkdir -p "$Z/.claude"; echo x > "$Z/STATUS.md"; echo STATUS.md > "$Z/.claude/brain"; chmod 555 "$Z/.claude"
  run "$(input "$Z")"
  check "read-only .claude folder: exit 0, no output (the session is never failed)" eval '[ $rc = 0 ] && [ -z "$out" ]'
  chmod 755 "$Z/.claude"
fi

# --- without jq, python3 reads the input ---------------------------------------------------------------------------
NOJQ="$T/bin-without-jq"; mkdir -p "$NOJQ"
for c in bash cat dirname basename readlink tr wc head date mkdir chmod mv rm python3; do ln -s "$(command -v "$c")" "$NOJQ/$c"; done
N="$HM/n"; mkdir -p "$N/.claude"; echo x > "$N/STATUS.md"; echo STATUS.md > "$N/.claude/brain"
out=$(input "$N" "python path summary" | env -u CLAUDE_PROJECT_DIR PATH="$NOJQ" HOME="$HM" "$NOJQ/bash" "$L" 2>&1); rc=$?
check "no jq on PATH: python3 reads the input, summary saved" \
  eval '[ $rc = 0 ] && grep -lq "python path summary" "$N/.claude/compactions"/*.md'

echo "== compact-log tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
