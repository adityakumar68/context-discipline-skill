#!/usr/bin/env bash
# brain.sh -- the /brain command of the context-discipline skill: list, attach, create and register brains.
# A brain belongs to a Claude Code window (session), never to a folder; its folder is only where its files live.
#
#   brain.sh                        list the registered brains (folder, STATUS size and date), mark the one this
#                                   window uses, and name an old .claude/brain pointer in the current folder
#   brain.sh <name>                 attach that brain to this Claude Code window, and print its STATUS
#   brain.sh none                   detach: this window uses no brain
#   brain.sh new <name> [--at <folder>]     create a brain (STATUS.md and overview, with init-brain.sh) in
#                                   <config>/brains/<name> or <folder>, register it and attach it to this window
#   brain.sh add <name> <folder|STATUS file>   register an existing brain: <folder>/STATUS.md, or that file
#   brain.sh add <name>             register the brain an old .claude/brain pointer in the current folder names
#   brain.sh rename <old> <new>     rename a brain (registry, the windows' choices and its compaction logs)
#   brain.sh remove <name>          unregister a brain (its files and logs stay)
#   brain.sh --args                 the same, with the words read from stdin as one raw string (what the /brain
#                                   skill passes): split here like shell words ('...', "...", \) with nothing
#                                   expanded, so no character in it can run a command or cut the command short
# A path argument that starts with ~ or ~/ is taken from $HOME.
#
# Registry: <config>/brains.json, <config> being $CLAUDE_CONFIG_DIR or ~/.claude. A window's choice:
# <config>/brain-sessions/pid-$CLAUDE_PID (else sid-$CLAUDE_CODE_SESSION_ID), two lines: the name (or "none") and
# when that Claude Code process started, so a later process with the same PID does not inherit it. Writing a
# choice prunes choices older than 7 days whose window no longer runs. The hooks read both through brain-lib.sh,
# with the same rules, so what this lists is what they load.
# Never moves or deletes a brain's files. The registry is replaced atomically, and only if it could be read.
# Always exits 0: the /brain skill runs this through Claude Code's !`command` injection, which aborts the skill on
# a non-zero exit before Claude sees any message. Errors are lines that start with "brain: ".

set -u
here="${BASH_SOURCE[0]%/*}"; [ "$here" = "${BASH_SOURCE[0]}" ] && here=.
here=$(cd -P -- "$here" && pwd -P) || { echo "brain: cannot find the folder of brain.sh"; exit 0; }
. "$here/brain-lib.sh" 2>/dev/null || { echo "brain: brain-lib.sh not found next to brain.sh"; exit 0; }

RESERVED=" none auto add new rename remove help list "
REG="$(cd_config_dir)/brains.json"
SES="$(cd_config_dir)/brain-sessions"

LOGS="$(cd_config_dir)/brain-logs"
POINTER_READ=4096   # bytes of an old pointer that are read (the refusal reasons say 4,096)
PATH_MAX=1024       # bytes in its path line, PATH_MAX on macOS (the refusal reasons say 1,024)

say_err() { printf 'brain: %s\n' "$*"; }

usage() {
  cat <<EOF
usage: /brain                              list the brains; * marks the one this window uses
       /brain <name>                       attach that brain to this window (prints its STATUS)
       /brain none                         detach: this window uses no brain
       /brain new <name> [--at <folder>]   create a brain (in $(cd_config_dir)/brains/<name>, or <folder>)
                                           and attach it to this window
       /brain add <name> <folder|STATUS file>   register an existing brain (no path: the one an old
                                           .claude/brain pointer in the current folder names)
       /brain rename <old> <new>           rename a brain (registry and compaction logs)
       /brain remove <name>                unregister a brain (its files stay)
Names: 1 to 32 of a-z, 0-9 and "-". Registry: $REG
A brain belongs to a Claude Code window, not a folder. Starting Claude Code with CD_BRAIN=<name> (or none)
attaches one for that window until /brain changes it.
EOF
}

