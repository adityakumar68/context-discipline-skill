#!/usr/bin/env bash
# brain.sh -- the /brain command of the context-discipline skill: list, pick and register named project brains.
#
#   brain.sh                        list the registered brains (project folder, STATUS size and date), mark the
#                                   one this window uses, and show an unregistered folder brain found from here
#   brain.sh <name>                 use that brain in this Claude Code window, and print its STATUS
#   brain.sh none                   use no brain in this window
#   brain.sh auto                   drop this window's choice: the default applies again (CD_BRAIN, else the folder)
#   brain.sh add <name> [folder]    register the brain of <folder> (default: the current folder)
#   brain.sh new <name> <folder>    set up a brain in <folder> with init-brain.sh, then register it
#   brain.sh rename <old> <new>     rename a registered brain (registry only)
#   brain.sh remove <name>          unregister a brain (registry only; its files stay)
#
# Registry: <config>/brains.json, <config> being $CLAUDE_CONFIG_DIR or ~/.claude. A window's choice:
# <config>/brain-sessions/pid-$CLAUDE_PID (else sid-$CLAUDE_CODE_SESSION_ID), two lines: the name (or "none") and
# when that Claude Code process started, so a later process with the same PID does not inherit it. Writing a
# choice prunes choices older than 7 days whose window no longer runs. The hooks read both through brain-lib.sh,
# with the same rules, so what this lists is what they load.
# Never moves or deletes project files. The registry is replaced atomically, and only if it could be read.
# Always exits 0: the /brain skill runs this through Claude Code's !`command` injection, which aborts the skill on
# a non-zero exit before Claude sees any message. Errors are lines that start with "brain: ".

set -u
here="${BASH_SOURCE[0]%/*}"; [ "$here" = "${BASH_SOURCE[0]}" ] && here=.
here=$(cd -P -- "$here" && pwd -P) || { echo "brain: cannot find the folder of brain.sh"; exit 0; }
. "$here/brain-lib.sh" 2>/dev/null || { echo "brain: brain-lib.sh not found next to brain.sh"; exit 0; }

RESERVED=" none auto add new rename remove help list "
REG="$(cd_config_dir)/brains.json"
SES="$(cd_config_dir)/brain-sessions"

say_err() { printf 'brain: %s\n' "$*"; }

usage() {
  cat <<EOF
usage: /brain                        list the brains; * marks the one this window uses
       /brain <name>                 use that brain in this window (prints its STATUS)
       /brain none                   use no brain in this window
       /brain auto                   back to the default: CD_BRAIN if set, else the folder's brain
       /brain add <name> [folder]    register the brain of a folder (default: the current one)
       /brain new <name> <folder>    set up a brain in a folder, then register it
       /brain rename <old> <new>     rename a registered brain (registry only)
       /brain remove <name>          unregister a brain (its files stay)
Names: 1 to 32 of a-z, 0-9 and "-". Registry: $REG
Starting Claude Code with CD_BRAIN=<name> (or none) picks a brain for that window until /brain changes it.
EOF
}

# The registry's write commands, added to the lib's reader (CD_REGISTRY_PY). Exit codes: 0 done, 3 no such name,
# 4 registry unusable (message printed), 5 already registered the same way, 6 name in use (its root printed),
# 7 entry updated (prints what changed: "status<TAB>old", "root<TAB>old" or "entry<TAB>").
IFS= read -r -d '' BRAIN_PY <<'PY' || true
import tempfile


def load(path):
    reg, problem = read_registry(path)
    if reg is None:
        print(f"{path} {problem}; fix it or move it aside, then run /brain again")
        sys.exit(4)
    return reg


def write(path, reg):
    """Replace the registry atomically (a symlinked registry stays a symlink; its mode is kept)."""
    real = os.path.realpath(path)
    folder = os.path.dirname(real)
    os.makedirs(folder, exist_ok=True)
    mode = os.stat(real).st_mode & 0o7777 if os.path.exists(real) else None
    fd, tmp = tempfile.mkstemp(prefix=".brains.", suffix=".tmp", dir=folder)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(reg, f, indent=2, ensure_ascii=False)
            f.write("\n")
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, real)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def cmd_set(path, name, root, status):
    """Register <name>. An existing entry is updated if it is for the same project folder, if its folder no longer
    exists (the project moved), or if it is unusable; any other existing entry is left alone (6)."""
    reg = load(path)
    old = reg["brains"].get(name)
    if old == {"root": root, "status": status}:
        return 5
    change = None
    if name in reg["brains"]:
        e = entry(reg["brains"], name)
        if e is None:
            change = "entry\t"
        elif os.path.isdir(e[0]) and os.path.realpath(e[0]) == os.path.realpath(root):
            change = "status\t" + e[1]
        elif not os.path.isdir(e[0]):
            change = "root\t" + e[0]
        else:
            print(e[0])
            return 6
    reg["brains"][name] = {"root": root, "status": status}
    write(path, reg)
    if change:
        print(change)
        return 7
    return 0


