#!/usr/bin/env bash
# install.sh -- install (or update, or remove) the context-discipline skill for Claude Code.
#
# Usage: ./install.sh [--dry-run] [--uninstall] [--skip-claude-md] [-h|--help]
#
# Works on macOS and Linux with bash and python3 only. Targets ${CLAUDE_CONFIG_DIR:-$HOME/.claude}.
# Run ./install.sh --help for what it changes. Safe to run again: steps already done are skipped,
# which is also how you update (git pull && ./install.sh).

# Re-run under bash if started with sh.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

CLAUDE_MD_LINE='- For any work that spans many steps or sessions (projects, research surveys, designs, specs, plans, subagent dispatches, reviews), follow the `context-discipline` skill: the main agent coordinates; subagents put deliverables in files and hand back about 15 lines; keep the project brain (STATUS.md, auto-loaded through a `.claude/brain` pointer) current at every decision.'

usage() {
  cat <<'EOF'
Usage: ./install.sh [--dry-run] [--uninstall] [--skip-claude-md] [-h|--help]

Installs the context-discipline skill for Claude Code into $CLAUDE_CONFIG_DIR, or ~/.claude if that is unset:
  1. Skill:     copies context-discipline/ to <dir>/skills/context-discipline/
                (an existing copy that differs is first moved to <dir>/skill-backups/)
  2. Hooks:     adds three hooks to <dir>/settings.json, each in one entry with no matcher (older
                entries for the same hook are replaced), running skills/context-discipline/scripts/...
                  SessionStart     brain-hook.sh   every source (startup, resume, clear, compact, fork):
                                                   prints the project's STATUS file
                  PostCompact      compact-log.sh  every compaction: saves the summary in the project
                  UserPromptSubmit ctx-nudge.sh    every prompt: a short note at 40% of the context
                                                   window and every 15% after (5-second timeout)
                The last two act only in projects with a brain (.claude/brain).
  3. CLAUDE.md: appends one line telling Claude when to follow the skill
settings.json and CLAUDE.md are backed up to <file>.bak-<timestamp> before they are changed.
Steps that are already done are skipped, so running it again is safe. To update: git pull && ./install.sh

Options:
  --dry-run         print every planned change and change nothing
  --uninstall       remove the skill, the three hooks and the CLAUDE.md line (backups first)
  --skip-claude-md  leave CLAUDE.md alone
  -h, --help        show this help
EOF
}

die() { echo "install.sh: $*" >&2; exit 1; }

DRY=0; UNINSTALL=0; SKIP_MD=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --skip-claude-md) SKIP_MD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "install.sh: unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || die "python3 is required (it edits settings.json safely). Install it and run again."

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SRC="$REPO_DIR/context-discipline"
for f in SKILL.md scripts/brain-hook.sh scripts/brain-lib.sh scripts/compact-log.sh scripts/ctx-nudge.sh; do
  [ -f "$SRC/$f" ] || die "cannot find the skill at $SRC ($f is missing). Run install.sh from a full clone of the repo."
