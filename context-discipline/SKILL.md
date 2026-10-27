---
name: context-discipline
description: Use when work will span several sessions or compactions; when dispatching any subagent (research, spec or plan drafting, implementation, review, fact-check); when writing a spec, plan or decisions file; when context is filling up, a context-check note arrives or a compaction just happened; or when deciding where a fact belongs.
---

# Context discipline

The main agent is a **coordinator**: it holds decisions and pointers (paths, verdicts, next steps); documents live
in files. Every call resends the context, and a compaction replaces it with a lossy summary.

## Pick your branch

- **Work will outlive this session:** give the session a brain (below). Done when `/brain` marks it for this window
  and you have told the user in two or three lines what lives where.
- **Resuming, or just compacted:** find `(Project brain loaded from ...)` in context, else read the brain's STATUS;
  run `git log --oneline -15`; continue from STATUS's next steps.
- **Dispatching a subagent:** the delegation contract and `references/agent-briefs.md`.
- **Designing a feature or reviewing a branch:** design, specs and reviews.
- **A context-check note arrived, or the session feels heavy:** sessions and compaction.
- **Unsure where a fact belongs:** "What goes where" in `references/brain-templates.md`. Secrets stay out of every file.

## The session's brain

A brain belongs to a Claude Code session, not to a folder: a name plus a folder holding `STATUS.md`,
`00-Project-Overview.md`, `decisions/` and `handoffs/`. The user attaches one per window with `/brain <name>` (or
`CD_BRAIN=<name>` at launch); a resumed session gets its brain back, and a session without one gets a one-line
hint at its start. To create one, agree a name
with the user, then:

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/brain.sh" new <name> [--at <folder>]
```

It writes STATUS and the overview into `~/.claude/brains/<name>/` (or `<folder>`, say inside the repo), registers
the brain and attaches it to this window; it never writes in the session's folder. Fill both from the templates in
`references/brain-templates.md`. A brain of an older version (a `.claude/brain` pointer): `/brain add <name>`, run
from that folder.

STATUS holds the current state, written as facts. Update it after every user decision, milestone or change of next
steps; history goes to the overview's decision log. Link the brain's own files relative to its folder, project
files by absolute path. **Limit: 9,000 characters (`wc -m`)**; the hook shows only the first 9,000 of a longer
file, with a trim notice.

- **Shared brain:** several windows may attach one brain. Re-read STATUS right before editing it and change only the
  sections you own. A note that STATUS "was updated since this session last read it" means another session wrote
  it: re-read it before relying on it.
- **Where facts go:** while a brain is attached, facts about the project go to the brain (overview or STATUS),
  never to folder memory; memory keeps facts about the user and their feedback; rules for every folder go in the
  global CLAUDE.md. For this work's current state, the loaded STATUS overrides older notes in memory.

Three global hooks (details and manual setup in `references/hooks.md`): SessionStart prints the brain's STATUS
(startup, resume, `/clear`, compaction, fork). With a brain, PostCompact saves each compaction summary to
`~/.claude/brain-logs/<name>/`, and UserPromptSubmit adds a context-check note at 40% of the window and every 15%
after, and a note when STATUS changed under the session. Check with
`grep -c context-discipline/scripts "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"` (3 when all are in). If missing, offer to install them
(global settings: ask first); meanwhile read STATUS yourself.

## The delegation contract

- **Output to a file, short hand-back.** The subagent writes its full output (survey, review, brief, spec draft) to
  a file and replies in at most ~15 lines: status, verdict, Critical/Important one-liners, the path. Implementers
  leave commits and a test log.
- **Dated topic file names** (`2026-03-14-auth-survey.md`). Never start one with REPORT, SUMMARY, FINDINGS or
  ANALYSIS: an undocumented Claude Code check refuses a subagent's Write of such a `.md` file, and the agent then
  pastes everything back.
- **Inputs as paths.** Write what the agent needs from the conversation into a brief or decisions file first.
- **One task per dispatch,** and one agent unless the result will be relied on (then add a fact-checker).
- **An agent type that fits.** Explore and Plan cannot write files and skip CLAUDE.md. A `fork` inherits this
  conversation; use general-purpose or a named type when the brief should be the only input.
- **The user's model** for subagents, named on every dispatch.

Outputs go to the project's convention, else `agent-reports/`, `reviews/`, `specs/`, `plans/`, listed in the
overview; `decisions/` and `handoffs/` live in the brain's folder. The user's rules on where specs and plans live
override these.

**With superpowers:** its skills lead the workflow and its implementer and reviewer prompts replace the briefs here;
this skill adds only the hand-back contract and the output paths.

## Design, specs and reviews

- Ask one question per message, with a reference point and your recommendation; append each answer at once to
  `decisions/YYYY-MM-DD-HHMM-<topic>.md` in the brain's folder (the time keeps two sessions' files apart).
- Subagents draft the spec (from the decisions file and a context brief), then the plan. Check a draft with
  `grep -n` and `sed -n` on what matters (a decision id, an interface); give the user the path.
- A reviewer writes its review to a file; read only the lines it flags. Send fixes by path, resuming the
  implementer with `SendMessage`. End with one whole-branch review and one fix wave.

## Main-agent hygiene

- Shrink output before it lands: `| tail -n 30`, `| grep -E 'error|FAIL'`, or a log file.
- Turn anything typed more than a few times (a remote login, an environment setup) into a helper script.
- Write files with the Write tool or a subagent; a long heredoc is paid in full as Bash input.
- Look at images only when the answer depends on them.

## Sessions and compaction

The brain keeps project state across compaction, `/clear`, resume and fork. Compaction still loses working state
held only in the conversation: the current hypothesis, half-done edits, what was just tried, early instructions.
Hook text is summarized too, and re-attached skills keep only their first 5,000 tokens (oldest dropped first).

- **Keep it on disk:** STATUS and decisions current; a handoff note (`handoffs/YYYY-MM-DD-HHMM-<sub-project>.md`)
  before a new sub-task, with its path as the first item of STATUS's Next steps. That link is how the next session
  finds it; nothing searches for notes by date.
- **Tell the summary what to keep:** a `# Compact instructions` section in the project-root CLAUDE.md.
- **Choose the moment:** at a natural break, suggest `/clear` (fresh session from STATUS and the handoff note) or
  `/compact <focus>` to the user. `/autocompact` or the `autoCompactWindow` setting moves the automatic point.
