# brain-lib.sh -- shared by the context-discipline hooks (brain-hook.sh, compact-log.sh, ctx-nudge.sh) and the
# /brain command (brain.sh). Sourced, not run. Picks a session's project brain with one set of rules, so every
# hook agrees on which brain a session uses (cd_select_brain), first match wins:
#   1. the choice made with /brain <name> or /brain none in this Claude Code window: the file
#      <config>/brain-sessions/<key>, where <config> is $CLAUDE_CONFIG_DIR or ~/.claude and <key> is
#      pid-$CLAUDE_PID (the Claude Code process, so the choice survives /clear and compaction), else
#      sid-<session id>;
#   2. CD_BRAIN=<name> or CD_BRAIN=none in the environment;
#   3. the folder walk-up: from the session's cwd to the nearest "<dir>/.claude/brain" pointer, stopping before
#      $HOME and "/" (so ~/.claude, the global config, is never read as a brain). The pointer's first non-empty
#      line not starting with "#" names the STATUS file, relative to <dir>; only the pointer's first 4,096 bytes
#      are read, and that line may be at most 1,024 bytes (a cloned repo's pointer is untrusted: a huge line would
#      otherwise stall every hook).
# A name is looked up in the registry <config>/brains.json:
#   {"version": 1, "brains": {"<name>": {"root": "<project folder>", "status": "<STATUS file>"}}}
# (absolute paths). Either way the STATUS file is accepted only if, with every symlink resolved, it is a regular
# text file inside its project folder, and that folder is neither $HOME nor "/".
# Never writes files, never touches the network.

