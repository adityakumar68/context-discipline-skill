# context-discipline

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) skill for long work: projects that run over many
sessions, research surveys, design → spec → plan, and anything that dispatches subagents. It keeps the main agent's
context small, and it keeps the project's state on disk where a compaction or a new session cannot lose it.

## The problem

Everything the main agent reads, prints, writes or receives stays in its context and is paid for again on every
later turn. When the context fills up, Claude Code compacts it into a summary, and detail is lost: the decision
made an hour ago, the file that holds the plan, what was running.

One measured long session (about 1.39M tokens through the main thread, 5 compactions) broke down like this:

| What filled the context | Share |
|---|---|
| Bash output | 19% |
| Subagent hand-backs | 15% |
| Bash input (long heredocs; one login boilerplate retyped about 800 times) | 14% |
| Write input (specs and plans the main agent wrote itself) | 13% |
| Read output (whole files, images) | 11% |
| Agent prompts | 7% |
| Skill texts re-injected after compaction | 6% |

Most of it was work a subagent could have done, or reading and printing more than was needed.

## What you get

- **The skill** (`context-discipline/SKILL.md`): where each kind of information lives, the delegation contract,
  design → spec → plan with subagents, cheap reviews, main-agent hygiene, and what to do after a compaction.
- **A SessionStart hook** (`scripts/brain-hook.sh`): on startup, resume, `/clear` and compaction it prints the
  project's STATUS file, so Claude Code puts the current state back into context automatically.
- **A project brain** (`scripts/init-brain.sh`): sets up `STATUS.md` (current state), `00-Project-Overview.md`
  (big picture and dated decision log) and the `.claude/brain` pointer the hook follows.
- **Agent brief templates** (`references/agent-briefs.md`): copy-ready briefs for research, context gathering,
  spec and plan drafting, implementation, review and fact-checking, each with a short hand-back contract.
- **ctx-audit** (`scripts/ctx-audit.py`): reads a session transcript and shows what filled the context.

## How it works

```text
Claude Code session: startup / resume / /clear / compaction
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

The delegation contract, which the skill applies to every subagent:

1. The subagent writes its full output (survey, review, spec draft) to a file.
2. It hands back at most about 15 lines: status, verdict, key issues as one-liners, the file path.
3. Inputs go in as file paths, not pasted text.
4. One task per dispatch, with an agent type that can write files.
5. The main agent keeps decisions and pointers, not documents, and records each decision on disk at once.

## Requirements

- Claude Code
- bash and python3 (`jq` is used if present, but not needed)
- macOS or Linux. Windows is untested.

## Quick install

```bash
git clone https://github.com/adityakumar68/context-discipline-skill.git
cd context-discipline-skill
./install.sh
```

Then restart Claude Code: hooks are read at startup. Open `/hooks` to see the new SessionStart entries.

## What the installer changes

It works in `$CLAUDE_CONFIG_DIR` if set, else `~/.claude`, and changes three things:

1. **The skill.** Copies `context-discipline/` to `~/.claude/skills/context-discipline/`. If a different copy is
   already there, it is first moved to `~/.claude/skill-backups/context-discipline.bak-<timestamp>` (outside
   `skills/`, so Claude Code does not load it as a second skill).
2. **The hook.** Adds four `SessionStart` entries (matchers `startup`, `resume`, `clear`, `compact`) to
   `~/.claude/settings.json`, each running `bash "<your home>/.claude/skills/context-discipline/scripts/brain-hook.sh"`.
   It edits the file with python's `json` module, keeps every other key and hook (the file is rewritten with
   2-space indentation), writes atomically, and first saves `settings.json.bak-<timestamp>`. If `settings.json` is not valid JSON, it stops and changes nothing.
3. **One line in `~/.claude/CLAUDE.md`** (backed up first; skipped if a line already mentions
   `context-discipline`, or with `--skip-claude-md`). The line is shown under Manual install.

Run `./install.sh --dry-run` to see every planned change without making any. Running the installer again is safe:
steps already done are skipped.

## Manual install

If you prefer to edit your settings yourself:

1. Copy the skill: `mkdir -p ~/.claude/skills && cp -R context-discipline ~/.claude/skills/`
2. Merge this into `~/.claude/settings.json`, next to any hooks you already have:

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

3. Add this line to `~/.claude/CLAUDE.md`:

   ```text
   - For any work that spans many steps or sessions (projects, research surveys, designs, specs, plans, subagent dispatches, reviews), follow the `context-discipline` skill: the main agent coordinates; subagents put deliverables in files and hand back about 15 lines; keep the project brain (STATUS.md, auto-loaded through a `.claude/brain` pointer) current at every decision.
   ```

4. Restart Claude Code.

## Set up a project

In each project that will outlive one session:

```bash
bash ~/.claude/skills/context-discipline/scripts/init-brain.sh ~/code/my-project   # optional 2nd arg: docs/STATUS.md
```

This creates `STATUS.md`, `00-Project-Overview.md` beside it, and `.claude/brain`, and never overwrites an existing
file. Fill both files in (or let Claude do it), keep STATUS under 10,000 characters (`wc -c STATUS.md`), and commit
all three. Or just ask Claude: "set up a project brain for this repo".

## Verify

```bash
echo '{"cwd": "'"$HOME"'/code/my-project/src", "source": "startup"}' \
  | bash ~/.claude/skills/context-discipline/scripts/brain-hook.sh
