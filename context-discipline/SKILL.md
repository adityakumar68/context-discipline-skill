---
name: context-discipline
description: Context discipline for long, multi-step and multi-session work, so the main agent's context stays small and nothing important is lost. The main agent coordinates; subagents write full outputs to files and hand back about 15 lines; a project brain (STATUS.md, auto-injected by a SessionStart hook) carries state across compactions and sessions. Use it whenever you start or resume a project that will take more than one session; dispatch any subagent (research or survey, context gathering, spec or plan drafting, implementation, review, fact-checking); write a spec, plan or decisions file; run code reviews; work in a long session, after a compaction, when context is filling up, or at a handoff between sessions; or decide whether something belongs in CLAUDE.md, memory, STATUS.md or a project file. Complements superpowers brainstorming, writing-plans and subagent-driven-development (they say what to do; this says how to brief agents and where outputs go).
---

# Context discipline

## The one idea

The main agent is a **coordinator**: it holds decisions and pointers (paths, verdicts, next steps), not documents.
Everything it reads, prints, writes or receives stays in context and is re-read on every later turn, so context is a
budget re-paid each turn until the next compaction, which then throws detail away.

One measured long session (~1.39M tokens through the main thread, 5 compactions) broke down as: Bash output 19%,
subagent hand-backs 15%, Bash input 14% (long heredocs; one remote-login boilerplate retyped ~800 times), Write input
13% (specs and plans the main agent wrote itself), Read output 11% (whole files, images), Agent prompts 7%, skill
texts re-injected 6%. Most of it was work a subagent could have done, or reading and printing more than needed.

## Pick your branch

- **Starting work that will outlive this session:** set up the project brain (below). Done when the hook test in
  `references/hooks.md` prints your STATUS and you have told the user, in two or three lines, what lives where
  (rules in CLAUDE.md, stable facts in memory, current state in STATUS.md, history in the overview).
- **Resuming, or just compacted:** look for the line `(Project brain loaded from ...)` in context; if it is
  missing, read STATUS.md yourself. Check `git log --oneline -15`, then continue from STATUS's next steps.
- **About to dispatch a subagent:** follow the delegation contract; start from a brief in
  `references/agent-briefs.md`.
- **Designing a feature:** follow Design → spec → plan.
- **Session feels heavy or compacted twice:** run the context audit, then apply the hygiene list.
- **Unsure where a fact belongs:** use the table in the next section.

## Where information lives

Each home has one job; putting information in the wrong one either bloats every session or lets it go stale.

| Home | Holds | Keep out |
|---|---|---|
| Global `~/.claude/CLAUDE.md` | Stable cross-project rules, a few lines, pointers to skills | Project detail, procedures |
| Project `CLAUDE.md` / `AGENTS.md` | Project rules, build/test commands, conventions | Current state, history |
| Memory files | Facts about the user; feedback with its **Why**; project facts not derivable from the repo; pointers | Procedures; state that changes daily |
| `STATUS.md` (project brain) | Current state, ≤ 10,000 chars, auto-injected each session | History (it goes to the overview) |
| Overview doc (project brain) | Big picture, dated decision log, metrics, where everything lives | Today's to-do list |
| Skills | Procedures reused across projects | Project facts |
| Project files | Specs, plans, decisions files, notes, handoffs, agent reports and reviews | Secrets |

Secrets go in none of these: every one of them is read into context or committed. Use env vars, an askpass helper
or a password manager, read at run time. Worked examples of what goes where: `references/brain-templates.md`.

## Project brain

Set one up as soon as a project will outlive one session:

```bash
bash ~/.claude/skills/context-discipline/scripts/init-brain.sh <project-root> [status-relpath]
```

It creates the STATUS file (default `STATUS.md`), `00-Project-Overview.md` next to it, and the `<root>/.claude/brain`
pointer, and never overwrites an existing file. Fill both files, then commit them with the pointer.

**STATUS.md holds:** the pitch; each sub-project's state; what is running now and how to check it; open decisions
awaiting the user; next steps, concrete enough to start cold; key file pointers; where expensive results and their
backups live. Templates: `references/brain-templates.md`.