def cmd_rename(path, old, new):
    reg = load(path)
    if old not in reg["brains"]:
        return 3
    if new in reg["brains"]:
        e = reg["brains"][new]
        print(e.get("root") if isinstance(e, dict) and isinstance(e.get("root"), str) else "another entry")
        return 6
    reg["brains"] = {(new if k == old else k): v for k, v in reg["brains"].items()}
    write(path, reg)
    return 0


def cmd_remove(path, name):
    reg = load(path)
    if name not in reg["brains"]:
        return 3
    e = reg["brains"].pop(name)
    write(path, reg)
    print(e.get("root", "") if isinstance(e, dict) and isinstance(e.get("root"), str) else "")
    return 0


COMMANDS.update(set=cmd_set, rename=cmd_rename, remove=cmd_remove)
PY

# regpy <command> <args>...: run a registry command; its output on stdout, its exit code returned.
regpy() { python3 -I -c "$CD_REGISTRY_PY"$'\n'"$BRAIN_PY"$'\n'"$CD_PY_MAIN" "$@" 2>&1; }
need_python() {
  command -v python3 >/dev/null 2>&1 && return 0
  say_err "python3 is needed to read and write the registry ($REG)."; return 1
}

# names: the registered names, as "a, b, c" ("" if none or the registry cannot be read).
names() { regpy list "$REG" 2>/dev/null | cut -f1 | paste -sd, - | sed 's/,/, /g'; }

# commas <n>: 12345 -> 12,345
commas() {
  local n="$1" out=""
  while [ ${#n} -gt 3 ]; do out=",${n#"${n%???}"}$out"; n="${n%???}"; done
  printf '%s' "$n$out"
}

# new_name_ok <name>: true if <name> can be registered (a valid name, not a word /brain itself uses).
new_name_ok() {
  if ! cd_valid_name "$1"; then
    say_err "\"$(cd_printable "$1")\" is not a brain name: use 1 to 32 of a-z, 0-9 and \"-\", not starting with \"-\"."
    return 1
  fi
  case "$RESERVED" in
    *" $1 "*) say_err "\"$1\" is a word /brain itself uses; pick another name."; return 1 ;;
  esac
}

# --- choices ----------------------------------------------------------------------------------------------------

# prune: remove choices older than 7 days, unless their window (same PID, same start) still runs.
prune() {
  local f base start now
  for f in "$SES"/pid-* "$SES"/sid-*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ -n "$(find "$f" -mtime +6 2>/dev/null)" ] || continue
    base="${f##*/}"
    case "$base" in
      pid-*)
        start=$(head -c "$CD_CHOICE_READ" "$f" 2>/dev/null | sed -n 2p)
        now=$(cd_process_start "${base#pid-}")
        [ -n "$now" ] && [ "$now" = "$start" ] && continue ;;
    esac
    rm -f -- "$f"
  done
}

# put_choice <file> <name> <start>: write a choice file atomically.
put_choice() {
  local tmp
  tmp=$(mktemp "$SES/.choice.XXXXXX" 2>/dev/null) || return 1
  if printf '%s\n%s\n' "$2" "$3" > "$tmp" && mv -f -- "$tmp" "$1"; then return 0; fi
  rm -f -- "$tmp"; return 1
}

# write_choice <name|none>: record the choice for this window.
write_choice() {
  local key start=""
  if ! key=$(cd_window_key ""); then
    say_err "cannot tell which Claude Code window this is: neither CLAUDE_PID nor CLAUDE_CODE_SESSION_ID is set." \
      "Run /brain inside Claude Code, or start Claude Code with CD_BRAIN=<name>."
    return 1
  fi
  case "$key" in pid-*) start=$(cd_process_start "${key#pid-}") ;; esac
  (umask 077 && mkdir -p -- "$SES") 2>/dev/null
  if [ -L "$SES" ] || [ ! -d "$SES" ]; then say_err "cannot use $SES (not a folder)."; return 1; fi
  chmod 700 "$SES" 2>/dev/null
  prune
  put_choice "$SES/$key" "$1" "$start" || { say_err "cannot write $SES/$key."; return 1; }
}