```

It should print your STATUS file and end with `(Project brain loaded from ...)`. In a new Claude Code session in
that project, the same text appears in Claude's context; ask "what does STATUS say?" to check.

## Day-to-day use

You mostly work as before; Claude changes how it works:

| You say | What Claude does differently |
|---|---|
| "Let's start a project to build X." | Sets up the project brain and tells you, in two or three lines, what lives where. |
| "Survey what's been published on X." | Sends one research subagent that writes the survey to a file and replies in about 15 lines; reads only that reply and the sections it needs. |
| "Write the spec from our decisions." | Has a subagent draft it from the decisions file, spot-checks it with `grep`, and gives you the path to review. |
| "Review this branch." | A reviewer writes the full review to a file; Claude reads only the lines it flags and sends fixes back by path. |
| Design questions | Asks one question per message, with a recommendation, and records each answer in a dated decisions file. |
| (after a compaction, or the next morning) | STATUS is already back in context; Claude continues from its next steps instead of asking you to recap. |

## Checking context use

When a session feels heavy or compacts a second time:

```bash
python3 ~/.claude/skills/context-discipline/scripts/ctx-audit.py ~/.claude/projects/<project-folder>/ [--top N]
```

Transcripts live in `~/.claude/projects/<cwd with "/" replaced by "-">/<session-id>.jsonl`; given the folder it
audits the newest one. Subagent transcripts are in `<session-id>/subagents/` (add `--include-sidechains`). The
output looks like this; the shares here are the published breakdown above, and the rest depends on your session:

```text
Transcript: <session-id>.jsonl  (<size> MB, <records> records)
Main-thread input estimate: ~<n>M tokens (chars/4)  |  compactions: <n>  |  images: <n> (...)

Category                              ~tokens   share   items
---------------------------------  ----------  ------  ------
Bash output                               ...   19.0%     ...
Agent hand-back                           ...   15.0%     ...
Bash input                                ...   14.0%     ...
Write input                               ...   13.0%     ...
Read output                               ...   11.0%     ...
Agent prompt                              ...    7.0%     ...
Skill texts re-injected (compact)         ...    6.0%     ...
...

Top 10 single largest items:
  1. <category>  ~<tokens>  <short preview>
```

Act on the top two or three categories; the skill's table maps each to a fix. Previews that look like
credentials are redacted.

## Updating

`git pull && ./install.sh` in your clone. The installed copy is refreshed (the old one goes to `skill-backups/`);
the hook and CLAUDE.md steps are no-ops.

## Uninstalling

`./install.sh --uninstall` (add `--dry-run` first to see what it will do) removes the skill folder, every hook entry whose command contains `context-discipline/scripts/brain-hook.sh`
(and any matcher entry or list left empty), and the CLAUDE.md line, backing up both files first. A locally edited
skill copy is moved to `skill-backups/` instead of deleted. Projects keep their `.claude/brain`, STATUS and overview.

## FAQ and troubleshooting

**The hook does not seem to fire.** Hooks are read when Claude Code starts: restart it, or check `/hooks`. Then
run the Verify command. If that prints nothing, check that `<project>/.claude/brain` exists and its first
non-comment line names an existing file. The walk stops before `$HOME`, so a project must be in a subfolder of
your home, not your home folder itself.

**STATUS got cut off.** Claude Code replaces hook output over 10,000 characters with a 2,000-character preview. The
hook prints only the first 9,000 bytes of a STATUS over 9,500 bytes, plus a line asking you to trim it. Move
history to the overview's decision log.

**A subagent's report file was refused.** Claude Code may refuse a file in which a subagent reports on its own
work. That is why the skill asks for deliverables in files (the survey, the review, the spec) and treats the short
reply as the agent's account of what it did.

**Do I need the superpowers plugin?** No. It works with or without it. With it, brainstorming, writing-plans and
subagent-driven-development say what to do; this skill says how to brief agents and where their outputs go.

**STATUS appears twice.** A project-level hook (for example a `cat STATUS.md` in the project's
`.claude/settings.json`) also prints it. Remove that one; the global hook covers every project with a pointer.

**Does the hook write files or use the network?** No. It only reads the pointer and the STATUS file, prints
nothing when anything is missing, always exits 0, and takes about 20 ms.

## Evals

Three test prompts (new-project setup, a literature survey, a spec from a decisions file) were each run with and
without the skill and graded against 5–6 assertions. Mean pass rate: 93.3% with the skill, 47.7% without, at a
cost of roughly 9–13k more tokens per run. It is one run per configuration, and the baseline had partly seen
similar rules, so read [evals/RESULTS.md](evals/RESULTS.md) for the per-assertion results and caveats, and
[evals/README.md](evals/README.md) to re-run them.

## Tests

`bash tests/run-all.sh` runs `tests/test-scripts.sh` (the hook, `init-brain.sh`, `ctx-audit.py`) and
`tests/test-install.sh` (the installer, against throwaway home folders, never your real `~/.claude`).

## Repo layout

```text
context-discipline/            the skill (what install.sh copies)
  SKILL.md
  references/                  agent briefs, brain templates, hook guide
  scripts/                     brain-hook.sh, init-brain.sh, ctx-audit.py
install.sh                     installer (--dry-run, --uninstall, --skip-claude-md)
tests/                         test-scripts.sh, test-install.sh, run-all.sh
evals/                         evals.json, files/, grade_eval1.py, RESULTS.md, README.md
```

## License

See [LICENSE](LICENSE).