# The registry's write commands, added to the lib's reader (CD_REGISTRY_PY). Each write saves version 2 (a version 1
# file is converted as it is read). Exit codes: 0 done, 3 no such name, 4 registry unusable (message printed),
# 5 already registered the same way, 6 name in use (its folder printed), 7 entry updated (prints what changed:
# "status<TAB>old", "dir<TAB>old" or "entry<TAB>").
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


def save(path, reg):
    """write(), with a failure turned into one line (exit 4) instead of a traceback."""
    try:
        write(path, reg)
    except OSError as e:
        print(f"cannot write {path}: {e.strerror or e}")
        sys.exit(4)


def cmd_set(path, name, folder, status):
    """Register <name>. An existing entry is updated if it is for the same folder, if its folder no longer exists
    (the brain moved), or if it is unusable; any other existing entry is left alone (6)."""
    reg = load(path)
    old = reg["brains"].get(name)
    if old == {"dir": folder, "status": status}:
        if WAS_V1[0]:
            save(path, reg)   # unchanged, but now saved as version 2
        return 5
    change = None
    if name in reg["brains"]:
        e = entry(reg["brains"], name)
        if e is None:
            change = "entry\t"
        elif e == (folder, status):
            pass
        elif os.path.isdir(e[0]) and os.path.realpath(e[0]) == os.path.realpath(folder):
            change = "status\t" + e[1]
        elif not os.path.isdir(e[0]):
            change = "dir\t" + e[0]
        else:
            print(e[0])
            return 6
    reg["brains"][name] = {"dir": folder, "status": status}
    save(path, reg)
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
        print(e.get("dir") if isinstance(e, dict) and isinstance(e.get("dir"), str) else "another entry")
        return 6
    reg["brains"] = {(new if k == old else k): v for k, v in reg["brains"].items()}
    save(path, reg)
    return 0


def cmd_remove(path, name):
    reg = load(path)
    if name not in reg["brains"]:
        return 3
    e = reg["brains"].pop(name)
    save(path, reg)
    print(e.get("dir", "") if isinstance(e, dict) and isinstance(e.get("dir"), str) else "")
    return 0


def cmd_upgrade(path, ts, dry):
    """For install.sh: convert a version 1 registry to version 2, after a backup to <path>.bak-<ts>. Prints one
    summary line, or nothing if there is no registry or it is already version 2."""
    if not os.path.lexists(path):
        return 0
    reg, problem = read_registry(path)
    if reg is None:
        print(f"NOTE: {path} {problem}, so it was left as it is; /brain cannot use it until it is fixed")
        return 0
    if not WAS_V1[0]:
        return 0
    n = len(reg["brains"])
    n = f"{n} brain" + ("" if n == 1 else "s")
    if dry == "1":
        print(f"would convert it from version 1 to version 2 ({n}); backup first to {path}.bak-{ts}")
        return 0
    backup = f"{path}.bak-{ts}"
    k = 2
    while os.path.lexists(backup):
        backup, k = f"{path}.bak-{ts}-{k}", k + 1
    try:
        import shutil
        shutil.copy2(path, backup)
    except OSError as e:
        print(f"NOTE: cannot back up {path} ({e.strerror or e}), so it was left as version 1")
        return 0
    save(path, reg)
    print(f"converted from version 1 to version 2 ({n}); backup: {backup}")
    return 0


COMMANDS.update(set=cmd_set, rename=cmd_rename, remove=cmd_remove, upgrade=cmd_upgrade)
PY

# regpy <command> <args>...: run a registry command; its output on stdout, its exit code returned.
regpy() { python3 -I -c "$CD_REGISTRY_PY"$'\n'"$BRAIN_PY"$'\n'"$CD_PY_MAIN" "$@" 2>&1; }
need_python() {
  command -v python3 >/dev/null 2>&1 && return 0
  say_err "python3 is needed to read and write the registry ($REG)."; return 1
}

