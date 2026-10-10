#!/usr/bin/env bash
# ctx-nudge.sh -- UserPromptSubmit hook for the context-discipline skill.
#
# In brain projects (same walk-up and containment rules as the SessionStart hook, from brain-lib.sh) it measures
# how full the session's context is and, at 40% of the window and then at every further 15% (55, 70, 85, 100),
# adds a short note for Claude (hookSpecificOutput.additionalContext): update STATUS at the next natural break,
# write a handoff note if a new sub-task starts, then suggest /clear or /compact <focus> to the user. Each step
# is noted once per session; the steps start again after a compaction.
#
# Context = the usage of the last main-thread API call in the transcript ("transcript_path"):
#   input_tokens + cache_creation_input_tokens + cache_read_input_tokens
# as ctx-audit.py measures it. Subagent (isSidechain) records, "<synthetic>" notices, zero-usage records and
# records a compaction carried over (compactMetadata.preservedMessages) are skipped. All records of one call
# carry the same input usage, so the last record stands for its call. Only the end of the transcript is read
# (256 KB, widened up to 16 MB when no call is found there), so the hook stays fast on long sessions.
#
# Window, first that applies:
#   1. $CD_CTX_WINDOW (tokens), used as given.
#   2. The auto-compact window, as Claude Code resolves it: $CLAUDE_CODE_AUTO_COMPACT_WINDOW (a plain token
#      count, raised to at least 100,000), else autoCompactWindow from settings (managed, project
#      .claude/settings.local.json, .claude/settings.json, then user settings; within a file
#      modelSettings.<model>.autoCompactWindow wins over the top-level key; "auto" means the model's window).
#      Capped at the model's window. The --autocompact flag of one launch cannot be seen from a hook.
#   3. The model's window, from the transcript's model id: 1,000,000 for "[1m]" models and for models with a
#      native 1M window (Fable, Mythos, Sonnet 5+, Haiku 5.5+, Opus 4.7+), unless CLAUDE_CODE_DISABLE_1M_CONTEXT
#      is set; otherwise 200,000. A context already above 200,000 means the window is 1,000,000.
#   4. 200,000.
# State: one small file per session in ${TMPDIR:-/tmp}/context-discipline/ (a private folder; if it is not one,
# the hook stays silent rather than repeat itself).
#
# Contract: prints nothing, or one JSON object with additionalContext. Never blocks the prompt, always exits 0,
# never touches the network. Needs python3 (3.9+) to measure; without it the hook does nothing.

here="${BASH_SOURCE[0]%/*}"; [ "$here" = "${BASH_SOURCE[0]}" ] && here=.
. "$here/brain-lib.sh" 2>/dev/null || exit 0

input=""
if [ ! -t 0 ]; then
  input=$(cat 2>/dev/null)
fi
[ -n "$input" ] || exit 0
cd_brain_of "$input" >/dev/null 2>&1 || exit 0   # not a brain project: nothing to do
command -v python3 >/dev/null 2>&1 || exit 0

# The measuring is done in Python (standard library only); its code is read here, so the hook stays one file.
IFS= read -r -d '' measure <<'PY'
import json, os, re, stat, sys, tempfile

TAIL, MAX_TAIL = 256 * 1024, 16 * 1024 * 1024
FIRST, STEP = 40, 15                       # first note at 40% of the window, then every further 15%
SMALL, LARGE, FLOOR = 200_000, 1_000_000, 100_000
CONTEXT_KEYS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")


def num(x):
    return int(x) if isinstance(x, (int, float)) and not isinstance(x, bool) and x > 0 else 0


def parse(line):
    try:
        r = json.loads(line)
    except ValueError:
        return None
    return r if isinstance(r, dict) else None


