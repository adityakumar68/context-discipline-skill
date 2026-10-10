# Eval results

Three prompts (in `evals.json`), each run once with the skill and once without, then graded against 5–6 assertions.
Iteration 2 re-ran only the with-skill side after edits to the skill; its baseline is iteration 1's without-skill
run. How the runs were made and graded: [README.md](README.md).

## Pass counts

| Eval | Iteration 1, with skill | Iteration 1, without skill (baseline) | Iteration 2, with skill |
|---|---|---|---|
| 1. Project brain setup (live run) | 4 / 5 | 2 / 5 | 4 / 5 |
| 2. Related-work survey (dry run) | 6 / 6 | 5 / 6 | 6 / 6 |
| 3. Spec from a decisions file (dry run) | 5 / 5 | 1 / 5 | 5 / 5 |
| **Mean pass rate** (mean of the three per-eval rates) | **93.3%** | **47.7%** | **93.3%** |

The baseline mean is the benchmark's figure, computed from per-eval rates rounded to two decimals (0.40, 0.83,
0.20); unrounded it is 47.8%. Counting assertions instead of averaging rates: 15 of 16 with the skill, 8 of 16
without.

## Time and tokens per run

Mean ± standard deviation over the three evals (one run each), as reported by the benchmark.

| | Iteration 1, with skill | Without skill (baseline) | Iteration 2, with skill |
|---|---|---|---|
| Time per run | 196.1 s ± 65.0 | 160.7 s ± 60.5 | 161.0 s ± 44.5 |
| Tokens per run | 73,269 ± 12,715 | 60,241 ± 13,127 | 69,091 ± 11,643 |

Per run:

| Eval | Iteration 1, with skill | Without skill | Iteration 2, with skill |
|---|---|---|---|
| 1 | 164.5 s, 72,113 tokens | 201.5 s, 65,881 tokens | 128.5 s, 63,272 tokens |
| 2 | 270.9 s, 86,523 tokens | 189.5 s, 69,605 tokens | 211.8 s, 82,496 tokens |
| 3 | 153.0 s, 61,172 tokens | 91.2 s, 45,236 tokens | 142.8 s, 61,504 tokens |

The skill costs more per run: +13,029 tokens and +35.4 s on average in iteration 1, +8,850 tokens and +0.3 s in
iteration 2. These are the eval runs' own costs, not the context the skill saves later in a long session.

## Assertions

Results are listed as iteration 1 with skill / without skill / iteration 2 with skill.

### Eval 1: project brain setup

| # | Assertion | Results |
|---|---|---|
| 1 | A `.claude/brain` pointer exists in the project and names an existing STATUS file | pass / fail / pass |
| 2 | The STATUS file is under 10,000 bytes and has project-specific content (mentions Obsidian or the static site) | pass / pass / pass |
| 3 | A big-picture/overview doc with a dated decision log exists | pass / pass / pass |
| 4 | `brain-hook.sh` run with cwd set to a project subfolder prints the STATUS content (automatic loading works) | pass / fail / pass |
| 5 | The reply tells the user what goes in memory vs CLAUDE.md vs STATUS/overview | fail / fail / fail |

Assertions 1–4 are checked by `grade_eval1.py`; assertion 5 by reading the reply.

### Eval 2: related-work survey

| # | Assertion | Results |
|---|---|---|
| 1 | The survey is delegated to a subagent; the main agent does not run the web searches itself | pass / pass / pass |
| 2 | The dispatch tells the subagent to write the full findings (sources, citations) to a named file | pass / pass / pass |
| 3 | The dispatch caps the hand-back with an explicit small line limit (about 20 lines or fewer) | pass / pass / pass |
| 4 | The chosen agent type can write files (not Explore or Plan) | pass / pass / pass |
| 5 | The dispatch forbids sending the user's email or private data to external services | pass / fail / pass |
| 6 | The main agent plans to use the short hand-back (and at most narrow reads), not read the whole survey file | pass / pass / pass |

### Eval 3: spec from a decisions file

| # | Assertion | Results |
|---|---|---|
| 1 | A subagent drafts the spec; the main agent does not write the spec file itself | pass / fail / pass |
| 2 | The decisions file (and context brief) are passed to the subagent as paths, not pasted | pass / fail / pass |
| 3 | The dispatch caps the hand-back with an explicit small line limit (about 20 lines or fewer) | pass / fail / pass |
| 4 | The main agent checks the draft with grep or narrow reads, not a whole-file Read | pass / fail / pass |
| 5 | The user is asked to review the spec file at a named path | pass / pass / pass |

## Caveats

- **n = 1 per configuration.** Each eval ran once per configuration. The ± figures are spread across the three
  evals, not across repeated runs, so they say nothing about run-to-run variance.
- **Eval 2 is not a clean A/B.** The baseline run read a project memory that already held rules similar to this
  skill's (deliverables in files, short hand-backs), so its 5 / 6 overstates what an agent does with no such
  rules.
- **Eval 1's baseline was also not clean.** It used the term "project brain", which suggests the same kind of
  contamination. It also built a different mechanism, a project-level SessionStart hook that does print STATUS,
  so assertions 1 and 4 (which test for the pointer and the global hook) under-credit it.
- **Eval 1's last assertion fails in both iterations** because the test forbade memory changes: the with-skill runs
  put their memory reasoning in a proposal file instead of the reply.
- **Evals 2 and 3 are dry runs.** They grade a written plan (steps, dispatch prompts, the reply to the user), not a
  live run, so they show what the agent intends to do, not that its subagents then behave.
- **Lenient passes.** In iteration 1, eval 3 assertion 2 passed although the dispatch restated most decision
  values next to the path; iteration 2's dispatch referred to decisions by id only. Eval 1 assertion 3's automatic
  check cited STATUS.md, while the dated decision log was in the overview file; the pass stands.
