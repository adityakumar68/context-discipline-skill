# Brain templates

Copy-ready templates for the files a long project keeps outside the agent's context. `scripts/init-brain.sh` copies
the STATUS and overview templates below (the fenced blocks after the `template:` markers) and fills `{{PROJECT}}` and
`{{DATE}}`; edit the markers and the script reads the new version.

Contents: STATUS.md · overview doc · decisions file · handoff note · memory file · what goes where.

## STATUS.md

The current state, re-injected into context on every startup, resume, clear and compact. Keep it under 10,000 chars
(`wc -c STATUS.md`): hook output over that becomes a 2,000-char preview. Rewrite sections in place instead of
appending; history belongs in the overview's decision log and in git.

<!-- template:status -->
~~~markdown
# {{PROJECT}} — STATUS

_Last updated: {{DATE}}. Rewrite in place; keep under 10,000 chars (`wc -c`)._

## Pitch
One or two sentences: what this project makes and why it matters.

## Sub-projects
| Sub-project | State | Where |
|---|---|---|
| (name) | not started / designing / spec ready / implementing / done | (spec, plan or branch path) |

## Running now
- (job, agent or experiment) — started (date), expected done (date), output goes to (path). Check with: (command).
- Nothing running.

## Open decisions awaiting the user
1. (question) — options (a) / (b); my recommendation: (a) because (reason).

## Next steps
1. (the very next action, concrete enough to start without re-reading anything)
2.

## Key files
- Big picture, decision log: `00-Project-Overview.md`
- Current decisions file: (path)
- Current spec / plan: (path)

## Expensive results and their backups
- (result, e.g. trained checkpoint or dataset build) — (path) — backup: (path or "none yet")
~~~
<!-- end:status -->

## Overview doc (`00-Project-Overview.md`)

The big picture that changes slowly. Read on demand (by section, with `grep -n '^## '`), never injected whole.

<!-- template:overview -->
~~~markdown
# {{PROJECT}} — Project Overview

_Created {{DATE}}. Current state lives in STATUS.md; this file holds the big picture and the history._

## Goal
What success looks like, for whom, by when. The main claim or deliverable in one paragraph.

## Architecture
The main components and how data flows between them. Link specs instead of restating them.

## Decision log
| Date | Decision | Why | Alternatives rejected | Source (decisions file, spec) |
|---|---|---|---|---|
| {{DATE}} | Project brain set up | Work spans many sessions | — | — |

## Experiments and metrics
| Date | Experiment | Metric | Result | Where the outputs live |
|---|---|---|---|---|

## Compute and resources
Machines, GPUs, quotas, accounts (names only; secrets stay in env vars or a password manager), usage rules.

## Where things live
| What | Path |
|---|---|
| Specs | |
| Plans | |
| Decisions files | |
| Agent reports and reviews | |
| Data and checkpoints | |

## Risks and open questions
- (risk) — likelihood, impact, mitigation.

## Working rules
- Main agent coordinates; subagents write full outputs to files and hand back at most ~15 lines.
- Update STATUS.md after every user decision, milestone or change of next steps, and commit it.
~~~
<!-- end:overview -->

## Decisions file (`decisions/YYYY-MM-DD-<topic>.md`)

Written during design, one entry appended the moment the user answers, so nothing depends on the conversation
surviving compaction. The spec drafter reads this file instead of the session history.

```markdown
# Decisions — <topic> (started YYYY-MM-DD)

Context brief: <path to the context-brief agent's output, if any>

## D1 — <question in a few words> (YYYY-MM-DD)
- Asked: <the question as put to the user>
- Reference point: <what the baseline / prior work does>
- Recommended: <option> because <reason>
- Decided: <the user's answer, in their words where it matters>
- Consequence: <what this rules in or out for the spec>

## Open
- <questions not yet asked>
```

## Handoff note (`handoffs/YYYY-MM-DD-<sub-project>.md`)

Written before choosing a fresh session at a sub-project boundary. The next session reads STATUS (injected) and this
note, then the files it points to, and nothing else.

```markdown
# Handoff — <sub-project> (YYYY-MM-DD)

## State
Done: <what is finished and verified, with commit hashes>. Not done: <what is left>.

## Decisions made this session
- <decision> — recorded in <decisions file / overview log>

## Read first
1. <path> — <why>
2. <path> — <why>

## Next action
<one concrete step>

## Watch out for
- <gotcha discovered this session>
```

## Memory file

Memory holds facts that are true across sessions and cannot be derived from the repo: who the user is, feedback with
its reason, project facts, pointers. One fact per file, plus a one-line entry in the memory index.

```markdown
---
name: feedback-report-to-file
description: User wants subagent outputs saved to files with a short hand-back, because pasted reports filled the main context
metadata:
  type: feedback
---

Subagents write their full report to a file and hand back at most ~15 lines (status, verdict, serious issues, path).

**Why:** in one long session, subagent hand-backs were 15% of everything the main agent read, and the main context
compacted five times.

**How to apply:** every dispatch ends with the hand-back contract from the context-discipline skill; when a report
arrives longer than ~15 lines, ask for the file path instead of reading on.
```

Memory types: `user` (role, goals, preferences), `feedback` (a correction or confirmed approach, with **Why:** and
**How to apply:**), `project` (facts about the work not visible in the repo), `reference` (where something lives).

## What goes where

| Information | Home | Why there |
|---|---|---|
| "Always use the `github-workflow` skill for git work" | global CLAUDE.md | Stable rule for every project, one line |
| "Run tests with `make test`; never push to `main`" | project CLAUDE.md / AGENTS.md | Project rule, true for anyone working here |
| "User prefers one question per message during design" | memory (`feedback`, with Why) | About the user, holds across projects and sessions |
| "Training run 3 is on GPU 2, finishes Friday" | STATUS.md "Running now" | Changes daily; memory would go stale |
| "We chose method A over B on 3 Oct because of latency" | decisions file, then overview decision log | Dated history the spec and future sessions cite |
| How to release a package, step by step | a skill | A procedure reused across projects |
| A 40-line code review | `reviews/<date>-<topic>.md` | Read once by the implementer; the main agent needs only the verdict |
| Server password or API token | env var / askpass helper / password manager | Every file above is read into context or committed |
