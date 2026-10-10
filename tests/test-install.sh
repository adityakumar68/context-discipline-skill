#!/usr/bin/env bash
# Tests for install.sh. Usage: bash tests/test-install.sh
#
# Every case runs install.sh with HOME set to a throwaway folder from mktemp and CLAUDE_CONFIG_DIR unset
# (or pointed into that folder), so your real ~/.claude is never read or written.
# Prints PASS/FAIL per check and a total; exits non-zero if anything failed.

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd -P)
INSTALL="$REPO/install.sh"
ROOT=$(mktemp -d) && [ -d "$ROOT" ] || { echo "mktemp failed" >&2; exit 1; }
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
# In the expression: d = the parsed file, ours() = [(event, matcher, command)] for our hook, A = extra args.
jq_() {
  python3 -I - "$@" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
A = sys.argv[3:]
M = "context-discipline/scripts/brain-hook.sh"
def ours():
    return [(ev, e.get("matcher"), h.get("command")) for ev, es in d.get("hooks", {}).items()
            for e in es for h in e.get("hooks", []) if M in h.get("command", "")]
sys.exit(0 if eval(sys.argv[2]) else 1)
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
want="bash \"$C/skills/context-discipline/scripts/brain-hook.sh\""
out=$(inst "$H" 2>&1); rc=$?
check "fresh: exit 0" [ "$rc" = 0 ]
check "fresh: skill copied, identical to the repo copy" same_tree "$REPO/context-discipline" "$C/skills/context-discipline"
check "fresh: scripts are executable" [ -x "$C/skills/context-discipline/scripts/brain-hook.sh" ]
check "fresh: settings.json has exactly 4 hooks (startup, resume, clear, compact) with the absolute command" \
  jq_ "$C/settings.json" 'sorted(m for _, m, _ in ours()) == ["clear", "compact", "resume", "startup"] and {c for _, _, c in ours()} == {A[0]} and set(d) == {"hooks"}' "$want"
check "fresh: CLAUDE.md created with the line once" [ "$(md_lines "$C/CLAUDE.md")" = 1 ]
check "fresh: no backups made (nothing existed)" eval '[ "$(count "$C/*.bak-*")" = 0 ] && [ ! -e "$C/skill-backups" ]'
check "fresh: summary gives the next steps (restart, init-brain, pipe test)" \
  eval 'printf "%s" "$out" | grep -q "Restart Claude Code" && printf "%s" "$out" | grep -q "init-brain.sh" && printf "%s" "$out" | grep -q "Project brain loaded from"'

# --- 2. Whole chain: installed init-brain.sh + the exact hook command from settings.json ---------------------
P="$H/work/notes-app"; mkdir -p "$P/src/deep"
inst_out=$(bash "$C/skills/context-discipline/scripts/init-brain.sh" "$P"); rc=$?
check "chain: installed init-brain.sh sets up the brain" eval '[ "$rc" = 0 ] && [ -f "$P/STATUS.md" ] && [ -f "$P/.claude/brain" ]'
echo "chain-marker-4711" >> "$P/STATUS.md"
cmd=$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print([h["command"] for e in d["hooks"]["SessionStart"] if e["matcher"]=="compact" for h in e["hooks"]][0])' "$C/settings.json")
hook_out=$(printf '{"cwd": "%s", "source": "compact"}' "$P/src/deep" | HOME="$H" bash -c "$cmd"); rc=$?
check "chain: the settings.json command, run from a project subfolder, prints STATUS" \
  eval '[ "$rc" = 0 ] && printf "%s" "$hook_out" | grep -q chain-marker-4711'
check "chain: hook output ends with the 'Project brain loaded from' line" \
  eval 'printf "%s\n" "$hook_out" | tail -n 1 | grep -qF "(Project brain loaded from $P/STATUS.md."'

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
check "existing: our 4 hooks added" jq_ "$C/settings.json" 'sorted(m for _, m, _ in ours()) == ["clear", "compact", "resume", "startup"]'
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
check "twice: still exactly 4 of our hooks (no duplicates)" jq_ "$C/settings.json" 'len(ours()) == 4'
check "twice: CLAUDE.md line still there once" [ "$(md_lines "$C/CLAUDE.md")" = 1 ]
check "twice: second run changed nothing at all (no new backups either)" [ "$before" = "$(tree_sum "$C")" ]
check "twice: summary says every step is unchanged" [ "$(printf '%s\n' "$out" | grep -c ': *unchanged')" = 3 ]

# --- 5. --dry-run changes nothing -----------------------------------------------------------------------------
H2=$(new_home)
out=$(inst "$H2" --dry-run 2>&1); rc=$?
check "dry-run (fresh home): exit 0 and ~/.claude is not even created" eval '[ "$rc" = 0 ] && [ ! -e "$H2/.claude" ]'
check "dry-run (fresh home): prints the three planned changes" \
  eval '[ "$(printf "%s\n" "$out" | grep -c "would ")" = 3 ] && printf "%s" "$out" | grep -qF "each runs: bash"'
H3=$(new_home); mkdir -p "$H3/.claude"; cp "$ROOT/orig-settings.json" "$H3/.claude/settings.json"; cp "$ROOT/orig-claude.md" "$H3/.claude/CLAUDE.md"
before=$(tree_sum "$H3")
out=$(inst "$H3" --dry-run 2>&1); rc=$?
check "dry-run (existing settings): exit 0 and checksums identical before/after" eval '[ "$rc" = 0 ] && [ "$before" = "$(tree_sum "$H3")" ]'
before=$(tree_sum "$C")
out=$(inst "$H" --uninstall --dry-run 2>&1); rc=$?
check "dry-run --uninstall: exit 0, plans the removals, checksums identical" \
  eval '[ "$rc" = 0 ] && [ "$(printf "%s\n" "$out" | grep -c "would ")" = 3 ] && [ "$before" = "$(tree_sum "$C")" ]'

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
  eval '[ "$rc" = 0 ] && [ -d "$H6/.claude/skills/context-discipline" ] && [ ! -e "$H6/.claude/CLAUDE.md" ] && jq_ "$H6/.claude/settings.json" "len(ours()) == 4"'
H7=$(new_home); CD="$H7/custom config"
env HOME="$H7" CLAUDE_CONFIG_DIR="$CD" bash "$INSTALL" >/dev/null 2>&1; rc=$?
check "CLAUDE_CONFIG_DIR (with a space): installs there, not in ~/.claude" \
  eval '[ "$rc" = 0 ] && [ -d "$CD/skills/context-discipline" ] && [ ! -e "$H7/.claude" ]'
cmd=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["SessionStart"][0]["hooks"][0]["command"])' "$CD/settings.json")
mkdir -p "$H7/proj/.claude"; echo STATUS.md > "$H7/proj/.claude/brain"; echo "space-marker" > "$H7/proj/STATUS.md"
check "CLAUDE_CONFIG_DIR (with a space): the hook command is quoted correctly and runs" \
  eval 'printf "{\"cwd\": \"%s\"}" "$H7/proj" | HOME="$H7" bash -c "$cmd" | grep -q space-marker'
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
  eval '[ "$(count "$C/skill-backups/context-discipline.bak-*")" = 1 ] && grep -q "local edit" "$C"/skill-backups/context-discipline.bak-*/SKILL.md && [ "$(ls "$C/skills")" = context-discipline ]'