CD_POINTER_READ=4096   # bytes of a pointer that are read (the refusal reasons below say 4,096)
CD_PATH_MAX=1024       # bytes in its path line, PATH_MAX on macOS (the refusal reasons say 1,024)
CD_CHOICE_READ=1024    # bytes of a window's choice file that are read
CD_REGISTRY_CAP=1000000   # bytes; a larger registry is not read (the refusal reasons say 1,000,000)

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
# Fails if <cwd> is not an absolute path to an existing folder, or no pointer is found, or if the environment
# sets CD_HOOKS=off (all the hooks then act as outside a brain project: for headless runs and benchmarks).
cd_find_brain() {
  local cwd="$1" home dir
  CD_POINTER=""; CD_ROOT=""
  [ "${CD_HOOKS:-}" = off ] && return 1
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
    d=$(dirname -- "$p" 2>/dev/null) && b=$(basename -- "$p" 2>/dev/null) || return 1
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
  local line="" rel="" size text ended=0 more=""
  LC_ALL=C; export LC_ALL
  CD_REL=""; CD_STATUS=""; CD_SIZE=""; CD_REFUSED=""
  # Only the first $CD_POINTER_READ bytes are read. The pointer is a regular file (cd_find_brain checks with -f),
  # so opening it cannot block; the cap keeps a huge pointer from costing memory or (bash 3.2 trims strings in
  # quadratic time) seconds of CPU.
  while :; do
    if IFS= read -r line; then ended=1; elif [ -n "$line" ]; then ended=0; else break; fi
    line="${line%$'\r'}"
    line="${line#$'\357\273\277'}"            # drop a UTF-8 byte-order mark
    line="${line#"${line%%[![:space:]]*}"}"   # trim leading whitespace
    line="${line%"${line##*[![:space:]]}"}"   # trim trailing whitespace
    case "$line" in
      ''|'#'*) continue ;;
    esac
    rel="$line"
    break
  done < <(head -c "$CD_POINTER_READ" -- "$CD_POINTER" 2>/dev/null)
  size=$(wc -c < "$CD_POINTER" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  [ "$size" -gt "$CD_POINTER_READ" ] && more=" in its first 4,096 bytes"
  # A line without a newline is whole only if the file ends there; one cut by the read is never used.
  if [ -n "$rel" ] && { [ "${#rel}" -gt "$CD_PATH_MAX" ] || { [ "$ended" = 0 ] && [ -n "$more" ]; }; }; then
    CD_REFUSED="names no file: its path line must be at most 1,024 bytes and end within its first 4,096"; return 1
  fi
  [ -n "$rel" ] || { CD_REFUSED="names no file$more"; return 1; }
  case "$rel" in
    /*|'~'*) CD_REFUSED="must name its STATUS file by a path relative to its project folder"; return 1 ;;
  esac
  CD_ROOT=$(cd -P -- "$CD_ROOT" 2>/dev/null && pwd -P) || return 2
  cd_check_status "$CD_ROOT/$rel" || return $?
  CD_REL="$rel"
  return 0
}

# cd_check_status <path>: accept <path> as the STATUS file of the project folder $CD_ROOT (symlinks already
# resolved) only if, with every symlink resolved, it is a regular, readable text file inside that folder.
# Sets CD_STATUS (the file, symlinks resolved), CD_SIZE (bytes) and CD_REL (its path below $CD_ROOT).
# Returns 1 with CD_REFUSED set if it is refused, 2 if it cannot be measured.
cd_check_status() {
  local size text
  CD_STATUS=$(cd_physical "$1") || { CD_STATUS=""; CD_REFUSED="names a missing file"; return 1; }
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
  CD_SIZE="$size"; CD_REL="${CD_STATUS#"$CD_ROOT"/}"
  return 0
}

# --- named brains ---------------------------------------------------------------------------------------------

# cd_config_dir: Claude Code's config folder, where the registry and the windows' choices live.
cd_config_dir() { printf '%s\n' "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"; }

# cd_valid_name <name>: true if <name> can name a brain: 1 to 32 of a-z, 0-9 and "-", not starting with "-".
# (Spelled out, not [a-z]: ranges depend on the locale.)
cd_valid_name() {
  case "$1" in
    ''|-*|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

# cd_printable <text> [max]: <text> with control characters replaced by "?", at most <max> bytes (default 64),
# for messages.
cd_printable() { printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' '?' | head -c "${2:-64}"; }

# cd_process_start <pid>: when process <pid> started, as ps prints it in the C locale and UTC ("" if ps cannot
# tell), so the writer and the readers agree whatever their locale and time zone. Kept with a window's choice, so a
# later process that gets the same PID does not inherit the choice.
cd_process_start() {
  local s
  s=$(LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9: ' | LC_ALL=C tr -s ' ')
  s="${s# }"; printf '%s\n' "${s% }"
}

# cd_window_key <json>: the key of this Claude Code window's choice file: pid-$CLAUDE_PID (the Claude Code
# process: the same for every hook, the Bash tool and skill commands, and across /clear), else sid-<session id>
# (the input's session_id, else $CLAUDE_CODE_SESSION_ID; /clear starts a new one). Fails if there is neither.
cd_window_key() {
  local pid="${CLAUDE_PID:-}" sid=""
  case "$pid" in ''|0*|*[!0-9]*) pid="" ;; esac
  if [ -n "$pid" ] && [ "${#pid}" -le 10 ]; then printf 'pid-%s\n' "$pid"; return 0; fi
  [ -n "$1" ] && sid=$(cd_json_get "$1" session_id 2>/dev/null)
  [ -n "$sid" ] || sid="${CLAUDE_CODE_SESSION_ID:-}"
  sid=$(printf '%s' "$sid" | LC_ALL=C tr -cd 'A-Za-z0-9_-' | head -c 64)
  [ -n "$sid" ] || return 1
  printf 'sid-%s\n' "$sid"
}

# cd_read_choice <key>: print the brain chosen for window <key> ("none" or a name). Fails if there is no choice,
# if the file is not a regular file or holds no valid name, or if it was made by an earlier process that had the
# same PID. Only its first $CD_CHOICE_READ bytes are read.
cd_read_choice() {
  local file name="" start="" now
  file="$(cd_config_dir)/brain-sessions/$1"
  [ -f "$file" ] || return 1
  { IFS= read -r name; IFS= read -r start; } < <(head -c "$CD_CHOICE_READ" -- "$file" 2>/dev/null)
  [ "$name" = none ] || cd_valid_name "$name" || return 1
  case "$1" in
    pid-*)
      if [ -n "$start" ]; then
        now=$(cd_process_start "${1#pid-}")
        [ -z "$now" ] || [ "$now" = "$start" ] || return 1
      fi ;;
  esac
  printf '%s\n' "$name"
}

# The registry reader, run as: python3 -I -c "$CD_REGISTRY_PY"$'\n'"$CD_PY_MAIN" <command> <args>...
# brain.sh adds its own commands to COMMANDS between the two. The registry is read only if it is a regular file
# of at most CD_REGISTRY_CAP bytes, opened non-blocking (as ctx-nudge.sh reads JSON), so a FIFO, a device or a
# huge file can neither hang a hook nor exhaust memory.
IFS= read -r -d '' CD_REGISTRY_PY <<'PY' || true
import json, os, re, stat, sys

CAP = 1_000_000
NAME = re.compile(r"[a-z0-9][a-z0-9-]{0,31}\Z")
BAD = re.compile(r"[\x00-\x1f\x7f]")


def read_registry(path):
    """(registry, problem): the whole registry ({"version": 1, "brains": {}} if the file does not exist), or
    (None, why it cannot be used)."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except FileNotFoundError:
        return {"version": 1, "brains": {}}, None
    except OSError:
        return None, "cannot be read"
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            return None, "is not a regular file"
        if st.st_size > CAP:
            return None, "is over 1,000,000 bytes"
        chunks, n = [], 0
        while n <= CAP:
            b = os.read(fd, CAP + 1 - n)
            if not b:
                break
            chunks.append(b)
            n += len(b)
        if n > CAP:
            return None, "is over 1,000,000 bytes"
        data = json.loads(b"".join(chunks).decode("utf-8"))
    except (OSError, ValueError):
        return None, "is not valid JSON"
    finally:
        os.close(fd)
    if not isinstance(data, dict) or data.get("version") != 1 or not isinstance(data.get("brains"), dict):
        return None, 'is not a version 1 registry ({"version": 1, "brains": {...}})'
    return data, None


def entry(brains, name):
    """(root, status) of a valid entry, else None."""
    e = brains.get(name)
    if not NAME.match(name) or not isinstance(e, dict):
        return None
    root, status = e.get("root"), e.get("status")
    if not (isinstance(root, str) and isinstance(status, str)) or BAD.search(root + status) or not root or not status:
        return None
    return root, status


def cmd_get(path, name):
    """Print the root and STATUS of <name>, one per line. Exit 3: not registered; 4: registry unusable."""
    reg, problem = read_registry(path)
    if reg is None:
        print(problem)
        return 4
    brains = reg["brains"]
    if name not in brains:
        return 3
    e = entry(brains, name)
    if e is None:
        print("has no usable entry for it (it needs a root and a status path)")
        return 4
    print(e[0])
    print(e[1])
    return 0


def cmd_list(path):
    """Print one line per usable entry: <name> TAB <root> TAB <status>, sorted. Exit 4: registry unusable."""
    reg, problem = read_registry(path)
    if reg is None:
        print(problem)
        return 4
    brains = reg["brains"]
    for name in sorted(brains):
        e = entry(brains, name)
        if e is not None and "\t" not in e[0] + e[1]:
            print(f"{name}\t{e[0]}\t{e[1]}")
    return 0


COMMANDS = {"get": cmd_get, "list": cmd_list}
PY
CD_PY_MAIN='sys.exit(COMMANDS[sys.argv[1]](*sys.argv[2:]) or 0)'

# cd_registry_get <name>: look <name> up in the registry. Sets CD_REGISTRY (its path), CD_REG_ROOT and
# CD_REG_STATUS. Fails with CD_REFUSED set (to follow 'brain "<name>" ') if the name is not registered or the
# registry cannot be used.
cd_registry_get() {
  local out rc=0
  CD_REGISTRY="$(cd_config_dir)/brains.json"; CD_REG_ROOT=""; CD_REG_STATUS=""
  command -v python3 >/dev/null 2>&1 || { CD_REFUSED="cannot be looked up: reading $CD_REGISTRY needs python3"; return 1; }
  out=$(python3 -I -c "$CD_REGISTRY_PY"$'\n'"$CD_PY_MAIN" get "$CD_REGISTRY" "$1" 2>/dev/null) || rc=$?
  case $rc in
    0) CD_REG_ROOT="${out%%$'\n'*}"; CD_REG_STATUS="${out#*$'\n'}"; return 0 ;;
    3) CD_REFUSED="is not registered in $CD_REGISTRY" ;;
    *) CD_REFUSED="cannot be looked up: $CD_REGISTRY ${out:-cannot be read}" ;;
  esac
  return 1
}

# cd_check_named <root> <status>: accept a registered brain: <root> an existing project folder (absolute, not
# $HOME or "/"), <status> an absolute path that cd_check_status accepts. Sets what cd_check_status sets, and
# CD_ROOT. Returns 1 with CD_REFUSED set if it is refused, 2 if the STATUS cannot be measured.
cd_check_named() {
  local home
  case "$1" in /*) ;; *) CD_REFUSED="must name its project folder by an absolute path"; return 1 ;; esac
  case "$2" in /*) ;; *) CD_REFUSED="must name its STATUS file by an absolute path"; return 1 ;; esac
  CD_ROOT=$(cd -P -- "$1" 2>/dev/null && pwd -P) || { CD_ROOT=""; CD_REFUSED="names a missing project folder"; return 1; }
  home=$(cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P) || home="${HOME%/}"
  if [ "$CD_ROOT" = / ] || [ "$CD_ROOT" = "$home" ]; then
    CD_REFUSED="names your home folder or / as its project folder (~/.claude there is Claude Code's config)"
    CD_ROOT=""; return 1
  fi
  cd_check_status "$2"
}

# cd_select_brain <json>: which brain this session uses (the rules at the top of this file), for a hook's input
# (or "" outside a hook: then the cwd is $CLAUDE_PROJECT_DIR, else $PWD). Sets CD_HOW ("/brain", "CD_BRAIN" or
# "folder"), CD_NAME (the chosen name, "none", or "" for the folder walk-up), and on success what cd_check_status
# sets plus CD_ROOT (and CD_POINTER for the walk-up). From here on LC_ALL=C.
# Returns 0 if a brain is selected and accepted; 1 if it is refused, with CD_SUBJECT and CD_REFUSED set (say
# "<subject> <reason>"); 2 if there is no brain: none chosen, no pointer found, the input is not a JSON object,
# CD_HOOKS=off, or the project cannot be read.
cd_select_brain() {
  local cwd key name
  CD_HOW=""; CD_NAME=""; CD_SUBJECT=""; CD_REFUSED=""; CD_ROOT=""; CD_REL=""; CD_STATUS=""; CD_SIZE=""; CD_POINTER=""
  [ "${CD_HOOKS:-}" = off ] && return 2
  cwd=$(cd_session_cwd "$1") || return 2
  LC_ALL=C; export LC_ALL
  if key=$(cd_window_key "$1") && name=$(cd_read_choice "$key"); then
    CD_HOW=/brain
  elif [ -n "${CD_BRAIN:-}" ]; then
    CD_HOW=CD_BRAIN; name="$CD_BRAIN"
  else
    CD_HOW=folder
    cd_find_brain "$cwd" || return 2
    CD_SUBJECT="$CD_POINTER"
    cd_check_pointer
    return
  fi
  CD_NAME="$name"
  [ "$name" = none ] && return 2
  if ! cd_valid_name "$name"; then
    CD_SUBJECT="CD_BRAIN=\"$(cd_printable "$name")\""
    CD_REFUSED="is not a brain name (1 to 32 of a-z, 0-9 and -, not starting with -)"
    return 1
  fi
  CD_SUBJECT="brain \"$name\" (chosen with $CD_HOW)"
  cd_registry_get "$name" || return 1
  cd_check_named "$CD_REG_ROOT" "$CD_REG_STATUS"
}
