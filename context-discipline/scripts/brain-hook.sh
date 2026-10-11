#!/usr/bin/env bash
# brain-hook.sh -- SessionStart hook for the context-discipline skill.
#
# Reads the hook's JSON from stdin and prints the STATUS file of the session's brain, so Claude Code adds it to
# context at every session start (startup, resume, clear, compact, fork). A brain belongs to the session, never to
# a folder: it is, first match wins, the one chosen with /brain in this Claude Code window, else CD_BRAIN=<name>
# (both looked up in <config>/brains.json; "none" means no brain), else none (brain-lib.sh has the rules). No
# .claude/brain pointer is ever read.
#
# The registered STATUS is printed only if, with every symlink resolved, it is a regular text file inside its
# brain folder (named by a path relative to it; the folder may not be $HOME or "/").
#
# Contract: with no brain, prints one line saying so: the brain last attached with /brain from this session's
# folder if it still exists, else that the folder has an old .claude/brain pointer (only tested for, never read),
# else the registered brains. A hint: it never attaches one. Nothing on a compaction (the start already said it),
# and nothing when the user chose no brain (/brain none, CD_BRAIN=none). When a chosen brain is refused, prints
# one warning line naming it (no file content). Prints nothing at all when CD_HOOKS=off or the input is not a JSON
# object. Always exits 0, never touches the network. Its one write: after printing a STATUS, it records for this
# window what it showed (the path, and its mtime in ns, size and inode, taken before printing) in
# <config>/brain-sessions/seen-<window key>, so the UserPromptSubmit hook (ctx-nudge.sh) can say when another
# session changes that STATUS.

LIMIT=9000   # characters of STATUS printed in full; longer files are cut to this many, with a notice
CAP=10000    # Claude Code replaces hook output over 10,000 characters with a 2,000-character preview

here="${BASH_SOURCE[0]%/*}"; [ "$here" = "${BASH_SOURCE[0]}" ] && here=.
. "$here/brain-lib.sh" 2>/dev/null || exit 0

# session_folder <input>: this session's folder, symlinks resolved (the input's cwd, else $CLAUDE_PROJECT_DIR, else
# $PWD); fails if it cannot be resolved.
session_folder() {
  local cwd
  cwd=$(cd_json_get "$1" cwd 2>/dev/null) || cwd=""
  [ -n "$cwd" ] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
  cd -P -- "$cwd" 2>/dev/null && pwd -P
}

# last_used <folder>: the brain last attached (with /brain) by a window whose session ran in <folder>, from
# <config>/brain-sessions/last-used; "" if none.
last_used() {
  local lu="$(cd_config_dir)/brain-sessions/last-used"
  [ -f "$lu" ] || return 0
  head -c 262144 -- "$lu" 2>/dev/null | D="$1" awk -F '\t' 'NF == 2 && $1 == ENVIRON["D"] { n = $2 } END { print n }'
}

# no_brain <input>: the one-line hint for a session with no brain (not after a compaction: the start said it). It
# names the brains, and the one last used from this folder if it still exists; it never attaches one.
no_brain() {
  local names n=0 shown="" more="" last="" dir home ok=1
  [ "$(cd_json_get "$1" source 2>/dev/null)" = compact ] && return
  names=$(cd_brain_names) || ok=0
  dir=$(session_folder "$1") || dir=""
  if [ "$ok" = 1 ] && [ -n "$names" ]; then
    while IFS= read -r name; do
      n=$((n + 1)); [ "$n" -le 10 ] && shown="${shown:+$shown, }$name"
    done <<<"$names"
    [ "$n" -gt 10 ] && more=" and $((n - 10)) more"
    [ -n "$dir" ] && last=$(last_used "$dir")
    if [ -n "$last" ] && printf '%s\n' "$names" | grep -qxF -- "$last"; then
      printf 'No brain attached. Last used here: %s (type /brain %s). All brains: %s%s.\n' "$last" "$last" "$shown" "$more"
      return
    fi
  fi
  # An old pointer here (earlier versions loaded it): only tested for, never opened, and not in $HOME (~/.claude).
  home=$(cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P) || home=""
  if [ -n "$dir" ] && [ "$dir" != "$home" ] && { [ -e "$dir/.claude/brain" ] || [ -L "$dir/.claude/brain" ]; }; then
    echo "No brain attached. This folder has an old brain pointer; /brain add <name> registers it."; return
  fi
  if [ "$ok" = 0 ]; then
    echo "No brain attached. Type /brain to list the brains, /brain <name> to attach one."
  elif [ -z "$names" ]; then
    echo "No brains yet. /brain new <name> creates one."
  else
    printf 'No brain attached. Brains: %s%s. Type /brain <name> to attach one.\n' "$shown" "$more"
  fi
}

