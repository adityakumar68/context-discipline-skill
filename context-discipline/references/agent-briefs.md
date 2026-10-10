# Agent briefs

Copy-ready dispatch prompts. Fill the `<angle-bracket>` slots, keep inputs as paths, and keep the hand-back contract
and constraints blocks in every brief: they are what keeps the reply small. Choose an agent type that can write files
(general-purpose, or any type with Write); read-only types such as Explore and Plan cannot save their output. Use the
model the user's rules name for subagents.

Contents: hand-back contract · constraints · research/survey · context brief · spec drafter · plan drafter ·
implementer · reviewer · fact-checker/verifier.

## Hand-back contract (paste into any dispatch)

```text
Hand-back contract: write your full output to <OUTPUT_PATH> (create the folder if needed). Your reply to me
is at most 15 lines:
  1. Status: DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
  2. Verdict or answer, one or two lines
  3. Critical and Important items, one line each ("none" if none)
  4. The output path
The file carries the content; the reply carries pointers. If you are blocked, say what you need in one line.
The file is the deliverable itself (survey, review, brief, draft). A summary of your own work goes in the reply,
not in a separate file; if any write is refused, still reply within 15 lines and name the refused path.
```

Why the last two lines: Claude Code refuses some subagent writes that look like a report about the agent's own
work ("Subagents should return findings as text, not write report files"), while deliverables such as a survey,
review or spec draft write fine. An agent that hits the refusal tends to paste its whole report into the reply,
which is exactly the cost the contract exists to avoid.

## Constraints (paste and adjust)

```text
Constraints:
- Work only in <ALLOWED_PATHS>. Read anything else you need; change nothing outside them.
- Keep the user's email, names, file contents and other private data out of web searches, fetches and any
  external service.
- Never print or copy secrets (passwords, tokens, keys); refer to them by the env var or helper that holds them.
- Run long commands with output piped through tail/grep or into a log file.
```

## Research / survey agent

```text
You are a research agent surveying <TOPIC> for <PURPOSE, one line>.

Inputs (read these first): <PATH to question or decisions file>, <PATH to prior notes, if any>.

Task: find what is known about <SPECIFIC QUESTIONS 1-3>. Prefer primary sources (papers, official docs, source
code) over blog posts. For each claim record the source (title, authors or org, year, URL or arXiv id) and how
confident you are (high / medium / low, with the reason).

Output file <OUTPUT_PATH> with sections: Summary (5-10 lines) · Findings (claim → source → confidence) ·
Comparison table if several options · What was searched and not found · Open questions.

<HAND-BACK CONTRACT>
<CONSTRAINTS>
```

## Context-brief agent

Used before a design discussion, so the main agent learns the interfaces without reading the code.

```text
You are a context agent preparing a brief for a later design discussion about <FEATURE / CHANGE>.

Inputs: the code or docs under <PATHS>; the goal in <PATH to decisions file or one-line goal>.

Task: read the area and summarise what a designer needs: entry points, public interfaces and their signatures,
data formats, configuration, tests that pin behaviour, known constraints and smells. Cite file:line for each
item. Summarise; quote code only where the exact text matters.

Output file <OUTPUT_PATH>, at most ~150 lines: Overview · Interfaces (file:line) · Data and config · Tests ·
Constraints and risks · Questions the design must answer.

<HAND-BACK CONTRACT>
<CONSTRAINTS>
```

## Spec drafter

```text
You are drafting a design spec for <FEATURE>.

Inputs: decisions file <PATH> (every decision is final unless marked open), context brief <PATH>,
<PATH to spec template or an earlier spec to match in style>.

Task: write the spec so an implementer who never saw the design conversation can build it. Every decision in
the decisions file appears in the spec (cite its id, e.g. D4). Where the decisions leave a gap, choose the
simplest option and list it under "Assumptions for the user to confirm".

Output file <OUTPUT_PATH> with sections: Goal · Non-goals · Design (components, interfaces, data flow) ·
Error handling · Testing approach · Assumptions for the user to confirm · Decision coverage (D1..Dn → section).

In the hand-back, list the assumptions as one-liners.
<HAND-BACK CONTRACT>
<CONSTRAINTS>
```

## Plan drafter

```text
You are writing an implementation plan for the approved spec <PATH>.

Inputs: spec <PATH>, context brief <PATH>, <PATH to plan template, e.g. the writing-plans skill's format>.

Task: break the work into small tasks that each end in a passing test and a commit: exact files to create or
modify, the test to write first, the commands to run, the expected result. Order tasks so each builds on
committed work. Flag any spec ambiguity instead of guessing.

Output file <OUTPUT_PATH>. Hand back the task count, the riskiest task, and any spec ambiguities.
<HAND-BACK CONTRACT>
<CONSTRAINTS>
```

## Implementer

```text
You are implementing task <N> of the plan <PATH> ("<task title>").

Inputs: plan <PATH> (read only task <N> and anything it references), spec <PATH>, <PATH to a review file if this
is a fix round>. If the superpowers subagent-driven-development skill is available, follow its implementer
process (test first, small commits, self-review).

Task: implement task <N> exactly as written; on a fix round, fix every Critical and Important item in the review.
Run the tests named in the plan.

The record of the work is the commits plus a test log: run the tests with output redirected to <LOG_PATH>
(e.g. `pytest ... > <LOG_PATH> 2>&1; tail -n 5 <LOG_PATH>`), so long test output never lands in a reply.

Hand back (at most 15 lines): status, commit hashes, one-line test summary (e.g. "42 passed, 0 failed"),
deviations from the plan and why, concerns one line each, the log path.
<HAND-BACK CONTRACT>
<CONSTRAINTS>
```

## Reviewer

```text
You are reviewing <the changes in commits BASE..HEAD | branch X | task N> against spec <PATH> and plan <PATH>.

Task, two passes:
1. Spec compliance: is every requirement of <spec sections / task N> implemented, and nothing extra?
2. Quality: correctness, error handling, tests that would catch a regression, readability, security.
Cite file:line for every finding. Severity: Critical (wrong or unsafe; must fix), Important (should fix before
merge), Minor (optional).

Output file <OUTPUT_PATH>: Verdict (APPROVE / CHANGES_REQUESTED) · Critical · Important · Minor · What was checked.

Hand back the verdict and Critical/Important items as one-liners with file:line; leave Minor items in the file.
<HAND-BACK CONTRACT>
<CONSTRAINTS>
```

## Fact-checker / verifier

```text
You are verifying claims in <PATH> (a report, spec, STATUS.md or draft) before they are relied on.

Task: for each factual claim in <SECTIONS or "all">, check it against the primary source (code, logs, data, the
cited paper or doc) and mark it Confirmed / Wrong (with the correct value and source) / Unverifiable (why).
Rerun cheap commands to confirm numbers; do not rerun anything expensive or destructive.

Output file <OUTPUT_PATH>: a table claim → verdict → evidence (file:line, command output, URL).

Hand back counts (confirmed / wrong / unverifiable) and every Wrong claim as a one-liner.
<HAND-BACK CONTRACT>
<CONSTRAINTS>
```
