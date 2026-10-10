# The hooks

What the three global hooks do, how to install, test and troubleshoot them, and the built-in alternatives.
`${CLAUDE_SKILL_DIR}` below is this skill's folder (the base directory shown when the skill loads; after
`install.sh`, `~/.claude/skills/context-discipline`).

| Event | Script | Does |
|---|---|---|
| `SessionStart` | `brain-hook.sh` | prints the project's STATUS file into context |
| `PostCompact` | `compact-log.sh` | saves the compaction summary in the project |
| `UserPromptSubmit` | `ctx-nudge.sh` | adds a context-check note as the context window fills |

All three share `brain-lib.sh`: they walk up from the session's `cwd` (else `$CLAUDE_PROJECT_DIR`, then `$PWD`) to
the nearest `<dir>/.claude/brain` pointer, stopping before `$HOME` and `/`, so `~/.claude` is never taken for a
project. A project with an accepted pointer is a *brain project*; the last two hooks do nothing anywhere else. All
three exit 0 on every path and never use the network.

## SessionStart: brain-hook.sh

- Runs on every source: `startup`, `resume`, `clear`, `compact` and `fork`. The installer adds one entry with no
  matcher, so sources Claude Code adds later are covered too.
- The pointer's first non-empty line not starting with `#` is the STATUS path, relative to `<dir>`. Only the
  pointer's first 4,096 bytes are read, and the path line may be at most 1,024 bytes. Absolute paths, `~/...`, `..`
  escapes and symlinks that leave `<dir>` are refused, and so are folders, missing files and binary files. A refused pointer prints one line, `(Project brain not loaded: <pointer> <reason>.)`, and no file content.
- An accepted file is printed as plain stdout, which Claude Code adds to context for `SessionStart`, followed by
  `(Project brain loaded from <path>. Working rules: context-discipline skill.)`.
- **Size limit: 9,000 characters**, counted as Claude Code counts them (an emoji counts 2; check with `wc -m`). A
  longer file is cut at a character boundary after 9,000 characters, followed by
  `[STATUS.md is N characters, over the 9,000 limit, so only the first 9,000 are shown here. Trim it so nothing is cut.]`.
  The reason: Claude Code replaces hook output over 10,000 characters with a file path and a 2,000-character
  preview, and does not ask Claude to read the file.
- No pointer, or input that is not a JSON object: prints nothing. Takes about 30 ms (about 60 ms when it cuts);
  installed with a 10-second timeout, as is `compact-log.sh`.

**Why a global hook:** Claude Code reads a project's `.claude/settings.json` only from the session's primary working
directory, so a project-level hook misses sessions started in a subfolder. The walk-up covers any subfolder of the
project (not a parent or sibling folder). A zero-install alternative is `@STATUS.md` imported from the project-root
CLAUDE.md, which Claude Code re-reads from disk after a compaction; the import loads as instructions rather than
context, counts toward CLAUDE.md size warnings, and gets no trim notice.

**Known risks.** A cloned repo that ships its own `.claude/brain` gets its STATUS injected, at the same trust level
as its CLAUDE.md. A pointer in a parent folder (for example `~/Downloads/.claude/brain`) can inject any text file
inside that folder. Write STATUS as factual statements: Claude Code's docs warn that hook text framed as system
instructions can trigger its prompt-injection defenses.

## PostCompact: compact-log.sh

- Input: `compact_summary` (the summary Claude Code wrote), `session_id`, `trigger` (`manual` or `auto`).
- Writes `<root>/.claude/compactions/<YYYY-MM-DD-HHMMSS>-<first 8 of session id>.md`: a heading with date, trigger
  and session, then the summary verbatim. Files are owner-only (mode 600) and never overwritten; a
  `.claude/compactions` that is a symlink out of the project is refused.
- `init-brain.sh` adds `.claude/compactions/` to the project's `.gitignore`, because a summary can quote anything the
  session saw.
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
  `hookSpecificOutput.additionalContext`, three lines, with the STATUS file's full path (the session's cwd may be a
  subfolder):
  ```text
  Context check (context-discipline): this session's context is at 45% of its 200,000-token window (90,000 tokens).
  Do not stop mid-task. At the next natural break, update /path/to/project/STATUS.md, and write a handoff note if a new sub-task is about to start.
  Then suggest to the user /clear (a fresh session that starts from /path/to/project/STATUS.md and the handoff) or /compact <focus>.
  ```
