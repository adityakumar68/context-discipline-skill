#!/usr/bin/env bash
# brain-hook.sh -- SessionStart hook for the context-discipline skill.
#
# Reads the hook's JSON from stdin, takes its "cwd", walks up from there looking
# for a "<dir>/.claude/brain" pointer file, and prints the STATUS file it names so
# Claude Code adds it to context on startup, resume, clear and compact.
#
# Pointer format: the first non-empty line not starting with "#" is the STATUS
# path, relative to <dir>. The hook prints it only if, with every symlink
# resolved, it is a regular text file inside <dir>: absolute paths, "~/...", ".."
# escapes and symlinks that leave <dir> are refused, because the hook runs in
# every session and a downloaded repo could otherwise point it at any file.
#
# Contract: prints nothing and exits 0 when no pointer is found. When a pointer
# is found but refused, prints one warning line naming it (no file content) and
# exits 0. Never writes files, never touches the network.
# Stops before $HOME and "/" so ~/.claude (global config) is never read as a brain.

LIMIT=9000   # characters of STATUS printed in full; longer files are cut to this many, with a notice
CAP=10000    # Claude Code replaces hook output over 10,000 characters with a 2,000-character preview

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

# 3. Read the STATUS path from the pointer and accept only a text file inside <dir>.
LC_ALL=C; export LC_ALL   # from here on, count and match bytes

# refuse <reason>: one warning line naming the pointer (never the file's content), then stop.
refuse() {
  printf '(Project brain not loaded: %s %s.)\n' "$pointer" "$1"
  exit 0
}

# physical <path>: <path> with every symlink resolved, its last part included. Fails if a folder is missing.
physical() {
  local p="$1" d b t n=0
  while :; do
    d=$(dirname -- "$p") && b=$(basename -- "$p") || return 1
    d=$(cd -P -- "$d" 2>/dev/null && pwd -P) || return 1
    case "$b" in .|..) return 1 ;; esac
    if [ "$d" = / ]; then p="/$b"; else p="$d/$b"; fi
    [ -L "$p" ] || break
    n=$((n + 1)); [ "$n" -le 20 ] || return 1
    t=$(readlink -- "$p") || return 1
    case "$t" in /*) p="$t" ;; *) p="$d/$t" ;; esac
  done
  printf '%s\n' "$p"
}

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
[ -n "$rel" ] || refuse "names no file"

case "$rel" in
  /*|'~'*) refuse "must name its STATUS file by a path relative to its project folder" ;;
esac
root=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || exit 0
status=$(physical "$root/$rel") || refuse "names a missing file"
case "$status" in
  "$root"/*) ;;
  *) refuse "names a file outside its project folder" ;;
esac
[ -f "$status" ] || refuse "names a missing file, or something that is not a regular file"
[ -r "$status" ] || refuse "names a file that cannot be read"

# 4. Print it (cut on a character boundary if too long), then one line naming the source.
# Characters are counted as Claude Code counts them: JavaScript string length, so most characters are 1
# and emoji (4-byte UTF-8) are 2. Bytes are never fewer, so a file of at most $budget bytes always fits.
size=$(wc -c < "$status" 2>/dev/null | tr -d '[:space:]')
case "$size" in
  ''|*[!0-9]*) exit 0 ;;
esac
text=$(tr -d '\000' < "$status" 2>/dev/null | wc -c | tr -d '[:space:]')
[ "$text" = "$size" ] || refuse "names a file that is not text"

loaded="(Project brain loaded from $status. Working rules: context-discipline skill.)"
budget=$((CAP - 200 - ${#loaded}))   # 200: room for the trim notice; ${#loaded} counts bytes (>= characters)
[ "$budget" -gt "$LIMIT" ] && budget=$LIMIT

chars=$size
if [ "$size" -gt "$budget" ]; then
  # characters = bytes that do not continue a UTF-8 sequence, plus one more for each 4-byte sequence
  chars=$(( $(tr -d '\200-\277' < "$status" | wc -c) + $(tr -cd '\360-\367' < "$status" | wc -c) ))
fi

# commas <n>: 12345 -> 12,345
commas() {
  local n="$1" out=""
  while [ ${#n} -gt 3 ]; do out=",${n#"${n%???}"}$out"; n="${n%???}"; done
  printf '%s' "$n$out"
}

if [ "$chars" -gt "$budget" ]; then
  # Find the byte offset of the first character that would go over the budget, and cut there.
  set -- $(head -c $((budget * 4)) "$status" 2>/dev/null | od -An -v -tu1 | awk -v max="$budget" '
    { for (i = 1; i <= NF; i++) {
        b = $i + 0
        if (b >= 128 && b < 192 && pend > 0) { pend--; n++; continue }   # continuation byte
        u = 1; pend = 0
        if (b >= 240 && b < 248) { u = 2; pend = 3 } else if (b >= 224 && b < 240) pend = 2; else if (b >= 192 && b < 224) pend = 1
        if (units + u > max) { done = 1; exit }
        units += u; n++
    } }
    END { print n + 0, units + 0 }')
  case "${1:-}${2:-}" in ''|*[!0-9]*) exit 0 ;; esac
  head -c "$1" "$status" 2>/dev/null
  printf '\n[%s is %s characters, over the %s limit, so only the first %s are shown here. Trim it so nothing is cut.]\n' \
    "$(basename -- "$status")" "$(commas "$chars")" "$(commas "$budget")" "$(commas "$2")"
else
  cat "$status" 2>/dev/null
  # keep the closing line on its own line even if the file lacks a final newline
  [ -n "$(tail -c 1 "$status" 2>/dev/null)" ] && printf '\n'
fi
printf '%s\n' "$loaded"
exit 0
