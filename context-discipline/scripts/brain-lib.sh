# brain-lib.sh -- shared by the context-discipline hooks (brain-hook.sh, compact-log.sh, ctx-nudge.sh).
# Sourced, not run. Finds a session's project brain with one set of rules, so every hook agrees on which
# folders are brain projects:
#   - walk up from the session's cwd to the nearest "<dir>/.claude/brain" pointer, stopping before $HOME
#     and "/" (so ~/.claude, the global config, is never read as a brain);
#   - the pointer's first non-empty line not starting with "#" names the STATUS file, relative to <dir>;
#   - it is accepted only if, with every symlink resolved, it is a regular text file inside <dir>.
# Never writes files, never touches the network.

# cd_json_get <json> <field>: print the top-level string <field> of <json> ("" if missing or not a string).
# Fails if <json> is not a JSON object, or if neither jq nor python3 is installed.
cd_json_get() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -j --arg k "$2" 'if type == "object" then (.[$k] | strings) // empty else error end' \
      2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -I -c 'import json, sys
d = json.load(sys.stdin)
if not isinstance(d, dict):
    sys.exit(1)
v = d.get(sys.argv[1])
sys.stdout.write(v if isinstance(v, str) else "")' "$2" 2>/dev/null
  else
    return 1
  fi
}

# cd_session_cwd <json>: print the session's working directory: the input's "cwd", else $CLAUDE_PROJECT_DIR,
# else $PWD. Fails if the input is not a JSON object (Claude Code always sends one). Empty input, or no JSON
# parser at all, uses the fallbacks.
cd_session_cwd() {
  local cwd="" rc=0
  if [ -n "$1" ]; then
    cwd=$(cd_json_get "$1" cwd) || rc=$?
    if [ "$rc" != 0 ] && { command -v jq || command -v python3; } >/dev/null 2>&1; then
      return 1
    fi
  fi
  [ -z "$cwd" ] && cwd="${CLAUDE_PROJECT_DIR:-}"
  [ -z "$cwd" ] && cwd="$PWD"
  printf '%s\n' "$cwd"
}

# cd_find_brain <cwd>: walk up from <cwd> to the nearest <dir>/.claude/brain, stopping before $HOME and "/".
# Both <cwd> and $HOME are compared with every symlink and ".." resolved, so neither a symlinked HOME nor
# "x/.." reaches ~/.claude. Sets CD_POINTER (the pointer file) and CD_ROOT (<dir>, symlinks resolved).
# Fails if <cwd> is not an absolute path to an existing folder, or no pointer is found.
cd_find_brain() {
  local cwd="$1" home dir
  CD_POINTER=""; CD_ROOT=""
  case "$cwd" in
    /*) ;;
    *) return 1 ;;
  esac
  cwd=$(cd -P -- "$cwd" 2>/dev/null && pwd -P) || return 1
  home=$(cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P) || home="${HOME%/}"
  dir="${cwd%/}"
  while [ -n "$dir" ] && [ "$dir" != "$home" ]; do
    if [ -f "$dir/.claude/brain" ]; then
      CD_POINTER="$dir/.claude/brain"
      CD_ROOT="$dir"
      return 0
    fi
    dir="${dir%/*}"   # the parent; "/" itself becomes "" and ends the walk
  done
  return 1
}

# cd_physical <path>: <path> with every symlink resolved, its last part included. Fails if a folder is missing.
cd_physical() {
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

# cd_check_pointer: read the STATUS path from $CD_POINTER and accept it only if it is a text file inside
# $CD_ROOT. Sets LC_ALL=C for the rest of the script (bytes are counted and matched from here on).
# On success sets CD_REL (the path as the pointer gives it), CD_STATUS (the file, symlinks resolved) and
# CD_SIZE (its size in bytes).
# Returns 1 with CD_REFUSED set to the reason (to follow "<pointer> ") if the pointer is refused,
# 2 if the project folder cannot be read at all.
cd_check_pointer() {
  local line rel="" size text
  LC_ALL=C; export LC_ALL
  CD_REL=""; CD_STATUS=""; CD_SIZE=""; CD_REFUSED=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#$'\357\273\277'}"            # drop a UTF-8 byte-order mark
    line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
    case "$line" in
      ''|'#'*) continue ;;
    esac
    rel="$line"
    break
  done < "$CD_POINTER" 2>/dev/null
  [ -n "$rel" ] || { CD_REFUSED="names no file"; return 1; }
  case "$rel" in
    /*|'~'*) CD_REFUSED="must name its STATUS file by a path relative to its project folder"; return 1 ;;
  esac
  CD_ROOT=$(cd -P -- "$CD_ROOT" 2>/dev/null && pwd -P) || return 2
  CD_STATUS=$(cd_physical "$CD_ROOT/$rel") || { CD_STATUS=""; CD_REFUSED="names a missing file"; return 1; }
  case "$CD_STATUS" in
    "$CD_ROOT"/*) ;;
    *) CD_STATUS=""; CD_REFUSED="names a file outside its project folder"; return 1 ;;
  esac
  [ -f "$CD_STATUS" ] || { CD_STATUS=""; CD_REFUSED="names a missing file, or something that is not a regular file"; return 1; }
  [ -r "$CD_STATUS" ] || { CD_STATUS=""; CD_REFUSED="names a file that cannot be read"; return 1; }
  size=$(wc -c < "$CD_STATUS" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) CD_STATUS=""; return 2 ;;
  esac
  text=$(tr -d '\000' < "$CD_STATUS" 2>/dev/null | wc -c | tr -d '[:space:]')
  [ "$text" = "$size" ] || { CD_STATUS=""; CD_REFUSED="names a file that is not text"; return 1; }
  CD_REL="$rel"; CD_SIZE="$size"
  return 0
}

# cd_brain_of <json>: the whole lookup for a hook's input. True (with CD_ROOT, CD_REL and CD_STATUS set) only
# if the session's cwd is in a project whose brain pointer is accepted.
cd_brain_of() {
  local cwd
  cwd=$(cd_session_cwd "$1") || return 1
  cd_find_brain "$cwd" || return 1
  cd_check_pointer
}
