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
- **Three hooks**, active only in projects with a brain:
  - `SessionStart` (`brain-hook.sh`) prints the project's STATUS file on startup, resume, `/clear`, compaction and
    fork, so the current state is back in context automatically.
  - `PostCompact` (`compact-log.sh`) saves each compaction summary to `.claude/compactions/` in the project, so you
    can check what a compaction kept.
  - `UserPromptSubmit` (`ctx-nudge.sh`) adds a short note for Claude when the context reaches 40% of its window, and
    every 15% after: at the next natural break, update STATUS and suggest `/clear` or `/compact <focus>`.
- **A project brain** (`scripts/init-brain.sh`): `STATUS.md` (current state), `00-Project-Overview.md` (big picture
  and dated decision log), the `.claude/brain` pointer the hooks follow, and a `.gitignore` line for the
  compaction logs.
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
brain-hook.sh walks up from the session's folder:
   ~/code/app/src/ui  ->  ~/code/app/src  ->  ~/code/app      (stops before $HOME)
        |
        v
finds ~/code/app/.claude/brain, whose first line says: STATUS.md
        |
        v
prints ~/code/app/STATUS.md and "(Project brain loaded from ...)"  ->  Claude reads it
```

The other two hooks find the project the same way. The pointer must name a text file inside the project by a
relative path; anything else is refused with a one-line warning.

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

It works in `$CLAUDE_CONFIG_DIR` if set, else `~/.claude`, and changes three things:

1. **The skill.** Copies `context-discipline/` to `~/.claude/skills/context-discipline/`. A different copy already
   there is first moved to `~/.claude/skill-backups/context-discipline.bak-<timestamp>` (outside `skills/`, so
   Claude Code does not load it as a second skill).
2. **The hooks.** Adds three hooks to `~/.claude/settings.json`, each in one entry with no matcher:
   `SessionStart` runs `brain-hook.sh` and `PostCompact` runs `compact-log.sh`, each with a 10-second timeout, and
   `UserPromptSubmit` runs `ctx-nudge.sh` with a 5-second timeout. Each command reads
   `bash "$HOME/.claude/skills/context-discipline/scripts/<script>"`, so a settings file synced between machines
   works on each (a config folder outside `$HOME` gets absolute paths). Older entries for the same scripts are
   replaced, including the four `SessionStart` entries with matchers that earlier versions installed, and an entry
   whose script path no longer exists is repaired. Every other key and hook is kept. The file is edited with
   python's `json` module (rewritten with 2-space indentation; a final newline, or its absence, is kept), written
   atomically, and first backed up to `settings.json.bak-<timestamp>`. If it is not valid JSON, the installer stops
   and changes nothing. It warns if `"disableAllHooks": true` is set.
3. **One line in `~/.claude/CLAUDE.md`** (backed up first; skipped if a line already mentions
   `context-discipline`, or with `--skip-claude-md`). The line is shown under Manual install.

Run `./install.sh --dry-run` to see every planned change without making any. Running the installer again is safe:
steps already done are skipped.

## Manual install

1. Copy the skill: `mkdir -p ~/.claude/skills && cp -R context-discipline ~/.claude/skills/`
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
   - For any work that spans many steps or sessions (projects, research surveys, designs, specs, plans, subagent dispatches, reviews), follow the `context-discipline` skill: the main agent coordinates; subagents put deliverables in files and hand back about 15 lines; keep the project brain (STATUS.md, auto-loaded through a `.claude/brain` pointer) current at every decision.
   ```

4. Open `/hooks` to check the three hooks are listed.

## Set up a project

In each project that will outlive one session:

```bash
bash "$HOME/.claude/skills/context-discipline/scripts/init-brain.sh" ~/code/my-project   # optional 2nd arg: docs/STATUS.md
```

This creates `STATUS.md`, `00-Project-Overview.md` beside it and `.claude/brain`, adds `.claude/compactions/` to the
project's `.gitignore`, and never overwrites an existing file. It refuses `$HOME` and `/` as the project, refuses
STATUS paths that are absolute, start with `~` or climb out with `..`, and exits 1 if anything was not created.
Fill both files in (or let Claude do it), keep STATUS under 9,000 characters (`wc -m STATUS.md`), and commit them
with the pointer. Or just ask Claude: "set up a project brain for this repo".

## Verify

```bash
echo '{"cwd": "'"$HOME"'/code/my-project/src", "source": "startup"}' \
  | bash "$HOME/.claude/skills/context-discipline/scripts/brain-hook.sh"
```

It should print your STATUS file and end with `(Project brain loaded from ...)`. In a new Claude Code session in
that project, ask "what does STATUS say?" to check. Tests for the other two hooks are in
`context-discipline/references/hooks.md`.

## Day-to-day use

You mostly work as before; Claude changes how it works:

