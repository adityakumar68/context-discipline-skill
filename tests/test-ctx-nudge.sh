#!/usr/bin/env bash
# Tests for ctx-nudge.sh (UserPromptSubmit hook): when the session has a brain it measures its context from the
# transcript and, at 40% of the window and every further 15%, adds a short note (additionalContext) asking
# Claude to update STATUS at the next natural break. Once per step per session; never blocks.
# Usage: bash tests/test-ctx-nudge.sh
# Self-contained: works in a mktemp folder with HOME and TMPDIR pointed into it, so nothing outside it is read or
# written.

set -u
unset CD_BRAIN CD_HOOKS CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR   # no brain choice from the calling window
S=$(cd "$(dirname "$0")/../context-discipline/scripts" && pwd -P)
N="$S/ctx-nudge.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/cd-tests.XXXXXX") && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
T=$(cd "$T" && pwd -P) || exit 1    # resolve symlinks (macOS /var -> /private/var) so paths compare equal
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name"; fi; }

HM="$T/home"; TS="$T/tmp"; mkdir -p "$HM/.claude" "$TS"
P="$HM/p"; mkdir -p "$P/.claude" "$P/docs" "$P/src"
printf '# STATUS\n' > "$P/docs/STATUS.md"; echo docs/STATUS.md > "$P/.claude/brain"   # an old pointer: never read
# regset [<name> <dir>]...: the registry holds brain p (folder $P/docs) and the brains given, each STATUS.md.
regset() {
  python3 -I -c 'import json, sys
r = ["p", sys.argv[2]] + sys.argv[3:]
json.dump({"version": 2, "brains": {r[i]: {"dir": r[i + 1], "status": "STATUS.md"} for i in range(0, len(r), 2)}},
          open(sys.argv[1], "w"))' "$HM/.claude/brains.json" "$P/docs" "$@"
}
regset
TR="$T/tr"; mkdir -p "$TR"

