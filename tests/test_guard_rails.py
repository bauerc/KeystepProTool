"""The PreToolUse guard blocks what it names, and nothing else."""

import json
import subprocess
from pathlib import Path

import pytest

GUARD = Path(__file__).resolve().parents[1] / "scripts" / "guard_rails.sh"


def run_guard(stdin: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(GUARD)],
        input=stdin,
        capture_output=True,
        text=True,
        check=False,
    )


def payload(command: str) -> str:
    return json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})


BLOCKED = [
    "rm -rf /",
    "git push --force origin main",
    "git commit --no-verify -m x",
    "git reset --hard origin/main",
    "cat .env",
    "rm -rf scripts/",
    # A stripped heredoc must not hide the command that follows it.
    "cat <<'EOF' > note.txt\nbody\nEOF\ngit push --force origin main",
]

ALLOWED = [
    "uv run ruff format .",
    "rm -rf .mypy_cache",
    'git commit -m "note -n here"',
    "ls scripts/",
    "git push origin main",
    "grep -rn credentials src/",
    # Heredoc bodies are data: a commit message may name the flags it doesn't use.
    "git commit -F - <<'EOF'\nmention -n and --no-verify here\nEOF",
]


@pytest.mark.parametrize("command", BLOCKED)
def test_blocked_commands_exit_two_with_reason(command: str) -> None:
    result = run_guard(payload(command))
    assert result.returncode == 2
    assert result.stderr.strip()


@pytest.mark.parametrize("command", ALLOWED)
def test_allowed_commands_pass_silently(command: str) -> None:
    result = run_guard(payload(command))
    assert result.returncode == 0
    assert result.stderr == ""


@pytest.mark.parametrize(
    "stdin",
    ["", "not json at all", "{}", json.dumps({"tool_name": "Bash"})],
)
def test_malformed_input_fails_open(stdin: str) -> None:
    assert run_guard(stdin).returncode == 0
