# brain-lib.sh -- shared by the context-discipline hooks (brain-hook.sh, compact-log.sh, ctx-nudge.sh) and the
# /brain command (brain.sh). Sourced, not run. A brain belongs to a Claude Code session, never to a folder: every
# hook picks the session's brain with one set of rules (cd_select_brain), first match wins:
#   1. the choice made with /brain <name> or /brain none in this Claude Code window: the file
#      <config>/brain-sessions/<key>, where <config> is $CLAUDE_CONFIG_DIR or ~/.claude and <key> is
#      pid-$CLAUDE_PID (the Claude Code process, so the choice survives /clear and compaction), else
#      sid-<session id>;
#   2. CD_BRAIN=<name> or CD_BRAIN=none in the environment;
#   3. else no brain. The session's folder plays no part: nothing here reads a .claude/brain pointer (only
#      /brain add does, in brain.sh, to register the brain an old pointer names).
# A name is looked up in the registry <config>/brains.json:
#   {"version": 2, "brains": {"<name>": {"dir": "<abs brain folder>", "status": "<STATUS file, relative to dir>"}}}
# A version 1 registry ({"root": "<project folder>", "status": "<abs STATUS file>"}) is read as if each entry's dir
# were its STATUS file's folder and its status that file's name; /brain writes version 2 at its next change.
# Either way the STATUS file is accepted only if, with every symlink resolved, it is a regular text file inside its
# folder, and that folder is neither $HOME nor "/".
# Never writes files, never touches the network.

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