# gen <file> <record>...: write a transcript, one compact JSON line per record (as Claude Code writes them).
#   a:<ctx>[:<model>[:<requestedModel>]]   main-thread assistant call (default model claude-opus-4-6, a 200K model)
#   s:<ctx>     subagent (isSidechain) call         syn:<ctx>   "<synthetic>" notice      z   zero-usage record
#   d:<ctx>     one call saved as 3 records with the same message id
#   p:<ctx>:<uuid>  call with a fixed uuid          b:<uuid>[:<uuid>,...]  compact boundary, preserving those uuids
#   u           user record                         big:<bytes>  user record with a large tool result
#   bad         a line that is not JSON             cut         a truncated last line
#   cutb:<uuid> a compact boundary still being written (its first 40 bytes, no newline: must be last)
#   e:<path>    main-thread Edit of <path>     se:<path>  the same in a subagent (isSidechain)
#   bash:<path> main-thread Bash command that names <path>
gen() {
  python3 -I - "$@" <<'PY'
import json, sys
out, n, lines = sys.argv[1], [0], []
def call(ctx, model="claude-opus-4-6", req=None, side=False, uuid=None, mid=None):
    n[0] += 1
    r = {"parentUuid": None, "isSidechain": side, "type": "assistant", "uuid": uuid or f"u{n[0]}",
         "timestamp": "2026-10-11T10:00:00.000Z", "sessionId": "s",
         "message": {"id": mid or f"msg_{n[0]}", "type": "message", "role": "assistant", "model": model,
                     "content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn",
                     "usage": {"input_tokens": 10, "cache_creation_input_tokens": 0,
                               "cache_read_input_tokens": ctx - 10, "output_tokens": 5}}}
    if req:
        r["requestedModel"] = req
    return json.dumps(r, separators=(",", ":"))
for spec in sys.argv[2:]:
    k, *a = spec.split(":")
    if k == "a":
        lines.append(call(int(a[0]), *(a[1:3])))
    elif k == "s":
        lines.append(call(int(a[0]), side=True))
    elif k == "syn":
        lines.append(call(int(a[0]), model="<synthetic>"))
    elif k == "z":
        lines.append(call(10).replace('"input_tokens":10', '"input_tokens":0'))
    elif k == "d":
        lines += [call(int(a[0]), mid="msg_same")] * 3
    elif k == "p":
        lines.append(call(int(a[0]), uuid=a[1]))
    elif k in ("b", "cutb"):
        kept = a[1].split(",") if len(a) > 1 else []
        b = json.dumps({"type": "system", "subtype": "compact_boundary", "uuid": a[0], "isSidechain": False,
                        "compactMetadata": {"trigger": "auto", "preTokens": 1, "postTokens": 1,
                                            "preservedMessages": {"uuids": kept}}}, separators=(",", ":"))
        lines.append(b if k == "b" else b[:40])
    elif k == "u":
        lines.append(json.dumps({"type": "user", "isSidechain": False, "message": {"role": "user", "content": "hi"}}))
    elif k == "big":
        lines.append(json.dumps({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t", "content": "x" * int(a[0])}]}}))
    elif k == "bad":
        lines.append("{not json")
    elif k == "cut":
        lines.append(call(150000)[:60])
    elif k in ("e", "se", "bash"):
        r = json.loads(call(1000, side=(k == "se")))
        use = {"type": "tool_use", "id": "t%d" % n[0], "name": "Edit",
               "input": {"file_path": a[0], "old_string": "x", "new_string": "y"}}
        if k == "bash":
            use.update(name="Bash", input={"command": "sed -i '' 's/a/b/' " + a[0]})
        r["message"]["content"] = [use]
        lines.append(json.dumps(r, separators=(",", ":")))
with open(out, "w") as f:
    f.write("\n".join(lines) + ("" if sys.argv[-1].split(":")[0] in ("cut", "cutb") else "\n"))
PY
}

# run <cwd> <transcript> <session_id> [VAR=value...]: run the hook with a clean environment and brain p
# (CD_BRAIN=p unless overridden). Sets out and rc.
# Session id "-" leaves the field out; transcript "-" leaves transcript_path out.
run() {
  local cwd="$1" tp="$2" sid="$3"; shift 3
  local in
  in=$(python3 -I -c 'import json, sys
d = {"session_id": sys.argv[3], "transcript_path": sys.argv[2], "cwd": sys.argv[1],
     "hook_event_name": "UserPromptSubmit", "prompt": "next step please"}
for k in ("session_id", "transcript_path"):
    if d[k] == "-": del d[k]
print(json.dumps(d))' "$cwd" "$tp" "$sid")
  out=$(printf '%s' "$in" | env -u CLAUDE_PROJECT_DIR -u CLAUDE_CONFIG_DIR -u CD_CTX_WINDOW \
    -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u CLAUDE_CODE_DISABLE_1M_CONTEXT HOME="$HM" TMPDIR="$TS" CD_BRAIN=p "$@" \
    perl -e 'alarm shift; exec @ARGV' 10 bash "$N" 2>&1)    # a hung hook is killed after 10 s (rc 142)
  rc=$?
}
# note: the additionalContext of the last run ("" if none, or if the output is not the expected JSON).
note() {
  printf '%s' "$out" | python3 -I -c 'import json, sys
try:
    h = json.load(sys.stdin)["hookSpecificOutput"]
    assert h["hookEventName"] == "UserPromptSubmit"
    print(h["additionalContext"])
except Exception:
    pass'
}
has() { printf '%s' "$1" | grep -qF -- "$2"; }
quiet() { [ "$rc" = 0 ] && [ -z "$out" ]; }                 # exit 0, no output
nudged() { [ "$rc" = 0 ] && has "$(note)" "$1"; }            # nudged <text>: exit 0 and the note contains <text>
k=0   # "sess-$((++k))" below is a fresh session id (expanded in this shell, so the count goes up)

# --- the note itself -----------------------------------------------------------------------------------------------
gen "$TR/t40" a:50000 u a:80000; S1="sess-$((++k))"
run "$P/src" "$TR/t40" "$S1"
check "40% of a 200K window: one note, valid UserPromptSubmit JSON" nudged "40%"
n=$(note)
check "note gives the tokens and the window" eval 'has "$n" "80,000" && has "$n" "200,000"'
check "note names the STATUS file by its full path (the session's cwd may be a subfolder)" \
  has "$n" "update $P/docs/STATUS.md,"
check "note asks for STATUS update, handoff note, then /clear or /compact <focus>, not mid-task" \
  eval 'has "$n" "handoff" && has "$n" "/clear" && has "$n" "/compact <focus>" && has "$n" "mid-task"'
check "note is 2 to 4 lines" eval 'l=$(printf "%s\n" "$n" | grep -c ""); [ "$l" -ge 2 ] && [ "$l" -le 4 ]'
check "never blocks: no decision field in the output" eval '! has "$out" "decision"'

# --- thresholds: first at 40%, then every further 15%, once per step per session ------------------------------------
gen "$TR/t" a:79999; S2="sess-$((++k))"; run "$P" "$TR/t" "$S2"
check "39.99%: no note" quiet
gen "$TR/t" a:80000; run "$P" "$TR/t" "$S2"
check "40.00%: note" nudged "40%"
gen "$TR/t" a:85000; run "$P" "$TR/t" "$S2"
check "42% in the same session: no second note for the same step" quiet
gen "$TR/t" a:109999; run "$P" "$TR/t" "$S2"
check "54.99%: still no note" quiet
gen "$TR/t" a:110000; run "$P" "$TR/t" "$S2"
check "55%: the next step's note" nudged "55%"
gen "$TR/t" a:190000; run "$P" "$TR/t" "$S2"
check "jump to 95%: one note (not one per skipped step)" nudged "95%"
gen "$TR/t" a:199000; run "$P" "$TR/t" "$S2"
check "99% (same step as 95%): no note" quiet
gen "$TR/t" a:60000; run "$P" "$TR/t" "$S2"
gen "$TR/t" a:85000; run "$P" "$TR/t" "$S2"
check "context falls (no compaction) and rises again: no repeat note" quiet
gen "$TR/t" a:85000; run "$P" "$TR/t" "sess-$((++k))"
check "another session at 42%: its own note" nudged "42%"

# --- compactions ---------------------------------------------------------------------------------------------------
S3="sess-$((++k))"; gen "$TR/c" a:150000; run "$P" "$TR/c" "$S3"
check "before a compaction: note at 75%" nudged "75%"
gen "$TR/c" a:150000 b:B1 u; run "$P" "$TR/c" "$S3"
check "compaction after the last call (context not measured yet): no note" quiet
gen "$TR/c" a:150000 b:B1:K1 p:160000:K1 u; run "$P" "$TR/c" "$S3"
check "records a compaction carried over (preservedMessages) do not count as the current context" quiet
gen "$TR/c" a:150000 b:B1:K1 p:160000:K1 u a:30000 u a:82000; run "$P" "$TR/c" "$S3"
check "after a compaction the steps start again: note at 41%" nudged "41%"
gen "$TR/c" a:150000 b:B1:K1 p:160000:K1 u a:30000 u a:84000; run "$P" "$TR/c" "$S3"
check "and only once for that step" quiet
# The compaction is found among everything written since the previous prompt, not only in the last 256 KB:
# an auto-compaction can happen mid-turn, and the rest of the turn can write more than that.
S4="sess-$((++k))"; gen "$TR/c4" a:150000; run "$P" "$TR/c4" "$S4"
gen "$TR/c4" a:150000 b:B4 a:30000 big:400000 a:82000; run "$P" "$TR/c4" "$S4"
check "compaction 400 KB before the prompt (a long turn after it): the steps start again, note at 41%" nudged "41%"
gen "$TR/c4" a:150000 b:B4 a:30000 big:400000 a:82000 u a:84000; run "$P" "$TR/c4" "$S4"
check "and the next prompt in that step: no repeat" quiet
# A compaction from before the previous prompt, first seen now because a large record pushed the last call out of
# the first read, is not a new compaction.
S5="sess-$((++k))"; gen "$TR/c5" a:150000 b:B5 a:30000 big:300000 a:82000; run "$P" "$TR/c5" "$S5"
check "first prompt of a session, compaction 300 KB back: note at 41%" nudged "41%"
gen "$TR/c5" a:150000 b:B5 a:30000 big:300000 a:82000 big:500000; run "$P" "$TR/c5" "$S5"
check "an old compaction seen for the first time is not a new one: no repeat note" quiet
# A boundary still being written at the previous prompt is not skipped when it is complete.
S6="sess-$((++k))"; gen "$TR/c6" a:150000 cutb:B6; run "$P" "$TR/c6" "$S6"
check "boundary half-written at a prompt: note for the call before it (75%)" nudged "75%"
gen "$TR/c6" a:150000 b:B6 u a:82000; run "$P" "$TR/c6" "$S6"
check "that boundary, complete at the next prompt, starts the steps again: note at 41%" nudged "41%"
# More than 16 MB written since the previous prompt is not all searched (the hook must stay fast); then a context
# that has fallen since the previous prompt counts as a compaction. Finite 17 MB files, no endless source.
S7="sess-$((++k))"; gen "$TR/c7" a:150000; run "$P" "$TR/c7" "$S7"
gen "$TR/c7" a:150000 b:B7 big:17000000 a:82000; run "$P" "$TR/c7" "$S7"
check "compaction 17 MB before the prompt (beyond the search): context fell, so the steps start again (41%)" \
  nudged "41%"
S8="sess-$((++k))"; gen "$TR/c8" a:150000; run "$P" "$TR/c8" "$S8"
gen "$TR/c8" a:150000 big:17000000 a:160000; run "$P" "$TR/c8" "$S8"
check "17 MB written, no compaction, context rose (80%): no repeat note" quiet
rm -f "$TR/c7" "$TR/c8"

# --- which records count --------------------------------------------------------------------------------------------
gen "$TR/r" a:10000 s:150000; run "$P" "$TR/r" "sess-$((++k))"
check "subagent (isSidechain) records are ignored" quiet
gen "$TR/r" a:10000 syn:150000; run "$P" "$TR/r" "sess-$((++k))"
check "<synthetic> records are ignored" quiet
gen "$TR/r" a:80000 z; run "$P" "$TR/r" "sess-$((++k))"
check "zero-usage records are skipped: the call before them counts" nudged "80,000"
gen "$TR/r" a:10000 d:80000; run "$P" "$TR/r" "sess-$((++k))"
check "one call saved as 3 records (same message id) counts once: 80,000, not 240,000" \
  eval 'nudged "80,000" && ! has "$(note)" "240,000"'
gen "$TR/r" a:80000 big:700000; run "$P" "$TR/r" "sess-$((++k))"
check "last call is behind a 700 KB record (past the first tail read): still found" nudged "80,000"

# --- window resolution: CD_CTX_WINDOW > auto-compact env > settings > model > 200,000 -----------------------------
gen "$TR/w" a:45000; run "$P" "$TR/w" "sess-$((++k))" CD_CTX_WINDOW=100000
check "CD_CTX_WINDOW=100000: 45,000 tokens is 45%" eval 'nudged "45%" && has "$(note)" "100,000"'
gen "$TR/w" a:50000; run "$P" "$TR/w" "sess-$((++k))" CD_CTX_WINDOW=200000 CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000
check "CD_CTX_WINDOW wins over CLAUDE_CODE_AUTO_COMPACT_WINDOW" quiet
run "$P" "$TR/w" "sess-$((++k))" CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000
check "CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000 on a 200K model: 50%" nudged "50%"
gen "$TR/w" a:120000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))" CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000
check "CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000 on a 1M model: 40% of 300,000" eval 'nudged "40%" && has "$(note)" "300,000"'
gen "$TR/w" a:80000; run "$P" "$TR/w" "sess-$((++k))" CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000
check "auto-compact window above the model's window is capped at it (200,000)" eval 'nudged "40%" && has "$(note)" "200,000"'
gen "$TR/w" a:40000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))" CLAUDE_CODE_AUTO_COMPACT_WINDOW=50000
check "auto-compact window below 100,000 is raised to 100,000 (as Claude Code does)" eval 'nudged "40%" && has "$(note)" "100,000"'
gen "$TR/w" a:400000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))" CLAUDE_CODE_AUTO_COMPACT_WINDOW=500k
check "CLAUDE_CODE_AUTO_COMPACT_WINDOW that is not a plain number is ignored (model window)" \
  eval 'nudged "40%" && has "$(note)" "1,000,000"'

