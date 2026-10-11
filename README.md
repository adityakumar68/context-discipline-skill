# context-discipline

A [Claude Code](https://code.claude.com/docs) skill for long work: projects that run over many sessions, research
surveys, design → spec → plan, and anything that dispatches subagents. It keeps the main agent's context small, and
it keeps the project's state on disk, where a compaction or a new session cannot lose it.

## The problem

Every API call resends the whole context. When the window fills, Claude Code compacts the conversation into a
summary, and detail is lost: the decision made an hour ago, the file that holds the plan, what was running.

The session in which this skill was written, measured afterwards with the repo's `ctx-audit.py` (from the API usage
Claude Code saves with every call):

- **Main thread:** 1,514 API calls and 6 compactions (4 manual, 2 automatic). Between compactions the context
  peaked at 232k to 967k tokens, in a 1M-token window.
- **Input processed:** 706M tokens in the main thread (98% of them cache reads) and 597M more in 149 subagents.
- **What filled it:** at the six peaks the context added up to 4.22M tokens. 54% of that is not in the transcript
  at all (system prompt, tool schemas, thinking sent back without its text, estimation error). The visible rest:

| Visible content | Tokens at the peaks | Share of the measured context |
|---|---|---|
| Bash output | 302,708 | 7.2% |
| Subagent hand-backs | 292,133 | 6.9% |
| Write input (specs and plans the main agent wrote itself) | 208,812 | 5.0% |
| Bash input (mostly heredocs) | 202,620 | 4.8% |
| Read output (whole files, images) | 183,657 | 4.3% |
| Agent prompts | 117,519 | 2.8% |
| Skill texts re-attached after compaction | 109,760 | 2.6% |

Most of the visible part was work a subagent could have done, or reading and printing more than needed. This is one
session, by the author, and the skill was written partway through it: it motivates the skill and proves nothing
about it. (An earlier version of this README quoted "1.39M tokens, 5 compactions" and larger shares, such as Bash
output at 19%. Those came from a characters/4 estimate of the visible content, taken before the session ended, not
from a measurement.)

## What you get

- **The skill** (`context-discipline/SKILL.md`): where each kind of information lives, the delegation contract,
  design → spec → plan with subagents, cheap reviews, and how to handle compaction.
- **Brains** for sessions: a brain is a name plus a folder holding `STATUS.md` (current state),
  `00-Project-Overview.md` (big picture and dated decision log), `decisions/` and `handoffs/`. It belongs to a
  Claude Code session, not to a folder: you attach one to a window with `/brain` (a small user-invoked skill running
  `scripts/brain.sh`), and several windows may share one. See [Brains](#brains).
- **Three hooks**, active only when the session has a brain:
  - `SessionStart` (`brain-hook.sh`) prints the brain's STATUS file on startup, resume, `/clear`, compaction and
    fork, so the current state is back in context automatically. A session with no brain gets a one-line hint
    instead.
  - `PostCompact` (`compact-log.sh`) saves each compaction summary to `~/.claude/brain-logs/<name>/`, so you can
    check what a compaction kept.
  - `UserPromptSubmit` (`ctx-nudge.sh`) adds a short note for Claude when the context reaches 40% of its window, and
    every 15% after: at the next natural break, update STATUS and suggest `/clear` or `/compact <focus>`. It also
    says once when another session changed STATUS.
- **Agent brief templates** (`references/agent-briefs.md`): research, context gathering, spec and plan drafting,
  implementation, review and fact-checking, each with a short hand-back contract.
- **ctx-audit** (`scripts/ctx-audit.py`): measures a past session's context from API usage (peaks, compactions,
  subagents) and estimates which visible content filled it.

## How it works

```text
Claude Code session: startup / resume / /clear / compaction / fork
        |
        v
SessionStart hook (global, in ~/.claude/settings.json) runs brain-hook.sh
        |
        v
which brain did this window attach?  /brain paper (kept per Claude Code process), else CD_BRAIN=paper
        |                                                  |
        v                                                  v
brains.json: paper -> ~/.claude/brains/paper/          none: one line, "No brain attached. Brains: paper,
prints its STATUS.md and "(Project brain loaded ...)"        thesis. Type /brain <name> to attach one."
```