def scan(chunk, cut_first):
    """In one tail chunk, find the last compact boundary and the last call after it.
    Returns None if the chunk has neither (read more), else (call record or None, boundary uuid or None)."""
    lines = chunk.split(b"\n")
    if cut_first:
        lines = lines[1:]               # the chunk starts inside a line
    start, boundary, kept = 0, None, set()
    for i in range(len(lines) - 1, -1, -1):
        if b"compact_boundary" not in lines[i]:
            continue
        r = parse(lines[i])
        if r and r.get("type") == "system" and r.get("subtype") == "compact_boundary" and not r.get("isSidechain"):
            boundary = r.get("uuid") if isinstance(r.get("uuid"), str) else ""
            meta = r.get("compactMetadata") if isinstance(r.get("compactMetadata"), dict) else {}
            pm = meta.get("preservedMessages") if isinstance(meta.get("preservedMessages"), dict) else {}
            for key in ("uuids", "allUuids"):
                if isinstance(pm.get(key), list):
                    kept.update(u for u in pm[key] if isinstance(u, str))
            start = i + 1
            break
    for i in range(len(lines) - 1, start - 1, -1):
        line = lines[i]
        if b"\"assistant\"" not in line or b"usage" not in line:
            continue
        r = parse(line)
        if not r or r.get("type") != "assistant" or r.get("isSidechain") or r.get("uuid") in kept:
            continue
        msg = r.get("message")
        if not isinstance(msg, dict) or msg.get("model") == "<synthetic>" or not isinstance(msg.get("usage"), dict):
            continue
        if sum(num(msg["usage"].get(k)) for k in CONTEXT_KEYS) > 0:
            return r, boundary
    return (None, boundary) if boundary is not None else None


def last_call(path):
    with open(path, "rb") as f:
        size = f.seek(0, 2)
        n = TAIL
        while True:
            start = max(0, size - n)
            f.seek(start)
            found = scan(f.read(size - start), start > 0)
            if found is not None:
                return found
            if start == 0 or n >= MAX_TAIL:
                return None, None
            n *= 4


def truthy(v):
    return str(v or "").strip().lower() in ("1", "true", "yes", "on")


def model_window(model):
    """The context window of a model id, as Claude Code 2.1.296 sets it (200K unless a 1M model)."""
    if truthy(os.environ.get("CLAUDE_CODE_DISABLE_1M_CONTEXT")):
        return SMALL
    m = (model or "").lower()
    if "[1m]" in m or "mythos" in m or "fable" in m:
        return LARGE
    f = re.search(r"claude-(opus|sonnet|haiku)-(\d+)(?:-(\d{1,2}))?(?!\d)", m)
    if not f:
        return SMALL
    ver = (int(f.group(2)), int(f.group(3) or 0))
    native = {"sonnet": (5, 0), "haiku": (5, 5), "opus": (4, 7)}[f.group(1)]
    return LARGE if ver >= native else SMALL


def settings_window(keys, project):
    """autoCompactWindow from the settings files, highest scope first: a number (100,000 to 1,000,000),
    "auto", or None if no file sets one."""
    managed = "/Library/Application Support/ClaudeCode" if sys.platform == "darwin" else "/etc/claude-code"
    user = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    files = [os.path.join(managed, "managed-settings.json")]
    if project:
        files += [os.path.join(project, ".claude", n) for n in ("settings.local.json", "settings.json")]
    files.append(os.path.join(user, "settings.json"))
    for p in files:
        try:
            with open(p, encoding="utf-8") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(d, dict):
            continue
        ms = d.get("modelSettings") if isinstance(d.get("modelSettings"), dict) else {}
        values = [ms[k].get("autoCompactWindow") for k in keys if isinstance(ms.get(k), dict)]
        values.append(d.get("autoCompactWindow"))
        for v in values:
            if v == "auto" or (isinstance(v, int) and not isinstance(v, bool) and FLOOR <= v <= LARGE):
                return v
    return None


def tokens(v):
    """A plain positive token count from an environment variable, else None."""
    v = (v or "").strip()
    return int(v) if re.fullmatch(r"[0-9]+", v) and int(v) > 0 else None