# mark_of <file>: "<mtime in ns> <size> <inode>" of <file>, the way ctx-nudge.sh tells a changed STATUS.
mark_of() { python3 -I -c 'import os, sys; s = os.stat(sys.argv[1]); print(s.st_mtime_ns, s.st_size, s.st_ino)' "$1" 2>/dev/null; }

# record_seen <mark>: remember, for this window, which STATUS it was shown and its mark (taken before printing, so
# a write while it prints counts as a change). Never written through a symlink; any failure is ignored.
record_seen() {
  local key ses tmp
  [ -n "$1" ] || return 0
  key=$(cd_window_key "$input") || return 0
  ses="$(cd_config_dir)/brain-sessions"
  if [ ! -e "$ses" ] && [ ! -L "$ses" ]; then (umask 077 && mkdir -p -- "$ses") 2>/dev/null || return 0; fi
  [ -d "$ses" ] && [ ! -L "$ses" ] && [ ! -d "$ses/seen-$key" ] || return 0
  tmp=$(mktemp "$ses/.seen.XXXXXX" 2>/dev/null) || return 0
  if printf '%s\n%s\n' "$status" "$1" > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$ses/seen-$key" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$tmp" 2>/dev/null
  return 0
}

input=""
if [ ! -t 0 ]; then
  input=$(cat 2>/dev/null)
fi
cd_select_brain "$input"   # from here on LC_ALL=C: count and match bytes
case $? in
  0) ;;
  1) printf '(Project brain not loaded: %s %s.)\n' "$CD_SUBJECT" "$CD_REFUSED"; exit 0 ;;
  2) [ "$CD_NAME" = none ] || no_brain "$input"; exit 0 ;;   # no hint when the user chose no brain
  *) exit 0 ;;   # CD_HOOKS=off, or input that is not a JSON object
esac
status="$CD_STATUS"; size="$CD_SIZE"
mark=$(mark_of "$status")   # before printing: what this window is about to read

# Print it (cut on a character boundary if too long), then one line naming the brain and its place: for the
# work's current state it beats older notes in memory, while the rules in CLAUDE.md still apply.
# Characters are counted as Claude Code counts them: JavaScript string length, so most characters are 1
# and emoji (4-byte UTF-8) are 2. Bytes are never fewer, so a file of at most $budget bytes always fits.
loaded="(Project brain loaded from $status (brain \"$CD_NAME\", chosen with $CD_HOW). For this work's current state it\
 overrides older notes in memory; rules in CLAUDE.md still apply. Working rules: context-discipline skill.)"
name=$(basename -- "$status" 2>/dev/null) || name=""
# 200: room for the trim notice's fixed text and numbers, plus the file name it gives; ${#...} counts bytes
# (>= characters)
budget=$((CAP - 200 - ${#name} - ${#loaded}))
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
    "$name" "$(commas "$chars")" "$(commas "$budget")" "$(commas "$2")"
else
  cat "$status" 2>/dev/null
  # keep the closing line on its own line even if the file lacks a final newline
  [ -n "$(tail -c 1 "$status" 2>/dev/null)" ] && printf '\n'
fi
printf '%s\n' "$loaded"
record_seen "$mark"
exit 0