US="$HM/.claude/settings.json"; mkdir -p "$HM/.claude"
echo '{"autoCompactWindow": 400000}' > "$US"
gen "$TR/w" a:160000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))"
check "autoCompactWindow in user settings: 40% of 400,000" eval 'nudged "40%" && has "$(note)" "400,000"'
run "$P" "$TR/w" "sess-$((++k))" CLAUDE_CODE_AUTO_COMPACT_WINDOW=800000
check "CLAUDE_CODE_AUTO_COMPACT_WINDOW wins over the setting" quiet
echo '{"autoCompactWindow": 400000, "modelSettings": {"claude-opus-5-5": {"autoCompactWindow": 320000}}}' > "$US"
gen "$TR/w" a:128000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))"
check "modelSettings.<model>.autoCompactWindow wins over the top-level key" eval 'nudged "40%" && has "$(note)" "320,000"'
echo '{"modelSettings": {"claude-opus-5-5": {"autoCompactWindow": "auto"}}, "autoCompactWindow": 200000}' > "$US"
gen "$TR/w" a:400000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))"
check "\"auto\" for the model means the model's own window" eval 'nudged "40%" && has "$(note)" "1,000,000"'
echo '{"autoCompactWindow": 400000}' > "$US"; echo '{"autoCompactWindow": 250000}' > "$P/.claude/settings.local.json"
gen "$TR/w" a:100000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))"
check "project settings.local.json wins over user settings" eval 'nudged "40%" && has "$(note)" "250,000"'
echo '{"autoCompactWindow": 500000}' > "$P/.claude/settings.json"
gen "$TR/w" a:100000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))"
check "project settings.local.json wins over project settings.json" eval 'nudged "40%" && has "$(note)" "250,000"'
rm -f "$P/.claude/settings.local.json"
gen "$TR/w" a:200000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))"
check "project settings.json wins over user settings" eval 'nudged "40%" && has "$(note)" "500,000"'
rm -f "$P/.claude/settings.json" "$US"
mkdir -p "$T/cfg"; echo '{"autoCompactWindow": 600000}' > "$T/cfg/settings.json"; cp "$HM/.claude/brains.json" "$T/cfg/"
gen "$TR/w" a:240000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))" CLAUDE_CONFIG_DIR="$T/cfg"
check "user settings are read from \$CLAUDE_CONFIG_DIR when it is set" eval 'nudged "40%" && has "$(note)" "600,000"'
echo '{"autoCompactWindow": ' > "$HM/.claude/settings.json"
gen "$TR/w" a:400000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))"
check "unreadable settings.json is skipped (model window)" eval 'nudged "40%" && has "$(note)" "1,000,000"'
rm -f "$HM/.claude/settings.json"
# A hostile project must not be able to hang the hook or exhaust memory through its settings files: only
# regular files up to 1 MB are read. (A settings.json symlinked to /dev/zero once made an unguarded version
# allocate memory until the machine froze; the FIFO case below takes the same "not a regular file" path
# without that risk, so /dev/zero itself is deliberately not used here.)
mkfifo "$P/.claude/settings.json"
gen "$TR/w" a:400000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))"
check "project settings.json that is a FIFO is skipped, no hang (model window)" \
  eval 'nudged "40%" && has "$(note)" "1,000,000"'
