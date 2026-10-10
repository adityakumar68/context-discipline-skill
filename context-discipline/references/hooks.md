# The brain hook

How the project brain reaches context automatically, how to install it, and how to test and troubleshoot it.

## How it works

1. Claude Code fires a `SessionStart` hook when a session starts (`startup`), is resumed (`resume`), after `/clear`
   (`clear`) and after a compaction (`compact`).
2. A global hook in `~/.claude/settings.json` runs `scripts/brain-hook.sh` for each of those four matchers.
3. The hook reads its stdin JSON, which carries `cwd`, `source`, `session_id`, `transcript_path` (and
   `hook_event_name`). It takes `cwd` (falls back to `$CLAUDE_PROJECT_DIR`, then `$PWD`).
4. It walks up from `cwd` to the nearest `<dir>/.claude/brain` pointer, stopping before `$HOME` and `/`, so the
   global `~/.claude` folder is never mistaken for a project.
5. The pointer's first non-empty line not starting with `#` is the STATUS path, relative to `<dir>` (an absolute
   path or `~/...` also works). The hook prints that file, then one line naming it.
6. For `SessionStart`, plain stdout is added to the model's context. Output over 10,000 chars is replaced by a
   2,000-char preview, so the hook prints only the first 9,000 bytes of a STATUS file over 9,500 bytes, followed by
   `[STATUS.md is N bytes; trim it under 10,000 so it is not cut]`.
7. No pointer, unreadable file, bad JSON, or any other problem: it prints nothing and exits 0. It never writes
   files or uses the network, and runs in about 20 ms.

Why a global hook with a pointer: a project-level `.claude/settings.json` only applies when Claude Code is launched
from that project directory. Sessions launched from a parent folder or a sibling repo would miss it. The global
hook plus a walk-up pointer works from any subdirectory and needs no per-project settings.

## Install (needs the user's approval: it edits global settings)

Add one entry per matcher under `hooks.SessionStart` in `~/.claude/settings.json`, merging with any existing hooks:

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "startup", "hooks": [ { "type": "command", "command": "bash ~/.claude/skills/context-discipline/scripts/brain-hook.sh" } ] },
      { "matcher": "resume",  "hooks": [ { "type": "command", "command": "bash ~/.claude/skills/context-discipline/scripts/brain-hook.sh" } ] },
      { "matcher": "clear",   "hooks": [ { "type": "command", "command": "bash ~/.claude/skills/context-discipline/scripts/brain-hook.sh" } ] },
      { "matcher": "compact", "hooks": [ { "type": "command", "command": "bash ~/.claude/skills/context-discipline/scripts/brain-hook.sh" } ] }
    ]
  }
}
```

Then, per project: `bash ~/.claude/skills/context-discipline/scripts/init-brain.sh <project-root> [status-relpath]`
(creates the pointer, STATUS and overview if missing), fill the files, commit them.

If a project already has its own SessionStart hook that prints its STATUS file (for example a `cat STATUS.md` in
the project's `.claude/settings.json`), remove that once the global hook is in place, or the file is injected twice.

Claude Code reads hook settings at startup; after editing them, open `/hooks` to review the change or start a new
session.

## Test

```bash
H=~/.claude/skills/context-discipline/scripts/brain-hook.sh
echo '{"cwd": "/path/to/project/some/subdir", "source": "startup"}' | bash "$H"   # prints STATUS + final line
echo '{"cwd": "/tmp", "source": "startup"}' | bash "$H"; echo "exit=$?"           # prints nothing, exit=0
echo 'not json' | bash "$H"; echo "exit=$?"                                         # exit=0
```

Check the size the hook will inject: `wc -c <STATUS file>` (keep it under 10,000).

## Troubleshoot

| Symptom | Check |
|---|---|
| Nothing injected | Is the hook in `~/.claude/settings.json` (`grep -n brain-hook ~/.claude/settings.json`)? Does the pipe test above print? Is the pointer at `<project>/.claude/brain` and does its first non-comment line name an existing file? Is the project under `$HOME` itself rather than in a subfolder? (The walk stops before `$HOME`.) |
| Wrong STATUS injected | The nearest pointer wins: a nested project's `.claude/brain` shadows its parent's. |
| Trim warning in context | STATUS is over 9,500 bytes: move history to the overview's decision log, shorten "Running now". |
| STATUS appears twice | An older per-project hook also prints it; remove one. |
| Hook seems ignored after editing settings | Hooks load at startup; review in `/hooks` or start a new session. |

## Disable

For one project: delete `<project>/.claude/brain`. Everywhere: remove the four entries from `~/.claude/settings.json`.
