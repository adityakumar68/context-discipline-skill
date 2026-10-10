#!/usr/bin/env bash
# brain-hook.sh -- SessionStart hook for the context-discipline skill.
#
# Reads the hook's JSON from stdin, takes its "cwd", walks up from there looking
# for a "<dir>/.claude/brain" pointer file, and prints the STATUS file it names so
# Claude Code adds it to context on startup, resume, clear and compact.
#
# Pointer format: the first non-empty line not starting with "#" is the STATUS
# path, relative to <dir> (an absolute path or "~/..." also works).
#
# Contract: prints nothing and exits 0 when no pointer is found or anything goes
# wrong. Never writes files, never touches the network, stays well under 100 ms.
# Stops before $HOME and "/" so ~/.claude (global config) is never read as a brain.

MAX_BYTES=9500   # above this, print a cut version (hook output > 10,000 chars becomes a 2,000-char preview)
CUT_BYTES=9000

# 1. Find the session's working directory.
input=""
if [ ! -t 0 ]; then
  input=$(cat 2>/dev/null)
fi

cwd=""
if [ -n "$input" ]; then
  if command -v jq >/dev/null 2>&1; then
    cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
  elif command -v python3 >/dev/null 2>&1; then
    cwd=$(printf '%s' "$input" | python3 -I -c 'import json,sys
try:
    v = json.load(sys.stdin).get("cwd") or ""
    print(v if isinstance(v, str) else "")
except Exception:
    pass' 2>/dev/null)
  fi
fi
[ -z "$cwd" ] && cwd="${CLAUDE_PROJECT_DIR:-}"
[ -z "$cwd" ] && cwd="$PWD"

case "$cwd" in
  /*) ;;
  *) exit 0 ;;
esac

# 2. Walk up to the nearest <dir>/.claude/brain, stopping before $HOME and "/".
home="${HOME%/}"
dir="${cwd%/}"
pointer=""
while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "$home" ]; do
  if [ -f "$dir/.claude/brain" ]; then
    pointer="$dir/.claude/brain"
    break
  fi
  parent=$(dirname "$dir" 2>/dev/null) || exit 0
  [ "$parent" = "$dir" ] && break
  dir="$parent"
done
[ -z "$pointer" ] && exit 0

# 3. Read the STATUS path from the pointer.
rel=""
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
  line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
  case "$line" in
    ''|'#'*) continue ;;
  esac
  rel="$line"
  break
done < "$pointer" 2>/dev/null
[ -z "$rel" ] && exit 0

case "$rel" in
  /*) status="$rel" ;;
  '~/'*) status="$home/${rel#\~/}" ;;
  *) status="$dir/$rel" ;;
esac
[ -f "$status" ] && [ -r "$status" ] || exit 0

# 4. Print it (cut if too large), then one line naming the source.
size=$(wc -c < "$status" 2>/dev/null | tr -d '[:space:]')
case "$size" in
  ''|*[!0-9]*) exit 0 ;;
esac

if [ "$size" -gt "$MAX_BYTES" ]; then
  head -c "$CUT_BYTES" "$status" 2>/dev/null
  printf '\n[STATUS.md is %s bytes; trim it under 10,000 so it is not cut]\n' "$size"
else
  cat "$status" 2>/dev/null
  # keep the closing line on its own line even if the file lacks a final newline
  [ -n "$(tail -c 1 "$status" 2>/dev/null)" ] && printf '\n'
fi
printf '(Project brain loaded from %s. Working rules: context-discipline skill.)\n' "$status"
exit 0