rm -f "$P/.claude/settings.json"
python3 -I -c 'import sys; open(sys.argv[1], "w").write("{\"autoCompactWindow\": 500000}" + " " * 2000000)' \
  "$P/.claude/settings.json"
gen "$TR/w" a:400000:claude-opus-5-5; run "$P" "$TR/w" "sess-$((++k))"
check "project settings.json over 1 MB is skipped (model window)" eval 'nudged "40%" && has "$(note)" "1,000,000"'
rm -f "$P/.claude/settings.json"

# model windows (no window configured anywhere)
for m in claude-opus-5-5 claude-opus-4-7 claude-sonnet-5 claude-haiku-5-5 claude-fable-5-1 us.anthropic.claude-opus-4-8-v1:0; do
  gen "$TR/m" "a:400000:$m"; run "$P" "$TR/m" "sess-$((++k))"
  check "model $m: 1M window (40% at 400,000)" eval 'nudged "40%" && has "$(note)" "1,000,000"'
done
for m in claude-opus-4-6 claude-sonnet-4-6 claude-haiku-4-5-20251001 claude-opus-4-1-20250805 some-other-model; do
  gen "$TR/m" "a:80000:$m"; run "$P" "$TR/m" "sess-$((++k))"
  check "model $m: 200K window (40% at 80,000)" eval 'nudged "40%" && has "$(note)" "200,000"'
