#!/usr/bin/env python3
"""PreToolUse gate for Claude Code / Gemini CLI Bash calls.

Reads the hook payload as JSON on stdin. Blocks with exit 2 plus a reason on
stderr; allows with a silent exit 0. Any internal error fails open, so a broken
guard never wedges every shell call in the session.
"""

from __future__ import annotations

import json
import re
import shlex
import sys
from collections.abc import Callable

# Path-token boundaries: start/end, whitespace, quote, '=' or '/'.
BOUND_L = r"(?:^|[\s\"'=/])"
BOUND_R = r"(?:$|[\s\"'=/])"

SECRET_TOKENS = (
    r"\.envrc",
    r"\.env",
    r"id_rsa",
    r"id_ed25519",
    r"\.aws/credentials",
    r"credentials\.(?:json|ya?ml)",
    r"secrets\.ya?ml",
    r"\.git/config",
)
SECRET_RE = re.compile(
    BOUND_L + "(?:" + "|".join(SECRET_TOKENS) + ")" + BOUND_R,
)

GIT_PUSH_RE = re.compile(r"\bgit\s+push\b")
GIT_COMMIT_RE = re.compile(r"\bgit\s+commit\b")
GIT_RESET_HARD_RE = re.compile(r"\bgit\s+reset\b.*--hard|--hard.*\bgit\s+reset\b")

PROTECTED_DIRS = ("scripts", ".claude", ".gemini")


HEREDOC_RE = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")


def strip_heredocs(command: str) -> str:
    """Drop heredoc bodies — they are data, not flags or paths."""
    kept: list[str] = []
    delimiter: str | None = None
    for line in command.splitlines():
        if delimiter is not None:
            if line.strip() == delimiter:
                delimiter = None
            continue
        kept.append(line)
        match = HEREDOC_RE.search(line)
        if match:
            delimiter = match.group(1)
    return "\n".join(kept)


def tokenize(command: str) -> list[str]:
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


def has_flag(tokens: list[str], flags: set[str]) -> bool:
    return any(t in flags for t in tokens)


def has_rm(tokens: list[str]) -> bool:
    return any(t == "rm" or t.endswith("/rm") for t in tokens)


def rm_recursive_force(tokens: list[str]) -> bool:
    recursive = force = False
    for t in tokens:
        if t in ("--recursive", "-R"):
            recursive = True
        elif t == "--force":
            force = True
        elif re.fullmatch(r"-[A-Za-z]+", t):
            short = t[1:]
            recursive = recursive or "r" in short or "R" in short
            force = force or "f" in short
    return recursive and force


def normalise_target(token: str) -> str:
    t = token.strip("\"'")
    while t.startswith("./"):
        t = t[2:]
    return t.rstrip("/") or "/"


def blocks_secret_read(command: str, tokens: list[str]) -> bool:
    return SECRET_RE.search(command) is not None


def blocks_force_push(command: str, tokens: list[str]) -> bool:
    return GIT_PUSH_RE.search(command) is not None and has_flag(
        tokens, {"--force", "--force-with-lease", "-f"}
    )


def blocks_hard_reset(command: str, tokens: list[str]) -> bool:
    return GIT_RESET_HARD_RE.search(command) is not None and "origin/" in command


def blocks_verify_bypass(command: str, tokens: list[str]) -> bool:
    touches_git = (
        GIT_PUSH_RE.search(command) is not None
        or GIT_COMMIT_RE.search(command) is not None
    )
    return touches_git and has_flag(tokens, {"--no-verify", "-n"})


def blocks_root_delete(command: str, tokens: list[str]) -> bool:
    if not (has_rm(tokens) and rm_recursive_force(tokens)):
        return False
    return any(t in ("/", ".") for t in tokens if not t.startswith("-"))


def blocks_config_delete(command: str, tokens: list[str]) -> bool:
    if not has_rm(tokens):
        return False
    for token in tokens:
        if token.startswith("-"):
            continue
        target = normalise_target(token)
        if any(target == d or target.startswith(d + "/") for d in PROTECTED_DIRS):
            return True
    return False


Rule = tuple[str, Callable[[str, list[str]], bool], str]

RULES: tuple[Rule, ...] = (
    (
        "secret-read",
        blocks_secret_read,
        "SECURITY DENIED: reading environment secrets, SSH keys or credential "
        "files is blocked.",
    ),
    (
        "force-push",
        blocks_force_push,
        "SECURITY DENIED: force-pushing to a remote is disabled for AI autonomy.",
    ),
    (
        "hard-reset",
        blocks_hard_reset,
        "SECURITY DENIED: destructive hard resets against origin are blocked.",
    ),
    (
        "verify-bypass",
        blocks_verify_bypass,
        "SECURITY DENIED: git verification bypass flags (-n / --no-verify) are "
        "prohibited.",
    ),
    (
        "root-delete",
        blocks_root_delete,
        "SECURITY DENIED: recursive deletion of / or the current directory is "
        "blocked.",
    ),
    (
        "config-delete",
        blocks_config_delete,
        "SECURITY DENIED: you cannot delete or tamper with scripts/ or the agent "
        "configuration directories.",
    ),
)


def extract_command(raw: str) -> str:
    """Pull the shell command out of a hook payload, tolerating shapes."""
    raw = raw.strip()
    if raw:
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            return raw  # not JSON: treat the whole payload as the command
        if isinstance(payload, dict):
            tool_input = payload.get("tool_input")
            if isinstance(tool_input, dict):
                command = tool_input.get("command")
                if isinstance(command, str):
                    return command
                args = tool_input.get("args")
                if isinstance(args, dict) and isinstance(args.get("command"), str):
                    return str(args["command"])
            params = payload.get("params")
            if isinstance(params, dict) and isinstance(params.get("command"), str):
                return str(params["command"])
            if isinstance(payload.get("command"), str):
                return str(payload["command"])
            return ""
    return " ".join(sys.argv[1:])


def main() -> int:
    try:
        command = strip_heredocs(extract_command(sys.stdin.read()))
        if not command.strip():
            return 0
        tokens = tokenize(command)
        for _name, predicate, message in RULES:
            if predicate(command, tokens):
                print(f"❌ {message}", file=sys.stderr)
                return 2
    except Exception as exc:  # fail open — never wedge the session
        print(f"⚠️  guard_rails: skipped ({exc})", file=sys.stderr)
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
