#!/usr/bin/env bash
# compact-log.sh -- PostCompact hook for the context-discipline skill.
#
# Saves the summary Claude Code wrote at a compaction (the hook input's "compact_summary") to
#   <config>/brain-logs/<brain name>/<YYYY-MM-DD-HHMMSS>-<first 8 characters of the session id>.md
# (<config> being $CLAUDE_CONFIG_DIR or ~/.claude), so what the compaction kept can be checked, and what it dropped
# recovered from the transcript.
#
# Only when the session has a brain, picked as the SessionStart hook picks it (brain-lib.sh): the one chosen with
# /brain in this window, else CD_BRAIN, else the one the session remembered from an earlier window. Never in the brain's own folder (it may be a git repo, and a summary can
# quote anything the session saw) and never in the session's folder. With no brain it does nothing.
# The log folders are created private (mode 700) and never written through a symlink; existing files are never
# overwritten; files are created readable by their owner only.
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

cd_select_brain "$input" >/dev/null 2>&1 || exit 0   # sets CD_NAME; from here on LC_ALL=C

# The log folder: <config>/brain-logs/<name>, a real folder (not a symlink), created private if missing.
logs="$(cd_config_dir)/brain-logs/$CD_NAME"
if [ ! -e "$logs" ] && [ ! -L "$logs" ]; then
  (umask 077 && mkdir -p -- "$logs") 2>/dev/null || exit 0
fi
[ ! -L "$logs" ] && [ -d "$logs" ] || exit 0

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
