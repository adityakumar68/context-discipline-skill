# The hooks

What the three global hooks do, how to install, test and troubleshoot them, and the built-in alternatives.
`${CLAUDE_SKILL_DIR}` below is this skill's folder (the base directory shown when the skill loads; after
`install.sh`, `~/.claude/skills/context-discipline`). `<config>` is `$CLAUDE_CONFIG_DIR`, else `~/.claude`.

| Event | Script | Does |
|---|---|---|
| `SessionStart` | `brain-hook.sh` | prints the session's brain's STATUS into context, or a one-line hint |
| `PostCompact` | `compact-log.sh` | saves the compaction summary in `<config>/brain-logs/<name>/` |
| `UserPromptSubmit` | `ctx-nudge.sh` | adds a context-check note as the window fills, and a note when STATUS changed |

A brain belongs to a Claude Code session, never to a folder. All three hooks pick the session's brain with one
shared function (`cd_select_brain` in `brain-lib.sh`), first match wins:

1. the choice made with `/brain <name>` or `/brain none` in this Claude Code window: the file
   `<config>/brain-sessions/pid-$CLAUDE_PID` (else `sid-<session id>`). `$CLAUDE_PID` is the Claude Code process,
   set for hooks and for the Bash tool alike, so the choice survives `/clear` (which starts a new session id) and
   compaction. The file also holds when that process started, so a later process that reuses the PID does not
   inherit it. Any number of windows may choose the same brain.
2. `CD_BRAIN=<name>` or `CD_BRAIN=none` in the environment.
3. else no brain. The session's folder plays no part: no hook reads a `.claude/brain` pointer.

A name is looked up in `<config>/brains.json`, `{"version": 2, "brains": {"<name>": {"dir": "<abs brain folder>",
"status": "STATUS.md"}}}` (`status` is relative to `dir`), which `/brain` (`scripts/brain.sh`) writes. A version 1
registry (`{"root": ..., "status": "<abs path>"}`, from an earlier version) is still read, each entry's `dir` being its
STATUS file's folder; `/brain` and `install.sh` rewrite it as version 2. The registry is read only if it is a regular
file of at most 1,000,000 bytes, opened non-blocking (python3 needed). The STATUS file is accepted only if, with
every symlink resolved, it is a regular text file inside `dir`, which may not be `$HOME` or `/`. All three hooks exit
0 on every path and never use the network.

## SessionStart: brain-hook.sh

- Runs on every source: `startup`, `resume`, `clear`, `compact` and `fork`. The installer adds one entry with no
  matcher, so sources Claude Code adds later are covered too.
- With a brain: the STATUS file is printed as plain stdout, which Claude Code adds to context for `SessionStart`,
  followed by one line: `(Project brain loaded from <path> (brain "<name>", chosen with /brain). For this work's
  current state it overrides older notes in memory; rules in CLAUDE.md still apply. Working rules: ...)` (or
  `chosen with CD_BRAIN`). It then records, for this window, which STATUS it showed and its mtime and size
  (`<config>/brain-sessions/seen-<window key>`), for the UserPromptSubmit hook.
- No brain (except on `compact`): one line, `No brain attached. Brains: a, b. Type /brain <name> to attach one.`
  When a window whose session ran in this same folder last attached a brain that still exists:
  `No brain attached. Last used here: a (type /brain a). All brains: a, b.` (a hint: it never attaches it; `/brain`
  keeps one line per folder in `<config>/brain-sessions/last-used`). With no brains registered:
  `No brains yet. /brain new <name> creates one.`
- A chosen brain that cannot be loaded prints one line, `(Project brain not loaded: brain "<name>" (chosen with
  /brain) <reason>.)`, and no file content: the name is not registered (renamed or removed?), its folder is gone,
  or its STATUS is refused (missing, outside its folder, not text).
- **Size limit: 9,000 characters**, counted as Claude Code counts them (an emoji counts 2; check with `wc -m`). A
  longer file is cut at a character boundary after 9,000 characters, followed by
  `[STATUS.md is N characters, over the 9,000 limit, so only the first 9,000 are shown here. Trim it so nothing is cut.]`.
  The reason: Claude Code replaces hook output over 10,000 characters with a file path and a 2,000-character
  preview, and does not ask Claude to read the file.
- `CD_HOOKS=off`, or input that is not a JSON object: prints nothing. Takes about 30 to 80 ms; installed with a
  10-second timeout, as is `compact-log.sh`.

**Why a global hook:** a brain follows the session, wherever it runs, so the hook must run in every session. A
zero-install alternative is `@STATUS.md` imported from a project's CLAUDE.md, which Claude Code re-reads from disk
after a compaction; the import loads as instructions rather than context, counts toward CLAUDE.md size warnings, and
gets no trim notice.