# --- commands -----------------------------------------------------------------------------------------------------

# auto: drop this window's choice, then say what the default gives (and print that STATUS, as /brain <name> does).
auto() {
  local key file
  if ! key=$(cd_window_key ""); then
    say_err "cannot tell which Claude Code window this is: neither CLAUDE_PID nor CLAUDE_CODE_SESSION_ID is set." \
      "Run /brain inside Claude Code."
    return
  fi
  file="$SES/$key"
  if [ -e "$file" ] || [ -L "$file" ]; then
    if [ -d "$file" ] && [ ! -L "$file" ]; then say_err "cannot remove $file (a folder)."; return; fi
    rm -f -- "$file" 2>/dev/null || { say_err "cannot remove $file."; return; }
  fi
  cd_select_brain ""
  case $? in
    0)
      if [ -n "$CD_NAME" ]; then
        printf 'This window now uses the default: brain "%s" (from CD_BRAIN, %s).\n' "$CD_NAME" "$CD_STATUS"
      else
        printf 'This window now uses the default: the folder brain %s (%s).\n' "$CD_ROOT" "$CD_STATUS"
      fi
      printf 'It replaces any project STATUS loaded earlier in this session; here it is:\n\n'
      printf '{}' | CD_HOOKS= bash "$here/brain-hook.sh" ;;
    1)
      echo "This window now uses the default, which loads no project brain: $CD_SUBJECT $CD_REFUSED."
      echo "Disregard any project STATUS loaded earlier in this session." ;;
    *)
      if [ "${CD_HOOKS:-}" = off ]; then echo "This window now uses the default; the hooks are off (CD_HOOKS=off)."
      elif [ "$CD_NAME" = none ]; then echo "This window now uses the default, which is no project brain (CD_BRAIN=none)."
      else echo "This window now uses the default, which is no project brain: CD_BRAIN is not set and there is no .claude/brain above this folder."
      fi
      echo "Disregard any project STATUS loaded earlier in this session." ;;
  esac
}

pick() {
  local name="$1"
  if [ "$name" != none ]; then
    if ! cd_valid_name "$name"; then
      say_err "\"$(cd_printable "$name")\" is not a brain name. See /brain help."; return
    fi
    need_python || return
    if ! cd_registry_get "$name"; then
      local known; known=$(names)
      say_err "brain \"$name\" $CD_REFUSED.${known:+ Registered: $known.} Nothing changed."; return
    fi
    LC_ALL=C; export LC_ALL
    if ! cd_check_named "$CD_REG_ROOT" "$CD_REG_STATUS" "$name"; then
      say_err "brain \"$name\" ${CD_REFUSED:-cannot be read}, so the hooks would not load it. Nothing changed."; return
    fi
  fi
  write_choice "$name" || return
  if [ "$name" = none ]; then
    echo "This window now uses no project brain: the hooks load none here, at the next start, /clear or compaction"
    echo "included. Disregard any project STATUS loaded earlier in this session. Pick one again with /brain <name>."
    return
  fi
  printf 'This window now uses brain "%s" (%s). The hooks load it at every start, /clear and compaction in this\n' \
    "$name" "$CD_STATUS"
  printf 'window. It replaces any project STATUS loaded earlier in this session; here it is:\n\n'
  [ -n "${CD_NOTE:-}" ] && printf 'Note: brain "%s": %s.\n\n' "$name" "$CD_NOTE"
  if [ "${CD_HOOKS:-}" = off ]; then
    echo "(CD_HOOKS=off is set in this window, so the hooks are off and will not load it.)"
  fi
  printf '{}' | CD_HOOKS= bash "$here/brain-hook.sh"
}

