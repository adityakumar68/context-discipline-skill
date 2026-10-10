# Evals

These evals check whether an agent follows the skill's checklist, not the scripts (the scripts are covered by
`tests/`). They do not measure context size or whether state survives a compaction; read the audit summary at the
top of [RESULTS.md](RESULTS.md) before using the numbers.

| File | What |
|---|---|
| `evals.json` | The three prompts, each with the expected outcome. `PROJECT_DIR` and `DECISIONS_FILE` are placeholders filled in at run time. |
| `files/decisions.md` | The decisions file eval 3 writes a spec from. |
| `grade_eval1.py` | Automatic checks for eval 1, assertions 1–4. |
| `RESULTS.md` | Pass counts, time and tokens, every assertion, and caveats. |

## How they were run

They follow the eval loop of Claude Code's `skill-creator` skill:

1. **Two runs per prompt.** A fresh subagent ran each prompt once with the skill ("with skill") and once without it
   ("without skill", the baseline). One run per configuration. With-skill prompts began by telling the agent to read
   the skill's SKILL.md and follow it. Baseline prompts said not to use the skill, but it was installed, so its
   description was in the skill listing.
2. **Eval 1 is a live run.** `PROJECT_DIR` was an empty, freshly `git init`ed folder in a temp directory. The agent
   really created its files there. It was told not to change global settings, the global CLAUDE.md or memory, and
   to write any such changes as a proposal instead.
3. **Evals 2 and 3 are dry runs.** A real survey or spec would take many minutes and launch further agents, so the
   agent instead wrote down what it would do: its steps, the exact prompts it would send to each subagent, and the
   reply it would give the user. `DECISIONS_FILE` was the absolute path of `files/decisions.md`.
4. **Grading.** For eval 1, `grade_eval1.py` checks the project folder (assertions 1–4). For assertion 5 and for
   evals 2 and 3, one LLM grader agent per iteration read the written plan and reply and marked each assertion pass
   or fail with a quoted piece of evidence. It knew which arm each run belonged to. The assertions are listed in
   `RESULTS.md`.
5. **Aggregation.** skill-creator's benchmark step combined the gradings with each run's time and token use into
   pass rates, means and standard deviations per configuration.

Iteration 2 re-ran only the with-skill side after edits to the skill and reused iteration 1's baseline.

What is published differs from what was run: the eval-2 prompt was reworded (a project name became "our project"),
`grade_eval1.py` was rewritten (same logic), and the skill has been edited and later rewritten since. The raw run
outputs and grading files are not published.

## Re-running them

1. Install the skill for the with-skill runs (`./install.sh` from the repo root). For the baseline, use a Claude
   Code config without it, for example a separate `CLAUDE_CONFIG_DIR`. Keep the baseline free of memory notes or
   CLAUDE.md rules that restate the skill's rules; the published baseline was not, which is the main caveat in
   `RESULTS.md`.
2. Fill the placeholders:
   ```bash
   P=$(mktemp -d)/notesync && mkdir -p "$P" && git -C "$P" init -q && echo "PROJECT_DIR=$P"
   echo "DECISIONS_FILE=$(cd evals/files && pwd)/decisions.md"
   ```
3. Run each prompt in `evals.json` in a fresh session or subagent, with and without the skill. For evals 2 and 3,
   ask for the dry-run form: the plan, the dispatch prompts and the reply to the user, written to files, with no
   searches or subagents launched.
4. Grade eval 1:
   ```bash
   python3 evals/grade_eval1.py --project "$P" --out grading.json
   ```
   then add assertion 5 by reading the reply. Grade evals 2 and 3 against the assertions in `RESULTS.md`, quoting
   evidence for each pass or fail.
5. Compare with `RESULTS.md`. With skill-creator installed you can instead ask Claude to run its eval loop on
   `context-discipline/` with `evals/evals.json`; it does steps 3–5 and shows the results side by side.

One run per configuration is noisy. For a result worth reading: run each configuration several times; use a
baseline config with no trace of the skill (not installed, no memory notes); let the skill trigger on its own
instead of telling the agent to read it; grade blind, with assertions that a different good approach can also pass;
and measure outcomes (context with `ctx-audit.py --json`, state after a compaction), not only the written plan.