def window_of(rec, ctx, project):
    """The window, in tokens, that the context is measured against."""
    own = tokens(os.environ.get("CD_CTX_WINDOW"))
    if own:
        return own
    msg = rec.get("message") or {}
    names = [x for x in (rec.get("requestedModel"), msg.get("model")) if isinstance(x, str) and x]
    model = LARGE if any(model_window(x) == LARGE for x in names) else SMALL
    if ctx > model:                     # more context than a 200K window holds: it is a 1M window
        model = LARGE
    env = tokens(os.environ.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW"))
    if env:
        return min(model, max(FLOOR, min(env, LARGE)))
    keys = []
    for x in names:
        base = re.sub(r"\[1m\]$", "", x, flags=re.I)
        keys += [x, base, re.sub(r"-\d{8}$", "", base)]
    v = settings_window(list(dict.fromkeys(keys)), project)
    if isinstance(v, int):
        return min(model, v)
    return model


def state_dir():
    """The private state folder, or None if it cannot be trusted."""
    d = os.path.join(os.environ.get("TMPDIR") or "/tmp", "context-discipline")
    try:
        os.mkdir(d, 0o700)
    except FileExistsError:
        pass
    st = os.lstat(d)
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        return None
    return d


def main():
    try:
        hook = json.load(sys.stdin)
    except ValueError:
        return
    if not isinstance(hook, dict):
        return
    path = hook.get("transcript_path")
    if not isinstance(path, str) or not os.path.isfile(path):
        return
    rec, boundary = last_call(path)
    if rec is None and boundary is None:
        return
    folder = state_dir()
    if folder is None:
        return
    sid = hook.get("session_id")
    if not isinstance(sid, str) or not sid:
        sid = os.path.basename(path)
    sfile = os.path.join(folder, "nudge-" + re.sub(r"[^A-Za-z0-9_.-]", "_", sid)[:120])
    try:
        with open(sfile, encoding="utf-8") as fh:
            state = json.load(fh)
        if not isinstance(state, dict):
            state = {}
    except (OSError, ValueError):
        state = {}
    old = dict(state)
    step = state.get("step") if isinstance(state.get("step"), int) else -1
    if boundary is not None and boundary != state.get("boundary"):
        step = -1                       # a compaction since the last note: the steps start again
        state["boundary"] = boundary
    note = None
    if rec is not None:
        u = rec["message"]["usage"]
        ctx = sum(num(u.get(k)) for k in CONTEXT_KEYS)
        project = os.environ.get("CLAUDE_PROJECT_DIR") or hook.get("cwd")
        window = window_of(rec, ctx, project if isinstance(project, str) else "")
        pct = ctx * 100 / window
        now = int((pct - FIRST) // STEP) if pct >= FIRST else -1
        if now > step:
            step = now
            rel = re.sub(r"[\x00-\x1f\x7f]", "?", os.environ.get("CD_REL") or "STATUS.md")[:200]
            note = (
                f"Context check (context-discipline): this session's context is at {int(pct)}% of its "
                f"{window:,}-token window ({ctx:,} tokens).\n"
                f"Do not stop mid-task. At the next natural break, update {rel}, and write a handoff note if a "
                f"new sub-task is about to start.\n"
                f"Then suggest to the user /clear (a fresh session that starts from {rel} and the handoff) "
                f"or /compact <focus>."
            )
    state["step"] = step
    if state != old:
        fd, tmp = tempfile.mkstemp(prefix=".nudge-", dir=folder)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(state, fh)
        os.replace(tmp, sfile)
    if note:
        out = {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": note}}
        sys.stdout.write(json.dumps(out) + "\n")


try:
    main()
except Exception:
    pass
PY

printf '%s' "$input" | CD_REL="$CD_REL" python3 -I -c "$measure" 2>/dev/null
exit 0