| You say | What Claude does differently |
|---|---|
| "Let's start a project to build X." | Sets up the project brain and tells you, in two or three lines, what lives where. |
| "Survey what's been published on X." | Sends one research subagent that writes the survey to a file and replies in about 15 lines; reads only that reply and the sections it needs. |
| "Write the spec from our decisions." | Has a subagent draft it from the decisions file, spot-checks it with `grep`, and gives you the path to review. |
| "Review this branch." | A reviewer writes the full review to a file; Claude reads only the lines it flags and sends fixes back by path. |
| Design questions | Asks one question per message, with a recommendation, and records each answer in a dated decisions file. |
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
- Read `.claude/compactions/` to see what a compaction kept; the full history stays in the session transcript.

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
`SessionStart` entries become one), and the CLAUDE.md step is a no-op.

## Uninstalling

`./install.sh --uninstall` (add `--dry-run` first to see what it will do) removes the skill folder; every hook whose
command contains `context-discipline/scripts/` followed by `brain-hook.sh`, `compact-log.sh` or `ctx-nudge.sh` (and
any entry or list left empty); and the CLAUDE.md line, backing up both files first. A locally edited skill copy is
moved to `skill-backups/` instead of deleted. Projects keep their `.claude/brain`, STATUS, overview,
`.claude/compactions/` and the `.gitignore` line. The context note's state files (a few bytes per session) stay in
`${TMPDIR:-/tmp}/context-discipline/` until the system clears its temp folder.

To turn the hooks off for some runs only, without uninstalling, set `CD_HOOKS=off` in their environment (for
example `CD_HOOKS=off claude -p ...`): all three hooks then do nothing. The hooks fire in headless `claude -p`, SDK and
eval runs too, so use this for any run that must not see a STATUS file or context notes, such as a benchmark's
baseline arm.

## FAQ and troubleshooting

**The hook does not seem to fire.** Check `/hooks`; restart Claude Code only if the hook is missing. Then run the
Verify command. If it prints `(Project brain not loaded: ...)`, the pointer was refused and the line says why. If it
prints nothing, check that `<project>/.claude/brain` exists and its first non-comment line names an existing file by
a relative path. The walk stops before `$HOME` and `/`, so the project folder can be anywhere except your home
folder itself (or `/`): a pointer there is never used.

**STATUS got cut off.** Claude Code replaces hook output over 10,000 characters with a file path and a
2,000-character preview. So the hook prints at most the first 9,000 characters of STATUS, followed by a line asking
you to trim it. Move history to the overview's decision log.

**A subagent's output file was refused.** Claude Code (2.1.29x, undocumented) refuses a subagent's Write when the
file name starts with `REPORT`, `SUMMARY`, `FINDINGS` or `ANALYSIS` and ends in `.md`, in any case. The skill names
output files by date and topic, which never trips the check.

**Do I need the superpowers plugin?** No. With it, its skills lead the workflow and its implementer and reviewer
prompts replace this skill's briefs; this skill adds the hand-back contract and the output paths.

**STATUS appears twice.** A project-level hook (for example a `cat STATUS.md` in the project's
`.claude/settings.json`) also prints it. Remove that one; the global hook covers every project with a pointer.

**Do the hooks write files or use the network?** None uses the network. `brain-hook.sh` only reads. `compact-log.sh`
writes one owner-only file per compaction to `.claude/compactions/`, in brain projects only. `ctx-nudge.sh` keeps one
small state file per session in `${TMPDIR:-/tmp}/context-discipline/`. All three always exit 0. `brain-hook.sh`
takes about 30 ms; `ctx-nudge.sh` about 60 ms on a 60 MB transcript and about 12 ms outside brain projects.

**Is a cloned repo's STATUS trusted?** It gets the same trust as the repo's own CLAUDE.md: a repo that ships a
`.claude/brain` puts its STATUS file in your context when you start Claude Code inside it. Likewise, a pointer in a
parent folder (say `~/Downloads/.claude/brain`) can inject any text file inside that folder. The hook never follows a
pointer out of its folder through an absolute path, `..` or a symlink.

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
`test-ctx-nudge.sh`), `init-brain.sh` (`test-init-brain.sh`), `ctx-audit.py` on synthetic transcripts
(`test-ctx-audit.sh`, fixtures in `tests/fixtures/`), the installer (`test-install.sh`), and end-to-end checks
(`test-scripts.sh`). All run against throwaway home folders, never your real `~/.claude`.

## Repo layout

```text
context-discipline/            the skill (what install.sh copies)
  SKILL.md
  references/                  agent briefs, brain templates, hook guide
  scripts/                     brain-hook.sh, compact-log.sh, ctx-nudge.sh, brain-lib.sh (shared),
                               init-brain.sh, ctx-audit.py
install.sh                     installer (--dry-run, --uninstall, --skip-claude-md)
tests/                         run-all.sh, test-*.sh, fixtures/
evals/                         evals.json, files/, grade_eval1.py, RESULTS.md, README.md
```

## License

See [LICENSE](LICENSE).