done
gen "$TR/m" "a:400000:claude-opus-4-6:claude-opus-4-6[1m]"; run "$P" "$TR/m" "sess-$((++k))"
check "requestedModel with [1m]: 1M window" eval 'nudged "40%" && has "$(note)" "1,000,000"'
gen "$TR/m" "a:80000:claude-opus-5-5"; run "$P" "$TR/m" "sess-$((++k))" CLAUDE_CODE_DISABLE_1M_CONTEXT=1
check "CLAUDE_CODE_DISABLE_1M_CONTEXT=1: a 1M model counts as 200K" eval 'nudged "40%" && has "$(note)" "200,000"'
gen "$TR/m" "a:450000:claude-opus-4-6"; run "$P" "$TR/m" "sess-$((++k))"
check "context above the guessed 200K window: the window must be 1M (45%)" eval 'nudged "45%" && has "$(note)" "1,000,000"'

# --- no note without a brain, and bad input never breaks anything ---------------------------------------------------
mkdir -p "$HM/plain/x"; gen "$TR/x" a:150000
run "$HM/plain/x" "$TR/x" "sess-$((++k))" CD_BRAIN=
check "no brain chosen: no output even at 75%" quiet
run "$P/src" "$TR/x" "sess-$((++k))" CD_BRAIN=
check "no brain chosen, inside a folder with an old .claude/brain pointer: no output" quiet
run "$P" "$TR/x" "sess-$((++k))" CD_HOOKS=off
check "CD_HOOKS=off: no output even at 75% with a brain" quiet
regset gone "$HM/gone"
run "$HM/plain/x" "$TR/x" "sess-$((++k))" CD_BRAIN=gone
check "a brain the SessionStart hook refuses (its folder is gone): no output" quiet
regset

