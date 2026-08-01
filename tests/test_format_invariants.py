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

from conftest import SAMPLE_NAMES

#: ``Default.KeyStepPro`` is MCC's factory template and is the only sample
#: without a ``version`` key -- spec section 2, and the reason M5 has to inject
#: one when it uses the template as a baseline.
NAMES_WITHOUT_VERSION = {"Default.KeyStepPro"}


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


def test_version_key_follows_device_except_in_the_factory_template(
    sample_name: str, sample_bytes: bytes
) -> None:
    """User saves carry ``version``; MCC's factory template does not.

    M5 builds output from the template, so it has to add the key. Pinning the
    distinction here means the assumption is checked against every sample
    rather than remembered.
    """
    has_version = sample_bytes.startswith(b'{\n\t"device": "KeyStepPro",\n\t"version": ')
    assert has_version is (sample_name not in NAMES_WITHOUT_VERSION)


def test_ground_truth_descriptions_are_present(analysis_dir: Path) -> None:
    """Hardware-confirmed expectations that become the M1 regression fixtures.

    These record values verified on a physical KeyStep Pro and cannot be
    regenerated without the device, so losing them is expensive.
    """
    for name in ("project_5_description.txt", "project_9_tests.txt"):
        path = analysis_dir / name
        assert path.is_file(), f"missing ground truth: {path}"
        assert path.stat().st_size > 0