The folder the session runs in plays no part: two windows in one repo can work on different brains, and one brain
can follow you across repos. The other two hooks use the same brain. A registered STATUS must be a text file inside
the brain's folder; anything else is refused with a one-line warning.

The delegation contract, which the skill applies to every subagent:

1. The subagent writes its full output (survey, review, spec draft) to a file with a dated name.
2. It hands back at most about 15 lines: status, verdict, key issues as one-liners, the file path.
3. Inputs go in as file paths, not pasted text.
4. One task per dispatch, with an agent type that can write files.
5. The main agent keeps decisions and pointers, not documents, and records each decision on disk at once.

## Requirements

- Claude Code
- bash and python3 (3.9 or later for the context note; `jq` is used if present, but not needed)
- macOS or Linux. Windows is untested.

## Quick install

```bash
git clone https://github.com/adityakumar68/context-discipline-skill.git
cd context-discipline-skill
./install.sh
```

Claude Code picks up the new hooks within a few seconds. Open `/hooks` to check that the SessionStart, PostCompact
and UserPromptSubmit hooks are listed, and restart Claude Code only if they are not.

## What the installer changes

It works in `$CLAUDE_CONFIG_DIR` if set, else `~/.claude`, and changes four things:

1. **The skill.** Copies `context-discipline/` to `~/.claude/skills/context-discipline/`. A different copy already
   there is first moved to `~/.claude/skill-backups/context-discipline.bak-<timestamp>` (outside `skills/`, so
   Claude Code does not load it as a second skill).