# --- the brain, as the SessionStart hook picks it (brain-lib.sh's cd_select_brain) ---------------------------------
NB="$HM/named"; mkdir -p "$NB"; echo s > "$NB/STATUS.md"
regset nb "$NB"
run "$HM/plain/x" "$TR/x" "sess-$((++k))" CD_BRAIN=nb
check "CD_BRAIN=nb, session in a plain folder: the note names nb's STATUS" \
  eval 'nudged "75%" && has "$(note)" "update $NB/STATUS.md,"'
run "$P/src" "$TR/x" "sess-$((++k))" CD_BRAIN=none
check "CD_BRAIN=none: no output" quiet
run "$P/src" "$TR/x" "sess-$((++k))" CD_BRAIN=nope
check "CD_BRAIN names an unregistered brain: no output" quiet
mkdir -p "$HM/.claude/brain-sessions"; printf 'none\n\n' > "$HM/.claude/brain-sessions/pid-$$"
run "$P/src" "$TR/x" "sess-$((++k))" CLAUDE_PID=$$ CD_BRAIN=nb
check "/brain none in this window: no output, even with CD_BRAIN set" quiet
printf 'nb\n\n' > "$HM/.claude/brain-sessions/pid-$$"
run "$P/src" "$TR/x" "sess-$((++k))" CLAUDE_PID=$$
check "/brain nb in this window (CD_BRAIN=p too): the note names nb's STATUS" \
  eval 'nudged "75%" && has "$(note)" "update $NB/STATUS.md,"'
