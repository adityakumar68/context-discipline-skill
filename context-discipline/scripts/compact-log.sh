#!/usr/bin/env bash
# compact-log.sh -- PostCompact hook for the context-discipline skill.
#
# Saves the summary Claude Code wrote at a compaction (the hook input's "compact_summary") to
#   <project root>/.claude/compactions/<YYYY-MM-DD-HHMMSS>-<first 8 characters of the session id>.md
# so what the compaction kept can be checked, and what it dropped recovered from the transcript.
#
# Only when the session has a brain, picked as the SessionStart hook picks it (brain-lib.sh): the one chosen with
# /brain in this window, else CD_BRAIN, else the .claude/brain pointer the session's cwd leads up to. The summary
# goes to that brain's project, whatever folder the session is in. With no brain ("none", or no pointer) it does
# nothing.
# The log folder must be inside the project (a symlink out of it is refused); existing files are never
# overwritten; files are created readable by their owner only. init-brain.sh adds .claude/compactions/ to the
# project's .gitignore, because a summary can quote anything the session saw.
#
# Contract: prints nothing, always exits 0 (a PostCompact hook cannot change the compaction, and a failure here
# must never disturb the session). Never touches the network.

here="${BASH_SOURCE[0]%/*}"; [ "$here" = "${BASH_SOURCE[0]}" ] && here=.
. "$here/brain-lib.sh" 2>/dev/null || exit 0

input=""
if [ ! -t 0 ]; then
  input=$(cat 2>/dev/null)
fi
[ -n "$input" ] || exit 0
summary=$(cd_json_get "$input" compact_summary 2>/dev/null) || exit 0
[ -n "$summary" ] || exit 0
sid=$(cd_json_get "$input" session_id 2>/dev/null) || sid=""
trigger=$(cd_json_get "$input" trigger 2>/dev/null) || trigger=""

cd_select_brain "$input" >/dev/null 2>&1 || exit 0   # sets CD_ROOT; from here on LC_ALL=C

# The log folder: <root>/.claude/compactions, with no symlink on the way that leaves the project.
claude_dir=$(cd_physical "$CD_ROOT/.claude" 2>/dev/null) || exit 0
[ "$claude_dir" = "$CD_ROOT/.claude" ] && [ -d "$claude_dir" ] || exit 0
logs="$claude_dir/compactions"
if [ -e "$logs" ] || [ -L "$logs" ]; then
  [ ! -L "$logs" ] && [ -d "$logs" ] || exit 0
else
  (umask 077 && mkdir -- "$logs") 2>/dev/null || exit 0
fi

# File name: local time, then the first 8 characters of the session id that are safe in a file name.
sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9_-' | head -c 8)
[ -n "$sid" ] || sid=unknown
case "$trigger" in
  auto|manual) ;;
  *) trigger=unknown ;;
esac
stamp=$(date +%Y-%m-%d-%H%M%S 2>/dev/null) || exit 0
when=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null) || when="$stamp"

# Create the file with noclobber, so an existing file (or a symlink planted there) is never written through.
set -C
umask 077
name="$stamp-$sid"; n=1
while [ "$n" -le 50 ]; do
  file="$logs/$name.md"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    { printf '# Compaction summary, %s (%s, session %s)\n\n' "$when" "$trigger" "$sid"
      printf '%s\n' "$summary"; } > "$file" 2>/dev/null
    break
  fi
  n=$((n + 1)); name="$stamp-$sid-$n"
done
exit 0