done

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-${HOME:?HOME is not set}/.claude}"
case "$CLAUDE_DIR" in
  /*) ;;
  *) CLAUDE_DIR="$PWD/$CLAUDE_DIR" ;;
esac
[ "$CLAUDE_DIR" = "/" ] || CLAUDE_DIR="${CLAUDE_DIR%/}"
[ ! -e "$CLAUDE_DIR" ] || [ -d "$CLAUDE_DIR" ] || die "$CLAUDE_DIR exists but is not a directory."

SKILLS_DIR="$CLAUDE_DIR/skills"
DEST="$SKILLS_DIR/context-discipline"
BACKUP_DIR="$CLAUDE_DIR/skill-backups"   # outside skills/, so Claude Code never loads a backup as a second skill
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
SCRIPTS="$DEST/scripts"
HOOK="$SCRIPTS/brain-hook.sh"
TS=$(date +%Y%m%d-%H%M%S)

# ---------------------------------------------------------------------------------------------------------------
# Python helper: JSON-safe edits of settings.json, CLAUDE.md edits, directory comparison.
# Prints one human-readable result line per step; exits 3 (with a message on stderr) if settings.json is unusable.
helper() {
  python3 -I - "$@" <<'PY'
import filecmp, json, os, shlex, shutil, sys, tempfile

PREFIX = "context-discipline/scripts/"
# (event, script, what an entry with no matcher fires on, extra fields of a new entry)
HOOKS = (
    ("SessionStart", "brain-hook.sh", "every source", " (startup, resume, clear, compact, fork)", {}),  # fork: 2.1.214+
    ("PostCompact", "compact-log.sh", "every compaction", " (manual and auto)", {}),
    ("UserPromptSubmit", "ctx-nudge.sh", "every prompt", "", {"timeout": 5}),
)
SCRIPTS = tuple(h[1] for h in HOOKS)
NO_MATCHER = {"UserPromptSubmit"}   # events that ignore "matcher": every entry fires every time
IGNORE = {"__pycache__", ".DS_Store"}


def fail(msg):
    sys.stderr.write("install.sh: " + msg + "\nNothing was changed.\n")
    sys.exit(3)


def load_settings(path):
    """Return (exists, data). Stops the installer if the file is not a usable JSON object."""
    if not os.path.exists(path):
        return False, {}
    try:
        with open(path, encoding="utf-8") as f:
            raw = f.read()
    except (OSError, ValueError) as e:
        fail(f"cannot read {path}: {e}")
    if not raw.strip():
        return True, {}
    try:
        data = json.loads(raw)
    except ValueError as e:
        fail(f"{path} is not valid JSON ({e}).\nFix the file, or move it aside, then run install.sh again.")
    if not isinstance(data, dict):
        fail(f"{path} is valid JSON but its top level is not an object ({{...}}).")
    hooks = data.get("hooks")
    if hooks is not None and not isinstance(hooks, dict):
        fail(f'"hooks" in {path} is not an object.')
    for event, *_ in HOOKS:
        if isinstance(hooks, dict) and not isinstance(hooks.get(event, []), list):
            fail(f'"hooks.{event}" in {path} is not a list.')
    return True, data


def unique(path):
    if not os.path.lexists(path):
        return path
    n = 2
    while os.path.lexists(f"{path}-{n}"):
        n += 1
    return f"{path}-{n}"


def backup(path, ts):
    dst = unique(f"{path}.bak-{ts}")
    shutil.copy2(path, dst)  # copies the content even if path is a symlink
    return dst


def write_atomic(path, text):
    real = os.path.realpath(path)  # keep a symlinked settings.json or CLAUDE.md a symlink
    folder = os.path.dirname(real)
    os.makedirs(folder, exist_ok=True)
    if os.path.exists(real):
        mode = os.stat(real).st_mode & 0o7777
    else:
        umask = os.umask(0)
        os.umask(umask)
        mode = 0o666 & ~umask
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(real) + ".", suffix=".tmp", dir=folder)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, real)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def esc(s):
    """Escape s for use inside double quotes on a shell command line."""
    return "".join("\\" + c if c in '\\"$`' else c for c in s)


def hook_command(hook_path):
    """The command for settings.json. Under $HOME it is written with $HOME, so a settings.json shared between
    machines with different home folders (dotfiles) still finds the script on each."""
    home = os.environ.get("HOME", "").rstrip("/")
    if home and hook_path.startswith(home + "/"):
        return 'bash "$HOME' + esc(hook_path[len(home):]) + '"'
    return 'bash "' + esc(hook_path) + '"'


def script_of(command, script):
    """The path of <script> that a hook command runs, with ~ and $HOME expanded. "" if the command cannot run
    (unbalanced quotes); None if it cannot be told (other variables, or no path)."""
    try:
        words = shlex.split(command)
    except ValueError:
        return ""
    for w in words:
        if PREFIX + script in w:
            p = os.path.expanduser(os.path.expandvars(w))
            return None if "$" in p else p
    return None


def missing_script(h, script, hook_path):
    """The script path of our hook h if it does not exist (and is not the one this run installs), else None."""
    p = script_of(h["command"], script)
    if p is None or os.path.isfile(p) or os.path.realpath(p) == os.path.realpath(hook_path):
        return None
    return p or h["command"]


def hooks_of(entry):
    if isinstance(entry, dict) and isinstance(entry.get("hooks"), list):
        return entry["hooks"]
    return []


def is_ours(h, scripts=SCRIPTS):
    """Is h a hook that runs one of <scripts> from the installed skill?"""
    return (isinstance(h, dict) and isinstance(h.get("command"), str)
            and any(PREFIX + s in h["command"] for s in scripts))


def covers_all(event, matcher):
    """Does an entry with this matcher fire every time the event happens (for SessionStart: every source,
    including ones added later)?"""
    return event in NO_MATCHER or matcher is None or (isinstance(matcher, str) and matcher.strip() in ("", "*"))


def label(entry):
    m = entry.get("matcher")
    return "no matcher" if m is None else (m or '""')


def plan_install(data, event, script, hook_path):
    """Edit data so hooks.<event> holds exactly one hook running <script>, in an entry with no matcher (it fires
    every time), whose script exists. Returns ((verb, rest) describing the change, whether a new entry was
    added), or (None, False) if it already holds."""
    _, _, every, detail, extra = next(h for h in HOOKS if h[0] == event)
    mine = (script,)
    hooks = data.get("hooks") if isinstance(data.get("hooks"), dict) else {}
    entries = hooks.get(event, [])
    ours = [(e, h) for e in entries if isinstance(e, dict) for h in hooks_of(e) if is_ours(h, mine)]
    missing = [m for m in (missing_script(h, script, hook_path) for e, h in ours) if m]
    keep = next((h for e, h in ours
                 if covers_all(event, e.get("matcher")) and not missing_script(h, script, hook_path)), None)
    if keep is not None and len(ours) == 1:
        return None, False
    removed, kept_entries = [], []
    for e in entries:
        if not (isinstance(e, dict) and any(is_ours(h, mine) for h in hooks_of(e))):
            kept_entries.append(e)
            continue
        rest = [h for h in e["hooks"] if h is keep or not is_ours(h, mine)]
        removed += [label(e)] * (len(e["hooks"]) - len(rest))
        if rest:
            e["hooks"] = rest
            kept_entries.append(e)
    if keep is None:
        kept_entries.append({"hooks": [dict({"type": "command", "command": hook_command(hook_path)}, **extra)]})
    data.setdefault("hooks", {})[event] = kept_entries
    n = len(removed)
    old = f"{n} old {event} hook {'entry' if n == 1 else 'entries'} ({', '.join(removed)})"
    gone = f"; the old hook ran {', '.join(sorted(set(missing)))}, which does not exist" if missing else ""
    if keep is not None:
        return ("remove", f"{old}; the entry for {every} stays{gone}"), False
    if removed:
        return ("replace", f"{old} with one for {every}{detail}{gone}"), True
    return ("add", f"one {event} hook for {every}{detail}"), True


def plan_all(data, scripts_dir):
    """plan_install for each of our hooks: [(event, change, added, command)] for the hooks that change."""
    out = []
    for event, script, *_ in HOOKS:
        path = os.path.join(scripts_dir, script)
        change, added = plan_install(data, event, script, path)
        if change is not None:
            out.append((event, change, added, hook_command(path)))
    return out


def said(change, dry):
    """('add', 'x') -> 'added x', or 'would add x' in a dry run."""
    verb, rest = change
    return f"would {verb} {rest}" if dry == "1" else f"{verb.rstrip('e')}ed {rest}"


def said_all(plan, dry):
    return "; ".join(said(change, dry) for _, change, _, _ in plan)


def dump(data):
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def need_writable(path):
    """Stop now if writing path later would fail: its backup goes beside it, the new file replaces its real file."""
    for folder in (os.path.dirname(os.path.abspath(path)), os.path.dirname(os.path.realpath(path))):
        d = folder
        while d and not os.path.exists(d):
            d = os.path.dirname(d)
        if not os.access(d or "/", os.W_OK):
            fail(f"cannot change {path}: the folder {d} is read-only.")


def cmd_check(path, md_path, line, scripts_dir, uninstall, skip_md):
    """Find every problem that would stop the run halfway, before anything is changed."""
    exists, data = load_settings(path)
    if uninstall == "1":
        changes = exists and bool(plan_uninstall(data))
    else:
        changes = bool(plan_all(data, scripts_dir))
    if changes:
        need_writable(path)
    if skip_md == "1":
        return
    text = read_md(md_path)
    changed = md_removed(text, line)[0] if uninstall == "1" else md_added(text, line)
    if changed is not None:
        need_writable(md_path)


def cmd_settings_install(path, scripts_dir, ts, dry):
    settings_install(path, scripts_dir, ts, dry)
    _, data = load_settings(path)
    if data.get("disableAllHooks") is True:
        print('settings.json: NOTE: "disableAllHooks" is true there, so Claude Code runs no hooks, these '
              "included, until you remove it")


def settings_install(path, scripts_dir, ts, dry):
    exists, data = load_settings(path)
    plan = plan_all(data, scripts_dir)
    if not plan:
        print("settings.json: unchanged, the hooks are already there (SessionStart, PostCompact, UserPromptSubmit;"
              " one entry each)")
        return
    if dry == "1":
        where = f"backup first to {path}.bak-{ts}" if exists else f"new file {path}"
        print(f"settings.json: {said_all(plan, dry)}; {where}")
        for event, _, added, command in plan:
            if added:
                print(f"               {event} runs: {command}")
        return
    saved = f"; backup: {backup(path, ts)}" if exists else "; created the file"
    write_atomic(path, dump(data))
    print(f"settings.json: {said_all(plan, dry)}{saved}")


def plan_uninstall(data):
    """Remove every one of our hooks from data (any event, any matcher). Returns what was removed."""
    hooks = data.get("hooks")
    removed = []
    if isinstance(hooks, dict):
        for event in list(hooks):
            entries = hooks[event]
            if not isinstance(entries, list):
                continue
            kept = []
            for e in entries:
                ours = [h for h in hooks_of(e) if is_ours(h)]
                if not ours:
                    kept.append(e)
                    continue
                removed += [f"{event}/{e.get('matcher', '*')}"] * len(ours)
                rest = [h for h in e["hooks"] if not is_ours(h)]
                if rest:
                    e["hooks"] = rest
                    kept.append(e)
            if kept:
                hooks[event] = kept
            elif entries:  # every entry held only our hook: drop the now-empty list
                del hooks[event]
        if not hooks and removed:
            del data["hooks"]
    return removed


def cmd_settings_uninstall(path, ts, dry):
    exists, data = load_settings(path)
    if not exists:
        print("settings.json: unchanged, no settings.json")
        return
    removed = plan_uninstall(data)
    if not removed:
        print("settings.json: unchanged, no context-discipline hook found")
        return
    what = ", ".join(removed)
    if dry == "1":
        print(f"settings.json: would remove {len(removed)} hook entries ({what}); backup first to {path}.bak-{ts}")
        return
    saved = backup(path, ts)
    write_atomic(path, dump(data))
    print(f"settings.json: removed {len(removed)} hook entries ({what}); backup: {saved}")


def read_md(path):
    """CLAUDE.md as text with its line endings untouched ("" if missing). Stops the run if it is not UTF-8."""
    if not os.path.exists(path):
        return ""
    try:
        with open(path, encoding="utf-8", newline="") as f:
            return f.read()
    except UnicodeDecodeError:
        fail(f"{path} is not UTF-8 text, so the installer will not edit it.\n"
             "Convert it to UTF-8, or run with --skip-claude-md and add the line yourself.")
    except OSError as e:
        fail(f"cannot read {path}: {e}")


def md_added(text, line):
    """text with line appended in the file's own line endings, or None if a line already mentions the skill."""
    if any("context-discipline" in l for l in text.splitlines()):
        return None
    nl = "\r\n" if "\r\n" in text else "\n"
    return text + (nl if text and not text.endswith("\n") else "") + line + nl


def md_removed(text, line):
    """(text without the installer's line, or None if it is not there; other lines that mention the skill)."""
    lines = text.splitlines(keepends=True)
    keep = [l for l in lines if l.strip() != line.strip()]
    others = [l.strip() for l in keep if "context-discipline" in l]
    return ("".join(keep) if len(keep) != len(lines) else None), others


def cmd_md_add(path, line, ts, dry):
    exists = os.path.exists(path)
    new = md_added(read_md(path), line)
    if new is None:
        print("CLAUDE.md:     unchanged, a line already mentions context-discipline")
        return
    if dry == "1":
        where = f"backup first to {path}.bak-{ts}" if exists else f"new file {path}"
        print(f"CLAUDE.md:     would append this line ({where}):")
        print(f"               {line}")
        return
    saved = f"; backup: {backup(path, ts)}" if exists else "; created the file"
    write_atomic(path, new)
    print(f"CLAUDE.md:     appended the context-discipline line{saved}")


def cmd_md_remove(path, line, ts, dry):
    if not os.path.exists(path):
        print("CLAUDE.md:     unchanged, no CLAUDE.md")
        return
    new, others = md_removed(read_md(path), line)
    warn = ""
    if others:
        warn = (f"\nCLAUDE.md:     NOTE: {len(others)} other line(s) mention context-discipline and were left alone; "
                f"edit {path} if you want them gone")
    if new is None:
        print("CLAUDE.md:     unchanged, the installer's line is not there" + warn)
        return
    if dry == "1":
        print(f"CLAUDE.md:     would remove the context-discipline line; backup first to {path}.bak-{ts}" + warn)
        return
    saved = backup(path, ts)
    write_atomic(path, new)
    print(f"CLAUDE.md:     removed the context-discipline line; backup: {saved}" + warn)


def files_under(root):
    out = {}
    for folder, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in IGNORE]
        for name in files:
            if name not in IGNORE:
                p = os.path.join(folder, name)
                out[os.path.relpath(p, root)] = p
    return out


def cmd_same_tree(a, b):
    fa, fb = files_under(a), files_under(b)
    same = fa.keys() == fb.keys() and all(filecmp.cmp(fa[k], fb[k], shallow=False) for k in fa)
    sys.exit(0 if same else 1)


COMMANDS = {
    "check": cmd_check,
    "settings-install": cmd_settings_install,
    "settings-uninstall": cmd_settings_uninstall,
    "md-add": cmd_md_add,
    "md-remove": cmd_md_remove,
    "same-tree": cmd_same_tree,
}
COMMANDS[sys.argv[1]](*sys.argv[2:])
PY
}

REPORT=""
report() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && REPORT="${REPORT}  ${line}"$'\n'
  done <<EOF
$1
EOF
  return 0
}

unique_path() {
  local p="$1" n=2
  if [ ! -e "$p" ] && [ ! -L "$p" ]; then printf '%s\n' "$p"; return; fi
  while [ -e "$p-$n" ] || [ -L "$p-$n" ]; do n=$((n + 1)); done
  printf '%s\n' "$p-$n"
}

copy_skill() {
  mkdir -p "$SKILLS_DIR"
  cp -R "$SRC" "$DEST"
  find "$DEST" \( -name __pycache__ -o -name .DS_Store \) -prune -exec rm -rf {} +
  chmod +x "$DEST"/scripts/* 2>/dev/null || true
}

skill_install() {
  if [ ! -e "$DEST" ] && [ ! -L "$DEST" ]; then
    if [ "$DRY" = 1 ]; then
      report "skill:         would copy $SRC to $DEST"
    else
      copy_skill
      report "skill:         copied to $DEST"
    fi
    return
  fi
  if [ -d "$DEST" ] && helper same-tree "$SRC" "$DEST"; then
    report "skill:         unchanged, $DEST already matches this repo"
    return
  fi
  local saved
  saved=$(unique_path "$BACKUP_DIR/context-discipline.bak-$TS")
  if [ "$DRY" = 1 ]; then
    report "skill:         would move the existing copy to $saved, then copy $SRC to $DEST"
  else
    mkdir -p "$BACKUP_DIR"
    mv "$DEST" "$saved"
    copy_skill
    report "skill:         updated $DEST; previous copy moved to $saved"
  fi
}

skill_uninstall() {
  if [ ! -e "$DEST" ] && [ ! -L "$DEST" ]; then
    report "skill:         unchanged, $DEST is not there"
    return
  fi
  if [ -d "$DEST" ] && [ ! -L "$DEST" ] && helper same-tree "$SRC" "$DEST"; then
    if [ "$DRY" = 1 ]; then
      report "skill:         would delete $DEST (it matches this repo)"
    else
      rm -rf "$DEST"
      report "skill:         deleted $DEST (it matched this repo)"
    fi
    return
  fi
  local saved
  saved=$(unique_path "$BACKUP_DIR/context-discipline.bak-$TS")
  if [ "$DRY" = 1 ]; then
    report "skill:         would move $DEST to $saved (it differs from this repo)"
  else
    mkdir -p "$BACKUP_DIR"
    mv "$DEST" "$saved"
    report "skill:         moved $DEST to $saved (it differed from this repo)"
  fi
}

# Check settings.json and CLAUDE.md before touching anything, so a problem stops the run with no change at all.
helper check "$SETTINGS" "$CLAUDE_MD" "$CLAUDE_MD_LINE" "$SCRIPTS" "$UNINSTALL" "$SKIP_MD" || exit 1

if [ "$DRY" = 1 ]; then
  echo "context-discipline installer: DRY RUN, nothing will be changed"
else
  echo "context-discipline installer"
fi
echo "Claude Code config dir: $CLAUDE_DIR"
echo

if [ "$UNINSTALL" = 1 ]; then
  out=$(helper settings-uninstall "$SETTINGS" "$TS" "$DRY") || die "editing settings.json failed (see above)."
  report "$out"
  if [ "$SKIP_MD" = 1 ]; then
    report "CLAUDE.md:     skipped (--skip-claude-md)"
  else
    out=$(helper md-remove "$CLAUDE_MD" "$CLAUDE_MD_LINE" "$TS" "$DRY") || die "editing CLAUDE.md failed (see above)."
    report "$out"
  fi
  skill_uninstall
else
  [ "$DRY" = 1 ] || mkdir -p "$CLAUDE_DIR"
  skill_install
  out=$(helper settings-install "$SETTINGS" "$SCRIPTS" "$TS" "$DRY") || die "editing settings.json failed (see above)."
  report "$out"
  if [ "$SKIP_MD" = 1 ]; then
    report "CLAUDE.md:     skipped (--skip-claude-md)"
  else
    out=$(helper md-add "$CLAUDE_MD" "$CLAUDE_MD_LINE" "$TS" "$DRY") || die "editing CLAUDE.md failed (see above)."
    report "$out"
  fi
fi

echo "Summary:"
printf '%s' "$REPORT"
echo

if [ "$DRY" = 1 ]; then
  echo "Dry run: nothing was changed. Run again without --dry-run to apply."
elif [ "$UNINSTALL" = 1 ]; then
  cat <<EOF
Next steps:
  1. Claude Code picks up the change within a few seconds: open /hooks to check the hooks are gone, and
     restart Claude Code only if they are still listed.
  2. Projects keep their .claude/brain pointer, STATUS.md, overview and .claude/compactions/ logs;
     delete them in a project if you no longer want them.
To install again: ./install.sh
EOF
else
  cat <<EOF
Next steps:
  1. Claude Code picks up the new hooks within a few seconds: open /hooks to check the SessionStart,
     PostCompact and UserPromptSubmit hooks are listed, and restart Claude Code only if they are not.
  2. In each project that will outlive one session, set up its brain:
       bash "$DEST/scripts/init-brain.sh" <project-root>
     then fill in STATUS.md and 00-Project-Overview.md and commit them with .claude/brain.
     Or ask Claude: "set up a project brain for this repo". In brain projects the other two hooks save
     each compaction summary to .claude/compactions/ (kept out of git) and add a short note when the
     context reaches 40% of its window and every 15% after.
  3. Check the SessionStart hook finds it (it prints your STATUS, then a "Project brain loaded from" line):
       echo '{"cwd": "<project-root>/some/subdir", "source": "startup"}' | bash "$HOOK"
To update later: git pull && ./install.sh
EOF
fi