rm -rf "$HM/.claude/brain-sessions"; regset
gen "$TR/g" bad a:80000 bad u cut; run "$P" "$TR/g" "sess-$((++k))"
check "malformed lines and a truncated last line: the last good call counts" nudged "40%"
printf '' > "$TR/empty"; run "$P" "$TR/empty" "sess-$((++k))"
check "empty transcript: exit 0, no output" quiet
run "$P" "$TR/no-such-file" "sess-$((++k))"
check "missing transcript file: exit 0, no output" quiet
run "$P" - "sess-$((++k))"
check "no transcript_path field: exit 0, no output" quiet
gen "$TR/ns" a:80000; run "$P" "$TR/ns" -
check "no session_id: still one note (state kept per transcript)" nudged "40%"
run "$P" "$TR/ns" -
check "no session_id, second prompt: no repeat" quiet
out=$(cd "$P" && printf '{bad json' | env -u CLAUDE_PROJECT_DIR HOME="$HM" TMPDIR="$TS" bash "$N" 2>&1); rc=$?
check "malformed hook input: exit 0, no output" quiet
gen "$TR/l" a:80000; mkdir -p "$T/elsewhere"; TS2="$T/tmp2"; mkdir -p "$TS2"; ln -s "$T/elsewhere" "$TS2/context-discipline"
out=$(python3 -I -c 'import json,sys; print(json.dumps({"session_id": "x", "transcript_path": sys.argv[1], "cwd": sys.argv[2]}))' "$TR/l" "$P" \
  | env -u CLAUDE_PROJECT_DIR -u CD_CTX_WINDOW -u CLAUDE_CODE_AUTO_COMPACT_WINDOW HOME="$HM" TMPDIR="$TS2" CD_BRAIN=p \
  bash "$N" 2>&1); rc=$?
check "state folder is a symlink: no note, nothing written through it" eval 'quiet && [ -z "$(ls -A "$T/elsewhere")" ]'