**Known risk.** Write STATUS as factual statements: Claude Code's docs warn that hook text framed as system
instructions can trigger its prompt-injection defenses. A brain folder inside a repo you share is read by everyone
who registers it.

## PostCompact: compact-log.sh

- Input: `compact_summary` (the summary Claude Code wrote), `session_id`, `trigger` (`manual` or `auto`).
- With a brain, writes `<config>/brain-logs/<name>/<YYYY-MM-DD-HHMMSS>-<first 8 of session id>.md`: a heading with
  date, trigger and session, then the summary verbatim. Never in the brain's folder (it may be a git repo, and a
  summary can quote anything the session saw) or the session's folder. The folders are created private (mode 700),
  files are owner-only (mode 600) and never overwritten; a log folder that is a symlink is refused.
- `/brain rename` moves the brain's log folder with it; `/brain remove` leaves it.
- Use it to check what a compaction kept; what it dropped is still in the session transcript.

## UserPromptSubmit: ctx-nudge.sh

- Measures the context of the last main-thread API call in `transcript_path`: `input_tokens` +
  `cache_creation_input_tokens` + `cache_read_input_tokens`, as `ctx-audit.py` does. Subagent, `<synthetic>` and
  zero-usage records and records a compaction carried over are skipped. Only the end of the transcript is read:
  what was written since the previous prompt, at least 256 KB and at most 16 MB.
- Notes at 40% of the window, then at 55, 70, 85 and 100%, once per step per session; the steps start again after a
  compaction. To see a compaction, the hook searches everything written to the transcript since the previous prompt
  (up to the last 16 MB) for its boundary record, so one early in a long turn is not missed; if more than 16 MB was
  written, a context lower than at the previous prompt counts as a compaction. The note is
  `hookSpecificOutput.additionalContext`, three lines, with the STATUS file's full path:
  ```text
  Context check (context-discipline): this session's context is at 45% of its 200,000-token window (90,000 tokens).
  Do not stop mid-task. At the next natural break, update /path/to/brain/STATUS.md, and write a handoff note if a new sub-task is about to start.
  Then suggest to the user /clear (a fresh session that starts from /path/to/brain/STATUS.md and the handoff) or /compact <focus>.
  ```
- **STATUS changed under the session** (several windows may share a brain): at each prompt the hook stats STATUS
  once and compares it with this window's record. If it changed, it adds one note,
  `STATUS.md of brain "<name>" (<path>) was updated since this session last read it (probably by another session);
  re-read it before relying on it or editing it.`, and records the new mtime, so it comes once per change. A change
  made by this session's own main-thread Edit, Write, MultiEdit, NotebookEdit or Bash call that names the STATUS path
  (also as `~/...`) since the previous prompt is recorded without a note; a read of STATUS never hides a change, and a
  subagent's edit is noted. No record yet (the hooks were installed mid-session): it
  records one, no note. Both notes may come in one `additionalContext`.
- Window, first that applies: `CD_CTX_WINDOW` (tokens); `CLAUDE_CODE_AUTO_COMPACT_WINDOW`; `autoCompactWindow` from
  settings (managed, project `.claude/settings.local.json`, `.claude/settings.json`, then user settings;
  `modelSettings.<model>` beats the top-level key); the model's window from the transcript (1,000,000 for `[1m]` and
  native 1M models, else 200,000); 200,000. The auto-compact values are capped at the model's window. The
  `--autocompact` launch flag is invisible to a hook.
- State: one small file per session in `${TMPDIR:-/tmp}/context-discipline/` (the last step noted, how far the
  transcript had got, the last context and compaction seen), plus the window's record in `<config>/brain-sessions/`.
  Installed with a 5-second timeout; takes about 60 ms on a 60 MB transcript and about 12 ms without a brain.
  Needs python3 3.9+.
- UserPromptSubmit also fires for scheduled tasks, `/loop` and background-subagent reports, so a note can arrive on
  those turns too.

## Install (edits global settings: ask the user first)