- **On a context-check note:** finish the current step. At the next natural break update STATUS, write a handoff
  note if a new sub-task is about to start (linked from STATUS's Next steps), then suggest `/clear` or `/compact <focus>`.
- **After a compaction:** trust files and `git log` over recollection; `grep -n` the decisions file or plan;
  `~/.claude/brain-logs/<name>/` holds the summary; re-invoke a skill whose full text you need.

Templates for the handoff note and Compact instructions: `references/brain-templates.md`.

## Checking what fills context

Live: `/context`. A past session:

```bash
python3 "${CLAUDE_SKILL_DIR}/scripts/ctx-audit.py" <transcript.jsonl | folder> [--top N] [--include-sidechains] [--json]
```

Transcripts sit in `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/<cwd, non-alphanumerics as "-">/`; subagent files are read automatically.
It prints context measured from API usage, then visible content by category. The top row is often
`[not in transcript]` (system prompt, tool schemas, thinking). Act on the top visible categories: Bash output →
tail/grep, logs; Bash input → helper scripts, Write; Write input → delegate drafting; Read output → narrow reads,
delegate; hand-backs → tighter contract; Agent prompt → paths.

## Red flags

| Thought | Reality |
|---|---|
| "I'll read the whole spec to check it." | Grep the sections that matter. |
| "The report is short enough to paste back." | File plus ~15 lines; short reports add up. |
| "I'll remember this decision." | Compaction may not. Write it down now. |
| "Auto-compaction will keep what matters." | It keeps what is on disk and in Compact instructions. |