# cd_input_ok <json>: false if the hook input is not a JSON object (Claude Code always sends one). Empty input (a
# hook run by hand, or by /brain) and a machine with neither jq nor python3 count as fine.
cd_input_ok() {
  [ -n "$1" ] || return 0
  cd_json_get "$1" cwd >/dev/null 2>&1 && return 0
  ! { command -v jq || command -v python3; } >/dev/null 2>&1
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

# cd_check_status <path>: accept <path> as the STATUS file of the brain folder $CD_DIR (symlinks already
# resolved) only if, with every symlink resolved, it is a regular, readable text file inside that folder.
# Sets CD_STATUS (the file, symlinks resolved), CD_SIZE (bytes) and CD_REL (its path below $CD_DIR).
# Returns 1 with CD_REFUSED set if it is refused, 2 if it cannot be measured.
cd_check_status() {
  local size text
  CD_STATUS=$(cd_physical "$1") || { CD_STATUS=""; CD_REFUSED="names a missing file"; return 1; }
  case "$CD_STATUS" in
    "$CD_DIR"/*) ;;
    *) CD_STATUS=""; CD_REFUSED="names a file outside its folder"; return 1 ;;
  esac
  [ -f "$CD_STATUS" ] || { CD_STATUS=""; CD_REFUSED="names a missing file, or something that is not a regular file"; return 1; }
  [ -r "$CD_STATUS" ] || { CD_STATUS=""; CD_REFUSED="names a file that cannot be read"; return 1; }
  size=$(wc -c < "$CD_STATUS" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) CD_STATUS=""; return 2 ;;
  esac
  text=$(tr -d '\000' < "$CD_STATUS" 2>/dev/null | wc -c | tr -d '[:space:]')
  [ "$text" = "$size" ] || { CD_STATUS=""; CD_REFUSED="names a file that is not text"; return 1; }
  CD_SIZE="$size"; CD_REL="${CD_STATUS#"$CD_DIR"/}"
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

# cd_process_start <pid>: when process <pid> started ("" if it cannot be told). Kept with a window's choice, so a
# later process that gets the same PID does not inherit the choice. On Linux it is "boot+<ticks>" from
# /proc/<pid>/stat (clock ticks after boot, which a wall-clock step does not move); elsewhere, ps's start time in the
# C locale and UTC, so the writer and the readers agree whatever their locale and time zone.
cd_process_start() {
  local s
  if [ -r "/proc/$1/stat" ]; then
    s=$(cd_stat_start "/proc/$1/stat")
    case "$s" in ''|*[!0-9]*) ;; *) printf 'boot+%s\n' "$s"; return 0 ;; esac
  fi
  s=$(LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9: ' | LC_ALL=C tr -s ' ')
  s="${s# }"; printf '%s\n' "${s% }"
}

# cd_stat_start <file>: field 22 (start time, in clock ticks after boot) of a /proc/<pid>/stat file. The fields are
# counted after the last ") ", since field 2, the command name, may itself hold spaces and parentheses.
cd_stat_start() {
  local l f
  l=$(head -c 4096 -- "$1" 2>/dev/null) || return 1
  case "$l" in *") "*) ;; *) return 1 ;; esac
  l="${l##*") "}"
  read -r -a f <<<"$l"
  printf '%s\n' "${f[19]:-}"
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
WAS_V1 = [False]   # set by read_registry when the file it read was version 1


def from_v1(brains):
    """Convert version 1 entries in place: {"root", "status": <abs STATUS>} -> {"dir": its folder, "status": its
    name}. An entry that cannot be converted is left as it is (and is then not usable)."""
    for name, e in brains.items():
        s = e.get("status") if isinstance(e, dict) else None
        if isinstance(s, str) and s.startswith("/") and not s.endswith("/") and not BAD.search(s):
            brains[name] = {"dir": os.path.dirname(s), "status": os.path.basename(s)}


def read_registry(path):
    """(registry, problem): the whole registry as version 2 ({"version": 2, "brains": {}} if the file does not
    exist; a version 1 file converted with from_v1, and WAS_V1[0] set to True), or (None, why it cannot be used)."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except FileNotFoundError:
        return {"version": 2, "brains": {}}, None
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
    version = data.get("version") if isinstance(data, dict) else None
    if version not in (1, 2) or isinstance(version, bool) or not isinstance(data.get("brains"), dict):
        return None, 'is not a version 2 registry ({"version": 2, "brains": {...}})'
    if version == 1:
        from_v1(data["brains"])
        data["version"] = 2
        WAS_V1[0] = True
    return data, None


def entry(brains, name):
    """(dir, status) of a valid entry, else None."""
    e = brains.get(name)
    if not NAME.match(name) or not isinstance(e, dict):
        return None
    d, status = e.get("dir"), e.get("status")
    if not (isinstance(d, str) and isinstance(status, str)) or BAD.search(d + status) or not d or not status:
        return None
    return d, status


def cmd_get(path, name):
    """Print the folder and STATUS of <name>, one per line. Exit 3: not registered; 4: registry unusable."""
    reg, problem = read_registry(path)
    if reg is None:
        print(problem)
        return 4
    brains = reg["brains"]
    if name not in brains:
        return 3
    e = entry(brains, name)
    if e is None:
        print("has no usable entry for it (it needs a dir and a status path)")
        return 4
    print(e[0])
    print(e[1])
    return 0


def shown(s):
    return BAD.sub("?", s) if isinstance(s, str) else ""


def cmd_list(path):
    """Print one line per entry, sorted: <name> US <dir> US <status> US <problem> (US = \\x1f; problem "" for a
    usable entry, else why /brain cannot use it, with names and paths made printable). Exit 4: registry unusable."""
    reg, problem = read_registry(path)
    if reg is None:
        print(problem)
        return 4
    brains = reg["brains"]
    for name in sorted(brains):
        e, raw = entry(brains, name), brains[name]
        if e is not None:
            print("\x1f".join((name, e[0], e[1], "")))
            continue
        d = shown(raw.get("dir") or raw.get("root")) if isinstance(raw, dict) else ""
        if not NAME.match(name):
            why = "its name is not a brain name; edit the registry to rename or remove it"
        elif not isinstance(raw, dict):
            why = "its entry is not an object; /brain add " + name + " <folder> replaces it"
        elif not (isinstance(raw.get("dir"), str) and isinstance(raw.get("status"), str)) or not raw.get("dir") \
                or not raw.get("status"):
            why = "it needs both a dir and a status path; /brain add " + name + " <folder> replaces it"
        else:
            why = "a path holds a tab or another control character; /brain add " + name + " <folder> replaces it"
        print("\x1f".join((shown(name)[:64], d, "", why)))
    return 0


COMMANDS = {"get": cmd_get, "list": cmd_list}
PY
CD_PY_MAIN='sys.exit(COMMANDS[sys.argv[1]](*sys.argv[2:]) or 0)'

# cd_registry_get <name>: look <name> up in the registry. Sets CD_REGISTRY (its path), CD_REG_DIR and
# CD_REG_STATUS. Fails with CD_REFUSED set (to follow 'brain "<name>" ') if the name is not registered or the
# registry cannot be used.
cd_registry_get() {
  local out rc=0
  CD_REGISTRY="$(cd_config_dir)/brains.json"; CD_REG_DIR=""; CD_REG_STATUS=""
  command -v python3 >/dev/null 2>&1 || { CD_REFUSED="cannot be looked up: reading $CD_REGISTRY needs python3"; return 1; }
  out=$(python3 -I -c "$CD_REGISTRY_PY"$'\n'"$CD_PY_MAIN" get "$CD_REGISTRY" "$1" 2>/dev/null) || rc=$?
  case $rc in
    0) CD_REG_DIR="${out%%$'\n'*}"; CD_REG_STATUS="${out#*$'\n'}"; return 0 ;;
    3) CD_REFUSED="is not registered in $CD_REGISTRY" ;;
    *) CD_REFUSED="cannot be looked up: $CD_REGISTRY ${out:-cannot be read}" ;;
  esac
  return 1
}

# cd_check_brain <dir> <status> [name]: accept a registered brain. <dir> must be an existing folder, named by an
# absolute path, that is not $HOME or "/"; <status> names its STATUS file by a path relative to <dir>, which
# cd_check_status must accept. No .claude/brain pointer is ever read. Sets what cd_check_status sets and CD_DIR
# (the folder, symlinks resolved); [name] goes into the advice of a refusal.
# Returns 1 with CD_REFUSED set if it is refused, 2 if the STATUS cannot be measured.
cd_check_brain() {
  local home name="${3:-<name>}"
  CD_DIR=""
  case "$1" in /*) ;; *) CD_REFUSED="must name its folder by an absolute path; /brain add $name <folder> replaces it"; return 1 ;; esac
  CD_DIR=$(cd -P -- "$1" 2>/dev/null && pwd -P) || {
    CD_DIR=""
    CD_REFUSED="names a missing folder ($1); if it moved, /brain add $name <folder> points it at the new one"
    return 1
  }
  home=$(cd -P -- "${HOME:-/}" 2>/dev/null && pwd -P) || home="${HOME%/}"
  if [ "$CD_DIR" = / ] || [ "$CD_DIR" = "$home" ]; then
    CD_REFUSED="names your home folder or / as its folder; give the brain a folder of its own"
    CD_DIR=""; return 1
  fi
  case "$2" in
    /*|'~'*) CD_REFUSED="must name its STATUS file by a path relative to its folder"; return 1 ;;
  esac
  cd_check_status "$CD_DIR/$2"
}

# cd_select_brain <json>: which brain this session uses (the rules at the top of this file), for a hook's input (or
# "" outside a hook). Sets CD_HOW ("/brain" or "CD_BRAIN"; "" when nothing was chosen), CD_NAME (the chosen name,
# "none", or ""), and on success what cd_check_brain sets. From here on LC_ALL=C.
# Returns 0 if a brain is selected and accepted; 1 if it is refused, with CD_SUBJECT and CD_REFUSED set (say
# "<subject> <reason>"); 2 if the session has no brain (none chosen, or nothing chosen); 3 if the hooks must do
# nothing at all (CD_HOOKS=off, or the input is not a JSON object).
cd_select_brain() {
  local key name
  CD_HOW=""; CD_NAME=""; CD_SUBJECT=""; CD_REFUSED=""; CD_DIR=""; CD_REL=""; CD_STATUS=""; CD_SIZE=""
  [ "${CD_HOOKS:-}" = off ] && return 3
  cd_input_ok "$1" || return 3
  LC_ALL=C; export LC_ALL
  if key=$(cd_window_key "$1") && name=$(cd_read_choice "$key"); then
    CD_HOW=/brain
  elif [ -n "${CD_BRAIN:-}" ]; then
    CD_HOW=CD_BRAIN; name="$CD_BRAIN"
  else
    return 2
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
  cd_check_brain "$CD_REG_DIR" "$CD_REG_STATUS" "$name"
}

# cd_brain_names: the registered names (only those that are brain names), one per line. Fails if the registry
# cannot be read (or python3 is missing); prints nothing if there is no registry or it is empty.
cd_brain_names() {
  local reg out
  reg="$(cd_config_dir)/brains.json"
  [ -e "$reg" ] || [ -L "$reg" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 1
  out=$(python3 -I -c "$CD_REGISTRY_PY"$'\n'"$CD_PY_MAIN" list "$reg" 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | while IFS=$'\037' read -r name _ _ problem; do
    cd_valid_name "$name" && printf '%s\n' "$name"
  done
  return 0
}