Preferred: `./install.sh` from the repo (`--dry-run` shows every change; it also converts a version 1 registry).
By hand, copy the skill folder and the repo's `brain/` folder (the `/brain` command) to `~/.claude/skills/` and merge
into `~/.claude/settings.json` (with `CLAUDE_CONFIG_DIR` set, use that folder instead of `~/.claude` throughout):

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/skills/context-discipline/scripts/brain-hook.sh\"", "timeout": 10 } ] }
    ],
    "PostCompact": [
      { "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/skills/context-discipline/scripts/compact-log.sh\"", "timeout": 10 } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "bash \"$HOME/.claude/skills/context-discipline/scripts/ctx-nudge.sh\"", "timeout": 5 } ] }
    ]
  }
}
```

Then, in a session: `/brain new <name> [--at <folder>]` creates a brain and attaches it to the window (from Claude's
Bash tool: `bash "${CLAUDE_SKILL_DIR}/scripts/brain.sh" new <name>`, which attaches it to the window it runs in).
It runs `init-brain.sh <brain-folder> <name>`, which refuses `$HOME` and `/` and never overwrites a file or writes
through a symlink.

**Upgrading from folder pointers.** Earlier versions loaded the STATUS named by the nearest `.claude/brain` above the
session's folder. Nothing reads those pointers now: run `/brain add <name>` in a session started in that folder (it
registers the STATUS the pointer names, reading only the pointer's first 4,096 bytes), then delete the pointer.
Brains registered by name before keep working (the registry is converted).

If a project already has its own SessionStart hook that prints its STATUS (for example `cat STATUS.md` in its
`.claude/settings.json`), remove it, or the file is injected twice. Claude Code picks up settings edits within a few
seconds: check `/hooks`, and restart only if a hook is not listed.

## Test

```bash
H="${CLAUDE_SKILL_DIR}/scripts"; N=<a registered brain name>
echo '{"source": "startup"}' | CD_BRAIN=$N bash "$H/brain-hook.sh"   # its STATUS, then "(Project brain loaded ...)"
echo '{"source": "startup"}' | bash "$H/brain-hook.sh"; echo "exit=$?"  # the one-line no-brain hint, exit=0
echo '{"session_id": "test0001", "trigger": "manual", "compact_summary": "hi"}' \
  | CD_BRAIN=$N bash "$H/compact-log.sh"; ls "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/brain-logs/$N/"   # one new file
T=$(mktemp); echo '{"type":"assistant","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":90000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}' > "$T"
echo '{"session_id": "nudge-'$RANDOM'", "transcript_path": "'"$T"'"}' \
  | CD_BRAIN=$N CD_CTX_WINDOW=200000 bash "$H/ctx-nudge.sh"                 # the note, at 45%
bash "$H/brain.sh"                                                           # the registry, as /brain lists it
```

## Troubleshoot

| Symptom | Check |
|---|---|
| Nothing injected | `grep -n context-discipline/scripts "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"`; does the pipe test print? Is `CD_HOOKS=off` set? |
| `No brain attached ...` | The window has no brain: `/brain <name>` attaches one (`/brain` lists them), `/brain new <name>` creates one. A `.claude/brain` pointer is not read any more: `/brain add <name>` from its folder. |
| `(Project brain not loaded: brain "x" ...)` | The chosen name is not registered (renamed or removed?) or its entry is refused; the line says how to fix it. `/brain` lists the registry; `/brain add x <folder>` points a moved brain's entry at its new folder. |
| Wrong STATUS injected | `/brain` shows which brain this window uses and why: a `/brain` choice beats `CD_BRAIN`. |
| Trim notice in context | STATUS is over 9,000 characters: move history to the overview's decision log. |
| STATUS appears twice | An older per-project hook also prints it; remove one. |
| No context-check note | No brain, the step was already noted this session, no python3, or the window is larger than you think (`CD_CTX_WINDOW` overrides it). |
| No file in `brain-logs/<name>/` | No brain, or neither jq nor python3 is installed. |

## Built-in features to use alongside

- `/context` shows the live context by category; `/usage` flags heavy patterns on subscription plans.
- `/compact <focus>` and a `# Compact instructions` section in the project-root CLAUDE.md steer what a summary keeps;
  `/rewind` can summarize part of a conversation.
- `/autocompact <tokens>`, `autoCompactWindow` (or `modelSettings`) and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` set when
  auto-compaction fires. Claude Code clears older tool outputs before it summarizes.
- `PreCompact` hooks can block auto-compaction; `PostCompact` gets the summary (used above).
- `bashOutputMaxChars` caps inline Bash output for every command.
- `/clear` starts fresh at no cost; `/btw` asks a side question without adding to the conversation.

## Disable

For one run (headless `claude -p`, SDK agents, evals, a benchmark's baseline): set `CD_HOOKS=off` in its
environment and all three hooks do nothing. For one window: `/brain none`. Everywhere: `./install.sh --uninstall`
from the repo, or remove the three entries above from `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` (an older
install may have four `SessionStart` entries with matchers; `--uninstall` removes both forms).