# register <name> <root> <status>
register() {
  local out rc=0
  case "$2$3" in *[[:cntrl:]]*) say_err "the project path contains control characters; not registered."; return ;; esac
  out=$(regpy set "$REG" "$1" "$2" "$3") || rc=$?
  case $rc in
    0) printf 'Registered brain "%s": %s (STATUS: %s).\nUse it in this window: /brain %s\n' "$1" "$2" "$3" "$1" ;;
    5) printf 'Brain "%s" is already registered for %s. Use it in this window: /brain %s\n' "$1" "$2" "$1" ;;
    7) case "$out" in
         status$'\t'*) printf 'Updated brain "%s": its STATUS is now %s (was %s).\n' "$1" "$3" "${out#*$'\t'}" ;;
         root$'\t'*) printf 'Updated brain "%s": its project folder is now %s (was %s, which no longer exists).\n' \
                        "$1" "$2" "${out#*$'\t'}" ;;
         *) printf 'Updated brain "%s": it now points to %s, in place of an entry /brain could not use.\n' "$1" "$2" ;;
       esac ;;
    6) say_err "the name \"$1\" is already used for $out; pick another name (or /brain rename or /brain remove it first)." ;;
    *) say_err "${out:-cannot write $REG}" ;;
  esac
}

add() {
  local name="$1" folder="${2:-$PWD}" dir
  new_name_ok "$name" || return
  need_python || return
  dir=$(cd -P -- "$folder" 2>/dev/null && pwd -P) || { say_err "not a folder: $folder"; return; }
  if ! CD_HOOKS= cd_find_brain "$dir"; then
    say_err "no project brain at or above $dir (a .claude/brain pointer below your home folder)." \
      "Set one up and register it with: /brain new $name <folder>"
    return
  fi
  LC_ALL=C; export LC_ALL
  cd_check_pointer
  case $? in
    0) ;;
    1) say_err "$CD_POINTER $CD_REFUSED, so the hooks would not load it; not registered."; return ;;
    *) say_err "cannot read the project at $CD_ROOT; not registered."; return ;;
  esac
  register "$name" "$CD_ROOT" "$CD_STATUS"
}

new() {
  local name="$1" folder="$2" dir rc=0 out
  new_name_ok "$name" || return
  need_python || return
  out=$(regpy get "$REG" "$name") || rc=$?
  case $rc in
    3) ;;
    0) say_err "the name \"$name\" is already used for ${out%%$'\n'*}; pick another name."; return ;;
    *) say_err "$REG ${out:-cannot be read}; fix it or move it aside, then run /brain again."; return ;;
  esac
  if ! bash "$here/init-brain.sh" "$folder" 2>&1; then
    say_err "init-brain.sh did not finish (see above); nothing registered."; return
  fi
  echo
  add "$name" "$folder"
}

# rechoose <old> <new>: windows that chose <old> now read <new>.
rechoose() {
  local f name start
  for f in "$SES"/pid-* "$SES"/sid-*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    { IFS= read -r name; IFS= read -r start; } < <(head -c "$CD_CHOICE_READ" -- "$f" 2>/dev/null)
    [ "$name" = "$1" ] && put_choice "$f" "$2" "$start"
  done
}

rename() {
  local old="$1" new="$2" out rc=0
  cd_valid_name "$old" || { say_err "\"$(cd_printable "$old")\" is not a brain name."; return; }
  new_name_ok "$new" || return
  need_python || return
  out=$(regpy rename "$REG" "$old" "$new") || rc=$?
  case $rc in
    0) rechoose "$old" "$new"
       printf 'Renamed brain "%s" to "%s" (registry only; no project file was changed).\n' "$old" "$new" ;;
    3) say_err "no brain named \"$old\" in $REG. See /brain." ;;
    6) say_err "the name \"$new\" is already used for $out; pick another name." ;;
    *) say_err "${out:-cannot write $REG}" ;;
  esac
}

remove() {
  local name="$1" out rc=0
  cd_valid_name "$name" || { say_err "\"$(cd_printable "$name")\" is not a brain name."; return; }
  need_python || return
  out=$(regpy remove "$REG" "$name") || rc=$?
  case $rc in
    0) printf 'Removed brain "%s" from the registry. Its files stay in %s; to register it again: /brain add %s %s\n' \
         "$name" "${out:-its project folder}" "$name" "${out:-<folder>}"
       echo "Windows that chose it load no brain (with a warning) until they pick another." ;;
    3) say_err "no brain named \"$name\" in $REG. See /brain." ;;
    *) say_err "${out:-cannot write $REG}" ;;
  esac
}