**Update it** after every user decision, milestone or change of next steps, and before any long autonomous stretch;
then commit (and push) if the folder is a repo. Rewrite sections in place; move history to the overview's decision
log. Keep it under 10,000 chars (`wc -c STATUS.md`), because larger hook output is cut to a 2,000-char preview.

**How it gets loaded:** a global `SessionStart` hook runs `scripts/brain-hook.sh`, which walks up from the session's
working directory to the nearest `.claude/brain` pointer and prints the STATUS file it names, on startup, resume,
`/clear` and compaction. Check it is installed with `grep -c brain-hook ~/.claude/settings.json`; if not, offer to
install it (it edits global settings, so ask first) using `references/hooks.md`, which also covers testing and
troubleshooting. Until it is installed, read STATUS.md yourself at the start of each session.

## The delegation contract

This is the core rule, and it applies to every dispatch:

- **Output to a file, short hand-back.** The subagent writes its full output (report, review, brief, survey, spec
  draft) to a file and hands back at most ~15 lines: status, verdict, Critical/Important items as one-liners, the
  file path. A pasted 200-line report costs 200 lines on every later turn; a path costs one. The file is the
  deliverable (survey, review, brief, spec draft); the agent's account of its own work is the short reply itself.
  Claude Code may refuse a subagent's "report of what I did" file, and an agent that hits that refusal pastes the
  whole report back, so don't ask for one; implementers leave commits and a test log instead.
- **Inputs as paths.** Point at files instead of pasting their text, and don't restate their contents in the
  dispatch (one source of truth, and the agent reads it anyway). Write anything the agent needs from the
  conversation into a brief or decisions file first; accumulated session history stays out of the dispatch.
- **One task per dispatch.** A focused agent finishes better and hands back less.
- **An agent type that can write.** Read-only types (Explore, Plan) cannot save output; use general-purpose or
  another type with Write when the agent must produce a file.
