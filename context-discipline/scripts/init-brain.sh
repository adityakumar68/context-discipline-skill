#!/usr/bin/env bash
# init-brain.sh <project-root> [status-relpath]
#
# Sets up a project brain for the context-discipline skill:
#   - <status-relpath> (default STATUS.md) from the STATUS template
#   - 00-Project-Overview.md next to it, from the overview template
#   - <project-root>/.claude/brain, the pointer the SessionStart hook (brain-hook.sh) follows
# Templates come from ../references/brain-templates.md. Existing files are never
# overwritten; the summary says which ones already existed.

set -u

usage() { echo "usage: $(basename "$0") <project-root> [status-relpath (default STATUS.md)]" >&2; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage

root_in="$1"
status_rel="${2:-STATUS.md}"
[ -d "$root_in" ] || { echo "init-brain: not a directory: $root_in" >&2; exit 1; }
root=$(cd "$root_in" && pwd -P) || exit 1

here=$(cd "$(dirname "$0")" && pwd -P)
templates="$here/../references/brain-templates.md"
[ -r "$templates" ] || { echo "init-brain: templates not found: $templates" >&2; exit 1; }

case "$status_rel" in
  /*) status="$status_rel" ;;
  *) status="$root/$status_rel" ;;
esac
overview="$(dirname "$status")/00-Project-Overview.md"
pointer="$root/.claude/brain"
project=$(basename "$root")
today=$(date +%Y-%m-%d)

# Print the fenced block that follows "<!-- template:NAME -->", with placeholders filled.
template() {
  awk -v name="$1" -v project="$project" -v today="$today" '
    function fill(s,   out, i) {
      out = ""
      while ((i = index(s, "{{PROJECT}}")) > 0) { out = out substr(s, 1, i - 1) project; s = substr(s, i + 11) }
      s = out s; out = ""
      while ((i = index(s, "{{DATE}}")) > 0) { out = out substr(s, 1, i - 1) today; s = substr(s, i + 8) }
      return out s
    }
    $0 == "<!-- template:" name " -->" { found = 1; next }
    found == 1 && /^~~~/ { found = 2; next }
    found == 2 && /^~~~/ { exit }
    found == 2 { print fill($0) }
  ' "$templates"
}

# create FILE TEMPLATE-NAME -> echoes "created" or "exists, left untouched"
create() {
  local file="$1" name="$2" body
  if [ -e "$file" ]; then
    echo "exists, left untouched"
    return
  fi
  body=$(template "$name")
  if [ -z "$body" ]; then
    echo "NOT created: template '$name' missing from $templates"
    return
  fi
  mkdir -p "$(dirname "$file")" && printf '%s\n' "$body" > "$file" && echo "created" || echo "NOT created: write failed"
}

status_state=$(create "$status" status)
overview_state=$(create "$overview" overview)

if [ -e "$pointer" ]; then
  current=$(grep -v '^[[:space:]]*#' "$pointer" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 1)
  pointer_state="exists, left untouched; points to ${current:-nothing}"
else
  mkdir -p "$root/.claude" && {
    echo "# Project brain pointer (context-discipline skill). The SessionStart hook prints the file named on"
    echo "# the first non-comment line; relative paths are relative to the project root. Delete to disable."
    echo "$status_rel"
  } > "$pointer" && pointer_state="created; points to $status_rel" || pointer_state="NOT created: write failed"
fi

echo "Project brain for $root:"
echo "  STATUS:   $status ($status_state)"
echo "  Overview: $overview ($overview_state)"
echo "  Pointer:  $pointer ($pointer_state)"
echo "Next: fill in both files (keep STATUS under 9,000 characters: wc -m), then commit them and .claude/brain if this is a repo."