# names: the registered names, as "a, b, c" ("" if none or the registry cannot be read).
names() {
  local o
  o=$(regpy list "$REG" 2>/dev/null) || return 0
  printf '%s\n' "$o" | cut -d $'\037' -f1 | paste -sd, - | sed 's/,/, /g'
}

# commas <n>: 12345 -> 12,345
commas() {
  local n="$1" out=""
  while [ ${#n} -gt 3 ]; do out=",${n#"${n%???}"}$out"; n="${n%???}"; done
  printf '%s' "$n$out"
}

# expand_tilde <path>: a leading ~ or ~/ replaced by $HOME (a quoted ~ reaches the script unexpanded).
expand_tilde() {
  case "$1" in
    "~") printf '%s\n' "${HOME:-~}" ;;
    "~/"*) printf '%s\n' "${HOME:-~}/${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
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
  [ -d "$1" ] && return 1   # mv would move the file into it and report success
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
  if [ ! -e "$SES" ] && [ ! -L "$SES" ]; then say_err "cannot create $SES (see README: Several brains, sandbox)."; return 1; fi
  if [ -L "$SES" ] || [ ! -d "$SES" ]; then say_err "cannot use $SES (not a folder)."; return 1; fi
  chmod 700 "$SES" 2>/dev/null
  prune
  if [ -d "$SES/$key" ]; then say_err "$SES/$key is a folder; remove it, then run /brain again."; return 1; fi
  put_choice "$SES/$key" "$1" "$start" || { say_err "cannot write $SES/$key (see README: Several brains, sandbox)."; return 1; }
}

# --- old .claude/brain pointers (read only to register the brain one names) ---------------------------------------