list() {
  local sel s_how s_name s_root s_status s_subject s_refused rows rc=0 width=4 name root status info mark
  local roots="" here_root here_rel
  cd_select_brain ""; sel=$?
  s_how="$CD_HOW"; s_name="$CD_NAME"; s_root="$CD_ROOT"; s_status="$CD_STATUS"
  s_subject="$CD_SUBJECT"; s_refused="$CD_REFUSED"
  if command -v python3 >/dev/null 2>&1; then
    rows=$(regpy list "$REG") || rc=$?
  else
    rows="needs python3 to be read"; rc=4
  fi
  if [ "$rc" != 0 ]; then
    echo "The registry $REG ${rows:-cannot be read}; fix it or move it aside."
    rows=""
  elif [ -z "$rows" ]; then
    echo "No named brains yet (registry: $REG)."
    echo "Register a folder's brain: /brain add <name> [folder]. Set up a new one: /brain new <name> <folder>"
  else
    echo "Named brains (registry: $REG):"
    while IFS=$'\t' read -r name root status; do [ ${#name} -gt $width ] && width=${#name}; done <<<"$rows"
    while IFS=$'\t' read -r name root status; do
      mark=" "
      if cd_check_named "$root" "$status" "$name"; then
        info="$CD_REL, $(commas "$CD_SIZE") bytes, changed $(date -r "$CD_STATUS" +%Y-%m-%d 2>/dev/null)"
        roots="$roots"$'\n'"$CD_ROOT"
        if [ "$sel" = 0 ] && { [ "$s_name" = "$name" ] || { [ "$s_how" = folder ] && [ "$s_status" = "$CD_STATUS" ]; }; }; then
          mark="*"
        fi
      else
        info="not usable: ${CD_REFUSED:-cannot be read}"
      fi
      printf '%s %-*s  %s  %s\n' "$mark" "$width" "$name" "$(cd_printable "$root" 4096)" "$info"
      [ -n "${CD_NOTE:-}" ] && printf '  %-*s  note: %s\n' "$width" "" "$(cd_printable "$CD_NOTE" 8192)"
    done <<<"$rows"
  fi

  # A folder brain found from here that is not registered.
  if CD_HOOKS= cd_find_brain "$PWD"; then
    LC_ALL=C; export LC_ALL
    if cd_check_pointer; then
      here_root="$CD_ROOT"; here_rel="$CD_REL"
      case "$roots"$'\n' in
        *$'\n'"$here_root"$'\n'*) ;;
        *) echo "Folder brain here, not registered: $here_root ($(cd_printable "$here_rel" 4096)). Register it: /brain add <name>" ;;
      esac
    else
      echo "Folder brain here: $CD_POINTER ${CD_REFUSED:-cannot be read}, so the hooks ignore it."
    fi
  fi

  if [ "${CD_HOOKS:-}" = off ]; then
    echo "This window has the hooks off (CD_HOOKS=off), so they load no brain."
  elif [ "$sel" = 0 ] && [ -n "$s_name" ]; then
    echo "This window uses brain \"$s_name\" (chosen with $s_how)."
  elif [ "$sel" = 0 ]; then
    echo "This window uses the folder brain $s_root (found from $PWD)."
  elif [ "$s_name" = none ]; then
    if [ "$s_how" = /brain ]; then echo "This window uses no brain (chosen with /brain none)."
    else echo "This window uses no brain (chosen with CD_BRAIN=none)."; fi
  elif [ "$sel" = 1 ]; then
    echo "This window uses no brain: $s_subject $s_refused."
  else
    echo "This window uses no brain: none chosen with /brain, CD_BRAIN not set, and no .claude/brain above this folder."
  fi
  echo "Pick: /brain <name>, /brain none, /brain auto (the default). Register: /brain add <name> [folder], /brain new <name> <folder>. Also: rename, remove, help."
}

usage_err() { echo "brain: wrong arguments."; usage; }

case "${1-}" in
  "") if [ $# -le 1 ]; then list; else usage_err; fi ;;
  help|-h|--help) usage ;;
  list) if [ $# = 1 ]; then list; else usage_err; fi ;;
  auto) if [ $# = 1 ]; then auto; else usage_err; fi ;;
  add) if [ $# = 2 ] || [ $# = 3 ]; then add "$2" "${3-}"; else usage_err; fi ;;
  new) if [ $# = 3 ]; then new "$2" "$3"; else usage_err; fi ;;
  rename) if [ $# = 3 ]; then rename "$2" "$3"; else usage_err; fi ;;
  remove) if [ $# = 2 ]; then remove "$2"; else usage_err; fi ;;
  *) if [ $# = 1 ]; then pick "$1"; else usage_err; fi ;;
esac
exit 0