- Window, first that applies: `CD_CTX_WINDOW` (tokens); `CLAUDE_CODE_AUTO_COMPACT_WINDOW`; `autoCompactWindow` from
  settings (managed, project `.claude/settings.local.json`, `.claude/settings.json`, then user settings;
  `modelSettings.<model>` beats the top-level key); the model's window from the transcript (1,000,000 for `[1m]` and
  native 1M models, else 200,000); 200,000. The auto-compact values are capped at the model's window. The
  `--autocompact` launch flag is invisible to a hook.
- State: one small file per session in `${TMPDIR:-/tmp}/context-discipline/` (the last step noted, how far the
  transcript had got, the last context and compaction seen). Installed with a 5-second timeout;
  takes about 60 ms on a 60 MB transcript and about 12 ms outside brain projects. Needs python3 3.9+.
- UserPromptSubmit also fires for scheduled tasks, `/loop` and background-subagent reports, so a note can arrive on
  those turns too.

## Install (edits global settings: ask the user first)

Preferred: `./install.sh` from the repo (`--dry-run` shows every change). By hand, copy the skill folder to
`~/.claude/skills/` and merge into `~/.claude/settings.json` (with `CLAUDE_CONFIG_DIR` set, use that folder instead
of `~/.claude` throughout):

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

Then, per project: `bash "${CLAUDE_SKILL_DIR}/scripts/init-brain.sh" <project-root> [status-relpath]`. It refuses
`$HOME` and `/` as the root, refuses STATUS paths the hook would refuse, and exits 1 if anything was not created.
It never overwrites a file or writes through a symlink, and it reads an existing pointer only as the hooks do, so a
cloned repo's planted files cannot hang it or send its writes outside the project.

If a project already has its own SessionStart hook that prints its STATUS (for example `cat STATUS.md` in its
`.claude/settings.json`), remove it, or the file is injected twice. Claude Code picks up settings edits within a few
seconds: check `/hooks`, and restart only if a hook is not listed.

## Test

```bash
H="${CLAUDE_SKILL_DIR}/scripts"; P=/path/to/project
echo '{"cwd": "'"$P"'/src", "source": "startup"}' | bash "$H/brain-hook.sh"   # STATUS, then "(Project brain loaded ...)"
echo '{"cwd": "/tmp"}' | bash "$H/brain-hook.sh"; echo "exit=$?"              # nothing, exit=0
echo '{"cwd": "'"$P"'", "session_id": "test0001", "trigger": "manual", "compact_summary": "hi"}' \
  | bash "$H/compact-log.sh"; ls "$P/.claude/compactions/"                     # one new file
T=$(mktemp); echo '{"type":"assistant","message":{"id":"m1","model":"claude-x","usage":{"input_tokens":90000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}' > "$T"
echo '{"cwd": "'"$P"'", "session_id": "nudge-'$RANDOM'", "transcript_path": "'"$T"'"}' \
  | CD_CTX_WINDOW=200000 bash "$H/ctx-nudge.sh"                                # the note, at 45%
```

## Troubleshoot

| Symptom | Check |
|---|---|
| Nothing injected | `grep -n context-discipline/scripts "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"`; does the pipe test print? Is the pointer at `<project>/.claude/brain`, naming an existing file by a relative path? Is the project folder something other than `$HOME` itself (or `/`)? Is `CD_HOOKS=off` set? |
| `(Project brain not loaded: ...)` | The pointer was refused; the line gives the reason. Use a relative path to a text file inside the project. |
| Wrong STATUS injected | The nearest pointer wins: a nested project's `.claude/brain` shadows its parent's. |
| Trim notice in context | STATUS is over 9,000 characters: move history to the overview's decision log. |
| STATUS appears twice | An older per-project hook also prints it; remove one. |
| No context-check note | Not a brain project, the step was already noted this session, no python3, or the window is larger than you think (`CD_CTX_WINDOW` overrides it). |
| No file in `.claude/compactions/` | Not a brain project, or neither jq nor python3 is installed. |

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
environment and all three hooks do nothing. For one project: delete `<project>/.claude/brain`. Everywhere:
`./install.sh --uninstall` from the repo, or remove the three entries above from `~/.claude/settings.json` (an older
install may have four `SessionStart` entries with matchers; `--uninstall` removes both forms).
