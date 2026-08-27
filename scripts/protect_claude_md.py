#!/usr/bin/env python3
"""PreToolUse gate: CLAUDE.md is readable but not writable by the agent."""

from __future__ import annotations

import json
import os
import re
import sys

TARGET_RE = re.compile(r"CLAUDE\.md\b")

# A redirect or tee onto CLAUDE.md, however the path in front of it is spelled.
REDIRECT_RE = re.compile(r">>?\s*[\"']?[^\s\"'|;&()]*CLAUDE\.md")
TEE_RE = re.compile(r"\btee\b[^|;&]*CLAUDE\.md")

SEGMENT_RE = re.compile(r"\|\||&&|[|;\n]")
ASSIGNMENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# Reading CLAUDE.md stays allowed; only these may name it.
READ_ONLY = frozenset(
    {
        "awk",
        "basename",
        "cat",
        "column",
        "comm",
        "cut",
        "diff",
        "dirname",
        "echo",
        "egrep",
        "false",
        "fgrep",
        "file",
        "fold",
        "grep",
        "head",
        "jq",
        "less",
        "ls",
        "md5",
        "md5sum",
        "more",
        "nl",
        "od",
        "printf",
        "rg",
        "sha256sum",
        "shasum",
        "sort",
        "stat",
        "tail",
        "test",
        "tr",
        "true",
        "uniq",
        "wc",
        "xxd",
        "[",
    }
)

# Anything that can run arbitrary code is judged by the whole command text,
# heredoc bodies included -- that is how CLAUDE.md was rewritten on 2026-08-27.
INTERPRETERS = frozenset(
    {
        "awk",
        "bash",
        "dash",
        "ed",
        "env",
        "ex",
        "node",
        "perl",
        "php",
        "python",
        "python2",
        "python3",
        "ruby",
        "sh",
        "uv",
        "zsh",
    }
)

GIT_READ_ONLY = frozenset(
    {"add", "blame", "cat-file", "diff", "grep", "log", "ls-files", "show", "status"}
)

# Naming CLAUDE.md is fine from a tool that only looks at it. Anything not
# listed here is treated as a writer, so a new tool fails closed.
READERS = frozenset({"Glob", "Grep", "LS", "NotebookRead", "Read"})
READER_VERBS = ("find_", "get_", "list_", "read_", "search_")

REASON = """\
DENIED: CLAUDE.md is protected. You may read it; you may not write it -- not with \
Edit/Write, and not through a shell redirect, sed -i, or an interpreter heredoc \
(that last one is how it was rewritten on 2026-08-27, so Bash is covered too).

WHY: CLAUDE.md is loaded into context on every turn, so every line is paid for on \
every request, forever. It reached 217 lines because each PR appended a paragraph \
and nothing was ever removed. An audit found ~115 of those lines were already \
documented elsewhere, usually in more detail and nearer the code.

DO ONE OF THESE INSTEAD.

1. Put it where it belongs. Almost nothing actually needs to live in CLAUDE.md:
     milestones, status, what landed, release track -> ROADMAP.md
     Swift toolchain, targets, the app, parity       -> swift/README.md
     domain vocabulary and naming                    -> CONTEXT.md
     a decision and its rationale                    -> docs/adr/
     format facts, timing, hardware protocol         -> analysis/
     agent and skill conventions                     -> docs/agents/
     why one line of code is odd                     -> a one-line comment
   Then, if CLAUDE.md must point at it at all, that is a pointer -- and a pointer \
is the User's line to add, not yours.

2. If it genuinely belongs in CLAUDE.md -- a rule that binds every task in every \
session, written nowhere else -- do not try again by another route. Tell the \
User what you want to add and the exact line you propose, and let them decide.

BEFORE YOU ASK, CHECK: is this already stated in one of the files above? Would a \
pointer do the same job in fewer tokens? Does it change behaviour, or does the \
model already do it by default? If any answer is yes, drop it -- those three \
questions are what the file grew 124 lines for want of asking.

An override exists (KSP_ALLOW_CLAUDE_MD=1). It is the User's to set, never yours \
to invoke. Do not re-run this command with it, and do not edit hook settings to \
get around this block."""


def first_word(segment: str) -> str:
    for token in segment.strip().split():
        if ASSIGNMENT_RE.match(token) or token in ("sudo", "command", "nohup", "exec"):
            continue
        return os.path.basename(token.strip("\"'"))
    return ""


def bash_writes_target(command: str) -> bool:
    if not TARGET_RE.search(command):
        return False
    if REDIRECT_RE.search(command) or TEE_RE.search(command):
        return True

    words = {os.path.basename(w.strip("\"'")) for w in command.split()}
    if words & INTERPRETERS:
        return True

    for segment in SEGMENT_RE.split(command):
        if not TARGET_RE.search(segment):
            continue
        word = first_word(segment)
        if word == "git":
            tokens = [t for t in segment.split() if not t.startswith("-")]
            if len(tokens) > 1 and tokens[1] in GIT_READ_ONLY:
                continue
            return True
        if word == "sed" and "-i" not in segment.split():
            continue
        if word not in READ_ONLY:
            return True
    return False


def paths_in(value: object) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [p for item in value for p in paths_in(item)]
    if isinstance(value, dict):
        return [p for item in value.values() for p in paths_in(item)]
    return []


def main() -> int:
    raw = sys.stdin.read()
    try:
        payload = json.loads(raw) if raw.strip() else {}
        if os.environ.get("KSP_ALLOW_CLAUDE_MD", "").strip().lower() in ("1", "true", "yes"):
            return 0

        tool = str(payload.get("tool_name", ""))
        tool_input = payload.get("tool_input")
        tool_input = tool_input if isinstance(tool_input, dict) else {}

        if tool == "Bash":
            hit = bash_writes_target(str(tool_input.get("command", "")))
        elif tool in READERS or any(verb in tool for verb in READER_VERBS):
            hit = False
        else:
            hit = any(os.path.basename(p.rstrip("/")) == "CLAUDE.md" for p in paths_in(tool_input))
    except Exception as exc:  # fail closed only where CLAUDE.md is actually in play
        if TARGET_RE.search(raw):
            hit = True
        else:
            print(f"protect_claude_md: skipped ({exc})", file=sys.stderr)
            return 0

    if hit:
        print(
            json.dumps(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": REASON,
                    }
                }
            )
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
