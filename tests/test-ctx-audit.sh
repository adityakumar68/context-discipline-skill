#!/usr/bin/env bash
# Checks ctx-audit.py against the small synthetic transcripts in tests/fixtures/ctx-audit/.
# Usage: bash tests/test-ctx-audit.sh
# The fixture numbers are chosen so each expected value can be checked by hand:
#   proj/s1.jsonl  main thread. Starts the way a file continued from a compaction does (boundary, summary, and a
#                  copied pre-compaction record that is not a new call). Then 7 API calls, contexts
#                  20,010 23,012 24,014 24,516 | compaction | 6,002 9,004 6,502. Call m1 is stored as two records
#                  (one per content block) with a partial then a final output count; one <synthetic> record.
#   proj/s1/subagents/agent-a1.jsonl      general-purpose subagent, contexts 8,003 9,006.
#   proj/s1/subagents/agent-a0fork.jsonl  fork of a1: copies a1's first call (same message id), then 8,506.
#   inline-sidechain.jsonl  older layout: subagent records inline in the main file.

set -u
here=$(cd "$(dirname "$0")" && pwd -P)
A="$here/../context-discipline/scripts/ctx-audit.py"
F="$here/fixtures/ctx-audit"
T=$(mktemp -d "${TMPDIR:-/tmp}/cd-tests.XXXXXX") && [ -d "$T" ] || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }

# check NAME FILE EXPR: EXPR is a Python expression over d (the parsed --json output); passes when truthy.
check() {
  python3 -I - "$2" "$3" <<'PY' && ok "$1" || no "$1"
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    print("   output is not JSON: " + open(sys.argv[1]).read(200).replace("\n", " | "))
    sys.exit(1)
def row(name, src=None):
    rows = (src or d)["categories"]["rows"]
    return next((r for r in rows if r["category"] == name), None)
def tok(name):
    r = row(name)
    return r["tokens"] if r else None
try:
    good = eval(sys.argv[2])
except Exception as e:
    good = False
    print("   error: %r" % e)
if not good:
    print("   expected: " + sys.argv[2])
sys.exit(0 if good else 1)
PY
}

run() { python3 -I "$A" "$@"; }

run "$F/proj/s1.jsonl" --json > "$T/s1.json" 2> "$T/s1.err"; rc=$?
[ $rc = 0 ] && [ ! -s "$T/s1.err" ] && ok "--json: exit 0, nothing on stderr" || no "--json run (rc=$rc)"
check "--json: schema_version 1 and the documented top-level keys" "$T/s1.json" \
  'd["schema_version"] == 1 and set(d) >= {"transcript", "main", "subagents", "combined", "categories"}'

# main thread, measured from usage
check "usage: one call per message id, <synthetic> and the copied pre-compaction record left out" "$T/s1.json" \
  'd["main"]["calls"] == 7'
check "usage: peak context = largest input + cache write + cache read" "$T/s1.json" 'd["main"]["peak_context"] == 24516'
check "usage: total input = sum of context over calls" "$T/s1.json" \
  'd["main"]["total_input"] == 113060 and d["main"]["input_tokens"] == 22 and d["main"]["cache_creation_input_tokens"] == 33500 and d["main"]["cache_read_input_tokens"] == 79538'
check "usage: output counts the final (largest) value of a split message once" "$T/s1.json" \
  'd["main"]["output_tokens"] == 260 and d["main"]["thinking_output_tokens"] == 80'
check "usage: final context is the last call's" "$T/s1.json" 'd["main"]["final_context"] == 6502'
check "compactions: count, context before and after each, recorded pre/post and trigger" "$T/s1.json" \
  'd["main"]["compaction_count"] == 2 and d["main"]["compactions"] == [
     {"context_before": None, "context_after": 20010, "pre_tokens": 90000, "post_tokens": 2000, "trigger": "auto"},
     {"context_before": 24516, "context_after": 6002, "pre_tokens": 24600, "post_tokens": 3000, "trigger": "manual"}]'
check "segments: first, peak and last context between compactions" "$T/s1.json" \
  '[(s["calls"], s["first_context"], s["peak_context"], s["last_context"]) for s in d["main"]["segments"]] == [
     (0, None, None, None), (4, 20010, 24516, 24516), (3, 6002, 9004, 6502)]'
check "context drop without a compaction (tool outputs cleared) is counted" "$T/s1.json" \
  'd["main"]["context_drops"] == 1'

# subagents and combined
check "subagents: files found, fork's copied call counted once and kept with its parent" "$T/s1.json" \
  'sorted((a["id"], a["agent_type"], a["calls"], a["peak_context"]) for a in d["subagents"]["agents"]) == [
     ("agent-a0fork", "fork", 1, 8506), ("agent-a1", "general-purpose", 2, 9006)]'
check "subagents: totals" "$T/s1.json" \
  'd["subagents"]["count"] == 2 and d["subagents"]["calls"] == 3 and d["subagents"]["peak_context"] == 9006 and d["subagents"]["total_input"] == 25515 and d["subagents"]["output_tokens"] == 150'
check "output: calls saved without a stop_reason are flagged as a lower bound" "$T/s1.json" \
  'd["main"]["output_incomplete_calls"] == 0 and d["subagents"]["output_incomplete_calls"] == 1 and d["combined"]["output_incomplete_calls"] == 1'
check "combined: peak is the largest single context, totals are sums" "$T/s1.json" \
  'd["combined"]["calls"] == 10 and d["combined"]["peak_context"] == 24516 and d["combined"]["total_input"] == 138575 and d["combined"]["output_tokens"] == 410 and d["combined"]["compaction_count"] == 2'