# check_pointer: read the STATUS path from the old pointer $CD_POINTER (a regular file) and accept it only if it is
# a text file inside the pointer's folder $CD_ROOT, as the hooks of earlier versions did. Sets LC_ALL=C.
# On success sets CD_REL (the path as the pointer gives it), CD_STATUS (the file, symlinks resolved) and
# CD_SIZE (its size in bytes).
# Returns 1 with CD_REFUSED set to the reason (to follow "<pointer> ") if the pointer is refused,
# 2 if its folder cannot be read at all.
check_pointer() {
  local line="" rel="" size text ended=0 more=""
  LC_ALL=C; export LC_ALL
  CD_REL=""; CD_STATUS=""; CD_SIZE=""; CD_REFUSED=""
  # Only the first $POINTER_READ bytes are read. The pointer is a regular file (the caller checks with -f), so
  # opening it cannot block; the cap keeps a huge pointer (a cloned repo's is untrusted) from costing memory or
  # (bash 3.2 trims strings in quadratic time) seconds of CPU.
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
  done < <(head -c "$POINTER_READ" -- "$CD_POINTER" 2>/dev/null)
  size=$(wc -c < "$CD_POINTER" 2>/dev/null | tr -d '[:space:]')
  case "$size" in ''|*[!0-9]*) size=0 ;; esac
  [ "$size" -gt "$POINTER_READ" ] && more=" in its first 4,096 bytes"
  # A line without a newline is whole only if the file ends there; one cut by the read is never used.
  if [ -n "$rel" ] && { [ "${#rel}" -gt "$PATH_MAX" ] || { [ "$ended" = 0 ] && [ -n "$more" ]; }; }; then
    CD_REFUSED="names no file: its path line must be at most 1,024 bytes and end within its first 4,096"; return 1
  fi
  [ -n "$rel" ] || { CD_REFUSED="names no file$more"; return 1; }
  case "$rel" in
    /*|'~'*) CD_REFUSED="must name its STATUS file by a path relative to its project folder"; return 1 ;;
  esac
  CD_ROOT=$(cd -P -- "$CD_ROOT" 2>/dev/null && pwd -P) || return 2
  CD_DIR="$CD_ROOT"
  cd_check_status "$CD_ROOT/$rel" || return $?
  CD_REL="$rel"
  return 0
}

# --- commands -----------------------------------------------------------------------------------------------------

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
    if ! cd_check_brain "$CD_REG_DIR" "$CD_REG_STATUS" "$name"; then
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
  if [ "${CD_HOOKS:-}" = off ]; then
    echo "(CD_HOOKS=off is set in this window, so the hooks are off and will not load it.)"
  fi
  printf '{}' | CD_HOOKS= bash "$here/brain-hook.sh"
}

# register <name> <dir> <status>: fails (after saying why) if nothing was registered.
register() {
  local out rc=0
  case "$2$3" in *[[:cntrl:]]*) say_err "the path contains control characters; not registered."; return 1 ;; esac
  out=$(regpy set "$REG" "$1" "$2" "$3") || rc=$?
  case $rc in
    0) printf 'Registered brain "%s": %s (STATUS: %s).\nUse it in this window: /brain %s\n' "$1" "$2" "$3" "$1" ;;
    5) printf 'Brain "%s" is already registered for %s. Use it in this window: /brain %s\n' "$1" "$2" "$1" ;;
    7) case "$out" in
         status$'\t'*) printf 'Updated brain "%s": its STATUS is now %s (was %s).\n' "$1" "$3" "${out#*$'\t'}" ;;
         dir$'\t'*) printf 'Updated brain "%s": its folder is now %s (was %s, which no longer exists).\n' \
                        "$1" "$2" "${out#*$'\t'}" ;;
         *) printf 'Updated brain "%s": it now points to %s, in place of an entry /brain could not use.\n' "$1" "$2" ;;
       esac ;;
    6) say_err "the name \"$1\" is already used for $out; pick another name (or /brain rename or /brain remove it first)."
       return 1 ;;
    *) say_err "${out:-cannot write $REG}"; return 1 ;;
  esac
}

# add <name> [path]: register <path>/STATUS.md, or the STATUS file <path>; with no path, the brain an old
# .claude/brain pointer in the current folder names.
add() {
  local name="$1" path dir file
  new_name_ok "$name" || return
  need_python || return
  LC_ALL=C; export LC_ALL
  if [ -z "${2-}" ]; then add_pointer "$name"; return; fi
  path=$(expand_tilde "$2")
  if [ -d "$path" ]; then
    dir="$path"; file=STATUS.md
    if [ ! -e "$dir/STATUS.md" ] && [ ! -L "$dir/STATUS.md" ]; then
      say_err "no STATUS.md in $path. Name the brain's STATUS file itself (/brain add $name <file>), or create a" \
        "brain there: /brain new $name --at $path"
      return
    fi
  elif [ -e "$path" ] || [ -L "$path" ]; then
    dir=$(dirname -- "$path"); file=$(basename -- "$path")
  else
    say_err "not found: $path"; return
  fi
  dir=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || { say_err "cannot read the folder of $path"; return; }
  if ! cd_check_brain "$dir" "$file" "$name"; then
    say_err "$path: the brain ${CD_REFUSED:-cannot be read}, so the hooks would not load it; not registered."; return
  fi
  register "$name" "$CD_DIR" "$CD_REL"
}

# add_pointer <name>: register the brain that the old pointer ./.claude/brain names (the migration from folder
# brains). The pointer is read as the hooks of earlier versions read it, and is left in place.
add_pointer() {
  local name="$1" ptr="$PWD/.claude/brain"
  if [ ! -e "$ptr" ] && [ ! -L "$ptr" ]; then
    say_err "name the brain's folder or STATUS file: /brain add $name <folder|STATUS file> (there is no old" \
      ".claude/brain pointer in $PWD to take it from). To create a brain: /brain new $name"
    return
  fi
  if [ ! -f "$ptr" ]; then say_err "$ptr is not a regular file; name the brain's folder or STATUS file instead."; return; fi
  CD_POINTER="$ptr"; CD_ROOT="$PWD"
  check_pointer
  case $? in
    0) ;;
    1) say_err "$ptr $CD_REFUSED, so it cannot be registered; name the brain's folder or STATUS file instead."; return ;;
    *) say_err "cannot read $PWD; not registered."; return ;;
  esac
  if ! cd_check_brain "${CD_STATUS%/*}" "${CD_STATUS##*/}" "$name"; then
    say_err "$ptr names $CD_STATUS, but the brain ${CD_REFUSED:-cannot be read}; not registered."; return
  fi
  register "$name" "$CD_DIR" "$CD_REL" || return
  echo "The old pointer $ptr is no longer read by the hooks; you can delete it."
}