# --- STATUS updated by another session: one note, once per change -----------------------------------------------
# The window's record (<config>/brain-sessions/seen-<window key>) is written by the SessionStart hook when it prints
# STATUS, and by this hook when it notes a change.
H="$S/brain-hook.sh"; ST="$P/docs/STATUS.md"; SEEN="$HM/.claude/brain-sessions/seen-pid-$$"
rm -rf "$HM/.claude/brain-sessions"
start_hook() { printf '{"session_id": "w1", "source": "%s"}' "${1:-startup}" | env HOME="$HM" CD_BRAIN=p CLAUDE_PID=$$ bash "$H" >/dev/null 2>&1; }
later() { python3 -I -c 'import os, sys; t = os.stat(sys.argv[1]).st_mtime + int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$ST" "${1:-10}"; }
stale() { has "$(note)" "was updated since this session last read it"; }
start_hook
check "SessionStart with a brain: records the STATUS it printed for this window (path, mtime, size)" \
  eval '[ "$(head -n 1 "$SEEN")" = "$ST" ] && [ "$(sed -n 2p "$SEEN")" = "$(python3 -I -c "import os, sys; s = os.stat(sys.argv[1]); print(int(s.st_mtime), s.st_size)" "$ST")" ]'
gen "$TR/s" a:1000; W="sess-$((++k))"
run "$P" "$TR/s" "$W" CLAUDE_PID=$$
check "STATUS unchanged since it was loaded: no note" quiet
printf 'line from another session\n' >> "$ST"; later
run "$P" "$TR/s" "$W" CLAUDE_PID=$$
check "STATUS changed by another session: one note naming the brain and the file, to re-read it before relying on it or editing it" \
  eval 'stale && has "$(note)" "STATUS.md of brain \"p\" ($ST)" && has "$(note)" "probably by another session" && has "$(note)" "re-read it before relying on it or editing it"'
run "$P" "$TR/s" "$W" CLAUDE_PID=$$
check "next prompt, no further change: no repeat" quiet
later 20; run "$P" "$TR/s" "$W" CLAUDE_PID=$$
check "changed again: noted again" stale
gen "$TR/s" a:1000 u "e:$ST"; later 30; run "$P" "$TR/s" "$W" CLAUDE_PID=$$
check "changed by this session's own Edit since the previous prompt: no note" quiet
run "$P" "$TR/s" "$W" CLAUDE_PID=$$
check "... and the record now holds that version (no note on the next prompt either)" quiet
gen "$TR/s" a:1000 u "e:$ST" u "bash:$ST"; later 40; run "$P" "$TR/s" "$W" CLAUDE_PID=$$
check "changed by this session's own Bash command naming STATUS: no note" quiet
gen "$TR/s" a:1000 u "e:$ST" u "bash:$ST" u "se:$ST"; later 50; run "$P" "$TR/s" "$W" CLAUDE_PID=$$
check "changed by a subagent's Edit (it did not read it into this session): noted" stale
gen "$TR/s" a:1000 u "e:$ST" u "bash:$ST" u "se:$ST" u "e:$P/docs/OTHER.md"; later 60; run "$P" "$TR/s" "$W" CLAUDE_PID=$$
check "an own Edit of another file does not hide the change: noted" stale
later 70; run "$P" - "$W" CLAUDE_PID=$$
check "no transcript_path in the input: the change is still noted" stale
later 80; gen "$TR/s2" a:150000; run "$P" "$TR/s2" "sess-$((++k))" CLAUDE_PID=$$
check "change and a context step at the same prompt: both notes in one additionalContext" \
  eval 'stale && nudged "75%" && [ "$(printf "%s" "$out" | grep -c additionalContext)" = 1 ]'
rm -f "$SEEN"; later 90; run "$P" "$TR/s" "$W" CLAUDE_PID=$$
check "no record for this window yet (installed mid-session): no note, the record is written" \
  eval 'quiet && [ "$(head -n 1 "$SEEN")" = "$ST" ]'
regset q "$HM/qq"; mkdir -p "$HM/qq"; echo q > "$HM/qq/STATUS.md"
run "$P" "$TR/s" "$W" CLAUDE_PID=$$ CD_BRAIN=q
check "the window's brain is another one than its record names: no note, the record follows the brain" \
  eval 'quiet && [ "$(head -n 1 "$SEEN")" = "$HM/qq/STATUS.md" ]'
regset
cp "$SEEN" "$T/seen.before"
run "$P" "$TR/s" "$W" CLAUDE_PID=$$ CD_BRAIN=
check "no brain: no note, no record written" eval 'quiet && cmp -s "$SEEN" "$T/seen.before"'
rm -f "$SEEN"; mkfifo "$SEEN"; later 100
run "$P" "$TR/s" "$W" CLAUDE_PID=$$
check "record that is a FIFO: no hang, no note, left alone" eval 'quiet && [ -p "$SEEN" ]'
rm -f "$SEEN"; start_hook; rm -rf "$HM/.claude/brain-sessions"; mkdir -p "$T/elsewhere2"
ln -s "$T/elsewhere2" "$HM/.claude/brain-sessions"; later 110
run "$P" "$TR/s" "$W" CLAUDE_PID=$$
check "brain-sessions is a symlink: nothing written through it, no note" eval 'quiet && [ -z "$(ls -A "$T/elsewhere2")" ]'
rm -f "$HM/.claude/brain-sessions"
start=$(python3 -c 'import time; print(time.time())')
for i in 1 2 3 4 5; do run "$P" "$TR/s" "$W" CLAUDE_PID=$$; done
ms=$(python3 -c "import time; print(int((time.time() - $start) * 200))")
check "with a brain and an unchanged STATUS: ~${ms} ms per prompt (limit 500)" eval '[ "$ms" -lt 500 ]'
rm -rf "$HM/.claude/brain-sessions"

# --- speed: a 60 MB transcript --------------------------------------------------------------------------------------
python3 -I - "$TR/huge" <<'PY'
import json, sys
call = json.dumps({"type": "assistant", "isSidechain": False, "uuid": "u", "message": {"id": "m", "model": "claude-opus-4-6",
       "usage": {"input_tokens": 10, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 89990}}}, separators=(",", ":"))
user = json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "content": "y" * 20000}]}})
with open(sys.argv[1], "w") as f:
    for i in range(3000):
        f.write(call.replace('"m"', '"m%d"' % i) + "\n" + user + "\n")
PY
start=$(python3 -c 'import time; print(time.time())')
for i in 1 2 3 4 5; do run "$P" "$TR/huge" "sess-$((++k))"; done
ms=$(python3 -c "import time; print(int((time.time() - $start) * 200))")
check "60 MB transcript: note found, ~${ms} ms per run (limit 500)" eval 'nudged "45%" && [ "$ms" -lt 500 ]'

echo "== ctx-nudge tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
