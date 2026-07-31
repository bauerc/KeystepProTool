"""The two empty baselines must decode to nothing at all.

An empty project is where a reader that mistakes uninitialised storage for
content fails loudly instead of subtly. Track 1's fourth polyphony slot is
zero-filled rather than sentinel-filled in every known file, so reading note
existence naively yields 64 phantom notes per parameter set per pattern --
against a file that a human can confirm holds nothing.

These two files also fix what "default" means. Every untouched value in
``project_9`` is corroborated here.
"""

import json
from pathlib import Path
from typing import Any

import pytest

from ksp.lenient_json import load_path
from ksp.reader import load


@pytest.fixture(scope="session")
def empty_cases(fixtures_dir: Path) -> list[dict[str, Any]]:
    data = json.loads((fixtures_dir / "empty_projects.expected.json").read_text(encoding="utf-8"))
    cases: list[dict[str, Any]] = data["projects"]
    return cases


def _case(cases: list[dict[str, Any]], name: str) -> dict[str, Any]:
    return next(c for c in cases if c["project_file"] == name)


@pytest.fixture(params=["Default.KeyStepPro", "user_empty_project.KeyStepPro"])
def empty_case(request: pytest.FixtureRequest, empty_cases: list[dict[str, Any]]) -> dict[str, Any]:
    return _case(empty_cases, str(request.param))


def test_decodes_to_no_notes(empty_case: dict[str, Any], project_files_dir: Path) -> None:
    project = load(project_files_dir / empty_case["project_file"])
    found = [
        (t.number, p.number, len(p.notes))
        for t in project.tracks
        for p in project.tracks[t.number - 1].patterns
        if p.notes
    ]
    assert found == [], f"decoded notes from an empty project: {found}"


def test_scalars_match(empty_case: dict[str, Any], project_files_dir: Path) -> None:
    """Tempo is the one global the hardware readout confirms: 120 BPM.

    It is a genuinely independent check on the tempo decode, because it comes
    from the device's own display rather than from another file.
    """
    project = load(project_files_dir / empty_case["project_file"])
    assert project.tempo_bpm == empty_case["tempo_bpm"]
    assert project.global_swing_percent == empty_case["global_swing_percent"]
    assert project.version == empty_case["version"]


def test_warnings_match(empty_case: dict[str, Any], project_files_dir: Path) -> None:
    project = load(project_files_dir / empty_case["project_file"])
    expected = empty_case["expected_warning_substrings"]
    assert len(project.warnings) == len(expected)
    for substring, warning in zip(expected, project.warnings, strict=True):
        assert substring in warning


def test_key_count_matches(empty_case: dict[str, Any], project_files_dir: Path) -> None:
    """The key set is fixed; only the ``version`` key varies between files."""
    raw = load_path(project_files_dir / empty_case["project_file"])
    assert len(raw) == empty_case["total_keys"]
