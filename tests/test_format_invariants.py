"""Byte-level invariants of the ``.KeyStepPro`` files checked into this repo."""

import json
from pathlib import Path

import pytest

from conftest import SAMPLE_NAMES

#: MCC's factory template is the only sample without a ``version`` key (spec section 2),
#: which is why midi_import has to inject one.
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
    """The trailing comma is why ``json.load`` rejects these files."""
    assert sample_bytes.endswith(b",\n}"), "trailing comma before '}' was stripped"


def test_has_no_final_newline(sample_bytes: bytes) -> None:
    assert not sample_bytes.endswith(b"\n"), "a final newline was appended"


def test_is_not_strict_json(sample_bytes: bytes) -> None:
    """Guards the premise behind ``ksp.lenient_json``."""
    with pytest.raises(json.JSONDecodeError):
        json.loads(sample_bytes)


def test_declares_keysteppro_device(sample_bytes: bytes) -> None:
    """The ``device`` key is first and identifies the hardware."""
    assert sample_bytes.startswith(b'{\n\t"device": "KeyStepPro",\n')


def test_version_key_follows_device_except_in_the_factory_template(
    sample_name: str, sample_bytes: bytes
) -> None:
    """User saves carry ``version``; MCC's factory template does not."""
    has_version = sample_bytes.startswith(b'{\n\t"device": "KeyStepPro",\n\t"version": ')
    assert has_version is (sample_name not in NAMES_WITHOUT_VERSION)


def test_ground_truth_descriptions_are_present(analysis_dir: Path) -> None:
    """Hardware-confirmed expectations that become the M1 regression fixtures."""
    for name in ("project_5_description.txt", "project_9_tests.txt"):
        path = analysis_dir / name
        assert path.is_file(), f"missing ground truth: {path}"
        assert path.stat().st_size > 0
