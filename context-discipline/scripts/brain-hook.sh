#!/usr/bin/env bash
# brain-hook.sh -- SessionStart hook for the context-discipline skill.
#
# Reads the hook's JSON from stdin, takes its "cwd", walks up from there looking
# for a "<dir>/.claude/brain" pointer file, and prints the STATUS file it names so
# Claude Code adds it to context at every session start (startup, resume, clear,
# compact, fork).
#
# Pointer format: the first non-empty line not starting with "#" is the STATUS
# path, relative to <dir>. The hook prints it only if, with every symlink
# resolved, it is a regular text file inside <dir>: absolute paths, "~/...", ".."
# escapes and symlinks that leave <dir> are refused, because the hook runs in
# every session and a downloaded repo could otherwise point it at any file.
#
# Contract: prints nothing and exits 0 when no pointer is found or the input is
# not a JSON object. When a pointer
# is found but refused, prints one warning line naming it (no file content) and
# exits 0. Never writes files, never touches the network.
# Stops before $HOME and "/" so ~/.claude (global config) is never read as a brain.

LIMIT=9000   # characters of STATUS printed in full; longer files are cut to this many, with a notice
CAP=10000    # Claude Code replaces hook output over 10,000 characters with a 2,000-character preview

# 1-3. Find the session's brain: walk up from its cwd to the nearest <dir>/.claude/brain (stopping before
#      $HOME and "/") and accept the STATUS file it names only if it is a text file inside <dir>. The rules live
#      in brain-lib.sh, shared with the other context-discipline hooks so they all agree on what a brain is.
here="${BASH_SOURCE[0]%/*}"; [ "$here" = "${BASH_SOURCE[0]}" ] && here=.
. "$here/brain-lib.sh" 2>/dev/null || exit 0

input=""
if [ ! -t 0 ]; then
  input=$(cat 2>/dev/null)
fi
# Input that is not a JSON object stops the hook (Claude Code always sends one). Valid JSON without "cwd",
# or no JSON parser at all, falls back to $CLAUDE_PROJECT_DIR, then $PWD.
cwd=$(cd_session_cwd "$input") || exit 0
cd_find_brain "$cwd" || exit 0
pointer="$CD_POINTER"

cd_check_pointer   # from here on LC_ALL=C: count and match bytes
case $? in
  0) ;;
  1) printf '(Project brain not loaded: %s %s.)\n' "$pointer" "$CD_REFUSED"; exit 0 ;;
  *) exit 0 ;;
esac
status="$CD_STATUS"; size="$CD_SIZE"

# 4. Print it (cut on a character boundary if too long), then one line naming the source.
# Characters are counted as Claude Code counts them: JavaScript string length, so most characters are 1
# and emoji (4-byte UTF-8) are 2. Bytes are never fewer, so a file of at most $budget bytes always fits.
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