# category estimate against the measured context
check "categories: measured context = sum of segment peaks" "$T/s1.json" \
  'd["categories"]["basis"] == "measured" and d["categories"]["measured_context"] == 24516 + 9004'
check "categories: visible estimate + not-in-transcript remainder = measured context" "$T/s1.json" \
  'd["categories"]["visible_estimate"] + d["categories"]["not_in_transcript"] == d["categories"]["measured_context"] and tok("[not in transcript]") == d["categories"]["not_in_transcript"]'
check "categories: thinking output of calls before each segment's peak bounds the thinking in the remainder" "$T/s1.json" \
  'd["categories"]["thinking_before_peaks"] == 80'
check "categories: shares add up to 100%" "$T/s1.json" 'abs(sum(r["share"] for r in d["categories"]["rows"]) - 100) < 0.5'
check "categories: only content sent before each segment's peak call is counted" "$T/s1.json" \
  'tok("Bash output") == 100 and tok("Read output") == 200 and tok("Compaction summary") == 150'
check "categories: preserved messages count again after a compaction" "$T/s1.json" 'tok("Assistant text") == 20'

# directory input, subagent file input, inline sidechains, no usage at all
run "$F/proj" --json > "$T/dir.json" 2>&1
check "directory input: newest top-level .jsonl, with its subagents" "$T/dir.json" \
  'd["transcript"]["file"] == "s1.jsonl" and d["subagents"]["count"] == 2'
run "$F/proj/s1/subagents/agent-a1.jsonl" --json > "$T/sub.json" 2>&1
check "a subagent file given directly is audited as the main thread" "$T/sub.json" \
  'd["main"]["calls"] == 2 and d["main"]["peak_context"] == 9006 and tok("WebSearch output") == 20'
run "$F/inline-sidechain.jsonl" --json > "$T/inl.json" 2>&1
check "inline sidechain records: measured as a subagent, kept out of the category table" "$T/inl.json" \
  'd["main"]["calls"] == 2 and d["main"]["peak_context"] == 5101 and d["subagents"]["count"] == 1 and d["subagents"]["peak_context"] == 3201 and tok("Bash output") is None'
run "$F/inline-sidechain.jsonl" --json --include-sidechains > "$T/inl2.json" 2>&1
check "--include-sidechains: subagent content and peaks join the category table" "$T/inl2.json" \
  'tok("Bash output") == 100 and d["categories"]["measured_context"] == 5101 + 3201'
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"ls"}}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"b1","content":"a long listing of files"}]}}' > "$T/nousage.jsonl"
run "$T/nousage.jsonl" --json > "$T/nu.json" 2>&1
check "no usage records: measured numbers are null, shares are of the visible estimate" "$T/nu.json" \
  'd["main"]["calls"] == 0 and d["main"]["peak_context"] is None and d["categories"]["basis"] == "visible-only" and d["categories"]["not_in_transcript"] is None and d["categories"]["thinking_before_peaks"] is None and tok("Bash output") is not None'

# text report
out=$(run "$F/proj/s1.jsonl" 2>&1)
printf '%s\n' "$out" | grep -q '^Main  *7  *24,516  *113,060  *260  *2$' \
  && printf '%s\n' "$out" | grep -q '^Subagents (2)  *3  *9,006  *25,515  *150  *0$' \
  && printf '%s\n' "$out" | grep -q '^Combined  *10  *24,516  *138,575  *410  *2$' \
  && ok "text: measured table for main, subagents and combined" || no "text measured table"
printf '%s\n' "$out" | grep -q '^\[not in transcript\]' && printf '%s\n' "$out" | grep -q '^Category' \
  && ok "text: category table ranks the not-in-transcript remainder" || no "text remainder row"
printf '%s\n' "$out" | grep -q '24,516 -> 6,002' && ok "text: context before -> after each compaction" || no "text compactions"
printf '%s\n' "$out" | grep -q '^Output is a lower bound: 1 call' && ok "text: says when output is a lower bound" || no "text output lower bound"
grep -q 'until a compaction' "$A" && no "docstring still says content is re-read until a compaction" \
  || ok "docstring: no claim that everything is re-read until a compaction"

# preview redaction: previews that look like credentials are replaced (over-redaction is the safe failure)
# redacted <yes|no> <text>...: preview() redacts each text (yes) or leaves it readable (no).
redacted() {
  python3 -I - "$A" "$@" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ctx_audit", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
want = sys.argv[2] == "yes"
wrong = [t for t in sys.argv[3:] if m.preview(t).startswith("[preview redacted") != want]
for t in wrong:
    print("   wrong: " + t)
sys.exit(1 if wrong else 0)
PY
}
redacted yes "echo 'Tr0ub4dor&3' | sudo -S nvidia-smi" "sudo -kS apt update" "mysql -u root -pHunter2xyz db" \
  "curl http://admin:Hunter2xyz@gpuserver:8080/x" "git clone https://user:Hunter2xyz@example.org/r.git" \
  "curl -u admin:Hunter2xyz https://h/api" \
  && ok "redaction: sudo -S, mysql -p<password>, user:password@ in a URL, curl -u user:password" \
  || no "redaction: sudo -S, mysql -p<password>, user:password@ in a URL, curl -u user:password"
redacted no "ls -la src" "mkdir -p build/out" "grep -Pn foo bar.txt" "ssh -p 2222 host" "https://example.org/docs/a:b" \
  "sudo nvidia-smi" && ok "redaction: ordinary commands and URLs stay readable" \
  || no "redaction: ordinary commands and URLs stay readable"

echo "== ctx-audit tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
