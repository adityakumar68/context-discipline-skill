#!/usr/bin/env python3
"""Programmatic checks for eval 1 (project brain setup), assertions 1-4.

Usage:
    python3 evals/grade_eval1.py --project <dir> --out <grading.json> [--hook <brain-hook.sh>]

<dir> is the project folder the eval run worked in (PROJECT_DIR in the prompt). The hook defaults to this repo's
context-discipline/scripts/brain-hook.sh, else the installed copy under $CLAUDE_CONFIG_DIR or ~/.claude.

Writes skill-creator's grading.json shape: {"expectations": [{text, passed, evidence}], "summary": {...}}.
Assertion 5 (what the reply tells the user about memory vs CLAUDE.md vs STATUS) needs a reader; add it to the
file by hand or with a grader agent. The check for assertion 4 creates an empty <dir>/src/deep to run the hook from
a subfolder.
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

PROJECT_WORDS = re.compile(r"(?i)obsidian|static site")


def default_hook():
    repo = Path(__file__).resolve().parent.parent / "context-discipline" / "scripts" / "brain-hook.sh"
    if repo.is_file():
        return repo
    config = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    return config / "skills" / "context-discipline" / "scripts" / "brain-hook.sh"


def project_files(proj, pattern):
    """Yield files under proj whose name matches pattern, skipping .git."""
    for root, dirs, files in os.walk(proj):
        dirs[:] = [d for d in dirs if d != ".git"]
        for f in files:
            if re.search(pattern, f):
                yield os.path.join(root, f)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def check(proj, hook):
    res = []

    # 1. pointer names an existing STATUS file
    ptr = os.path.join(proj, ".claude", "brain")
    status = None
    if os.path.isfile(ptr):
        line = next((l.strip() for l in read(ptr).splitlines() if l.strip() and not l.lstrip().startswith("#")), "")
        cand = os.path.expanduser(line) if line.startswith("~/") else line
        cand = cand if os.path.isabs(cand) else os.path.join(proj, cand)
        status = cand if line and os.path.isfile(cand) else None
    res.append(("A .claude/brain pointer exists in the project and names an existing STATUS file",
                status is not None, f"pointer={os.path.isfile(ptr)} status={status}"))

    # 2. STATUS (the pointer's target, else any STATUS.md) is small and project-specific
    if status is None:
        status = next(project_files(proj, r"(?i)^status\.md$"), None)
    ok2, ev2 = False, "no STATUS file"
    if status:
        txt = read(status)
        size = len(txt.encode())
        specific = bool(PROJECT_WORDS.search(txt))
        ok2 = size < 10000 and specific
        ev2 = f"{os.path.relpath(status, proj)}: {size} bytes, project-specific={specific}"
    res.append(("The STATUS file is under 10,000 bytes and has project-specific content "
                "(mentions Obsidian or the static site)", ok2, ev2))

    # 3. an overview doc with a dated decision log
    ok3, ev3 = False, "no overview with a decision log"
    for path in project_files(proj, r"\.md$"):
        t = read(path)
        if re.search(r"(?i)decision", t) and re.search(r"\d{4}-\d{2}-\d{2}", t) \
                and re.search(r"(?i)overview|big picture|architecture", t):
            ok3, ev3 = True, os.path.relpath(path, proj)
            break
    res.append(("A big-picture/overview doc with a dated decision log exists", ok3, ev3))

    # 4. the hook, run from a subfolder, prints the STATUS content
    sub = os.path.join(proj, "src", "deep")
    os.makedirs(sub, exist_ok=True)
    out = subprocess.run(["bash", str(hook)], input=json.dumps({"cwd": sub, "source": "startup"}),
                         capture_output=True, text=True).stdout
    res.append(("brain-hook.sh run with cwd set to a project subfolder prints the STATUS content "
                "(automatic loading works)", len(out) > 200, f"hook printed {len(out)} chars"))
    return res


def main():
    ap = argparse.ArgumentParser(description="Check eval 1 assertions 1-4 against a project folder.")
    ap.add_argument("--project", required=True, help="the project folder the eval run set up (PROJECT_DIR)")
    ap.add_argument("--out", required=True, help="where to write the grading JSON")
    ap.add_argument("--hook", help="brain-hook.sh to test with (default: this repo's, else the installed one)")
    args = ap.parse_args()

    proj = os.path.abspath(args.project)
    if not os.path.isdir(proj):
        sys.exit(f"not a directory: {proj}")
    hook = Path(args.hook) if args.hook else default_hook()
    if not hook.is_file():
        sys.exit(f"brain-hook.sh not found: {hook} (pass --hook)")

    exp = [{"text": t, "passed": p, "evidence": e} for t, p, e in check(proj, hook)]
    passed = sum(x["passed"] for x in exp)
    result = {"expectations": exp,
              "summary": {"passed": passed, "failed": len(exp) - passed, "total": len(exp),
                          "pass_rate": round(passed / len(exp), 2)}}
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=1)
    for x in exp:
        print(("PASS " if x["passed"] else "FAIL ") + x["text"])
    print(f"{passed}/{len(exp)} automatic checks passed; assertion 5 still needs a reader. Wrote {args.out}")


if __name__ == "__main__":
    main()