# new <name> <folder>: create a brain (in <config>/brains/<name> when <folder> is ""), register it, attach it.
new() {
  local name="$1" folder rc=0 out
  new_name_ok "$name" || return
  need_python || return
  out=$(regpy get "$REG" "$name") || rc=$?
  case $rc in
    3) ;;
    0) say_err "the name \"$name\" is already used for ${out%%$'\n'*}; pick another name."; return ;;
    *) say_err "$REG ${out:-cannot be read}; fix it or move it aside, then run /brain again."; return ;;
  esac
  if [ -n "$2" ]; then
    folder=$(expand_tilde "$2")
  else
    folder="$(cd_config_dir)/brains/$name"
    mkdir -p -- "${folder%/*}" 2>/dev/null || { say_err "cannot create ${folder%/*}."; return; }
  fi
  if [ -e "$folder/STATUS.md" ] || [ -L "$folder/STATUS.md" ]; then
    say_err "$folder already holds a STATUS.md; register it as it is with: /brain add $name $folder"
    return
  fi
  if ! bash "$here/init-brain.sh" "$folder" "$name" 2>&1; then
    say_err "init-brain.sh did not finish (see above); nothing registered."; return
  fi
  folder=$(cd -P -- "$folder" 2>/dev/null && pwd -P) || { say_err "cannot read $folder; nothing registered."; return; }
  out=$(register "$name" "$folder" STATUS.md) || { printf '%s
' "$out"; return; }
  printf 'Registered brain "%s": %s.\n\n' "$name" "$folder"
  pick "$name"
}

# rechoose <old> <new>: windows that chose <old> now read <new>. Each file is checked again just before it is
# replaced, so a choice that window made in the meantime is kept.
rechoose() {
  local f name start tmp now
  for f in "$SES"/pid-* "$SES"/sid-*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    { IFS= read -r name; IFS= read -r start; } < <(head -c "$CD_CHOICE_READ" -- "$f" 2>/dev/null)
    [ "$name" = "$1" ] || continue
    tmp=$(mktemp "$SES/.choice.XXXXXX" 2>/dev/null) || continue
    if printf '%s\n%s\n' "$2" "$start" > "$tmp" && IFS= read -r now < <(head -c "$CD_CHOICE_READ" -- "$f" 2>/dev/null) \
       && [ "$now" = "$1" ] && [ -f "$f" ]; then
      mv -f -- "$tmp" "$f" || rm -f -- "$tmp"
    else
      rm -f -- "$tmp"
    fi
  done
}

# move_logs <old> <new>: brain-logs/<old> becomes brain-logs/<new>, unless that already exists.
move_logs() {
  [ -d "$LOGS/$1" ] && [ ! -L "$LOGS/$1" ] || return 0
  if [ -e "$LOGS/$2" ] || [ -L "$LOGS/$2" ]; then
    echo "Its compaction logs stay in $LOGS/$1 ($LOGS/$2 already exists)."
  elif mv -- "$LOGS/$1" "$LOGS/$2" 2>/dev/null; then
    echo "Its compaction logs moved to $LOGS/$2."
  else
    echo "Its compaction logs stay in $LOGS/$1 (they could not be moved)."
  fi
}

