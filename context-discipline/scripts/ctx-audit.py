#!/usr/bin/env python3
"""ctx-audit.py -- how full did a Claude Code session's context get, and with what?

Usage:
    ctx-audit.py <transcript.jsonl | project-transcript-dir> [--top N] [--include-sidechains] [--json]

Transcripts live at ~/.claude/projects/<cwd with "/" turned into "-">/<session-id>.jsonl. Given a
directory, the newest *.jsonl in it is used. The session's subagent transcripts,
<session-id>/subagents/agent-*.jsonl, are read too. A subagent file can also be audited on its own.

MEASURED (exact): Claude Code saves the API usage of every call on its assistant messages.
  context of a call = input_tokens + cache_creation_input_tokens + cache_read_input_tokens
From these: peak context, final context, context before and after each compaction, number of
compactions, total input (context summed over all calls: everything sent, cached or not), output
tokens. Reported for the main thread, for subagents (each one, and summed) and combined.
  - One call is often saved as several records (one per content block) with the same message id.
    Each call counts once: input fields from any of its records, output from the largest value.
  - Not calls: records from model "<synthetic>" (notices made by Claude Code), records with zero
    context, and records a compaction copied in from before it (compactMetadata.preservedMessages).
  - A fork copies its parent's records. A call found in several files counts once, for the file read
    first: the main thread, then subagents that are not forks, then forks.
  - Output is exact only when a record of the call carries a stop_reason. Subagent files often keep
    only the record written as the reply started, whose output_tokens is the count so far; such calls
    are counted in output_incomplete_calls, and output_tokens is then a lower bound. Input-side
    numbers are complete at the start of a reply, so context figures are not affected.

ESTIMATED (chars / 4): which visible content filled the context, by category -- tool input per tool
("Bash input", "Agent prompt", ...), tool output per tool ("Read output", "Agent hand-back", ...),
assistant text and visible thinking, typed user text, skill texts, hook output, system reminders,
compaction summaries, images (~1,600 tokens each). Every call resends the context, but Claude Code
clears older tool outputs before it compacts, so saved content can leave the context earlier.
The estimate is therefore taken per segment (the stretch between two compactions) at the call with
the segment's peak context: content saved before that call, plus the messages a compaction kept.
The measured context of those calls (sum of segment peaks) minus the estimate is the row
"[not in transcript]": system prompt, tool schemas, thinking that is sent back but saved without its
text, and estimate error. It is negative when the estimate is above the measurement (for example
after tool outputs were cleared). Shares are of the measured context and add up to 100%. Without
usage records (old transcripts) shares are of the visible estimate and there is no remainder row.
By default the table covers the main thread; --include-sidechains adds the subagents' content.

--json prints one JSON object instead of the text report. The text layout may change; the JSON
schema changes only together with schema_version. Schema (version 1); counts are integers, null
means there was no API call to measure:
{
  "schema_version": 1,
  "transcript": {"file": str (base name), "bytes": int, "records": int (lines in the main file),
                 "skipped_records": int (unreadable or unrecognised, all files),
                 "subagent_files": int},
  "main": Thread,
  "subagents": Totals + {"count": int (subagent threads found),
                         "agents": [Thread + {"id": str (file name without .jsonl, or "inline:<agentId>"
                                                         for subagent records inside the main file),
                                              "agent_type": str|null (from <id>.meta.json)}]},
  "combined": Totals (main + subagents; peak_context is the largest single context),
  "categories": {
    "threads": "main" | "main+subagents",
    "basis": "measured" | "visible-only",
    "measured_context": int|null (sum, over segments with calls, of the segment's peak context),
    "visible_estimate": int (chars/4 of the visible content counted at those peaks),
    "not_in_transcript": int|null (measured_context - visible_estimate; may be negative),
    "thinking_before_peaks": int|null (thinking output tokens, from usage, of the calls before each of
              those peaks; the text is not saved, so this is the most of not_in_transcript that can be
              thinking: all of it if Claude Code sends every earlier thinking block back),
    "rows": [{"category": str, "tokens": int, "share": float (percent of measured_context, or of
              visible_estimate when basis is "visible-only"), "items": int|null (items that entered,
              each counted once; null for the remainder row)}], largest first; includes the
              "[not in transcript]" row when basis is "measured",
    "largest": [{"category": str, "tokens": int}] (the --top largest single items; no text)
  },
  "thinking_blocks_without_text": int,
  "images": {"count": int, "base64_bytes": int}
}
Totals = {"calls": int, "peak_context": int|null, "total_input": int, "input_tokens": int,
          "cache_creation_input_tokens": int, "cache_read_input_tokens": int, "output_tokens": int,
          "thinking_output_tokens": int|null (usage.output_tokens_details, when saved),
          "output_incomplete_calls": int (calls with no stop_reason saved: their output is a lower bound),
          "compaction_count": int}
Thread = Totals + {
  "final_context": int|null,
  "compactions": [{"context_before": int|null (last call before it), "context_after": int|null (first
                   call after it), "pre_tokens": int|null, "post_tokens": int|null, "trigger": str|null
                   (the last three as Claude Code recorded them in compactMetadata)}],
  "segments": [{"calls": int, "first_context": int|null, "peak_context": int|null,
                "last_context": int|null}] (one per stretch between compactions, in order),
  "context_drops": int (calls whose context fell by >= 10% and >= 2,000 tokens with no compaction
                        between: older tool outputs were cleared),
  "carried_over_records": int (records a compaction copied in; not counted as calls)}

Previews that look like credentials are redacted. Standard library only (Python 3.9+). Unknown
record shapes are skipped and counted, never fatal.
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict

SCHEMA_VERSION = 1
IMAGE_TOKENS = 1600  # rough per-image cost; base64 size does not map to pixels
PREVIEW_CHARS = 60
DROP_MIN_TOKENS = 2000
DROP_MIN_FRACTION = 0.10
SYNTHETIC_MODEL = "<synthetic>"
REMAINDER = "[not in transcript]"
CONTEXT_KEYS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
MAX_COMPACTION_LINES = 12

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


def num(x):
    """A usage count as a non-negative int (missing or odd values count as 0)."""
    if isinstance(x, bool) or not isinstance(x, (int, float)) or x <= 0:
        return 0
    return int(x)


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


def fmt(n):
    return "-" if n is None else f"{n:,}"


# ---- measured usage -----------------------------------------------------------


class Call:
    __slots__ = ("inp", "cw", "cr", "out", "thinking", "final")

    def __init__(self, inp, cw, cr, out, thinking, final):
        self.inp, self.cw, self.cr, self.out, self.thinking = inp, cw, cr, out, thinking
        self.final = final  # a record with the final usage (it has a stop_reason) was saved

    @property
    def ctx(self):
        return self.inp + self.cw + self.cr


class Segment:
    """The stretch of a thread between two compactions."""

    def __init__(self):
        self.calls = []
        self.peak = 0
        self.peak_index = 0  # position of the peak call in calls
        self.chars = defaultdict(int)  # visible content saved so far in this segment
        self.at_peak = None  # copy of chars taken at the peak call


class Thread:
    def __init__(self, name, agent_type=None, categories=True):
        self.name = name
        self.agent_type = agent_type
        self.categories = categories  # collect visible content for the category table?
        self.segments = [Segment()]
        self.compactions = []
        self.carried = set()  # uuids the latest compaction kept
        self.carried_over = 0
        self.drops = 0
        self.items = defaultdict(int)
        self.by_uuid = {}  # uuid -> [(category, chars)], to count kept messages again

    @property
    def seg(self):
        return self.segments[-1]

    def calls(self):
        return [c for s in self.segments for c in s.calls]

    def add_call(self, call):
        seg = self.seg
        if seg.calls:
            prev = seg.calls[-1].ctx
            if prev - call.ctx >= max(DROP_MIN_TOKENS, DROP_MIN_FRACTION * prev):
                self.drops += 1
        seg.calls.append(call)
        if call.ctx > seg.peak:
            seg.peak = call.ctx
            seg.peak_index = len(seg.calls) - 1
            if self.categories:
                seg.at_peak = dict(seg.chars)

    def compact(self, meta):
        meta = meta if isinstance(meta, dict) else {}
        kept = meta.get("preservedMessages")
        kept = kept if isinstance(kept, dict) else {}
        uuids = kept.get("allUuids") or kept.get("uuids") or []
        uuids = [u for u in uuids if isinstance(u, str)] if isinstance(uuids, list) else []
        calls = self.seg.calls
        self.compactions.append({
            "context_before": calls[-1].ctx if calls else None,
            "pre_tokens": meta.get("preTokens") if isinstance(meta.get("preTokens"), int) else None,
            "post_tokens": meta.get("postTokens") if isinstance(meta.get("postTokens"), int) else None,
            "trigger": meta.get("trigger") if isinstance(meta.get("trigger"), str) else None,
        })
        self.segments.append(Segment())
        self.carried = set(uuids)
        if self.categories:
            for u in uuids:
                for cat, n in self.by_uuid.get(u, ()):
                    self.seg.chars[cat] += n

    def as_json(self):
        calls = self.calls()
        d = totals(calls, len(self.compactions))
        d["final_context"] = calls[-1].ctx if calls else None
        comps = []
        for i, c in enumerate(self.compactions):
            after = self.segments[i + 1].calls
            comps.append({"context_before": c["context_before"],
                          "context_after": after[0].ctx if after else None,
                          "pre_tokens": c["pre_tokens"], "post_tokens": c["post_tokens"],
                          "trigger": c["trigger"]})
        d["compactions"] = comps
        d["segments"] = [{"calls": len(s.calls),
                          "first_context": s.calls[0].ctx if s.calls else None,
                          "peak_context": s.peak if s.calls else None,
                          "last_context": s.calls[-1].ctx if s.calls else None}
                         for s in self.segments]
        d["context_drops"] = self.drops
        d["carried_over_records"] = self.carried_over
        return d


def totals(calls, compactions):
    thinking = [c.thinking for c in calls if c.thinking is not None]
    return {
        "calls": len(calls),
        "peak_context": max(c.ctx for c in calls) if calls else None,
        "total_input": sum(c.ctx for c in calls),
        "input_tokens": sum(c.inp for c in calls),
        "cache_creation_input_tokens": sum(c.cw for c in calls),
        "cache_read_input_tokens": sum(c.cr for c in calls),
        "output_tokens": sum(c.out for c in calls),
        "thinking_output_tokens": sum(thinking) if thinking else None,
        "output_incomplete_calls": sum(1 for c in calls if not c.final),
        "compaction_count": compactions,
    }


# ---- the audit -----------------------------------------------------------------


class Audit:
    def __init__(self, top, include_sidechains):
        self.top = top
        self.include_sidechains = include_sidechains
        self.main = Thread("main")
        self.subs = {}  # name -> Thread, in reading order
        self.seen = {}  # message id (or request id) -> Call, across all files
        self.largest = []  # (chars, category, text)
        self.tool_names = {}  # tool_use_id -> tool name
        self.uuid = None  # uuid of the record being read
        self.images = 0
        self.image_b64 = 0
        self.hidden_thinking = 0
        self.records = 0
        self.skipped = 0
        self.subagent_files = 0

    # ---- reading -------------------------------------------------------------

    def read_main(self, path):
        own_sidechain = os.path.basename(path).startswith("agent-")  # a subagent file audited alone
        for r in self.lines(path, count=True):
            if own_sidechain or not r.get("isSidechain"):
                t = self.main
            else:
                name = "inline:" + str(r.get("agentId") or "sidechain")
                if name not in self.subs:
                    self.subs[name] = Thread(name, categories=self.include_sidechains)
                t = self.subs[name]
            self.record(t, r)

    def read_subagents(self, folder):
        found = []
        for base, _dirs, files in os.walk(folder):
            for f in files:
                if f.endswith(".jsonl"):
                    p = os.path.join(base, f)
                    found.append((p, agent_type(p)))
        # read parents before forks: a fork's copied calls then stay with the parent
        found.sort(key=lambda pa: (pa[1] == "fork", first_timestamp(pa[0]), os.path.basename(pa[0])))
        for p, kind in found:
            self.subagent_files += 1
            name = os.path.basename(p)[: -len(".jsonl")]
            t = self.subs[name] = Thread(name, kind, categories=self.include_sidechains)
            for r in self.lines(p, count=False, usage_only=not t.categories):
                self.record(t, r)

    def lines(self, path, count, usage_only=False):
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if count:
                    self.records += 1
                line = line.strip()
                if not line:
                    continue
                if usage_only and '"assistant"' not in line and "compact_boundary" not in line:
                    continue  # fast path: only usage and compactions are needed from this file
                try:
                    r = json.loads(line)
                except ValueError:
                    self.skipped += 1
                    continue
                if isinstance(r, dict):
                    yield r
                else:
                    self.skipped += 1

    def record(self, t, r):
        try:
            self.uuid = r.get("uuid") if isinstance(r.get("uuid"), str) else None
            kind = r.get("type")
            if kind == "assistant":
                self.assistant(t, r)
            elif kind == "system":
                self.system(t, r)
            elif not t.categories:
                return
            elif kind == "user":
                self.user(t, r)
            elif kind == "attachment":
                self.attachment(t, r)
            # every other record type (titles, modes, snapshots, queue ops...) is UI state
        except Exception:  # unknown shapes must never stop the audit
            self.skipped += 1

    # ---- usage ---------------------------------------------------------------

    def usage(self, t, r, msg):
        u = msg.get("usage")
        if not isinstance(u, dict) or msg.get("model") == SYNTHETIC_MODEL:
            return
        inp, cw, cr = (num(u.get(k)) for k in CONTEXT_KEYS)
        if inp + cw + cr == 0:
            return
        out = num(u.get("output_tokens"))
        details = u.get("output_tokens_details")
        thinking = None
        if isinstance(details, dict) and "thinking_tokens" in details:
            thinking = num(details.get("thinking_tokens"))
        final = bool(msg.get("stop_reason"))
        key = msg.get("id") or r.get("requestId")
        key = key if isinstance(key, str) else None
        if key in self.seen:  # another record of a call already counted
            c = self.seen[key]
            c.out = max(c.out, out)
            c.final = c.final or final
            if thinking is not None:
                c.thinking = max(c.thinking or 0, thinking)
            return
        c = Call(inp, cw, cr, out, thinking, final)
        if key:
            self.seen[key] = c
        if self.uuid and self.uuid in t.carried:
            t.carried_over += 1  # copied in by a compaction; the call was made before it
            return
        t.add_call(c)

    # ---- visible content -----------------------------------------------------

    def add(self, t, category, text):
        if not isinstance(text, str):
            text = text_of(text)
        n = len(text)
        if n == 0:
            return
        t.seg.chars[category] += n
        t.items[category] += 1
        if self.uuid:
            t.by_uuid.setdefault(self.uuid, []).append((category, n))
        self.largest.append((n, category, text))
        if len(self.largest) > self.top * 20:
            self.largest.sort(key=lambda x: -x[0])
            del self.largest[self.top * 5:]

    def add_images(self, t, obj):
        c, size = images_in(obj)
        if c:
            self.images += c
            self.image_b64 += size
            n = c * IMAGE_TOKENS * 4
            t.seg.chars["Images"] += n
            t.items["Images"] += c
            if self.uuid:
                t.by_uuid.setdefault(self.uuid, []).append(("Images", n))

    def assistant(self, t, r):
        msg = r.get("message") or {}
        self.usage(t, r, msg)  # first, so the call's context excludes its own reply
        if not t.categories:
            return
        content = msg.get("content")
        if isinstance(content, str):
            self.add(t, "Assistant text", content)
            return
        for b in content or []:
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "text":
                self.add(t, "Assistant text", b.get("text") or "")
            elif bt == "thinking":
                th = b.get("thinking") or ""
                if th:
                    self.add(t, "Assistant thinking (visible)", th)
                else:
                    self.hidden_thinking += 1
            elif bt == "redacted_thinking":
                self.hidden_thinking += 1
            elif bt in ("tool_use", "server_tool_use"):
                name = b.get("name") or "unknown-tool"
                if b.get("id"):
                    self.tool_names[b["id"]] = name
                label = "Agent prompt" if name in ("Agent", "Task") else f"{name} input"
                self.add(t, label, json.dumps(b.get("input"), ensure_ascii=False))
            else:
                self.add(t, "Assistant other blocks", text_of(b))

    def user(self, t, r):
        msg = r.get("message") or {}
        content = msg.get("content")
        if r.get("isCompactSummary"):
            self.add(t, "Compaction summary", text_of(content))
            return
        if isinstance(content, str):
            self.add(t, self.classify_user_text(r, content), content)
            return
        for b in content or []:
            if not isinstance(b, dict):
                continue
            bt = b.get("type")
            if bt == "tool_result":
                name = self.tool_names.get(b.get("tool_use_id"), "unknown-tool")
                label = "Agent hand-back" if name in ("Agent", "Task") else f"{name} output"
                self.add(t, label, text_of(b.get("content")))
                self.add_images(t, b.get("content"))
            elif bt == "image":
                self.add_images(t, b)
            elif bt == "text":
                txt = b.get("text") or ""
                self.add(t, self.classify_user_text(r, txt), txt)
            else:
                self.add(t, "User other blocks", text_of(b))

    @staticmethod
    def classify_user_text(r, s):
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

    def attachment(self, t, r):
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
        self.add(t, label, txt)
        self.add_images(t, r.get("rendered"))

    def system(self, t, r):
        st = r.get("subtype")
        if st == "compact_boundary":
            t.compact(r.get("compactMetadata"))
        elif st == "local_command" and r.get("content") and t.categories:
            self.add(t, "Local command output", text_of(r.get("content")))
        # other system records (durations, summaries for the UI, bridge status) are not model input

    # ---- results -------------------------------------------------------------

    def categories(self):
        threads = [self.main] + (list(self.subs.values()) if self.include_sidechains else [])
        measured_mode = bool(self.main.calls())
        chars = defaultdict(float)
        items = defaultdict(int)
        measured = 0
        thinking, thinking_known = 0, False
        for t in threads:
            for cat, n in t.items.items():
                items[cat] += n
            for s in t.segments:
                if not measured_mode:
                    src = s.chars
                elif s.calls and s.at_peak is not None:
                    measured += s.peak
                    src = s.at_peak
                    for c in s.calls[: s.peak_index]:
                        if c.thinking is not None:
                            thinking += c.thinking
                            thinking_known = True
                else:
                    continue  # content in a segment without calls was never sent
                for cat, n in src.items():
                    chars[cat] += n
        visible = round(est(sum(chars.values())))
        basis = measured if measured_mode else visible
        rows = []
        for cat in set(chars) | set(items):
            tok = est(chars.get(cat, 0))
            rows.append({"category": cat, "tokens": round(tok),
                         "share": round(100.0 * tok / basis, 2) if basis else 0.0,
                         "items": items.get(cat, 0)})
        remainder = None
        if measured_mode:
            remainder = measured - visible
            rows.append({"category": REMAINDER, "tokens": remainder,
                         "share": round(100.0 * remainder / measured, 2), "items": None})
        rows.sort(key=lambda x: (-x["tokens"], x["category"]))
        self.largest.sort(key=lambda x: -x[0])
        return {
            "threads": "main+subagents" if self.include_sidechains else "main",
            "basis": "measured" if measured_mode else "visible-only",
            "measured_context": measured if measured_mode else None,
            "visible_estimate": visible,
            "not_in_transcript": remainder,
            "thinking_before_peaks": thinking if thinking_known else None,
            "rows": rows,
            "largest": [{"category": c, "tokens": round(est(n))} for n, c, _ in self.largest[: self.top]],
        }

    def as_json(self, path):
        subs = list(self.subs.values())
        sub_calls = [c for t in subs for c in t.calls()]
        sub_comps = sum(len(t.compactions) for t in subs)
        agents = []
        for t in subs:
            d = {"id": t.name, "agent_type": t.agent_type}
            d.update(t.as_json())
            agents.append(d)
        sub = totals(sub_calls, sub_comps)
        sub["count"] = len(subs)
        sub["agents"] = agents
        return {
            "schema_version": SCHEMA_VERSION,
            "transcript": {"file": os.path.basename(path), "bytes": os.path.getsize(path),
                           "records": self.records, "skipped_records": self.skipped,
                           "subagent_files": self.subagent_files},
            "main": self.main.as_json(),
            "subagents": sub,
            "combined": totals(self.main.calls() + sub_calls, len(self.main.compactions) + sub_comps),
            "categories": self.categories(),
            "thinking_blocks_without_text": self.hidden_thinking,
            "images": {"count": self.images, "base64_bytes": self.image_b64},
        }

    def report(self, path):
        d = self.as_json(path)
        m, s, cats = d["main"], d["subagents"], d["categories"]
        lines = [f"Transcript: {d['transcript']['file']}  ({d['transcript']['bytes'] / 1e6:.1f} MB, "
                 f"{self.records:,} records, {self.subagent_files} subagent files)", ""]

        lines.append("Measured from API usage (context of a call = input + cache write + cache read tokens)")
        table = [("Thread", "calls", "peak context", "total input", "output", "compactions")]
        for label, x in (("Main", m), (f"Subagents ({s['count']})", s), ("Combined", d["combined"])):
            table.append((label, fmt(x["calls"]), fmt(x["peak_context"]), fmt(x["total_input"]),
                          fmt(x["output_tokens"]), fmt(x["compaction_count"])))
        w0 = max(len(row[0]) for row in table)
        ws = [max(len(row[i]) for row in table) for i in range(1, 6)]
        for row in table:
            lines.append((f"{row[0]:<{w0}}" + "".join(f"  {v:>{w}}" for v, w in zip(row[1:], ws))).rstrip())
        if not m["calls"]:
            lines.append("No API usage records in the main thread (older transcript?): only the estimate below.")
        if m["compactions"]:
            lines.append("Main-thread compactions (context before -> after; as recorded by Claude Code):")
            for i, c in enumerate(m["compactions"][:MAX_COMPACTION_LINES], 1):
                rec = f"recorded {fmt(c['pre_tokens'])} -> {fmt(c['post_tokens'])}, {c['trigger'] or 'unknown'}"
                lines.append(f"  {i:>2}. {fmt(c['context_before'])} -> {fmt(c['context_after'])}  ({rec})")
            if len(m["compactions"]) > MAX_COMPACTION_LINES:
                lines.append(f"  ... {len(m['compactions']) - MAX_COMPACTION_LINES} more (see --json)")
        if m["context_drops"]:
            lines.append(f"Main-thread context fell {m['context_drops']} time(s) without a compaction "
                         f"(Claude Code clears older tool outputs first).")
        inc = d["combined"]["output_incomplete_calls"]
        if inc:
            lines.append(f"Output is a lower bound: {inc:,} call(s) ({s['output_incomplete_calls']:,} in subagents) "
                         f"were saved without their final usage.")
        th = d["combined"]["thinking_output_tokens"]
        if th is not None or self.hidden_thinking:
            lines.append(f"Thinking: {fmt(th) if th is not None else 'unknown'} output tokens in all threads; "
                         f"{self.hidden_thinking:,} thinking blocks saved without text.")
        top = sorted((a for a in s["agents"] if a["calls"]), key=lambda a: -a["peak_context"])[:3]
        if top:
            lines.append("Largest subagent peaks: " + "; ".join(
                f"{a['id']}{' (' + a['agent_type'] + ')' if a['agent_type'] else ''} {fmt(a['peak_context'])}"
                for a in top))
        lines.append("")

        who = "main thread and subagents" if self.include_sidechains else "main thread"
        lines.append(f"Visible content by category ({who}; chars/4 estimate),")
        if cats["basis"] == "measured":
            lines.append(f"counted at each segment's peak call. Shares are of the measured context, "
                         f"{fmt(cats['measured_context'])} tokens (sum of segment peaks).")
        else:
            lines.append(f"all content. Shares are of the visible estimate, {fmt(cats['visible_estimate'])} tokens.")
        if s["count"] and not self.include_sidechains:
            lines.append("Subagent content is not in this table (add --include-sidechains).")
        w = max([len(r["category"]) for r in cats["rows"]] + [8])
        lines.append(f"{'Category':<{w}}  {'~tokens':>10}  {'share':>6}  {'items':>6}")
        lines.append(f"{'-' * w}  {'-' * 10}  {'-' * 6}  {'-' * 6}")
        for r in cats["rows"]:
            items = "-" if r["items"] is None else str(r["items"])
            lines.append(f"{r['category']:<{w}}  {r['tokens']:>10,}  {r['share']:>5.1f}%  {items:>6}")
        if cats["basis"] == "measured":
            lines.append(f"{REMAINDER} = measured minus visible: system prompt, tool schemas, thinking sent back")
            lines.append("without saved text, and estimate error; below zero when the estimate is above the")
            lines.append("measurement (for example after older tool outputs were cleared).")
            if cats["thinking_before_peaks"] is not None:
                lines.append(f"Up to {fmt(cats['thinking_before_peaks'])} tokens of it can be thinking (output usage "
                             f"of the calls before each peak).")
        if self.skipped:
            lines.append(f"Unrecognised records skipped: {self.skipped:,}")
        lines.append("")
        lines.append(f"Top {self.top} single largest items:")
        for i, (n, cat, txt) in enumerate(self.largest[: self.top], 1):
            lines.append(f"{i:>3}. {cat:<{w}}  ~{est(n):>8,.0f}  {preview(txt)}")
        return "\n".join(lines)


def agent_type(path):
    try:
        with open(path[: -len(".jsonl")] + ".meta.json", encoding="utf-8") as fh:
            meta = json.load(fh)
        kind = meta.get("agentType") if isinstance(meta, dict) else None
        return kind if isinstance(kind, str) else None
    except (OSError, ValueError):
        return None


def first_timestamp(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for i, line in enumerate(fh):
                if i >= 50:
                    break
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict) and isinstance(r.get("timestamp"), str):
                    return r["timestamp"]
    except OSError:
        pass
    return ""


def main():
    ap = argparse.ArgumentParser(description="Measure how full a Claude Code session's context got, and "
                                             "estimate what filled it.")
    ap.add_argument("transcript", help="session .jsonl, or a project transcript directory (newest file used)")
    ap.add_argument("--top", type=int, default=10, help="how many single largest items to list (default 10)")
    ap.add_argument("--include-sidechains", action="store_true",
                    help="also put subagent content into the category table")
    ap.add_argument("--json", action="store_true", help="print JSON (schema in the script's docstring)")
    args = ap.parse_args()

    path = os.path.expanduser(args.transcript)
    if os.path.isdir(path):
        files = [os.path.join(path, f) for f in os.listdir(path) if f.endswith(".jsonl")]
        if not files:
            sys.exit(f"no .jsonl files in {path}")
        path = max(files, key=os.path.getmtime)
    if not os.path.isfile(path):
        sys.exit(f"not a file: {path}")

    audit = Audit(max(1, args.top), args.include_sidechains)
    audit.read_main(path)
    folder = os.path.join(os.path.dirname(path), os.path.basename(path)[: -len(".jsonl")], "subagents")
    if path.endswith(".jsonl") and os.path.isdir(folder):
        audit.read_subagents(folder)
    if args.json:
        print(json.dumps(audit.as_json(path), indent=1))
    else:
        print(audit.report(path))


if __name__ == "__main__":
    main()