2. **The `/brain` skill.** Copies `brain/` to `~/.claude/skills/brain/` with the same backup rule. A different skill
   already called `brain` (one that does not run this repo's `brain.sh`) is left alone, and the summary says
   `/brain` was not installed.
3. **The hooks.** Adds three hooks to `~/.claude/settings.json`, each in one entry with no matcher:
   `SessionStart` runs `brain-hook.sh` and `PostCompact` runs `compact-log.sh`, each with a 10-second timeout, and
   `UserPromptSubmit` runs `ctx-nudge.sh` with a 5-second timeout. Each command reads
   `bash "$HOME/.claude/skills/context-discipline/scripts/<script>"`, so a settings file synced between machines
   works on each (a config folder outside `$HOME` gets absolute paths). Older entries for the same scripts are
   replaced, including the four `SessionStart` entries with matchers that earlier versions installed, and an entry
   whose script path no longer exists is repaired. Every other key and hook is kept. The file is edited with
   python's `json` module (rewritten with 2-space indentation; a final newline, or its absence, is kept), written
   atomically, and first backed up to `settings.json.bak-<timestamp>`. If it is not valid JSON, the installer stops
   and changes nothing. It warns if `"disableAllHooks": true` is set.
4. **One line in `~/.claude/CLAUDE.md`** (backed up first; skipped if a line already mentions
   `context-discipline`, or with `--skip-claude-md`; the line an earlier version appended is replaced). The line is
   shown under Manual install.

It also converts a `brains.json` registry of version 1 (an earlier version's) to version 2, after a backup.

Run `./install.sh --dry-run` to see every planned change without making any. Running the installer again is safe:
steps already done are skipped.

## Manual install

1. Copy both skills: `mkdir -p ~/.claude/skills && cp -R context-discipline brain ~/.claude/skills/`
2. Merge this into `~/.claude/settings.json`, next to any hooks you already have:

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

3. Add this line to `~/.claude/CLAUDE.md`:

   ```text
   - For any work that spans many steps or sessions (projects, research surveys, designs, specs, plans, subagent dispatches, reviews), follow the `context-discipline` skill: the main agent coordinates; subagents put deliverables in files and hand back about 15 lines; keep the session's brain (STATUS.md, attached with `/brain` and loaded at every session start) current at every decision.
   ```

4. Open `/hooks` to check the three hooks are listed.

## Start a brain

In a Claude Code session whose work will outlive it:

```text
/brain new thesis                     a brain in ~/.claude/brains/thesis/, attached to this window
/brain new app --at ~/code/app/brain  or in a folder of your choice, say inside the repo (to commit it)
```

This writes `STATUS.md` and `00-Project-Overview.md` from the templates (never overwriting a file), registers the
brain and attaches it to the window; nothing is written in the folder the session runs in. Fill both files in (or let
Claude do it) and keep STATUS under 9,000 characters (`wc -m STATUS.md`). Or just ask Claude: "start a brain for
this project". Claude can run the same command (`bash ~/.claude/skills/context-discipline/scripts/brain.sh new
<name>`); attaching an existing brain is yours to do with `/brain <name>`.

## Verify

```bash
echo '{"source": "startup"}' | CD_BRAIN=thesis bash "$HOME/.claude/skills/context-discipline/scripts/brain-hook.sh"
```

It should print your STATUS file and end with `(Project brain loaded from ...)`. Without `CD_BRAIN` it prints the
one-line no-brain hint. In a new Claude Code session, `/brain thesis`, then ask "what does STATUS say?". Tests for
the other two hooks are in `context-discipline/references/hooks.md`.

## Brains

A brain belongs to a Claude Code session, not to a folder. Its folder is only where its files live.

```text
/brain                          list the brains: folder, STATUS size and date, how many windows use each;
                                * marks the one this window uses
/brain paper                    attach brain "paper" to this window from now on (prints its STATUS)
/brain none                     detach: this window uses no brain
/brain new thesis [--at <dir>]  create a brain (default folder ~/.claude/brains/thesis) and attach it
/brain add paper <dir|file>     register an existing brain: <dir>/STATUS.md, or that STATUS file
/brain add paper                register the brain an old .claude/brain pointer in the current folder names
/brain rename paper paper1      rename it (registry, the windows' choices and its compaction logs)
/brain remove paper1            unregister it; its files stay
```

Arguments are split like shell words, but nothing in them is expanded or run: quote a path with spaces
(`/brain add p '~/My Proj'` or `~/My\ Proj`); a leading `~` is your home folder.

Which brain a session uses, first match wins:

1. **The choice made with `/brain` in this window.** It holds until you change it, across `/clear` and compactions:
   it is keyed to the Claude Code process (`$CLAUDE_PID`), not to the session id, which `/clear` replaces. A new
   window, or `claude --resume` in a new process, starts without one. Subagents of the window share it.
2. **`CD_BRAIN=<name>` (or `none`) at launch**, for example `CD_BRAIN=paper claude`.
3. **None.** The session starts with one line: `No brain attached. Brains: paper, thesis. Type /brain <name> to
   attach one.` If a window started in the same folder attached a brain with `/brain` before, the line suggests it
   (`Last used here: paper (type /brain paper)`); if the folder still has an old `.claude/brain` pointer, it says
   `/brain add <name>` registers it. It never attaches one by itself, and it says nothing when you chose no brain
   (`/brain none`, `CD_BRAIN=none`).

All three hooks follow the same choice: the STATUS that is loaded, where compaction summaries go, and whether the
notes fire. `CD_HOOKS=off` still turns them all off.

**Several windows on one brain.** Any number of windows may attach the same brain. `/brain` shows how many live
windows use each, and attaching a brain that another window uses says so ("Also attached in 1 other window; STATUS
may change under you"). When another session changes STATUS, the next prompt in this window carries one note to
re-read it; Claude re-reads STATUS right before editing it and changes only the sections it owns. Handoff and
decisions files carry the time in their names (`2026-10-12-1430-<topic>.md`), so two sessions never write the same
file.

Names are 1 to 32 of `a-z`, `0-9` and `-`. The registry is `~/.claude/brains.json` (in `$CLAUDE_CONFIG_DIR` if set):

```json
{"version": 2, "brains": {"paper": {"dir": "/home/me/.claude/brains/paper", "status": "STATUS.md"}}}
```

`status` is relative to `dir`. The STATUS must be a text file inside `dir` (after resolving symlinks), and `dir`
may not be your home folder or `/`; the same 9,000-character limit applies. If a chosen brain cannot be loaded
(removed, folder gone), the session starts with one warning line that says how to fix it, instead of a STATUS;
`/brain add <name> <dir>` points a moved brain's entry at its new folder. A window's choice is a two-line file in
`~/.claude/brain-sessions/`: the name, and when its Claude Code process started, so a later process that gets the
same PID does not inherit it. Choices older than 7 days are pruned when a new one is written, unless their window
still runs. The same folder keeps, per window, which STATUS it was last shown (`seen-*`) and, per folder, which
brain was last attached there (`last-used`).

**Upgrading from folder pointers.** Earlier versions loaded the brain named by a `.claude/brain` pointer above the
session's folder. Nothing reads those pointers now. Start Claude Code in such a folder and run `/brain add <name>`:
it registers the STATUS the pointer names (reading only the pointer's first 4,096 bytes) and tells you the pointer
can be deleted. Brains you had registered by name keep working: the installer converts the registry. Compaction
summaries now go to `~/.claude/brain-logs/<name>/`; old `.claude/compactions/` folders are left as they are.

`/brain` is a user-invoked skill (Claude does not load it on its own). Its script runs before Claude sees anything,
through Claude Code's `!` command injection, pre-approved in the skill's `allowed-tools`; your arguments reach it as
one quoted value, and Claude only relays the result. With `disableSkillShellExecution` set, `/brain` cannot run: use
`CD_BRAIN`, or run `bash ~/.claude/skills/context-discipline/scripts/brain.sh help` in a terminal (attaching a brain
to a window still has to happen inside Claude Code).

**With Claude Code's Bash sandbox on**, the script runs inside the sandbox (seen with 2.1.296; an `excludedCommands`
entry for it did not take it out). Its `ps` call is blocked there, so a choice is saved without its start time and
the PID-reuse guard is off; the choice still works. The sandbox lets commands write only to the working folder, temp
and folders you allow, and protects most of `~/.claude`; writing `brains.json`, `brains/` and `brain-sessions/` there
was not tested. If `/brain` says `cannot write` or `cannot create`, add `"sandbox": {"filesystem": {"allowWrite":
["~/.claude"]}}` to your settings (the sandbox keeps its protected files there protected; use your
`$CLAUDE_CONFIG_DIR` if set), or pick brains with `CD_BRAIN=<name>` at launch.

## Day-to-day use

You mostly work as before; Claude changes how it works:

| You say | What Claude does differently |
|---|---|
| "Let's start a project to build X." | Starts a brain for the session (or asks you to attach one) and tells you, in two or three lines, what lives where. |
| "Survey what's been published on X." | Sends one research subagent that writes the survey to a file and replies in about 15 lines; reads only that reply and the sections it needs. |
| "Write the spec from our decisions." | Has a subagent draft it from the decisions file, spot-checks it with `grep`, and gives you the path to review. |
| "Review this branch." | A reviewer writes the full review to a file; Claude reads only the lines it flags and sends fixes back by path. |
| Design questions | Asks one question per message, with a recommendation, and records each answer in a decisions file named with date and time. |
| (context passes 40%, 55%, ...) | Finishes the current step, updates STATUS at the next natural break, and suggests `/clear` or `/compact <focus>`. |
| (after a compaction, or the next morning) | STATUS is already back in context; Claude continues from its next steps instead of asking you to recap. |

## Compaction: what survives

STATUS and every other file on disk survive a compaction. The conversation's working state does not: the current
hypothesis, half-finished edits, what was just tried, detailed instructions from early on. Hook text is summarized
with the rest, and invoked skills come back cut to their first 5,000 tokens (25,000 in all, oldest dropped first).
See Claude Code's [What survives compaction](https://code.claude.com/docs/en/context-window#what-survives-compaction).
The skill makes compaction safer, not safe. What helps:

- Keep STATUS and the decisions file current, and write a handoff note before a new sub-task.
- Add a `# Compact instructions` section to the project-root CLAUDE.md naming what the summary must keep (template
  in `references/brain-templates.md`), and use `/compact <focus>` for a single compaction.
- At a task boundary, `/clear` and start from STATUS and the handoff note. Claude Code's docs recommend clearing
  between tasks, and `/clear` costs nothing.
- `/autocompact <tokens>` or the `autoCompactWindow` setting moves the point where auto-compaction fires.
- Read `~/.claude/brain-logs/<name>/` to see what a compaction kept; the full history stays in the session
  transcript.

## Checking context use

`/context` shows the live breakdown. For a past session:

```bash
python3 "$HOME/.claude/skills/context-discipline/scripts/ctx-audit.py" ~/.claude/projects/<project-folder>/ [--top N] [--include-sidechains] [--json]
```

Transcripts live in `~/.claude/projects/<folder>/<session-id>.jsonl`, where the folder is the working directory with
every character other than letters and digits replaced by `-`. Given the folder, it audits the newest transcript
(while a session is running, that is usually the running one; pass a file to audit another) and reads that
session's subagent transcripts automatically. `--include-sidechains` adds the subagents' content to the
category table; `--json` prints a versioned JSON object for scripts. The text output looks like this:

```text
Transcript: <session-id>.jsonl  (<size> MB, <records> records, <n> subagent files)

Measured from API usage (context of a call = input + cache write + cache read tokens)
Thread         calls  peak context  total input  output  compactions
Main             ...           ...          ...     ...          ...
Subagents (n)    ...           ...          ...     ...          ...
Combined         ...           ...          ...     ...          ...
Main-thread compactions (context before -> after; as recorded by Claude Code):
   1. ... -> ...  (recorded ... -> ..., manual)

Visible content by category (main thread; chars/4 estimate),
counted at each segment's peak call. Shares are of the measured context, ... tokens (sum of segment peaks).
Category                ~tokens   share   items
-------------------  ----------  ------  ------
[not in transcript]         ...     ...       -
Bash output                 ...     ...     ...
Agent hand-back             ...     ...     ...
...

Top 10 single largest items:
  1. <category>  ~<tokens>  <short preview>
```

`[not in transcript]` is the measured context minus the visible estimate: system prompt, tool schemas, thinking sent
back without its text, and estimation error. No habit changes it much, so act on the top two or three visible
categories; the skill maps each to a fix. Previews that look like credentials are redacted.

## Built-in Claude Code features that help

- `/context` for the live breakdown; `/usage` flags heavy patterns on Pro, Max, Team and Enterprise plans.
- `/compact <focus>`, the `# Compact instructions` section, `/clear`, and `/rewind` to summarize part of a
  conversation.
- `/autocompact`, `autoCompactWindow` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` for when auto-compaction fires.
- `bashOutputMaxChars` caps inline Bash output for every command.
- `CLAUDE_CODE_SUBAGENT_MODEL` runs every subagent on one model; `SendMessage` resumes a subagent with its history.
- `@STATUS.md` imported from the project-root CLAUDE.md is a zero-install alternative to the SessionStart hook; the
  trade-offs are in `references/hooks.md`.

## Updating

`git pull && ./install.sh` in your clone. The installed copy is refreshed (the old one goes to `skill-backups/`),
missing hooks are added (an install from before the compaction hooks gets the two new ones, and its four
`SessionStart` entries become one), the CLAUDE.md line of an earlier version is replaced, and a version 1 registry is
converted. Folder pointers need one `/brain add <name>` each (see Brains).

## Uninstalling

`./install.sh --uninstall` (add `--dry-run` first to see what it will do) removes the skill folder; every hook whose
command contains `context-discipline/scripts/` followed by `brain-hook.sh`, `compact-log.sh` or `ctx-nudge.sh` (and
any entry or list left empty); and the CLAUDE.md line, backing up both files first. A locally edited skill copy is
moved to `skill-backups/` instead of deleted; the `/brain` skill is removed the same way. Brains keep their folders,
and the registry (`brains.json`), the windows' choices (`brain-sessions/`) and the compaction logs (`brain-logs/`)
stay in `~/.claude`. The context note's state files (a few bytes per session) stay in
`${TMPDIR:-/tmp}/context-discipline/` until the system clears its temp folder.

To turn the hooks off for some runs only, without uninstalling, set `CD_HOOKS=off` in their environment (for
example `CD_HOOKS=off claude -p ...`): all three hooks then do nothing. The hooks fire in headless `claude -p`, SDK and
eval runs too, so use this for any run that must not see a STATUS file or context notes, such as a benchmark's
baseline arm.

## FAQ and troubleshooting

**The hook does not seem to fire.** Check `/hooks`; restart Claude Code only if the hook is missing. Then run the
Verify command. If it prints `(Project brain not loaded: ...)`, the brain was refused and the line says why. If it
prints `No brain attached`, the window has none: `/brain <name>`. A `.claude/brain` pointer in a folder is not read
any more: `/brain add <name>` from that folder registers its brain.

**STATUS got cut off.** Claude Code replaces hook output over 10,000 characters with a file path and a
2,000-character preview. So the hook prints at most the first 9,000 characters of STATUS, followed by a line asking
you to trim it. Move history to the overview's decision log.

**A subagent's output file was refused.** Claude Code (2.1.29x, undocumented) refuses a subagent's Write when the
file name starts with `REPORT`, `SUMMARY`, `FINDINGS` or `ANALYSIS` and ends in `.md`, in any case. The skill names
output files by date and topic, which never trips the check.

**Do I need the superpowers plugin?** No. With it, its skills lead the workflow and its implementer and reviewer
prompts replace this skill's briefs; this skill adds the hand-back contract and the output paths.

**STATUS appears twice.** A project-level hook (for example a `cat STATUS.md` in the project's
`.claude/settings.json`) also prints it. Remove that one; the global hook covers every session with a brain.

**Do the hooks write files or use the network?** None uses the network. `brain-hook.sh` writes one small record per
window (which STATUS it showed) in `~/.claude/brain-sessions/`. `compact-log.sh` writes one owner-only file per
compaction to `~/.claude/brain-logs/<name>/`, only when the session has a brain. `ctx-nudge.sh` keeps one small state
file per session in `${TMPDIR:-/tmp}/context-discipline/` and updates the window's record. All three always exit 0.
`/brain` writes the registry and its choice files in `~/.claude`; `/brain new` also runs `init-brain.sh`, which
creates the brain's two files in its folder. `brain-hook.sh` takes about 30 to 80 ms; `ctx-nudge.sh` about 60 ms on a
60 MB transcript and about 12 ms without a brain.

**Can a cloned repo inject a STATUS?** No longer: the hooks load only brains you registered and attached. A brain
folder you register from someone else's repo gets the same trust as that repo's CLAUDE.md.

## Evals

The `evals/` folder holds an early check of whether an agent follows the skill's checklist; it does not show that
the skill saves context or keeps state. Three prompts were each run once with the skill and once without. One LLM
grader, which knew which arm it was grading, scored them against assertions that restate the skill's own lines; two
of the assertions can only be passed with this skill's file names and hook. The skill was force-loaded in the
with-skill arm, while the baseline had seen the skill's description and, in one eval, read notes holding the same
rules. Two of the three evals are dry runs that grade a written plan. No eval measured context size or whether state
survives a compaction, and the raw run outputs are not published. The skill has been rewritten since. Details and
corrected scores: [evals/RESULTS.md](evals/RESULTS.md); how to re-run: [evals/README.md](evals/README.md).

## Does it help?

Not measured yet. The tests check that the scripts do what this README says; they do not show that the skill makes
the work Claude produces better. An outcome benchmark (the same multi-session task run with and without the skill)
was designed but has not been run.

To judge it on your own work: run `ctx-audit.py --json` on a few sessions from before you installed it and a few
after, and compare the main thread's peak context, compactions per hour, and whether a fresh session picks up where
the last one stopped. To compare against the skill switched off, set `CD_HOOKS=off` (see Uninstalling).

## Tests

`bash tests/run-all.sh` runs every `tests/test-*.sh`: the three hooks (`test-hook.sh`, `test-compact-log.sh`,
`test-ctx-nudge.sh`), brains as the hooks pick them (`test-brains.sh`) and the `/brain` script
(`test-brain-cmd.sh`), `init-brain.sh` (`test-init-brain.sh`), `ctx-audit.py` on synthetic transcripts
(`test-ctx-audit.sh`, fixtures in `tests/fixtures/`), the installer (`test-install.sh`), and end-to-end checks
(`test-scripts.sh`). All run against throwaway home folders, never your real `~/.claude`.

## Repo layout

```text
context-discipline/            the skill (what install.sh copies)
  SKILL.md
  references/                  agent briefs, brain templates, hook guide
  scripts/                     brain-hook.sh, compact-log.sh, ctx-nudge.sh, brain-lib.sh (shared),
                               init-brain.sh, brain.sh (/brain), ctx-audit.py
brain/SKILL.md                 the /brain command (what install.sh copies to skills/brain/)
install.sh                     installer (--dry-run, --uninstall, --skip-claude-md)
tests/                         run-all.sh, test-*.sh, fixtures/
evals/                         evals.json, files/, grade_eval1.py, RESULTS.md, README.md
```

## License

See [LICENSE](LICENSE).
