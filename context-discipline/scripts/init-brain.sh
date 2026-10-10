#!/usr/bin/env bash
# init-brain.sh <project-root> [status-relpath]
#
# Sets up a project brain for the context-discipline skill:
#   - <status-relpath> (default STATUS.md) from the STATUS template
#   - 00-Project-Overview.md next to it, from the overview template
#   - <project-root>/.claude/brain, the pointer the SessionStart hook (brain-hook.sh) follows
#   - the line .claude/compactions/ in <project-root>/.gitignore (created if missing), so the compaction
#     summaries the PostCompact hook (compact-log.sh) saves are never committed
# Templates come from ../references/brain-templates.md. Existing files are never overwritten, and a
# symlink is never written through; the summary says which ones already existed. An existing pointer is read
# only as the hooks read it (brain-lib.sh: a regular file, its first 4,096 bytes).

set -u

usage() { echo "usage: $(basename "$0") <project-root> [status-relpath (default STATUS.md)]" >&2; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage
refuse() { echo "init-brain: $*" >&2; exit 1; }

root_in="$1"
status_rel="${2:-STATUS.md}"
[ -d "$root_in" ] || refuse "not a directory: $root_in"
root=$(cd -P "$root_in" && pwd -P) || exit 1

here=$(cd "$(dirname "$0")" && pwd -P)
templates="$here/../references/brain-templates.md"
[ -r "$templates" ] || refuse "templates not found: $templates"
# The hooks' own rules for reading a pointer (cd_check_pointer), so an existing one is judged as they judge it.
. "$here/brain-lib.sh" 2>/dev/null || refuse "brain-lib.sh not found next to $(basename "$0")"

# The hook never loads a brain whose pointer sits in $HOME or /, so refuse those roots.
home=$(cd -P "${HOME:-/}" 2>/dev/null && pwd -P) || home="${HOME%/}"
[ "$root" = / ] && refuse "refusing to use / as a project root; pass the project's own folder."
[ "$root" = "$home" ] && refuse "refusing to set up a brain in your home folder ($root): the hook stops before \$HOME, \
so it would never load it, and $root/.claude is Claude Code's global config. Pass a project folder instead."

# physical <path>: <path> with every symlink resolved, its last part included. Fails if a folder is missing.
physical() {
  local p="$1" d b t n=0
  while :; do
    d=$(dirname -- "$p") && b=$(basename -- "$p") || return 1
    d=$(cd -P -- "$d" 2>/dev/null && pwd -P) || return 1
    if [ "$d" = / ]; then p="/$b"; else p="$d/$b"; fi
    [ -L "$p" ] || break
    n=$((n + 1)); [ "$n" -le 20 ] || return 1
    t=$(readlink -- "$p") || return 1
    case "$t" in /*) p="$t" ;; *) p="$d/$t" ;; esac
  done
  printf '%s\n' "$p"
}

# The hook only loads a STATUS file inside the project root, named by a relative path; check that here too.
case "$status_rel" in
  /*|'~'*) refuse "the STATUS path must be relative to the project root, because the hook only loads files inside it: $status_rel" ;;
  */|.|*/.) refuse "the STATUS path names a folder, not a file: $status_rel" ;;
esac
case "/$status_rel/" in
  */../*) refuse "the STATUS path must not contain '..': $status_rel" ;;
esac
status="$root/$status_rel"
[ -d "$status" ] && refuse "the STATUS path names a folder, not a file: $status_rel"
check="$status"   # the STATUS file, or the deepest folder on its way that already exists
while [ ! -e "$check" ] && [ ! -L "$check" ] && [ ! -d "$(dirname "$check")" ]; do check=$(dirname "$check"); done
real=$(physical "$check") || refuse "cannot resolve the STATUS path: $status_rel"
case "$real" in
  "$root"|"$root"/*) ;;
  *) refuse "the STATUS path leads outside the project root through a symlink: $status_rel" ;;
esac
overview="$(dirname "$status")/00-Project-Overview.md"
pointer="$root/.claude/brain"
project=$(basename "$root")
today=$(date +%Y-%m-%d)

# Print the fenced block that follows "<!-- template:NAME -->", with placeholders filled.
template() {
  PROJECT="$project" TODAY="$today" awk -v name="$1" '
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
# counts as existing: a cloned repo's planted link is never written through)
create() {
  local file="$1" name="$2" body
  if [ -e "$file" ] || [ -L "$file" ]; then
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

# An existing pointer (perhaps from a cloned repo) is untrusted: it is read only if it is a regular file, and then
# only as the hooks read it (the first 4,096 bytes). Its text is shown only if the hook would accept it.
if [ -L "$pointer" ] && [ ! -e "$pointer" ]; then
  pointer_state="exists, left untouched; a symlink to a missing file, so the hook ignores it"
elif [ -e "$pointer" ] && [ ! -f "$pointer" ]; then
  pointer_state="exists, left untouched; not a regular file, so the hook ignores it"
elif [ -e "$pointer" ]; then
  CD_POINTER="$pointer"; CD_ROOT="$root"
  if cd_check_pointer; then
    pointer_state="exists, left untouched; points to ${CD_REL//[[:cntrl:]]/?}"
  else
    pointer_state="exists, left untouched; the hook refuses it because it ${CD_REFUSED:-cannot be checked}"
  fi
elif [ -L "$root/.claude" ] || { [ -e "$root/.claude" ] && [ ! -d "$root/.claude" ]; }; then
  pointer_state="NOT created: $root/.claude is a symlink or not a folder; create the pointer yourself"
else
  mkdir -p "$root/.claude" && {
    echo "# Project brain pointer (context-discipline skill). The SessionStart hook prints the file named on"
    echo "# the first non-comment line; relative paths are relative to the project root. Delete to disable."
    echo "$status_rel"
  } > "$pointer" && pointer_state="created; points to $status_rel" || pointer_state="NOT created: write failed"
fi

# Keep the compaction summaries that compact-log.sh saves out of git: they can quote anything the session saw.
ignore_line='.claude/compactions/'
gitignore="$root/.gitignore"
if [ -L "$gitignore" ] || { [ -e "$gitignore" ] && [ ! -f "$gitignore" ]; }; then
  ignore_state="NOT changed: not a regular file; add the line $ignore_line to it yourself"
elif [ -f "$gitignore" ] && [ "$(wc -c < "$gitignore" 2>/dev/null | tr -d '[:space:]')" -gt 1048576 ] 2>/dev/null; then
  ignore_state="NOT changed: over 1 MB, so not read; add the line $ignore_line to it yourself"
elif [ -f "$gitignore" ] && tr -d '\r' < "$gitignore" | grep -Eqx '[[:space:]]*/?\.claude/compactions/?[[:space:]]*'; then
  ignore_state="exists, already ignores $ignore_line"
elif [ -f "$gitignore" ]; then
  nl=$'\n'; grep -q $'\r$' "$gitignore" 2>/dev/null && nl=$'\r\n'
  lead=""; [ -s "$gitignore" ] && [ -n "$(tail -c 1 "$gitignore")" ] && lead="$nl"
  printf '%s%s%s' "$lead" "$ignore_line" "$nl" >> "$gitignore" 2>/dev/null \
    && ignore_state="added $ignore_line" || ignore_state="NOT changed: write failed; add the line $ignore_line yourself"
else
  printf '%s\n' "$ignore_line" > "$gitignore" 2>/dev/null \
    && ignore_state="created; ignores $ignore_line" || ignore_state="NOT changed: write failed; add the line $ignore_line yourself"
fi

echo "Project brain for $root:"
echo "  STATUS:    $status ($status_state)"
echo "  Overview:  $overview ($overview_state)"
echo "  Pointer:   $pointer ($pointer_state)"
echo "  Gitignore: $gitignore ($ignore_state)"
case "$status_state$overview_state$pointer_state" in
  *"NOT created"*) echo "Some files were NOT created; fix the cause above and run again." >&2; exit 1 ;;
esac
echo "Next: fill in both files (keep STATUS under 9,000 characters: wc -m), then commit them and .claude/brain if this is a repo."