- **The user's model.** Use the model the user's rules (CLAUDE.md) name for subagents.
- **Parallel when independent.** Send independent dispatches in one message so they run concurrently.
- **Scale the team to the task.** One agent is usually enough for a survey or a draft; add a merge or fact-check
  agent only when the result will be relied on (a paper's related work, a claim of novelty). Every extra agent is
  another hand-back and another wait.

Give outputs a predictable home, the project's own convention if it has one, else for example `agent-reports/`,
`reviews/`, `decisions/`, `specs/`, `plans/`, `handoffs/`, with dated file names (`2026-03-14-auth-survey.md`), and
list it in the overview's "Where things live". The user's rules on where specs and plans live, and whether they
may be committed, override these defaults: some users keep design docs out of the code repo entirely, and choosing
a new folder just to make a spec committable defeats that rule.

A hand-back that meets the contract looks like this:

```text
Status: DONE_WITH_CONCERNS
Verdict: spec drafted; covers D1-D9; two assumptions need the user.
Important: D6 (retry policy) conflicts with the rate limit in the context brief; assumed exponential backoff.
Important: no decision on config format; assumed TOML.
Output: specs/2026-03-14-sync-engine.md
```

When a hand-back arrives long anyway, take the path and verdict and move on; tighten the contract in the next
dispatch. Copy-ready briefs (research/survey, context brief, spec drafter, plan drafter, implementer, reviewer,
fact-checker) and a hand-back contract block to paste into any dispatch: `references/agent-briefs.md`.

## Design → spec → plan

1. **Context first, if the area is unfamiliar:** a context-brief agent reads the code or docs and writes the
   interfaces to a file. You read its summary, not the code.
2. **One question per message.** For each, give the reference point (what the baseline or prior work does) and your
   recommendation with its reason. One question keeps answers unambiguous; the anchor makes them fast.
3. **Record each answer immediately** in a dated decisions file (`decisions/YYYY-MM-DD-<topic>.md`, template in
   `references/brain-templates.md`). The file survives compaction; your memory of the conversation does not.
4. **A subagent drafts the spec** from the decisions file plus the context brief (spec-drafter brief). In the
   measured session the main agent writing specs and plans itself was 13% of everything.
5. **Check it cheaply:** read the drafter's hand-back, then `grep -n` the sections that matter (a decision id, "error
   handling", an interface name) and `sed -n` a few lines around each hit. A whole-file Read of the spec costs its
   full length on every later turn.
6. **The user reviews the file** (give the path). Their comments go back to the drafter, with the spec path.
7. **The plan is drafted the same way** from the approved spec (plan-drafter brief).

With superpowers: brainstorming's questions feed the decisions file; writing-plans runs inside the plan-drafter;
subagent-driven-development uses the implementer and reviewer briefs.

## Reviews

- The reviewer writes the full review to a file (Critical / Important / Minor, each with file:line) and hands back
  the verdict plus Critical and Important one-liners.
- Read only the lines the review flags (`sed -n 'a,bp' file`), never the whole review or the whole diff.
- A fix round goes back to the implementer with the review's path, not its text.
- Finish with one whole-branch review, then one fix wave; batch the findings instead of a review round per nit.

## Main-agent hygiene

- **Read narrow:** `grep -n` to locate, then `sed -n 'a,bp'` or Read with offset and limit.
- **Shrink output before it lands:** pipe through `tail -n 30` or `grep -E 'error|FAIL|warn'`, or redirect to a log
  file and read the lines you need. Logs stay on disk.
- **Script the boilerplate:** anything typed more than a few times (a remote login, an environment setup, a deploy
  preamble) becomes one small helper script that reads secrets at run time from an env var or askpass helper.
- **Reuse loaded skills:** a skill invoked earlier this session is still in context (and is re-injected after a
  compaction); follow it from there instead of invoking it again for every commit or task.
- **Look at images only when the answer depends on them**; each one costs a large block of tokens.
- **Trust the edit tool:** it errors when an edit fails, so a file you just edited needs no re-read.
- **Write files with the Write tool or delegate them**, rather than long heredocs inside Bash commands, where the
  whole body is paid as Bash input and often printed back.
- **Delegate investigations** that would read across several files; keep the conclusion, not the file dumps.

## Sessions and compaction

- With a brain and the hook, auto-compaction is safe: STATUS.md is re-injected after compact, resume, clear and
  startup, so the user never has to restart sessions by hand.
- Keep STATUS current; then whatever the compaction summary drops is already on disk.
- After a compaction, trust files and `git log --oneline -15` over your recollection; reopen the decisions file or
  plan with `grep -n`, not a full read.
- A fresh session is optional at sub-project boundaries. Before choosing one, write a short handoff note in the
  project (state, decisions, file pointers, next action; template in `references/brain-templates.md`) and point
  STATUS's next steps at it.

## Checking what fills context

```bash
python3 ~/.claude/skills/context-discipline/scripts/ctx-audit.py <transcript.jsonl> [--top N]
```

Transcripts live at `~/.claude/projects/<cwd with "/" as "-">/<session-id>.jsonl` (pass the folder to audit its
newest file); subagent transcripts sit in `<session-id>/subagents/` (audit with `--include-sidechains`). It prints
estimated tokens by category and the largest single items. Run it when a session feels heavy or compacts a second
time, and act on the top two or three categories:

| Top category | Fix |
|---|---|
| Bash output | tail/grep, logs to files |
| Bash input | helper scripts; Write instead of heredocs |
| Write input | delegate spec, plan and report drafting |
| Read output | narrow reads; delegate multi-file reading |
| Agent hand-back / task notices | tighten the hand-back contract |
| Agent prompt | pass paths instead of pasted text |
| Skill texts (incl. re-injected) | invoke each skill once; fewer compactions |

## Red flags

| Thought | Reality |
|---|---|
| "I'll just read the whole spec to check it." | Grep the sections that matter; the drafter's summary covers the rest. |
| "The report is short enough to paste back." | File plus ~15 lines. Short reports add up across 100 dispatches. |
| "I'll write the spec myself, it's faster." | Self-written specs and plans were 13% of one session's context. Delegate. |
| "I'll remember this decision." | Compaction will not. Append it to the decisions file now. |
| "I'll give the agent the background by pasting our discussion." | Write a brief file and pass its path. |
| "Let me print the log and see what happened." | `tail`/`grep` it; the log stays on disk. |
| "It's just one more ssh preamble." | It was retyped ~800 times in one session. Write the helper script. |
| "Let me invoke the skill again to be safe." | Its text is already in context. |
| "STATUS can wait until the end of the session." | The session may compact first. Update it at the decision. |
| "This fact should go in memory." | Only if it is stable and not derivable from the repo; current state goes in STATUS. |
