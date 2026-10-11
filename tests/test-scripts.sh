#!/usr/bin/env bash
# Checks for the context-discipline scripts (brain-hook.sh, init-brain.sh, ctx-audit.py), taken from this repo.
# Usage: bash tests/test-scripts.sh
# Self-contained: works in a mktemp folder with HOME pointed there, so nothing outside it is read or written.

set -u
unset CD_BRAIN CD_HOOKS CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR   # no brain choice from the calling window
S=$(cd "$(dirname "$0")/../context-discipline/scripts" && pwd -P)
H="$S/brain-hook.sh"; I="$S/init-brain.sh"; A="$S/ctx-audit.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/cd-tests.XXXXXX") && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
T=$(cd "$T" && pwd -P) || exit 1    # resolve symlinks (macOS /var -> /private/var) so paths compare equal
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
hook() { env -u CLAUDE_PROJECT_DIR HOME="$T" bash "$H"; }   # the walk-up stops at $HOME, so it never leaves $T
sum() { cat "$@" | cksum; }

mkdir -p "$T/proj/.claude" "$T/proj/docs" "$T/proj/sub/dir" "$T/none/a" "$T/big/.claude"
echo docs/STATUS.md > "$T/proj/.claude/brain"; printf '# STATUS\nhello\n' > "$T/proj/docs/STATUS.md"

out=$(echo "{\"cwd\": \"$T/proj/sub/dir\", \"source\": \"startup\"}" | hook); rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q hello \
  && printf '%s\n' "$out" | tail -n 1 | grep -qF "Project brain loaded from $T/proj/docs/STATUS.md" \
  && ok "hook: walk-up from sub/dir prints STATUS + final line" || no "hook walk-up"

out=$(echo "{\"cwd\": \"$T/none/a\", \"source\": \"startup\"}" | hook); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "hook: no pointer -> no output, exit 0" || no "hook no pointer"

out=$(cd "$T/none" && echo '{bad json' | hook); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "hook: malformed JSON -> no output, exit 0" || no "hook malformed"

echo STATUS.md > "$T/big/.claude/brain"; head -c 12000 /dev/zero | tr '\0' 'x' > "$T/big/STATUS.md"
out=$(echo "{\"cwd\": \"$T/big\"}" | hook)
printf '%s\n' "$out" | grep -q '^\[STATUS.md is 12,000 characters, over the 9,000 limit, so only the first 9,000 are shown here' && [ ${#out} -lt 10000 ] \
  && ok "hook: oversized STATUS cut to 9,000 characters + trim line (total ${#out} chars)" || no "hook oversized"

mkdir -p "$T/fh/.claude" "$T/fh/x"; echo "$T/proj/docs/STATUS.md" > "$T/fh/.claude/brain"
out=$(echo "{\"cwd\": \"$T/fh/x\"}" | HOME="$T/fh" bash "$H")
[ -z "$out" ] && ok "hook: pointer in \$HOME/.claude is ignored" || no "hook home stop"

mkdir -p "$T/abs/.claude" "$T/abs/x"; echo "$T/proj/docs/STATUS.md" > "$T/abs/.claude/brain"
out=$(echo "{\"cwd\": \"$T/abs/x\"}" | hook)
! printf '%s' "$out" | grep -q hello && printf '%s' "$out" | grep -qF "$T/abs/.claude/brain" \
  && ok "hook: absolute path in the pointer is refused with a warning" || no "hook absolute pointer"

start=$(python3 -c 'import time; print(time.time())')
for i in 1 2 3 4 5 6 7 8 9 10; do echo "{\"cwd\": \"$T/proj/sub/dir\"}" | hook >/dev/null; done
ms=$(python3 -c "import time; print(int((time.time() - $start) * 100))")
# Hang check only (the hook usually takes tens of ms); the limit is loose so slow machines pass.
[ "$ms" -lt 1000 ] && ok "hook: ~${ms} ms per run (limit 1000)" || no "hook slow ${ms} ms per run"

mkdir -p "$T/init"; bash "$I" "$T/init" >/dev/null; echo edit >> "$T/init/STATUS.md"
a=$(sum "$T/init/STATUS.md" "$T/init/00-Project-Overview.md" "$T/init/.claude/brain")
out=$(bash "$I" "$T/init"); b=$(sum "$T/init/STATUS.md" "$T/init/00-Project-Overview.md" "$T/init/.claude/brain")
[ "$a" = "$b" ] && [ "$(printf '%s\n' "$out" | grep -c 'exists, left untouched')" = 3 ] && [ "$(printf '%s\n' "$out" | wc -l)" -eq 6 ] \
  && ok "init-brain: second run overwrote nothing, reported 3x 'exists', 6-line summary" || no "init-brain rerun"

out=$(echo "{\"cwd\": \"$T/init\"}" | hook | tail -n 1)
printf '%s' "$out" | grep -qF "$T/init/STATUS.md" && ok "init-brain + hook: pointer works end to end" || no "init+hook"

mkdir -p "$T/init2"; bash "$I" "$T/init2" notes/STATUS.md >/dev/null
[ -f "$T/init2/notes/STATUS.md" ] && [ -f "$T/init2/notes/00-Project-Overview.md" ] \
  && echo "{\"cwd\": \"$T/init2\"}" | hook | tail -n 1 | grep -qF "$T/init2/notes/STATUS.md" \
  && ok "init-brain: custom STATUS path, overview beside it, hook follows it" || no "init-brain custom path"

G="$T/garbage.jsonl"
printf '%s\n' 'nope' '[1]' 'null' '{"type":"assistant","message":"s"}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"z","content":[{"type":"image","source":{"data":"AA"}},"x"]}]}}' \
  '{"type":"attachment","rendered":{"w":[1,{"a":"b"}]}}' > "$G"
python3 -I "$A" "$G" >/dev/null 2>&1 && ok "ctx-audit: survives unknown/malformed records" || no "ctx-audit garbage"

R="$T/session.jsonl"
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"ls"}}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b1","content":"a long listing of files"}]}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"g1","name":"Agent","input":{"prompt":"survey the field"}}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"g1","content":"Status: DONE"}]}}' > "$R"
out=$(python3 -I "$A" "$R" 2>&1)
printf '%s\n' "$out" | grep -q '^Category' && printf '%s\n' "$out" | grep -q '^Bash output' && printf '%s\n' "$out" | grep -q '^Agent hand-back' \
  && ok "ctx-audit: categorises Bash output and Agent hand-back" || no "ctx-audit categories"

echo "== script tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
