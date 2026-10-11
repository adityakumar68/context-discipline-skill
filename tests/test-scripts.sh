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
hook() { env -u CLAUDE_PROJECT_DIR HOME="$T" bash "$H"; }   # the registry is $T/.claude/brains.json
sum() { cat "$@" | cksum; }
mkdir -p "$T/.claude"
# reg <name> <dir> [status]: add brain <name> to the registry (status default STATUS.md).
reg() {
  python3 -I -c 'import json, os, sys
f = sys.argv[1]; d = json.load(open(f)) if os.path.exists(f) else {"version": 2, "brains": {}}
d["brains"][sys.argv[2]] = {"dir": sys.argv[3], "status": sys.argv[4]}; json.dump(d, open(f, "w"))' \
    "$T/.claude/brains.json" "$1" "$2" "${3:-STATUS.md}"
}

mkdir -p "$T/proj/.claude" "$T/proj/docs" "$T/proj/sub/dir" "$T/none/a" "$T/big"
echo docs/STATUS.md > "$T/proj/.claude/brain"; printf '# STATUS\nhello\n' > "$T/proj/docs/STATUS.md"
reg proj "$T/proj/docs"

out=$(echo "{\"cwd\": \"$T/none/a\", \"source\": \"startup\"}" | CD_BRAIN=proj hook); rc=$?
[ $rc = 0 ] && printf '%s' "$out" | grep -q hello \
  && printf '%s\n' "$out" | tail -n 1 | grep -qF "loaded from $T/proj/docs/STATUS.md" \
  && ok "hook: CD_BRAIN=proj, session in any folder, prints STATUS + final line" || no "hook CD_BRAIN"

out=$(echo "{\"cwd\": \"$T/proj/sub/dir\", \"source\": \"startup\"}" | hook); rc=$?
[ $rc = 0 ] && ! printf '%s' "$out" | grep -q hello && [ "$(printf '%s\n' "$out" | grep -c '')" = 1 ] \
  && printf '%s' "$out" | grep -q "^No brain attached" \
  && ok "hook: no brain chosen, inside a folder with a .claude/brain pointer -> the one-line hint, exit 0" \
  || no "hook no brain"

out=$(cd "$T/none" && echo '{bad json' | CD_BRAIN=proj hook); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && ok "hook: malformed JSON -> no output, exit 0" || no "hook malformed"

head -c 12000 /dev/zero | tr '\0' 'x' > "$T/big/STATUS.md"; reg big "$T/big"
out=$(echo "{\"cwd\": \"$T/big\"}" | CD_BRAIN=big hook)
printf '%s\n' "$out" | grep -q '^\[STATUS.md is 12,000 characters, over the 9,000 limit, so only the first 9,000 are shown here' && [ ${#out} -lt 10000 ] \
  && ok "hook: oversized STATUS cut to 9,000 characters + trim line (total ${#out} chars)" || no "hook oversized"

reg abs "$T/proj" "$T/proj/docs/STATUS.md"
out=$(echo "{\"cwd\": \"$T/none\"}" | CD_BRAIN=abs hook)
! printf '%s' "$out" | grep -q hello && printf '%s' "$out" | grep -qF 'brain "abs"' \
  && ok "hook: a registered STATUS named by an absolute path is refused with a warning" || no "hook absolute status"

start=$(python3 -c 'import time; print(time.time())')
for i in 1 2 3 4 5 6 7 8 9 10; do echo "{\"cwd\": \"$T/proj/sub/dir\"}" | CD_BRAIN=proj hook >/dev/null; done
ms=$(python3 -c "import time; print(int((time.time() - $start) * 100))")
# Hang check only (the hook usually takes tens of ms); the limit is loose so slow machines pass.
[ "$ms" -lt 1000 ] && ok "hook: ~${ms} ms per run (limit 1000)" || no "hook slow ${ms} ms per run"

mkdir -p "$T/init"; bash "$I" "$T/init" >/dev/null; echo edit >> "$T/init/STATUS.md"
a=$(sum "$T/init/STATUS.md" "$T/init/00-Project-Overview.md" "$T/init/.claude/brain")
out=$(bash "$I" "$T/init"); b=$(sum "$T/init/STATUS.md" "$T/init/00-Project-Overview.md" "$T/init/.claude/brain")
[ "$a" = "$b" ] && [ "$(printf '%s\n' "$out" | grep -c 'exists, left untouched')" = 3 ] && [ "$(printf '%s\n' "$out" | wc -l)" -eq 6 ] \
  && ok "init-brain: second run overwrote nothing, reported 3x 'exists', 6-line summary" || no "init-brain rerun"

reg init "$T/init"
out=$(echo "{\"cwd\": \"$T/none\"}" | CD_BRAIN=init hook | tail -n 1)
printf '%s' "$out" | grep -qF "$T/init/STATUS.md" && ok "init-brain + hook: the brain it set up loads once registered" || no "init+hook"

mkdir -p "$T/init2"; bash "$I" "$T/init2" notes/STATUS.md >/dev/null; reg init2 "$T/init2/notes"
[ -f "$T/init2/notes/STATUS.md" ] && [ -f "$T/init2/notes/00-Project-Overview.md" ] \
  && echo "{\"cwd\": \"$T/init2\"}" | CD_BRAIN=init2 hook | tail -n 1 | grep -qF "$T/init2/notes/STATUS.md" \
  && ok "init-brain: custom STATUS path, overview beside it, the hook loads it" || no "init-brain custom path"

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
