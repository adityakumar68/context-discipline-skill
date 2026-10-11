#!/usr/bin/env bash
# ctx-nudge.sh -- UserPromptSubmit hook for the context-discipline skill.
#
# When the session has a brain (picked as the SessionStart hook picks it, from brain-lib.sh: /brain in this window,
# else CD_BRAIN, else the folder walk-up) it measures how full the session's context is and, at 40% of the window
# and then at every further 15% (55, 70, 85, 100), adds a short note for Claude
# (hookSpecificOutput.additionalContext): update STATUS at the next natural break,
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
# Compactions: the state file keeps how far the transcript had got at the previous prompt, and everything written
# since then (up to the last 16 MB) is searched for a compaction boundary record, so a compaction early in a long
# turn is still seen. If more than 16 MB was written since then, a context lower than at the previous prompt
# counts as a compaction instead.
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
cd_select_brain "$input" >/dev/null 2>&1 || exit 0   # no brain for this session: nothing to do
command -v python3 >/dev/null 2>&1 || exit 0

# The measuring is done in Python (standard library only); its code is read here, so the hook stays one file.
IFS= read -r -d '' measure <<'PY'
import json, os, re, stat, sys, tempfile

TAIL, MAX_TAIL = 256 * 1024, 16 * 1024 * 1024
FIRST, STEP = 40, 15                       # first note at 40% of the window, then every further 15%
SMALL, LARGE, FLOOR = 200_000, 1_000_000, 100_000
CONTEXT_KEYS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
JSON_CAP = 1_000_000   # bytes; settings or state files larger than this are skipped


def read_json(path, cap=JSON_CAP):
    """Parse path as JSON only if it is a regular file of at most cap bytes; otherwise (or on any error) None.
    Opened non-blocking and re-checked on the open descriptor, so a FIFO, a device such as /dev/zero, or a huge
    file in a hostile project can neither hang this hook nor exhaust memory."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > cap:
            return None
        chunks, n = [], 0
        while n <= cap:
            b = os.read(fd, cap + 1 - n)
            if not b:
                break
            chunks.append(b)
            n += len(b)
        if n > cap:
            return None
        return json.loads(b"".join(chunks).decode("utf-8"))
    except (OSError, ValueError):
        return None
    finally:
        os.close(fd)


def num(x):
    return int(x) if isinstance(x, (int, float)) and not isinstance(x, bool) and x > 0 else 0


def parse(line):
    try:
        r = json.loads(line)
    except ValueError:
        return None
    return r if isinstance(r, dict) else None


def read_lines(f, start, end):
    """(lines, base): the lines of f that start in [start, end), and the offset of the first. A line that starts
    before start is left out. The last item is what follows the last newline: b"" if the range ends with one,
    else a line still being written. ([], end) if no line starts in the range."""
    begin = max(0, start - 1)
    f.seek(begin)
    data = f.read(end - begin)
    if start > 0:
        cut = data.find(b"\n") + 1      # one byte before start is read, so a line starting at start is kept
        if cut == 0:
            return [], end
        data, begin = data[cut:], begin + cut
    return data.split(b"\n"), begin


def boundary_in(lines):
    """(index, uuid, uuids carried over) of the last main-thread compact boundary in lines, or None."""
    for i in range(len(lines) - 1, -1, -1):
        if b"compact_boundary" not in lines[i]:
            continue
        r = parse(lines[i])
        if r and r.get("type") == "system" and r.get("subtype") == "compact_boundary" and not r.get("isSidechain"):
            meta = r.get("compactMetadata") if isinstance(r.get("compactMetadata"), dict) else {}
            pm = meta.get("preservedMessages") if isinstance(meta.get("preservedMessages"), dict) else {}
            kept = set()
            for key in ("uuids", "allUuids"):
                if isinstance(pm.get(key), list):
                    kept.update(u for u in pm[key] if isinstance(u, str))
            return i, (r.get("uuid") if isinstance(r.get("uuid"), str) else ""), kept
    return None


def call_in(lines, start, kept):
    """The record of the last main-thread call in lines[start:], or None."""
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
            return r
    return None


def last_call(path, since):
    """Read the end of the transcript. since: the offset it had reached at the previous prompt (None if unknown).
    Returns (call, boundary, new, done, unsearched):
      call       the last main-thread call after the last compaction (None if there is none yet)
      boundary   the uuid of that compaction's boundary record ("" if it has none, None if none was found)
      new        whether that boundary was written at or after since (always True when since is None)
      done       the offset just past the last complete line (None if unknown), the next prompt's since
      unsearched whether more than MAX_TAIL bytes were written since since, so a compaction may be unseen."""
    with open(path, "rb") as f:
        size = f.seek(0, 2)
        if since is not None and not 0 <= since <= size:
            since = None                # the file was replaced or cut: start over
        n = TAIL if since is None else max(TAIL, size - since)   # all that was written since the previous prompt
        while True:
            start = max(0, size - min(n, MAX_TAIL))
            lines, base = read_lines(f, start, size)
            b = boundary_in(lines)
            call = call_in(lines, b[0] + 1 if b else 0, b[2] if b else set())
            if call is not None or b is not None or start == 0 or n >= MAX_TAIL:
                break
            n *= 4
    done = size - len(lines[-1]) if lines else None
    new = True
    if b is not None and since is not None:
        new = base + sum(len(x) + 1 for x in lines[:b[0]]) >= since
    unsearched = since is not None and size - since > MAX_TAIL
    return call, (b[1] if b else None), new, done, unsearched


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
        d = read_json(p)
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
    folder = state_dir()
    if folder is None:
        return
    sid = hook.get("session_id")
    if not isinstance(sid, str) or not sid:
        sid = os.path.basename(path)
    sfile = os.path.join(folder, "nudge-" + re.sub(r"[^A-Za-z0-9_.-]", "_", sid)[:120])
    state = read_json(sfile)
    if not isinstance(state, dict):
        state = {}
    old = dict(state)

    def count(key):
        v = state.get(key)
        return v if isinstance(v, int) and not isinstance(v, bool) else None

    rec, boundary, new, done, unsearched = last_call(path, count("size"))
    if rec is None and boundary is None:
        return
    step = count("step")
    step = -1 if step is None else step
    ctx = None
    if rec is not None:
        ctx = sum(num(rec["message"]["usage"].get(k)) for k in CONTEXT_KEYS)
    if boundary is not None and new and boundary != state.get("boundary"):
        step = -1                       # a compaction since the previous prompt: the steps start again
        state["boundary"] = boundary
    elif unsearched and ctx is not None and count("ctx") is not None and ctx < count("ctx"):
        step = -1                       # too much written since then to search, but the context fell: a compaction
    if done is not None:
        state["size"] = done
    note = None
    if rec is not None:
        state["ctx"] = ctx
        project = os.environ.get("CLAUDE_PROJECT_DIR") or hook.get("cwd")
        window = window_of(rec, ctx, project if isinstance(project, str) else "")
        pct = ctx * 100 / window
        now = int((pct - FIRST) // STEP) if pct >= FIRST else -1
        if now > step:
            step = now
            # the full path: the session's cwd may be a subfolder of the project
            rel = re.sub(r"[\x00-\x1f\x7f]", "?", os.environ.get("CD_STATUS") or "STATUS.md")[:2100]
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

# exec, so a hook timeout (or any kill) reaches python itself instead of leaving it orphaned. The script ends in
# try/except, so it always exits 0.
CD_STATUS="$CD_STATUS" exec python3 -I -c "$measure" 2>/dev/null <<<"$input"