check "update: hook and CLAUDE.md steps were no-ops" eval 'jq_ "$C/settings.json" "len(ours()) == 4" && [ "$(md_lines "$C/CLAUDE.md")" = 1 ]'
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
check "manual install: only the missing matcher (compact) is added" \
  eval '[ "$rc" = 0 ] && jq_ "$C/settings.json" "len(ours()) == 3 and [m for _, m, _ in ours()] == [\"startup|resume\", \"clear\", \"compact\"]"'
check "manual install: a CLAUDE.md that already mentions context-discipline is left alone" cmp -s "$C/CLAUDE.md" "$ROOT/manual-claude.md"

# --- 11. A symlinked settings.json stays a symlink -----------------------------------------------------------------
H10=$(new_home); C="$H10/.claude"; mkdir -p "$C" "$H10/dotfiles"
echo '{"theme": "dark"}' > "$H10/dotfiles/settings.json"; ln -s "$H10/dotfiles/settings.json" "$C/settings.json"
inst "$H10" >/dev/null 2>&1; rc=$?
check "symlinked settings.json: still a symlink, and its target got the hooks" \
  eval '[ "$rc" = 0 ] && [ -L "$C/settings.json" ] && jq_ "$H10/dotfiles/settings.json" "len(ours()) == 4 and d[\"theme\"] == \"dark\""'

echo "== install tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
