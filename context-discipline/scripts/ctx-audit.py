#!/usr/bin/env python3
"""ctx-audit.py -- what filled a Claude Code session's context?

Usage:
    ctx-audit.py <transcript.jsonl | project-transcript-dir> [--top N] [--include-sidechains]

Transcripts live at ~/.claude/projects/<cwd with "/" turned into "-">/<session-id>.jsonl.
Given a directory, the newest *.jsonl in it is used. Subagent transcripts sit beside it in
<session-id>/subagents/agent-*.jsonl; audit one of those with --include-sidechains.

Estimates (chars / 4) the tokens that passed through the main thread, by category:
tool_use input per tool ("Bash input", "Write input", "Agent prompt", ...), tool_result per
tool ("Bash output", "Read output", "Agent hand-back", ...), assistant text and visible
thinking, typed user text, skill texts, hook output, system reminders, compaction
summaries, and images (counted at a flat ~1,600 tokens each). Each item is counted once,
when it enters the context; it is then re-read on every later turn until a compaction.

Prints a table sorted by share, then the N largest single items with short previews.
Previews that look like credentials are redacted. Standard library only; unknown record
shapes are skipped and counted, never fatal.
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict

IMAGE_TOKENS = 1600  # rough per-image cost; base64 size does not map to pixels
PREVIEW_CHARS = 60

# Checked against the preview window only; over-redaction is the safe failure.
SECRET_RE = re.compile(
    r"(pass(word|wd|phrase)?\b|secret|api[_-]?key|access[_-]?key|bearer|authorization|"
    r"credential|private[_ -]?key|sshpass|askpass|BEGIN [A-Z ]*KEY|"
    r"\btoken\s*[=:]|(auth|access|refresh|api|github|gh|hf)[_ -]?token|"
    r"\bsk-[A-Za-z0-9]|\bghp_|\bgho_|github_pat_|\bxox[bp]-|\bAKIA[0-9A-Z]{8}|\bAIza|"
    r"[\w.+-]+@[\w-]+\.[\w.-]+|\b\d{1,3}(\.\d{1,3}){3}\b|"
    r"(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{32,})",
    re.IGNORECASE,
)


def est(chars):
    return chars / 4.0


def text_of(obj):
    """Concatenate every string reachable inside obj (skips base64 image data)."""
    out = []

    def walk(x):
        if isinstance(x, str):
            out.append(x)
        elif isinstance(x, list):
            for y in x:
                walk(y)
        elif isinstance(x, dict):
            if x.get("type") == "image":
                return
            for k, v in x.items():
                if k in ("signature", "data", "media_type", "type", "tool_use_id", "id"):
                    continue
                walk(v)

    walk(obj)
    return "\n".join(out)


def images_in(obj):
    """Return (count, base64 chars) of image blocks inside obj."""
    count, size = 0, 0
    stack = [obj]
    while stack:
        x = stack.pop()
        if isinstance(x, list):
            stack.extend(x)
        elif isinstance(x, dict):
            if x.get("type") == "image":
                count += 1
                src = x.get("source")
                if isinstance(src, dict) and isinstance(src.get("data"), str):
                    size += len(src["data"])
            else:
                stack.extend(v for v in x.values() if isinstance(v, (list, dict)))
    return count, size


def preview(s):
    s = " ".join(str(s)[: PREVIEW_CHARS * 8].split())
    window = s[: PREVIEW_CHARS * 2]
    if SECRET_RE.search(window):
        return "[preview redacted: may contain a credential or address]"
    return s[:PREVIEW_CHARS] + ("..." if len(s) > PREVIEW_CHARS else "")


class Audit:
    def __init__(self, top):
        self.chars = defaultdict(int)
        self.items = defaultdict(int)
        self.largest = []  # (chars, category, preview)
        self.top = top
        self.tool_names = {}  # tool_use_id -> tool name
        self.images = 0
        self.image_b64 = 0
        self.redacted_thinking = 0
        self.compactions = 0
        self.skipped = 0
        self.sidechain_skipped = 0
        self.records = 0

    def add(self, category, text):
        n = len(text) if isinstance(text, str) else len(text_of(text))
        if n == 0:
            return
        self.chars[category] += n
        self.items[category] += 1
        self.largest.append((n, category, text if isinstance(text, str) else text_of(text)))
        if len(self.largest) > self.top * 20:
            self.largest.sort(key=lambda t: -t[0])
            del self.largest[self.top * 5:]

    def add_images(self, obj):
        c, size = images_in(obj)
        if c:
            self.images += c
            self.image_b64 += size
            self.chars["Images"] += c * IMAGE_TOKENS * 4
            self.items["Images"] += c

    # ---- record handlers -------------------------------------------------

    def record(self, r, include_sidechains):
        self.records += 1
        if not isinstance(r, dict):
            self.skipped += 1
            return
        if r.get("isSidechain") and not include_sidechains:
            self.sidechain_skipped += 1
            return
        t = r.get("type")
        if t == "assistant":
            self.assistant(r)
        elif t == "user":
            self.user(r)
        elif t == "attachment":
            self.attachment(r)
        elif t == "system":
            self.system(r)
        # every other record type (titles, modes, snapshots, queue ops...) is UI state

    def assistant(self, r):
        msg = r.get("message") or {}
        content = msg.get("content")
        if isinstance(content, str):
            self.add("Assistant text", content)
            return
        for b in content or []:
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "text":
                self.add("Assistant text", b.get("text") or "")
            elif bt == "thinking":
                th = b.get("thinking") or ""
                if th:
                    self.add("Assistant thinking (visible)", th)
                else:
                    self.redacted_thinking += 1
            elif bt == "redacted_thinking":
                self.redacted_thinking += 1
            elif bt in ("tool_use", "server_tool_use"):
                name = b.get("name") or "unknown-tool"
                if b.get("id"):
                    self.tool_names[b["id"]] = name
                label = "Agent prompt" if name in ("Agent", "Task") else f"{name} input"
                self.add(label, json.dumps(b.get("input"), ensure_ascii=False))
            else:
                self.add("Assistant other blocks", text_of(b))

    def user(self, r):
        msg = r.get("message") or {}
        content = msg.get("content")
        if r.get("isCompactSummary"):
            self.add("Compaction summary", text_of(content))
            return
        if isinstance(content, str):
            self.add(self.classify_user_text(r, content), content)
            return
        for b in content or []:
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "tool_result":
                name = self.tool_names.get(b.get("tool_use_id"), "unknown-tool")
                if name in ("Agent", "Task"):
                    label = "Agent hand-back"
                else:
                    label = f"{name} output"
                self.add(label, text_of(b.get("content")))
                self.add_images(b.get("content"))
            elif bt == "image":
                self.add_images(b)
            elif bt == "text":
                txt = b.get("text") or ""
                self.add(self.classify_user_text(r, txt), txt)
            else:
                self.add("User other blocks", text_of(b))

    def classify_user_text(self, r, s):
        head = s[:400]
        origin = r.get("origin") if isinstance(r.get("origin"), dict) else {}
        if "<task-notification" in head:
            return "Agent task notices"
        if origin.get("kind") == "peer" or "<agent-message" in head:
            return "Agent hand-back"
        if s.startswith("Base directory for this skill") or s.startswith("(Re-invocation of /") \
                or s.startswith("Skill /") or (r.get("isMeta") and r.get("sourceToolUseID")):
            return "Skill texts"
        if "<local-command-stdout>" in head or "<local-command-caveat>" in head \
                or s.startswith("## Context Usage"):
            return "Local command output"
        if r.get("isMeta") or s.lstrip().startswith("<system-reminder>"):
            return "System reminders / injected"
        return "User typed text"

    def attachment(self, r):
        # Only attachments with a "rendered" form are put into the model's context.
        if "rendered" not in r:
            return
        a = r.get("attachment") if isinstance(r.get("attachment"), dict) else {}
        kind = a.get("type") or "unknown"
        txt = text_of(r.get("rendered"))
        if kind == "invoked_skills":
            label = "Skill texts re-injected (compact)"
        elif kind == "skill_listing":
            label = "Skill listing"
        elif kind.startswith("hook"):
            label = "Hook output"
        elif kind in ("instructions", "nested_memory", "claude_md"):
            label = "CLAUDE.md / instructions"
        elif kind in ("file", "edited_text_file", "compact_file_reference", "directory"):
            label = "Injected file contents"
        elif kind == "queued_command":
            origin = a.get("origin") if isinstance(a.get("origin"), dict) else {}
            head = txt[:600]
            if "<task-notification" in head:
                label = "Agent task notices"
            elif origin.get("kind") == "peer" or "<agent-message" in head:
                label = "Agent hand-back"
            elif origin.get("kind") == "human":
                label = "User typed text"
            else:
                label = "System reminders / injected"
        else:
            label = "System reminders / injected"
        self.add(label, txt)
        self.add_images(r.get("rendered"))

    def system(self, r):
        st = r.get("subtype")
        if st == "compact_boundary":
            self.compactions += 1
        elif st == "local_command" and r.get("content"):
            self.add("Local command output", text_of(r.get("content")))
        # other system records (durations, summaries for the UI, bridge status) are not model input

    # ---- report --------------------------------------------------------------

    def report(self, path):
        total = sum(self.chars.values())
        lines = []
        lines.append(f"Transcript: {os.path.basename(path)}  ({os.path.getsize(path) / 1e6:.1f} MB, "
                     f"{self.records} records)")
        lines.append(f"Main-thread input estimate: ~{est(total) / 1e6:.2f}M tokens (chars/4)  |  "
                     f"compactions: {self.compactions}  |  images: {self.images} "
                     f"(~{self.image_b64 / 1e6:.1f} MB base64, counted at ~{IMAGE_TOKENS} tokens each)")
        if self.redacted_thinking:
            lines.append(f"Thinking blocks with hidden text (not counted): {self.redacted_thinking}")
        if self.sidechain_skipped:
            lines.append(f"Sidechain (subagent) records skipped: {self.sidechain_skipped} "
                         f"(use --include-sidechains to count them)")
        if self.skipped:
            lines.append(f"Unrecognised records skipped: {self.skipped}")
        lines.append("")
        w = max([len(c) for c in self.chars] + [8])
        lines.append(f"{'Category':<{w}}  {'~tokens':>10}  {'share':>6}  {'items':>6}")
        lines.append(f"{'-' * w}  {'-' * 10}  {'-' * 6}  {'-' * 6}")
        for cat, n in sorted(self.chars.items(), key=lambda kv: -kv[1]):
            share = 100.0 * n / total if total else 0.0
            lines.append(f"{cat:<{w}}  {est(n):>10,.0f}  {share:>5.1f}%  {self.items[cat]:>6}")
        lines.append("")
        lines.append(f"Top {self.top} single largest items:")
        self.largest.sort(key=lambda t: -t[0])
        for i, (n, cat, txt) in enumerate(self.largest[: self.top], 1):
            lines.append(f"{i:>3}. {cat:<{w}}  ~{est(n):>8,.0f}  {preview(txt)}")
        return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="Estimate what filled a Claude Code session's context.")
    ap.add_argument("transcript", help="session .jsonl, or a project transcript directory (newest file used)")
    ap.add_argument("--top", type=int, default=10, help="how many single largest items to list (default 10)")
    ap.add_argument("--include-sidechains", action="store_true",
                    help="also count subagent (sidechain) records found in this file")
    args = ap.parse_args()

    path = os.path.expanduser(args.transcript)
    if os.path.isdir(path):
        files = [os.path.join(path, f) for f in os.listdir(path) if f.endswith(".jsonl")]
        if not files:
            sys.exit(f"no .jsonl files in {path}")
        path = max(files, key=os.path.getmtime)
    if not os.path.isfile(path):
        sys.exit(f"not a file: {path}")

    audit = Audit(max(1, args.top))
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                audit.skipped += 1
                continue
            try:
                audit.record(r, args.include_sidechains)
            except Exception:  # unknown shapes must never stop the audit
                audit.skipped += 1
    print(audit.report(path))


if __name__ == "__main__":
    main()
