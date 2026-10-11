#!/usr/bin/env bash
# init-brain.sh <brain-folder> [name]
#
# Copies the brain templates into a brain folder (what /brain new runs; /brain new also registers the brain and
# attaches it to the window):
#   - STATUS.md, from the STATUS template
#   - 00-Project-Overview.md, from the overview template
# Templates come from ../references/brain-templates.md; {{PROJECT}} becomes [name] (default: the folder's name)
# and {{DATE}} today. The folder is created if it is missing and its parent exists. Nothing else is written: no
# .claude/brain pointer (the hooks never read one; a session gets a brain with /brain or CD_BRAIN) and no
# .gitignore line (compaction logs go to <config>/brain-logs/). Existing files are never overwritten and a symlink
# is never written through; the summary says which files already existed. $HOME and / are refused as the folder.

set -u

usage() { echo "usage: $(basename "$0") <brain-folder> [name]" >&2; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage
refuse() { echo "init-brain: $*" >&2; exit 1; }

folder_in="$1"
name="${2-}"
here=$(cd "$(dirname "$0")" && pwd -P)
templates="$here/../references/brain-templates.md"
[ -r "$templates" ] || refuse "templates not found: $templates"
. "$here/brain-lib.sh" 2>/dev/null || refuse "brain-lib.sh not found next to $(basename "$0")"
if [ -n "$name" ] && ! cd_valid_name "$name"; then
  refuse "\"$(cd_printable "$name")\" is not a brain name (1 to 32 of a-z, 0-9 and -). The second argument is the" \
    "brain's name; its STATUS is always <brain-folder>/STATUS.md."
fi

# The folder: created if missing (its parent must exist); never $HOME or /, where the hooks would refuse it.
home=$(cd -P "${HOME:-/}" 2>/dev/null && pwd -P) || home="${HOME%/}"
if [ ! -d "$folder_in" ]; then
  { [ -e "$folder_in" ] || [ -L "$folder_in" ]; } && refuse "not a folder: $folder_in"
  [ -d "$(dirname -- "$folder_in")" ] || refuse "not a directory, nor is its parent: $folder_in"
  mkdir -- "$folder_in" 2>/dev/null || refuse "cannot create $folder_in"
fi
folder=$(cd -P "$folder_in" && pwd -P) || exit 1
[ "$folder" = / ] && refuse "refusing to use / as a brain folder; give the brain a folder of its own."
[ "$folder" = "$home" ] && refuse "refusing to use your home folder ($folder) as a brain folder: the hooks never \
load a brain whose folder is \$HOME. Give the brain a folder of its own."

[ -n "$name" ] || name=$(basename "$folder")
status="$folder/STATUS.md"
overview="$folder/00-Project-Overview.md"
today=$(date +%Y-%m-%d)

# Print the fenced block that follows "<!-- template:NAME -->", with placeholders filled.
template() {
  PROJECT="$name" TODAY="$today" awk -v name="$1" '
    function fill(s,   out, i) {
      out = ""
      while ((i = index(s, "{{PROJECT}}")) > 0) { out = out substr(s, 1, i - 1) ENVIRON["PROJECT"]; s = substr(s, i + 11) }
      s = out s; out = ""
      while ((i = index(s, "{{DATE}}")) > 0) { out = out substr(s, 1, i - 1) ENVIRON["TODAY"]; s = substr(s, i + 8) }
      return out s
    }
    $0 == "<!-- template:" name " -->" { found = 1; next }
    found == 1 && /^~~~/ { found = 2; next }
    found == 2 && /^~~~/ { exit }
    found == 2 { print fill($0) }
  ' "$templates"
}

# create FILE TEMPLATE-NAME -> echoes "created" or "exists, left untouched" (a symlink, even a dangling one,
# counts as existing, so a planted link is never written through)
create() {
  local file="$1" tname="$2" body
  if [ -e "$file" ] || [ -L "$file" ]; then
    echo "exists, left untouched"
    return
  fi
  body=$(template "$tname")
  if [ -z "$body" ]; then
    echo "NOT created: template '$tname' missing from $templates"
    return
  fi
  printf '%s\n' "$body" > "$file" 2>/dev/null && echo "created" || echo "NOT created: write failed"
}

status_state=$(create "$status" status)
overview_state=$(create "$overview" overview)

echo "Brain folder $folder:"
echo "  STATUS:    $status ($status_state)"
echo "  Overview:  $overview ($overview_state)"
case "$status_state$overview_state" in
  *"NOT created"*) echo "Some files were NOT created; fix the cause above and run again." >&2; exit 1 ;;
esac
echo "Next: fill in both files (keep STATUS under 9,000 characters: wc -m)."
