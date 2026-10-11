#!/usr/bin/env bash
# Tests for install.sh. Usage: bash tests/test-install.sh
#
# Every case runs install.sh with HOME set to a throwaway folder from mktemp and CLAUDE_CONFIG_DIR unset
# (or pointed into that folder), so your real ~/.claude is never read or written.
# Prints PASS/FAIL per check and a total; exits non-zero if anything failed.

set -u
unset CD_BRAIN CD_HOOKS CLAUDE_PID CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR   # no brain choice from the calling window
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
INSTALL="$REPO/install.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cd-tests.XXXXXX") && [ -d "$ROOT" ] || { echo "mktemp failed" >&2; exit 1; }
ROOT=$(cd "$ROOT" && pwd -P) || exit 1    # resolve symlinks (macOS /var -> /private/var) so paths compare equal
trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass + 1)); }
no() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else no "$name"; fi; }

new_home() { mktemp -d "$ROOT/home.XXXXXX"; }

# inst <fake-home> [args...]: run install.sh against the fake home only.
inst() {
  local h="$1"; shift
  case "$h" in "$ROOT"/*) ;; *) echo "refusing to run install.sh outside $ROOT" >&2; exit 1 ;; esac
  env -u CLAUDE_CONFIG_DIR HOME="$h" bash "$INSTALL" "$@"
}

# jq_ <settings.json> <python expression> [args...]: true if the expression holds.
# In the expression: d = the parsed file, A = extra args, ours() = [(event, matcher, command)] for the SessionStart
# hook (brain-hook.sh), ours_of(script) the same for any script, all_ours() for all three hooks.
jq_() {
  python3 -I - "$@" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
A = sys.argv[3:]
def ours_of(script):
    M = "context-discipline/scripts/" + script
    return [(ev, e.get("matcher"), h.get("command")) for ev, es in d.get("hooks", {}).items()
            for e in es if isinstance(e, dict) for h in e.get("hooks", []) if M in h.get("command", "")]
def ours():
    return ours_of("brain-hook.sh")
def all_ours():
    return ours_of("brain-hook.sh") + ours_of("compact-log.sh") + ours_of("ctx-nudge.sh")
sys.exit(0 if eval(sys.argv[2]) else 1)
PY
}

# full_settings <settings.json> <SessionStart command>: a settings.json with all three hooks as the installer
# writes them, the SessionStart one running the given command.
full_settings() {
  python3 -I - "$1" "$2" <<'PY'
import json, sys
cmd = lambda s: 'bash "$HOME/.claude/skills/context-discipline/scripts/%s"' % s
json.dump({"hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": sys.argv[2], "timeout": 10}]}],
    "PostCompact": [{"hooks": [{"type": "command", "command": cmd("compact-log.sh"), "timeout": 10}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": cmd("ctx-nudge.sh"), "timeout": 5}]}]}},
    open(sys.argv[1], "w"))
PY
}

# same_json <a> <b>: both files parse to the same JSON value.
same_json() { python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$1" "$2"; }

# tree_sum <path>: one checksum over every path, file content and symlink target below <path> ("absent" if missing).
tree_sum() {
  [ -e "$1" ] || [ -L "$1" ] || { echo absent; return; }
  python3 -I - "$1" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
h = hashlib.sha256()
if os.path.isfile(root):
    h.update(open(root, "rb").read())
for folder, dirs, files in os.walk(root):
    dirs.sort()
    for name in sorted(dirs + files):
        p = os.path.join(folder, name)
        h.update(os.path.relpath(p, root).encode() + b"\0")
        if os.path.islink(p):
            h.update(b"L" + os.readlink(p).encode())
        elif os.path.isfile(p):
            h.update(b"F" + open(p, "rb").read())
        h.update(b"\0")
print(h.hexdigest())
PY
}

same_tree() { diff -r -q -x __pycache__ -x .DS_Store "$1" "$2" >/dev/null 2>&1; }
count() { ls -d $1 2>/dev/null | wc -l | tr -d ' '; }   # count paths matching a glob
md_lines() { grep -c 'context-discipline' "$1" 2>/dev/null || true; }

# --- 1. Fresh home: no ~/.claude at all ----------------------------------------------------------------------
H=$(new_home); C="$H/.claude"
want='bash "$HOME/.claude/skills/context-discipline/scripts/brain-hook.sh"'   # $HOME is expanded by the shell
want_cl='bash "$HOME/.claude/skills/context-discipline/scripts/compact-log.sh"'
want_cn='bash "$HOME/.claude/skills/context-discipline/scripts/ctx-nudge.sh"'
out=$(inst "$H" 2>&1); rc=$?
check "fresh: exit 0" [ "$rc" = 0 ]
check "fresh: skill copied, identical to the repo copy" same_tree "$REPO/context-discipline" "$C/skills/context-discipline"
check "fresh: scripts are executable" [ -x "$C/skills/context-discipline/scripts/brain-hook.sh" ]
check "fresh: settings.json has one SessionStart entry, with no matcher (every source), running the hook, 10-second timeout" \
  jq_ "$C/settings.json" 'd["hooks"]["SessionStart"] == [{"hooks": [{"type": "command", "command": A[0], "timeout": 10}]}]' "$want"
check "fresh: one PostCompact entry, with no matcher (manual and auto), running compact-log.sh, 10-second timeout" \
  jq_ "$C/settings.json" 'd["hooks"]["PostCompact"] == [{"hooks": [{"type": "command", "command": A[0], "timeout": 10}]}]' "$want_cl"
check "fresh: one UserPromptSubmit entry running ctx-nudge.sh, with a 5-second timeout" \
  jq_ "$C/settings.json" 'd["hooks"]["UserPromptSubmit"] == [{"hooks": [{"type": "command", "command": A[0], "timeout": 5}]}]' "$want_cn"
check "fresh: no other hook events or settings keys" jq_ "$C/settings.json" 'list(d) == ["hooks"] and len(d["hooks"]) == 3'
check "fresh: CLAUDE.md created with the line once" [ "$(md_lines "$C/CLAUDE.md")" = 1 ]
check "fresh: no backups made (nothing existed)" eval '[ "$(count "$C/*.bak-*")" = 0 ] && [ ! -e "$C/skill-backups" ]'
check "fresh: summary gives the next steps (/hooks check, init-brain, pipe test)" \
  eval 'printf "%s" "$out" | grep -q "/hooks" && printf "%s" "$out" | grep -q "init-brain.sh" && printf "%s" "$out" | grep -q "Project brain loaded from"'
check "fresh: summary does not claim hooks load only at startup" eval '! printf "%s" "$out" | grep -qi "read at startup"'

# --- 2. Whole chain: the installed brain.sh new + the exact hook commands from settings.json -----------------
P="$H/work/notes-app"; mkdir -p "$P/src/deep"
new_out=$(cd "$H/work" && env -u CLAUDE_CONFIG_DIR HOME="$H" CLAUDE_PID=$$ bash "$C/skills/context-discipline/scripts/brain.sh" new notes --at "$P" 2>&1); rc=$?
check "chain: the installed brain.sh new sets up and registers the brain, with no pointer" \
  eval '[ "$rc" = 0 ] && [ -f "$P/STATUS.md" ] && [ ! -e "$P/.claude" ] && printf "%s" "$new_out" | grep -q "Registered brain \"notes\""'
echo "chain-marker-4711" >> "$P/STATUS.md"
cmd=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print([h["command"] for e in d["hooks"]["SessionStart"] if "matcher" not in e for h in e["hooks"]][0])' "$C/settings.json")
hook_out=$(printf '{"cwd": "%s", "source": "compact"}' "$P/src/deep" | HOME="$H" CD_BRAIN=notes bash -c "$cmd"); rc=$?
check "chain: the settings.json command, with CD_BRAIN=notes, prints STATUS" \
  eval '[ "$rc" = 0 ] && printf "%s" "$hook_out" | grep -q chain-marker-4711'
check "chain: hook output ends with the line naming the STATUS it loaded" \
  eval 'printf "%s\n" "$hook_out" | tail -n 1 | grep -qF "loaded from $P/STATUS.md"'
cmd_of() { python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"][sys.argv[2]][0]["hooks"][0]["command"])' "$C/settings.json" "$1"; }
printf '{"cwd": "%s", "session_id": "chain123", "trigger": "manual", "compact_summary": "chain-summary-4712"}' "$P/src/deep" \
  | env -u CLAUDE_PROJECT_DIR HOME="$H" CD_BRAIN=notes bash -c "$(cmd_of PostCompact)"; rc=$?
check "chain: the PostCompact command saves the summary in <config>/brain-logs/notes/" \
  eval '[ "$rc" = 0 ] && grep -rq chain-summary-4712 "$C/brain-logs/notes"'
check "chain: nothing was written in the brain folder but its two files (no .gitignore, no logs)" \
  eval '[ "$(ls -A "$P" | LC_ALL=C sort | paste -sd, -)" = "00-Project-Overview.md,STATUS.md,src" ]'
printf '%s\n' '{"type":"assistant","isSidechain":false,"uuid":"a","message":{"id":"m","model":"claude-opus-4-6","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":79990}}}' > "$ROOT/chain.jsonl"
mkdir -p "$ROOT/chain-tmp"
nudge_out=$(printf '{"cwd": "%s", "session_id": "chain", "transcript_path": "%s"}' "$P/src/deep" "$ROOT/chain.jsonl" \
  | env -u CLAUDE_PROJECT_DIR -u CD_CTX_WINDOW -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u CLAUDE_CONFIG_DIR HOME="$H" TMPDIR="$ROOT/chain-tmp" CD_BRAIN=notes bash -c "$(cmd_of UserPromptSubmit)"); rc=$?
check "chain: the UserPromptSubmit command adds the context note at 40%" \
  eval '[ "$rc" = 0 ] && printf "%s" "$nudge_out" | grep -q "additionalContext" && printf "%s" "$nudge_out" | grep -q "40%"'

# --- 3. Existing settings.json with other keys and another SessionStart hook; existing CLAUDE.md -------------
H=$(new_home); C="$H/.claude"; mkdir -p "$C"
cat > "$C/settings.json" <<'EOF'
{
  "statusLine": {"type": "command", "command": "echo my-status"},
  "enabledPlugins": {"example-plugin@example-market": true},
  "hooks": {
    "SessionStart": [
      {"matcher": "startup", "hooks": [{"type": "command", "command": "echo other-startup-hook"}]}
    ],
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre-tool"}]}
    ]
  }
}
EOF
printf '# My rules\n\n- Keep answers short.' > "$C/CLAUDE.md"    # no final newline on purpose
cp "$C/settings.json" "$ROOT/orig-settings.json"; cp "$C/CLAUDE.md" "$ROOT/orig-claude.md"
out=$(inst "$H" 2>&1); rc=$?
check "existing: exit 0" [ "$rc" = 0 ]
check "existing: statusLine, enabledPlugins and PreToolUse kept as they were" \
  jq_ "$C/settings.json" 'd["statusLine"] == {"type": "command", "command": "echo my-status"} and d["enabledPlugins"] == {"example-plugin@example-market": True} and d["hooks"]["PreToolUse"] == [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo pre-tool"}]}]'
check "existing: the other SessionStart hook is still there" \
  jq_ "$C/settings.json" 'any(h["command"] == "echo other-startup-hook" for e in d["hooks"]["SessionStart"] for h in e["hooks"])'
check "existing: our hook added once, in an entry with no matcher" jq_ "$C/settings.json" '[m for _, m, _ in ours()] == [None]'
check "existing: settings.json backed up first (backup equals the original)" \
  eval '[ "$(count "$C/settings.json.bak-*")" = 1 ] && cmp -s "$C"/settings.json.bak-* "$ROOT/orig-settings.json"'
check "existing: CLAUDE.md backed up first (backup equals the original)" \
  eval '[ "$(count "$C/CLAUDE.md.bak-*")" = 1 ] && cmp -s "$C"/CLAUDE.md.bak-* "$ROOT/orig-claude.md"'
check "existing: CLAUDE.md keeps its content and gets the line on its own line" \
  eval 'grep -qx -- "- Keep answers short." "$C/CLAUDE.md" && [ "$(tail -n 1 "$C/CLAUDE.md" | grep -c "^- For any work that spans many steps")" = 1 ]'
check "existing: no temp files left behind" [ "$(count "$C/.settings.json.*")" = 0 ]

# --- 4. Running it twice --------------------------------------------------------------------------------------
before=$(tree_sum "$C")
out=$(inst "$H" 2>&1); rc=$?
check "twice: exit 0" [ "$rc" = 0 ]
check "twice: still exactly 1 of each of our 3 hooks (no duplicates)" \
  jq_ "$C/settings.json" 'len(ours()) == 1 and len(ours_of("compact-log.sh")) == 1 and len(ours_of("ctx-nudge.sh")) == 1'
check "twice: CLAUDE.md line still there once" [ "$(md_lines "$C/CLAUDE.md")" = 1 ]
check "twice: second run changed nothing at all (no new backups either)" [ "$before" = "$(tree_sum "$C")" ]
check "twice: summary says every step is unchanged (both skills, settings, CLAUDE.md)" [ "$(printf '%s\n' "$out" | grep -c ': *unchanged')" = 4 ]

# --- 5. --dry-run changes nothing -----------------------------------------------------------------------------
H2=$(new_home)
out=$(inst "$H2" --dry-run 2>&1); rc=$?
check "dry-run (fresh home): exit 0 and ~/.claude is not even created" eval '[ "$rc" = 0 ] && [ ! -e "$H2/.claude" ]'
check "dry-run (fresh home): prints the four planned changes (both skills, settings, CLAUDE.md)" \
  eval '[ "$(printf "%s\n" "$out" | grep -c "would ")" = 4 ] && printf "%s" "$out" | grep -qF "runs: bash"'
names_hooks() { local e; for e in SessionStart PostCompact UserPromptSubmit; do printf '%s' "$out" | grep -q "$e runs: bash" || return 1; done; }
check "dry-run (fresh home): names all three hooks and the commands they run" names_hooks
H3=$(new_home); mkdir -p "$H3/.claude"; cp "$ROOT/orig-settings.json" "$H3/.claude/settings.json"; cp "$ROOT/orig-claude.md" "$H3/.claude/CLAUDE.md"
before=$(tree_sum "$H3")
out=$(inst "$H3" --dry-run 2>&1); rc=$?
check "dry-run (existing settings): exit 0 and checksums identical before/after" eval '[ "$rc" = 0 ] && [ "$before" = "$(tree_sum "$H3")" ]'
before=$(tree_sum "$C")
out=$(inst "$H" --uninstall --dry-run 2>&1); rc=$?
check "dry-run --uninstall: exit 0, plans the removals (both skills too), checksums identical" \
  eval '[ "$rc" = 0 ] && [ "$(printf "%s\n" "$out" | grep -c "would ")" = 4 ] && [ "$before" = "$(tree_sum "$C")" ]'

# --- 6. --uninstall leaves everything else intact ---------------------------------------------------------------
out=$(inst "$H" --uninstall 2>&1); rc=$?
check "uninstall: exit 0" [ "$rc" = 0 ]
check "uninstall: settings.json is back to the original (other keys and hooks intact, ours gone)" same_json "$C/settings.json" "$ROOT/orig-settings.json"
check "uninstall: skill folder removed" [ ! -e "$C/skills/context-discipline" ]
check "uninstall: CLAUDE.md line removed, the rest kept" \
  python3 -I -c 'import sys; a=open(sys.argv[1]).read().rstrip("\n"); b=open(sys.argv[2]).read().rstrip("\n"); sys.exit(0 if a == b else 1)' "$C/CLAUDE.md" "$ROOT/orig-claude.md"
check "uninstall: backed up settings.json and CLAUDE.md again first" \
  eval '[ "$(count "$C/settings.json.bak-*")" = 2 ] && [ "$(count "$C/CLAUDE.md.bak-*")" = 2 ]'
H4=$(new_home); inst "$H4" >/dev/null 2>&1; inst "$H4" --uninstall >/dev/null 2>&1
check "uninstall (fresh install): empty matcher entries and arrays dropped, settings.json is {}" jq_ "$H4/.claude/settings.json" 'd == {}'

# --- 7. Invalid settings.json aborts with no change ------------------------------------------------------------
H5=$(new_home); mkdir -p "$H5/.claude"; printf '{ "statusLine": {"type": "command", ' > "$H5/.claude/settings.json"
before=$(tree_sum "$H5")
out=$(inst "$H5" 2>&1); rc=$?
check "invalid JSON: exits non-zero with a clear message" eval '[ "$rc" != 0 ] && printf "%s" "$out" | grep -q "is not valid JSON" && printf "%s" "$out" | grep -q "Nothing was changed"'
check "invalid JSON: nothing changed (no skill copy, no CLAUDE.md, same bytes)" [ "$before" = "$(tree_sum "$H5")" ]
out=$(inst "$H5" --uninstall 2>&1); rc=$?
check "invalid JSON: --uninstall also aborts with no change" eval '[ "$rc" != 0 ] && [ "$before" = "$(tree_sum "$H5")" ]'

# --- 8. Options and other homes -------------------------------------------------------------------------------
H6=$(new_home)
inst "$H6" --skip-claude-md >/dev/null 2>&1; rc=$?
check "--skip-claude-md: skill and hook installed, no CLAUDE.md" \
  eval '[ "$rc" = 0 ] && [ -d "$H6/.claude/skills/context-discipline" ] && [ ! -e "$H6/.claude/CLAUDE.md" ] && jq_ "$H6/.claude/settings.json" "len(ours()) == 1"'
H7=$(new_home); CD="$H7/custom config"
env HOME="$H7" CLAUDE_CONFIG_DIR="$CD" bash "$INSTALL" >/dev/null 2>&1; rc=$?
check "CLAUDE_CONFIG_DIR (with a space): installs there, not in ~/.claude" \
  eval '[ "$rc" = 0 ] && [ -d "$CD/skills/context-discipline" ] && [ ! -e "$H7/.claude" ]'
cmd=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$CD/settings.json")
mkdir -p "$H7/proj"; echo "space-marker" > "$H7/proj/STATUS.md"
python3 -I -c 'import json, sys
json.dump({"version": 2, "brains": {"sp": {"dir": sys.argv[2], "status": "STATUS.md"}}}, open(sys.argv[1], "w"))' \
  "$CD/brains.json" "$H7/proj"
check "CLAUDE_CONFIG_DIR (with a space): the hook command is quoted correctly and runs" \
  eval 'printf "{\"cwd\": \"%s\"}" "$H7/proj" | HOME="$H7" CLAUDE_CONFIG_DIR="$CD" CD_BRAIN=sp bash -c "$cmd" | grep -q space-marker'
out=$(inst "$H6" --help 2>&1); rc=$?
check "-h/--help: exit 0 and prints usage" eval '[ "$rc" = 0 ] && printf "%s" "$out" | grep -q "^Usage: ./install.sh"'
inst "$H6" --bogus >/dev/null 2>&1; rc=$?
check "unknown option: exit 2" [ "$rc" = 2 ]

# --- 9. Updating: a changed installed copy is moved out of skills/ first ---------------------------------------
H8=$(new_home); C="$H8/.claude"; inst "$H8" >/dev/null 2>&1
echo "local edit" >> "$C/skills/context-discipline/SKILL.md"
inst "$H8" >/dev/null 2>&1; rc=$?
check "update: installed copy refreshed to match the repo" eval '[ "$rc" = 0 ] && same_tree "$REPO/context-discipline" "$C/skills/context-discipline"'
check "update: old copy kept in skill-backups/, and skills/ holds only the live skill" \
  eval '[ "$(count "$C/skill-backups/context-discipline.bak-*")" = 1 ] && grep -q "local edit" "$C"/skill-backups/context-discipline.bak-*/SKILL.md && [ "$(ls "$C/skills" | paste -sd, -)" = brain,context-discipline ]'
check "update: hook and CLAUDE.md steps were no-ops" eval 'jq_ "$C/settings.json" "len(ours()) == 1" && [ "$(md_lines "$C/CLAUDE.md")" = 1 ]'
echo "another edit" >> "$C/skills/context-discipline/SKILL.md"
inst "$H8" --uninstall >/dev/null 2>&1
check "uninstall: a locally changed copy is moved to skill-backups/, not deleted" \
  eval '[ ! -e "$C/skills/context-discipline" ] && [ "$(count "$C/skill-backups/context-discipline.bak-*")" = 2 ]'

# --- 10. Existing manual installs are recognised -----------------------------------------------------------------
H9=$(new_home); C="$H9/.claude"; mkdir -p "$C"
cat > "$C/settings.json" <<'EOF'
{"hooks": {"SessionStart": [
  {"matcher": "startup|resume", "hooks": [{"type": "command", "command": "bash ~/.claude/skills/context-discipline/scripts/brain-hook.sh"}]},
  {"matcher": "clear", "hooks": [{"type": "command", "command": "bash ~/.claude/skills/context-discipline/scripts/brain-hook.sh"}]}
]}}
EOF
printf -- '- Follow my own `context-discipline` rule.\n' > "$C/CLAUDE.md"
cp "$C/CLAUDE.md" "$ROOT/manual-claude.md"
out=$(inst "$H9" 2>&1); rc=$?
check "manual install: its matcher entries are replaced by one entry for every source" \
  eval '[ "$rc" = 0 ] && jq_ "$C/settings.json" "[m for _, m, _ in ours()] == [None] and len(d[\"hooks\"][\"SessionStart\"]) == 1"'
check "manual install: a CLAUDE.md that already mentions context-discipline is left alone" cmp -s "$C/CLAUDE.md" "$ROOT/manual-claude.md"

# --- 11. A symlinked settings.json stays a symlink -----------------------------------------------------------------
H10=$(new_home); C="$H10/.claude"; mkdir -p "$C" "$H10/dotfiles"
echo '{"theme": "dark"}' > "$H10/dotfiles/settings.json"; ln -s "$H10/dotfiles/settings.json" "$C/settings.json"
inst "$H10" >/dev/null 2>&1; rc=$?
check "symlinked settings.json: still a symlink, and its target got the hooks" \
  eval '[ "$rc" = 0 ] && [ -L "$C/settings.json" ] && jq_ "$H10/dotfiles/settings.json" "len(ours()) == 1 and d[\"theme\"] == \"dark\""'

# --- 12. Upgrading the old four-entry install, and other matcher forms -------------------------------------------
H11=$(new_home); C="$H11/.claude"; inst "$H11" >/dev/null 2>&1
old_cmd="bash \"$C/skills/context-discipline/scripts/brain-hook.sh\""
python3 -I - "$C/settings.json" "$old_cmd" <<'PY'
import json, sys
hook = {"type": "command", "command": sys.argv[2]}
ss = [{"matcher": m, "hooks": [dict(hook)]} for m in ("startup", "resume", "clear", "compact")]
ss[0]["hooks"].insert(0, {"type": "command", "command": "echo user-startup"})
json.dump({"hooks": {"SessionStart": ss}}, open(sys.argv[1], "w"))
PY
out=$(inst "$H11" 2>&1); rc=$?
check "upgrade from four matcher entries: one entry for every source, no duplicates" \
  eval '[ "$rc" = 0 ] && jq_ "$C/settings.json" "[m for _, m, _ in ours()] == [None]"'
check "upgrade: the user's hook in the old startup entry is kept there" \
  jq_ "$C/settings.json" 'd["hooks"]["SessionStart"][0] == {"matcher": "startup", "hooks": [{"type": "command", "command": "echo user-startup"}]} and len(d["hooks"]["SessionStart"]) == 2'
check "upgrade: the summary says what was replaced" eval 'printf "%s" "$out" | grep -q "replaced 4 old SessionStart hook entries"'
before=$(tree_sum "$C"); out=$(inst "$H11" 2>&1)
check "upgrade: a second run changes nothing" eval '[ "$before" = "$(tree_sum "$C")" ] && printf "%s" "$out" | grep -q "settings.json: unchanged"'

H12=$(new_home); C="$H12/.claude"; mkdir -p "$C"
cat > "$C/settings.json" <<'JSON'
{"hooks": {"SessionStart": [
  {"matcher": ".*", "hooks": [{"type": "command", "command": "bash ~/.claude/skills/context-discipline/scripts/brain-hook.sh"}]},
  {"matcher": "^(startup|resume|clear|compact)$", "hooks": [{"type": "command", "command": "bash ~/.claude/skills/context-discipline/scripts/brain-hook.sh"}]}
]}}
JSON
inst "$H12" >/dev/null 2>&1; rc=$?
check "regex matchers (.*, ^(a|b)\$): replaced by one entry, no duplicates" \
  eval '[ "$rc" = 0 ] && jq_ "$C/settings.json" "[m for _, m, _ in ours()] == [None] and len(d[\"hooks\"][\"SessionStart\"]) == 1"'

# --- 13. Uninstall removes both the old and the new form ---------------------------------------------------------
H13=$(new_home); C="$H13/.claude"; inst "$H13" >/dev/null 2>&1
python3 -I - "$C/settings.json" "$old_cmd" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hook = {"type": "command", "command": sys.argv[2]}
d["hooks"]["SessionStart"] += [{"matcher": m, "hooks": [dict(hook)]} for m in ("startup", "resume", "clear", "compact")]
d["hooks"]["SessionStart"].append({"matcher": "startup", "hooks": [{"type": "command", "command": "echo keep-me"}]})
json.dump(d, open(sys.argv[1], "w"))
PY
inst "$H13" --uninstall >/dev/null 2>&1; rc=$?
check "uninstall: removes the one-entry form and old matcher entries, keeps other hooks" \
  eval '[ "$rc" = 0 ] && jq_ "$C/settings.json" "len(ours()) == 0 and d == {\"hooks\": {\"SessionStart\": [{\"matcher\": \"startup\", \"hooks\": [{\"type\": \"command\", \"command\": \"echo keep-me\"}]}]}}"'

# --- 14. A hook whose script does not exist is repaired, never reported as "unchanged" --------------------------
H14=$(new_home); C="$H14/.claude"; mkdir -p "$C"
cat > "$C/settings.json" <<'JSON'
{"hooks": {"SessionStart": [
  {"hooks": [{"type": "command", "command": "bash \"/no/such/olduser/.claude/skills/context-discipline/scripts/brain-hook.sh\""}]}
]}}
JSON
out=$(inst "$H14" 2>&1); rc=$?
check "stale hook path: replaced by the working command" \
  eval '[ "$rc" = 0 ] && jq_ "$C/settings.json" "[c for _, _, c in ours()] == [A[0]]" "$want"'
check "stale hook path: the summary names the missing script, and does not say unchanged" \
  eval 'printf "%s" "$out" | grep -q "/no/such/olduser/.*does not exist" && ! printf "%s" "$out" | grep -q "settings.json: unchanged"'

for form in 'bash ~/.claude/skills/context-discipline/scripts/brain-hook.sh' \
            "bash \"$C/skills/context-discipline/scripts/brain-hook.sh\""; do
  full_settings "$C/settings.json" "$form"
  out=$(inst "$H14" 2>&1)
  check "working hook command ($form): left as it is" \
    eval 'printf "%s" "$out" | grep -q "settings.json: unchanged" && jq_ "$C/settings.json" "[c for _, _, c in ours()] == [A[0]]" "$form"'
done

# The command is written with $HOME, so a settings.json shared between two homes (dotfiles) runs in both.
H15=$(new_home); H16=$(new_home); inst "$H15" >/dev/null 2>&1; inst "$H16" >/dev/null 2>&1
cp "$H15/.claude/settings.json" "$H16/.claude/settings.json"; rm -rf "$H15"    # the other machine is gone
out=$(inst "$H16" 2>&1)
check "settings.json copied from another home: the hook is still valid there (unchanged)" \
  eval 'printf "%s" "$out" | grep -q "settings.json: unchanged"'

H17=$(new_home); CD="$ROOT/config-outside-home"
env HOME="$H17" CLAUDE_CONFIG_DIR="$CD" bash "$INSTALL" >/dev/null 2>&1
check "CLAUDE_CONFIG_DIR outside \$HOME: the hook command uses the absolute path" \
  jq_ "$CD/settings.json" '[c for _, _, c in ours()] == [A[0]]' "bash \"$CD/skills/context-discipline/scripts/brain-hook.sh\""

H18=$(new_home); mkdir -p "$H18/.claude"
full_settings "$H18/.claude/settings.json" "$want"
out=$(inst "$H18" --dry-run 2>&1)
check "dry run before the skill is copied: the hook that will run it is not called stale" \
  eval 'printf "%s" "$out" | grep -q "settings.json: unchanged"'

# --- 15. Problems found before anything is changed ---------------------------------------------------------------
H19=$(new_home); C="$H19/.claude"; mkdir -p "$C"
echo '{"hooks": {"SessionStart": ["echo legacy"]}}' > "$C/settings.json"
out=$(inst "$H19" --dry-run 2>&1); rc1=$?
out=$(inst "$H19" 2>&1); rc=$?
check "SessionStart entry that is a plain string: dry run and install work, the entry is kept" \
  eval '[ "$rc1" = 0 ] && [ "$rc" = 0 ] && jq_ "$C/settings.json" "d[\"hooks\"][\"SessionStart\"][0] == \"echo legacy\" and len(ours()) == 1"'

H20=$(new_home); C="$H20/.claude"; mkdir -p "$C"
echo '{"theme": "dark"}' > "$C/settings.json"; printf '# R\xe9gles\n' > "$C/CLAUDE.md"
before=$(tree_sum "$H20"); out=$(inst "$H20" 2>&1); rc=$?
check "CLAUDE.md that is not UTF-8: stops with a message naming it, nothing changed" \
  eval '[ "$rc" != 0 ] && printf "%s" "$out" | grep -q "CLAUDE.md" && [ "$before" = "$(tree_sum "$H20")" ]'
inst "$H20" --skip-claude-md >/dev/null 2>&1; rc=$?
check "CLAUDE.md that is not UTF-8: --skip-claude-md still installs" eval '[ "$rc" = 0 ] && jq_ "$C/settings.json" "len(ours()) == 1"'

if [ "$(id -u)" != 0 ]; then   # root can write to a read-only folder, so these cases mean nothing there
H21=$(new_home); C="$H21/.claude"; mkdir -p "$C" "$H21/store"
echo '{"theme": "dark"}' > "$H21/store/settings.json"; ln -s "$H21/store/settings.json" "$C/settings.json"; chmod 555 "$H21/store"
before=$(tree_sum "$H21"); out=$(inst "$H21" 2>&1); rc=$?
check "settings.json in a read-only folder: stops before any change, says why" \
  eval '[ "$rc" != 0 ] && printf "%s" "$out" | grep -q "read-only" && [ "$before" = "$(tree_sum "$H21")" ]'
chmod 755 "$H21/store"; inst "$H21" >/dev/null 2>&1; chmod 555 "$H21/store"
out=$(inst "$H21" 2>&1); rc=$?
check "settings.json in a read-only folder that already has the hook: install still runs" \
  eval '[ "$rc" = 0 ] && printf "%s" "$out" | grep -q "settings.json: unchanged"'
chmod 755 "$H21/store"
fi

# --- 16. CRLF CLAUDE.md keeps its line endings; disableAllHooks is pointed out -------------------------------------
H22=$(new_home); C="$H22/.claude"; mkdir -p "$C"
printf '# Rules\r\n- one\r\n' > "$C/CLAUDE.md"; cp "$C/CLAUDE.md" "$ROOT/crlf.md"
inst "$H22" >/dev/null 2>&1
check "CRLF CLAUDE.md: still CRLF throughout after install (3 lines, 3 CRs)" \
  eval '[ "$(tr -cd "\r" < "$C/CLAUDE.md" | wc -c | tr -d " ")" = 3 ] && [ "$(wc -l < "$C/CLAUDE.md" | tr -d " ")" = 3 ]'
inst "$H22" --uninstall >/dev/null 2>&1
check "CRLF CLAUDE.md: uninstall gives back the original bytes" cmp -s "$C/CLAUDE.md" "$ROOT/crlf.md"

H23=$(new_home); C="$H23/.claude"; mkdir -p "$C"; echo '{"disableAllHooks": true}' > "$C/settings.json"
out=$(inst "$H23" 2>&1)
check "disableAllHooks: the summary warns that no hook will run" eval 'printf "%s" "$out" | grep -q "disableAllHooks"'

# --- 17. The PostCompact and UserPromptSubmit hooks: upgrade, repair, matchers, other hooks --------------------------
H24=$(new_home); C="$H24/.claude"; mkdir -p "$C"
python3 -I - "$C/settings.json" "$want" <<'PY'
import json, sys
json.dump({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": sys.argv[2]}]}],
                     "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "echo user-prompt-hook"}]}]}},
          open(sys.argv[1], "w"))
PY
out=$(inst "$H24" 2>&1); rc=$?
check "upgrade from a SessionStart-only install: the two new hooks are added, the SessionStart entry kept" \
  eval '[ "$rc" = 0 ] && jq_ "$C/settings.json" "len(all_ours()) == 3 and d[\"hooks\"][\"SessionStart\"] == [{\"hooks\": [{\"type\": \"command\", \"command\": A[0]}]}]" "$want"'
check "upgrade: the user's own UserPromptSubmit hook is kept" \
  jq_ "$C/settings.json" 'any(h["command"] == "echo user-prompt-hook" for e in d["hooks"]["UserPromptSubmit"] for h in e["hooks"])'
check "upgrade: the summary names the added hooks and does not say unchanged" \
  eval 'printf "%s" "$out" | grep -q "added one PostCompact hook" && printf "%s" "$out" | grep -q "added one UserPromptSubmit hook" && ! printf "%s" "$out" | grep -q "settings.json: unchanged"'
before=$(tree_sum "$C"); out=$(inst "$H24" 2>&1)
check "upgrade: a second run changes nothing" eval '[ "$before" = "$(tree_sum "$C")" ] && printf "%s" "$out" | grep -q "settings.json: unchanged"'

H25=$(new_home); C="$H25/.claude"; inst "$H25" >/dev/null 2>&1
python3 -I - "$C/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["hooks"]["PostCompact"] = [
    {"matcher": "auto", "hooks": [{"type": "command", "command": "bash ~/.claude/skills/context-discipline/scripts/compact-log.sh"}]},
    {"hooks": [{"type": "command", "command": 'bash "/no/such/olduser/.claude/skills/context-discipline/scripts/compact-log.sh"'}]}]
d["hooks"]["UserPromptSubmit"] = [
    {"hooks": [{"type": "command", "command": 'bash "/no/such/olduser/.claude/skills/context-discipline/scripts/ctx-nudge.sh"'}]}]
json.dump(d, open(sys.argv[1], "w"))
PY
out=$(inst "$H25" 2>&1); rc=$?
check "PostCompact entry with matcher auto and one with a missing script: replaced by one entry for every compaction" \
  eval '[ "$rc" = 0 ] && jq_ "$C/settings.json" "[(m, c) for _, m, c in ours_of(\"compact-log.sh\")] == [(None, A[0])]" "$want_cl"'
check "UserPromptSubmit hook whose script is missing: replaced by the working command" \
  jq_ "$C/settings.json" '[c for _, _, c in ours_of("ctx-nudge.sh")] == [A[0]]' "$want_cn"
check "the summary names the missing scripts" eval 'printf "%s" "$out" | grep -q "compact-log.sh, which does not exist" && printf "%s" "$out" | grep -q "ctx-nudge.sh, which does not exist"'

H26=$(new_home); C="$H26/.claude"; mkdir -p "$C"
python3 -I - "$C/settings.json" <<'PY'
import json, sys
json.dump({"hooks": {"UserPromptSubmit": [{"matcher": "deploy", "hooks": [
    {"type": "command", "command": "bash ~/.claude/skills/context-discipline/scripts/ctx-nudge.sh", "timeout": 9}]}]}},
    open(sys.argv[1], "w"))
PY
inst "$H26" >/dev/null 2>&1
check "UserPromptSubmit hook already there (a matcher, which that event ignores; own timeout): left as it is" \
  jq_ "$C/settings.json" 'd["hooks"]["UserPromptSubmit"] == [{"matcher": "deploy", "hooks": [{"type": "command", "command": "bash ~/.claude/skills/context-discipline/scripts/ctx-nudge.sh", "timeout": 9}]}]'

H28=$(new_home); mkdir -p "$H28/.claude"; echo '{"hooks": {"PostCompact": {"oops": 1}}}' > "$H28/.claude/settings.json"
before=$(tree_sum "$H28"); out=$(inst "$H28" 2>&1); rc=$?
check "hooks.PostCompact that is not a list: stops with a message, nothing changed" \
  eval '[ "$rc" != 0 ] && printf "%s" "$out" | grep -q "hooks.PostCompact" && [ "$before" = "$(tree_sum "$H28")" ]'

H27=$(new_home); C="$H27/.claude"; inst "$H27" >/dev/null 2>&1
python3 -I - "$C/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["hooks"]["PostCompact"].append({"matcher": "manual", "hooks": [{"type": "command", "command": "echo keep-compact"}]})
d["hooks"]["UserPromptSubmit"][0]["hooks"].append({"type": "command", "command": "echo keep-prompt"})
json.dump(d, open(sys.argv[1], "w"))
PY
out=$(inst "$H27" --uninstall 2>&1); rc=$?
check "uninstall: all three of our hooks removed, the user's PostCompact and UserPromptSubmit hooks kept" \
  eval '[ "$rc" = 0 ] && jq_ "$C/settings.json" "len(all_ours()) == 0 and d == {\"hooks\": {\"PostCompact\": [{\"matcher\": \"manual\", \"hooks\": [{\"type\": \"command\", \"command\": \"echo keep-compact\"}]}], \"UserPromptSubmit\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"echo keep-prompt\"}]}]}}"'
check "uninstall: the summary counts 3 hook entries" eval 'printf "%s" "$out" | grep -q "removed 3 hook entries"'

# settings.json keeps its final newline, or its lack of one (many editors and Claude Code write none).
lastbyte() { tail -c 1 "$1" | od -An -c | tr -d ' '; }
H29=$(new_home); mkdir -p "$H29/.claude"; printf '{\n  "model": "x"\n}' > "$H29/.claude/settings.json"
inst "$H29" --skip-claude-md >/dev/null 2>&1
check "install: settings.json without a final newline stays without one" eval '[ "$(lastbyte "$H29/.claude/settings.json")" = "}" ]'
inst "$H29" --uninstall --skip-claude-md >/dev/null 2>&1
check "uninstall: settings.json without a final newline stays without one" eval '[ "$(lastbyte "$H29/.claude/settings.json")" = "}" ]'
H30=$(new_home); mkdir -p "$H30/.claude"; printf '{\n  "model": "x"\n}\n' > "$H30/.claude/settings.json"
inst "$H30" --skip-claude-md >/dev/null 2>&1
check "install: settings.json with a final newline keeps it" eval '[ "$(lastbyte "$H30/.claude/settings.json")" = "\\n" ]'

out=$(inst "$H27" --help 2>&1)
check "--help names the PostCompact and UserPromptSubmit hooks" \
  eval 'printf "%s" "$out" | grep -q PostCompact && printf "%s" "$out" | grep -q UserPromptSubmit'

# --- 18. The /brain skill: a tiny user-invoked skill installed next to context-discipline -------------------------
H31=$(new_home); C="$H31/.claude"; BR="$C/skills/brain"
out=$(inst "$H31" 2>&1); rc=$?
check "/brain skill: copied to skills/brain, identical to the repo's brain/" \
  eval '[ "$rc" = 0 ] && same_tree "$REPO/brain" "$BR"'
check "/brain skill: the summary names it" eval 'printf "%s" "$out" | grep -q "^  brain skill: *copied to $BR"'
check "/brain skill: user-invoked only (disable-model-invocation: true), named brain" \
  eval 'grep -qx "disable-model-invocation: true" "$BR/SKILL.md" && grep -qx "name: brain" "$BR/SKILL.md"'
# The skill's one command, as Claude Code runs it: a fenced ```! block, ${CLAUDE_SKILL_DIR} and $ARGUMENTS
# substituted, then bash. $ARGUMENTS sits alone in a quoted heredoc, so the shell never parses the user's text.
block=$(sed -n '/^```!$/,/^```$/p' "$BR/SKILL.md" | sed '1d;$d')
first=$(printf '%s\n' "$block" | head -n 1)
check "/brain skill: one fenced command: brain.sh --args, with \$ARGUMENTS alone in a quoted heredoc" \
  eval '[ "$first" = "bash \"\${CLAUDE_SKILL_DIR}/../context-discipline/scripts/brain.sh\" --args <<'"'"'CD_BRAIN_ARGS_END'"'"'" ] && [ "$(printf "%s\n" "$block" | sed -n 2p)" = "\$ARGUMENTS" ] && [ "$(printf "%s\n" "$block" | sed -n 3p)" = CD_BRAIN_ARGS_END ] && [ "$(printf "%s\n" "$block" | grep -c "")" = 3 ] && ! grep -q "^!\`" "$BR/SKILL.md"'
run_bang() {   # run_bang <arguments>: the command with the substitutions made, run in a plain folder
  local cmd="${block//\$\{CLAUDE_SKILL_DIR\}/$BR}"; cmd="${cmd//\$ARGUMENTS/$1}"
  (mkdir -p "$H31/work" && cd "$H31/work" && env -u CLAUDE_CONFIG_DIR HOME="$H31" CLAUDE_PID=$$ bash -c "$cmd" 2>&1)
}
check "/brain skill: '/brain help' runs the installed script and prints its usage" eval 'run_bang help | grep -q "^usage: /brain"'
check "/brain skill: '/brain' (no arguments) lists, exit 0" eval 'run_bang "" | grep -q "No brains yet"'
check "/brain skill: arguments with a backtick, \$(...) and ; run nothing" \
  eval 'run_bang "x \`touch $H31/p1\` \$(touch $H31/p2); touch $H31/p3" >/dev/null; [ ! -e "$H31/p1" ] && [ ! -e "$H31/p2" ] && [ ! -e "$H31/p3" ]'
# allowed-tools pre-approves exactly that command, so it runs without a prompt.
rules=$(sed -n '/^allowed-tools:/,/^[a-z-]*:/p' "$BR/SKILL.md" | sed -n 's/^ *- Bash(\(.*\))$/\1/p')
check "/brain skill: allowed-tools is one Bash rule: that script with --args" \
  eval '[ "$(printf "%s\n" "$rules" | grep -c "")" = 1 ] && [ "$rules" = "bash \"\${CLAUDE_SKILL_DIR}/../context-discipline/scripts/brain.sh\" --args *" ]'
before=$(tree_sum "$C"); out=$(inst "$H31" 2>&1)
check "/brain skill: a second run leaves it unchanged" \
  eval '[ "$before" = "$(tree_sum "$C")" ] && printf "%s" "$out" | grep -q "brain skill: *unchanged"'
echo "local edit" >> "$BR/SKILL.md"; out=$(inst "$H31" 2>&1)
check "/brain skill: a locally changed copy is moved to skill-backups/ and replaced" \
  eval 'same_tree "$REPO/brain" "$BR" && grep -q "local edit" "$C"/skill-backups/brain.bak-*/SKILL.md'
H32=$(new_home); out=$(inst "$H32" --dry-run 2>&1)
check "/brain skill: --dry-run says it would copy it, and copies nothing" \
  eval 'printf "%s" "$out" | grep -q "brain skill: *would copy" && [ ! -e "$H32/.claude" ]'
out=$(inst "$H31" --uninstall 2>&1); rc=$?
check "/brain skill: --uninstall deletes it (it matches the repo)" \
  eval '[ "$rc" = 0 ] && [ ! -e "$BR" ] && printf "%s" "$out" | grep -q "brain skill: *deleted"'
inst "$H31" >/dev/null 2>&1; echo "edit" >> "$BR/SKILL.md"; inst "$H31" --uninstall >/dev/null 2>&1
check "/brain skill: --uninstall moves a locally changed copy to skill-backups/" \
  eval '[ ! -e "$BR" ] && [ "$(count "$C/skill-backups/brain.bak-*")" = 2 ]'
# Someone else's skill that happens to be called "brain" is never moved or deleted.
H33=$(new_home); C="$H33/.claude"; mkdir -p "$C/skills/brain"
printf -- '---\nname: brain\ndescription: my own notes skill\n---\nMine.\n' > "$C/skills/brain/SKILL.md"
before=$(tree_sum "$C/skills/brain"); out=$(inst "$H33" 2>&1); rc=$?
check "another skill named brain: left untouched, the summary says /brain was not installed, rest installed" \
  eval '[ "$rc" = 0 ] && [ "$before" = "$(tree_sum "$C/skills/brain")" ] && printf "%s" "$out" | grep -q "brain skill: *NOT installed" && [ -d "$C/skills/context-discipline" ]'
out=$(inst "$H33" --uninstall 2>&1)
check "another skill named brain: --uninstall leaves it too" \
  eval '[ "$before" = "$(tree_sum "$C/skills/brain")" ] && printf "%s" "$out" | grep -q "brain skill: *unchanged"'
# A skills/brain that is a symlink (say, to the repo's brain/) is never replaced or deleted, and both runs say so.
H34=$(new_home); C="$H34/.claude"; mkdir -p "$C/skills"; ln -s "$REPO/brain" "$C/skills/brain"
out=$(inst "$H34" 2>&1)
check "skills/brain is a symlink to this repo's brain/: install leaves it and says it is a symlink" \
  eval '[ -L "$C/skills/brain" ] && printf "%s" "$out" | grep -q "brain skill: *unchanged, .*a symlink"'
out=$(inst "$H34" --uninstall 2>&1)
check "skills/brain symlink: uninstall leaves it too, with the same wording" \
  eval '[ -L "$C/skills/brain" ] && printf "%s" "$out" | grep -q "brain skill: *unchanged, .*a symlink"'
out=$(inst "$H33" --help 2>&1)
check "--help names the /brain skill" eval 'printf "%s" "$out" | grep -q "skills/brain/"'

echo "== install tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
