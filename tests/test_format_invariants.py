"""Byte-level invariants of the ``.KeyStepPro`` files checked into this repo.

These files are the baseline for M3's byte-identical round-trip, so their
exact bytes matter. MIDI Control Center writes a non-standard JSON dialect and
we have to reproduce it exactly; anything that "tidies" these files -- an
editor, a pre-commit hook, a well-meaning formatter -- silently destroys the
thing M3 is meant to prove.

This module exists to make that corruption loud and immediate rather than
surfacing later as a mysterious round-trip failure. See
``analysis/KeyStepPro_Format_Spec.md`` section 2.
"""

import json
from pathlib import Path

import pytest

SAMPLE_NAMES = [
    "initial_project.KeyStepPro",
    "project_5.KeyStepPro",
    "project_9.KeyStepPro",
]


@pytest.fixture(params=SAMPLE_NAMES)
def sample_bytes(request: pytest.FixtureRequest, project_files_dir: Path) -> bytes:
    path = project_files_dir / str(request.param)
    assert path.is_file(), f"missing sample project: {path}"
    return path.read_bytes()


def test_sample_projects_are_present(project_files_dir: Path) -> None:
    """All three hardware exports are checked in."""
    found = sorted(p.name for p in project_files_dir.glob("*.KeyStepPro"))
    assert found == sorted(SAMPLE_NAMES)


def test_uses_tab_indentation(sample_bytes: bytes) -> None:
    """MCC indents with a single tab, not spaces."""
    assert sample_bytes.startswith(b"{\n\t"), "expected '{' + newline + tab"
    assert b"\n    " not in sample_bytes, "space indentation found; file was reformatted"


def test_has_trailing_comma_before_closing_brace(sample_bytes: bytes) -> None:
    """The trailing comma is why ``json.load`` rejects these files.

    Boost.PropertyTree (which MCC uses) tolerates it. We must re-emit it.
    """
    assert sample_bytes.endswith(b",\n}"), "trailing comma before '}' was stripped"


def test_has_no_final_newline(sample_bytes: bytes) -> None:
    """The file ends at ``}`` with no terminating newline.

    A standard ``end-of-file-fixer`` hook appends one, which would break the
    M3 byte-identical round-trip. ``.pre-commit-config.yaml`` excludes
    ``project_files/`` for exactly this reason.
    """
    assert not sample_bytes.endswith(b"\n"), "a final newline was appended"


def test_is_not_strict_json(sample_bytes: bytes) -> None:
    """Guards the premise behind ``ksp.lenient_json``.

    If this ever passes strict parsing, MCC changed its output format and the
    lenient loader's reason for existing needs revisiting.
    """
    with pytest.raises(json.JSONDecodeError):
        json.loads(sample_bytes)


def test_declares_keysteppro_device(sample_bytes: bytes) -> None:
    """The ``device`` key is first and identifies the hardware."""
    assert sample_bytes.startswith(b'{\n\t"device": "KeyStepPro",\n')


def test_ground_truth_descriptions_are_present(analysis_dir: Path) -> None:
    """Hardware-confirmed expectations that become the M1 regression fixtures.

    These record values verified on a physical KeyStep Pro and cannot be
    regenerated without the device, so losing them is expensive.
    """
    for name in ("project_5_description.txt", "project_9_tests.txt"):
        path = analysis_dir / name
        assert path.is_file(), f"missing ground truth: {path}"
        assert path.stat().st_size > 0
