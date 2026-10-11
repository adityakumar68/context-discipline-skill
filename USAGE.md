# Using brains in Claude Code — quick guide

A **brain** is a small set of notes about one piece of work: what is done, what is next, what you decided.
A Claude Code session **attaches** a brain and reads it at the start, so you never re-explain your project.
Folders do not own brains. Any session, started in any folder, can use any brain.

## Set up once

```bash
git clone https://github.com/adityakumar68/context-discipline-skill.git
cd context-discipline-skill && bash install.sh
```

The installer adds two skills (`context-discipline`, `brain`), three hooks in `~/.claude/settings.json` and one
line in `~/.claude/CLAUDE.md`.
It backs up what it replaces. Undo with `bash install.sh --uninstall`.

## Every day

1. **Start Claude anywhere.** With no brain attached, you see one line:
   `No brain attached. Last used here: thesis (type /brain thesis). All brains: thesis, reading.`
2. **Attach a brain:** `/brain thesis`. Claude reads its STATUS and carries on from the last next step.
3. **Work as usual.** Claude records each decision, keeps STATUS current and hands big reading or writing jobs
   to helper agents, so your session stays small.
4. **When context fills up**, Claude gets a nudge at 40%, 55%, 70% and 85%. At the next natural break it saves
   STATUS, writes a handoff note and suggests `/clear`. Run `/clear`: the brain reloads and work continues in a
   fresh, sharp session.

To skip typing step 2, launch with the brain already attached: `CD_BRAIN=thesis claude`
(an alias such as `alias ct='CD_BRAIN=thesis claude'` makes it one word).

## The /brain command

| Command | What it does |
|---|---|
| `/brain` | List brains: folder, size, last change, how many windows use each |
| `/brain <name>` | Attach a brain to this window (it stays through `/clear` and compaction) |
| `/brain none` | Detach; this window uses no brain |
| `/brain new <name>` | Create a brain in `~/.claude/brains/<name>/` and attach it |
| `/brain new <name> --at <folder>` | Create it in a folder you choose, e.g. inside a git repo so it is versioned |
| `/brain add <name> <folder>` | Register notes that already exist |
| `/brain rename <old> <new>` | Rename it; no files move unless it lives in the default folder |
| `/brain remove <name>` | Forget the name; the notes stay on disk |

## What a brain holds

| File | Purpose | Loaded at start? |
|---|---|---|
| `STATUS.md` | Current state and next steps (max 9,000 characters) | **Yes, the only one** |
| `00-Project-Overview.md` | Big picture, decision log, rules for this work | When needed |
| `decisions/` | One file per design topic | When STATUS points to it |
| `handoffs/` | One note per break between sessions | Only the one STATUS links to |

Each compaction summary is saved to `~/.claude/brain-logs/<name>/`, so you can read what a compaction kept.

## What goes where

| Place | Holds | Example |
|---|---|---|
| Global `~/.claude/CLAUDE.md` | Rules for every project | "use opus for subagents" |
| Project `CLAUDE.md` | Rules for the code in that folder | "run tests with pytest" |
| Memory | Facts about you | "no LaTeX in the terminal" |
| Brain | The state of one piece of work | "sub-project 4 next; GPU 3 is ours" |

If memory and a brain disagree about the work, the brain wins: it is newer.

## Several windows, one brain

Attach the same brain in as many windows as you like. When one window changes STATUS, the others get a note
on their next message to re-read it. Handoff and decision files carry the time in their names, so windows never
overwrite each other.

## Good habits

- Use `/brain none` for quick questions that have nothing to do with a project.
- Glance at STATUS's "Next steps" before `/clear`: it should name the latest handoff note.
- Put important brains inside a git repo (`--at`) so they are backed up.
- To see what fills a session, run
  `python3 ~/.claude/skills/context-discipline/scripts/ctx-audit.py <transcript.jsonl>`.

## Limits

- Claude cannot press `/clear` or `/compact` for you; it can only suggest the moment.
- The hooks always run. The habits (helper agents, decision files) depend on Claude following the skill.
- Launch with `CD_HOOKS=off claude` to switch the hooks off for that session.