rename() {
  local old="$1" new="$2" out rc=0
  cd_valid_name "$old" || { say_err "\"$(cd_printable "$old")\" is not a brain name."; return; }
  if [ "$old" = "$new" ]; then say_err "\"$old\" already has that name (same name); nothing changed."; return; fi
  new_name_ok "$new" || return
  need_python || return
  out=$(regpy rename "$REG" "$old" "$new") || rc=$?
  case $rc in
    0) rechoose "$old" "$new"
       printf 'Renamed brain "%s" to "%s" (no file in its folder was changed).\n' "$old" "$new"
       move_logs "$old" "$new" ;;
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
         "$name" "${out:-its folder}" "$name" "${out:-<folder>}"
       if [ -d "$LOGS/$name" ]; then echo "Its compaction logs stay in $LOGS/$name."; fi
       echo "Windows that chose it load no brain (with a warning) until they pick another." ;;
    3) say_err "no brain named \"$name\" in $REG. See /brain." ;;
    *) say_err "${out:-cannot write $REG}" ;;
  esac
}

list() {
  local sel s_how s_name s_subject s_refused rows rc=0 width=4 name root status problem info mark roots=""
  cd_select_brain ""; sel=$?
  s_how="$CD_HOW"; s_name="$CD_NAME"
  s_subject="$CD_SUBJECT"; s_refused="$CD_REFUSED"
  if [ ! -e "$REG" ] && [ ! -L "$REG" ]; then
    rows=""
  elif command -v python3 >/dev/null 2>&1; then
    rows=$(regpy list "$REG") || rc=$?
  else
    rows=""; rc=5
  fi
  if [ "$rc" = 5 ]; then
    echo "Brains need python3, which is not installed (the registry is $REG); CD_BRAIN cannot load one either."
  elif [ "$rc" != 0 ]; then
    echo "The registry $REG ${rows:-cannot be read}; fix it or move it aside."
    rows=""
  elif [ -z "$rows" ]; then
    echo "No brains yet (registry: $REG)."
    echo "Create one: /brain new <name> [--at <folder>]. Register an existing one: /brain add <name> <folder|STATUS file>"
  else
    echo "Brains (registry: $REG):"
    while IFS=$'\037' read -r name root status problem; do [ ${#name} -gt $width ] && width=${#name}; done <<<"$rows"
    while IFS=$'\037' read -r name root status problem; do
      mark=" "
      if [ -n "$problem" ]; then
        info="not usable: $problem"
      elif cd_check_brain "$root" "$status" "$name"; then
        info="$CD_REL, $(commas "$CD_SIZE") bytes, changed $(date -r "$CD_STATUS" +%Y-%m-%d 2>/dev/null)"
        roots="$roots"$'\n'"$CD_STATUS"
        [ "$sel" = 0 ] && [ "$s_name" = "$name" ] && mark="*"
      else
        info="not usable: ${CD_REFUSED:-cannot be read}"
      fi
      printf '%s %-*s  %s  %s\n' "$mark" "$width" "$name" "$(cd_printable "$root" 4096)" "$info"
    done <<<"$rows"
  fi

  # An old .claude/brain pointer in the current folder (the hooks no longer read pointers) whose brain is not
  # registered: say how to register it.
  if [ -f "$PWD/.claude/brain" ]; then
    CD_POINTER="$PWD/.claude/brain"; CD_ROOT=$(pwd -P)
    LC_ALL=C; export LC_ALL
    if check_pointer; then
      case "$roots"$'\n' in
        *$'\n'"$CD_STATUS"$'\n'*) ;;
        *) echo "Old pointer here: $CD_POINTER names $(cd_printable "$CD_STATUS" 4096); it is no longer read." \
             "Register its brain: /brain add <name>" ;;
      esac
    else
      echo "Old pointer here: $CD_POINTER (no longer read) ${CD_REFUSED:-cannot be read}."
    fi
  fi

  if [ "${CD_HOOKS:-}" = off ]; then
    echo "This window has the hooks off (CD_HOOKS=off), so they load no brain."
  elif [ "$sel" = 0 ] && [ -n "$s_name" ]; then
    echo "This window uses brain \"$s_name\" (chosen with $s_how)."
  elif [ "$s_name" = none ]; then
    if [ "$s_how" = /brain ]; then echo "This window uses no brain (chosen with /brain none)."
    else echo "This window uses no brain (chosen with CD_BRAIN=none)."; fi
  elif [ "$sel" = 1 ]; then
    echo "This window uses no brain: $s_subject $s_refused."
  else
    echo "This window uses no brain: none chosen with /brain, and CD_BRAIN is not set."
  fi
  echo "Attach: /brain <name>, /brain none. Create: /brain new <name> [--at <folder>]. Register: /brain add <name> <folder|STATUS file>. Also: rename, remove, help."
}

