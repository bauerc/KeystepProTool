"""A comparison that broke is not a disagreement, and the gates have to say which they have."""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / "scripts" / "lib" / "parity.sh"
GATES = ["port_parity.sh", "writer_parity.sh", "midi_parity.sh", "pull_parity.sh"]

PARITY_BROKEN = 2


def run_compare(command: str) -> subprocess.CompletedProcess[str]:
    """``compare`` over a stand-in whose exit code is the whole point of the case."""
    script = f'. "{LIB}"\ncompare "the subject" {command}\n'
    return subprocess.run(
        ["bash", "-c", script], capture_output=True, text=True, check=False, cwd=ROOT
    )


@pytest.mark.parametrize(
    ("command", "expected"),
    [
        ("true", 0),
        ("sh -c 'exit 1'", 1),
        ("sh -c 'exit 2'", PARITY_BROKEN),
        # Anything worse than 2 is still trouble, and still not a difference.
        ("sh -c 'exit 3'", PARITY_BROKEN),
    ],
)
def test_compare_reports_what_the_tool_meant(command: str, expected: int) -> None:
    assert run_compare(command).returncode == expected


def test_a_comparison_that_ran_says_nothing() -> None:
    for command in ("true", "sh -c 'exit 1'"):
        assert run_compare(command).stderr == ""


def test_a_broken_comparison_names_its_subject() -> None:
    """A gate tends to break on every case at once, so an unlabelled line says nothing."""
    stderr = run_compare("sh -c 'exit 2'").stderr
    assert "the subject" in stderr
    assert "nothing was compared" in stderr
    # The word that sent the last reader after a Swift bug that was never there.
    assert "differ" not in stderr


def test_every_gate_sources_the_shared_classification() -> None:
    for gate in GATES:
        assert "lib/parity.sh" in (ROOT / "scripts" / gate).read_text(), gate


def test_no_gate_still_folds_trouble_in_with_difference() -> None:
    """``if ! diff`` and ``if ! cmp`` cannot tell exit 1 from exit 2; ``compare`` is why."""
    for gate in GATES:
        body = (ROOT / "scripts" / gate).read_text()
        assert "if ! diff" not in body, gate
        assert "if ! cmp" not in body, gate


def test_validate_rebuilds_the_stamp_when_the_shared_helper_changes() -> None:
    """The parity stamp skips all four gates, so an unhashed helper would keep a stale green."""
    fingerprint = (ROOT / "scripts" / "validate.sh").read_text()
    assert "scripts/lib/parity.sh" in fingerprint


def test_validate_tells_a_broken_harness_apart_from_a_disagreement() -> None:
    body = (ROOT / "scripts" / "validate.sh").read_text()
    assert "THE PARITY HARNESS BROKE" in body
    assert "could not run its own comparison" in body