usage_err() { echo "brain: wrong arguments."; usage; }

# --upgrade-registry <ts> [--dry-run]: for install.sh only (never reachable through --args): convert a version 1
# registry to version 2, backing it up first; prints one summary line, or nothing.
if [ "${1-}" = --upgrade-registry ] && { [ $# = 2 ] || { [ $# = 3 ] && [ "$3" = --dry-run ]; }; }; then
  command -v python3 >/dev/null 2>&1 || exit 0
  out=$(regpy upgrade "$REG" "$2" "$([ $# = 3 ] && echo 1 || echo 0)")
  [ -n "$out" ] && printf '%s\n' "$out"
  exit 0
fi

# --args: the /brain skill passes the user's raw argument string on stdin, in a quoted heredoc that the shell never
# reads. Split it into words with xargs, which honours '...', "..." and backslashes and expands nothing.
if [ "${1-}" = --args ] && [ $# = 1 ]; then
  raw=$(head -c 4097 2>/dev/null)
  if [ "$(printf '%s' "$raw" | LC_ALL=C wc -c | tr -d '[:space:]')" -gt 4096 ]; then
    say_err "the arguments are too long (over 4,096 bytes)."; exit 0
  fi
  words=()
  if [ -n "${raw//[[:space:]]/}" ]; then
    if ! printf '%s' "$raw" | xargs true >/dev/null 2>&1; then   # fails only on an unmatched quote
      say_err "unmatched quote in: $(cd_printable "$raw" 200)" \
        "(quote a path with ' or spaces in double quotes, as in /brain add x \"~/Bob's Proj\")."
      exit 0
    fi
    while IFS= read -r -d '' w; do words+=("$w"); done < <(printf '%s' "$raw" | xargs printf '%s\0' 2>/dev/null)
  fi
  set -- ${words[@]+"${words[@]}"}
fi

case "${1-}" in
  "") if [ $# -le 1 ]; then list; else usage_err; fi ;;
  help|-h|--help) usage ;;
  list) if [ $# = 1 ]; then list; else usage_err; fi ;;
  auto) say_err "/brain auto is gone: a brain belongs to a window, not a folder, so there is no default to go back to." \
         "/brain none detaches this window; /brain <name> attaches a brain." ;;
  add) if [ $# = 2 ] || [ $# = 3 ]; then add "$2" "${3-}"; else usage_err; fi ;;
  new) if [ $# = 2 ]; then new "$2" ""; elif [ $# = 4 ] && [ "$3" = --at ]; then new "$2" "$4"; else usage_err; fi ;;
  rename) if [ $# = 3 ]; then rename "$2" "$3"; else usage_err; fi ;;
  remove) if [ $# = 2 ]; then remove "$2"; else usage_err; fi ;;
  *) if [ $# = 1 ]; then pick "$1"; else usage_err; fi ;;
esac
exit 0
