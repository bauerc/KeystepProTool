"""M1's regression test: the reader must reproduce the hardware-confirmed data.

Expected values come from JSON fixtures rather than from assertions written
inline, for two reasons. The Swift port at M8/M9 can be checked against the
same files instead of a translated copy of these expectations; and the
fixtures were transcribed by hand from the descriptions in ``analysis/``, so
what they encode is what a person read off the KeyStep Pro's display, not what
this reader happens to produce. A test generated from the implementation would
only prove the implementation agrees with itself.

See ``tests/fixtures/README.md`` for what is hardware-confirmed and what is
merely transcribed from the file.
"""

import json
from pathlib import Path
from typing import Any

import pytest

from ksp.model import Note, Project
from ksp.reader import load

#: The note fields a fixture pins down. Everything else on ``Note`` -- the raw
#: gate value, the note ordinal -- is implementation detail that the ground
#: truth documents say nothing about.
COMPARED_FIELDS = (
    "kind",
    "slot",
    "index",
    "step",
    "pitch",
    "velocity",
    "gate",
    "time_shift",
    "randomness",
    "skip",
)

FIXTURE_NAMES = ["project_5.expected.json", "project_9.expected.json"]


def _load_fixture(fixtures_dir: Path, name: str) -> dict[str, Any]:
    data: dict[str, Any] = json.loads((fixtures_dir / name).read_text(encoding="utf-8"))
    return data


def _note_to_comparable(note: Note) -> dict[str, Any]:
    as_dict = note.to_dict()
    return {field: as_dict[field] for field in COMPARED_FIELDS}


def _expected_to_comparable(expected: dict[str, Any]) -> dict[str, Any]:
    return {field: expected[field] for field in COMPARED_FIELDS}


@pytest.fixture(params=FIXTURE_NAMES)
def case(
    request: pytest.FixtureRequest, fixtures_dir: Path, project_files_dir: Path
) -> tuple[dict[str, Any], Project]:
    fixture = _load_fixture(fixtures_dir, str(request.param))
    project = load(project_files_dir / str(fixture["project_file"]))
    return fixture, project


def test_project_scalars_match(case: tuple[dict[str, Any], Project]) -> None:
    fixture, project = case
    assert project.tempo_bpm == fixture["tempo_bpm"]
    assert project.global_swing_percent == fixture["global_swing_percent"]


def test_notes_match_ground_truth(case: tuple[dict[str, Any], Project]) -> None:
    """Every documented note decodes to exactly the documented values."""
    fixture, project = case
    for expected_pattern in fixture["patterns"]:
        pattern = project.track(expected_pattern["track"]).pattern(expected_pattern["pattern"])
        where = f"track {expected_pattern['track']} pattern {expected_pattern['pattern']}"

        assert pattern.mode.value == expected_pattern["mode"], where
        if "seq_step_count" in expected_pattern:
            assert pattern.seq_step_count == expected_pattern["seq_step_count"], where
        if "drum_step_count" in expected_pattern:
            assert pattern.drum_step_count == expected_pattern["drum_step_count"], where

        actual = [_note_to_comparable(n) for n in pattern.notes]
        expected = [_expected_to_comparable(n) for n in expected_pattern["notes"]]
        assert actual == expected, where


def test_undocumented_patterns_are_empty(case: tuple[dict[str, Any], Project]) -> None:
    """Nothing is decoded outside the patterns the description accounts for.

    This is the half of the comparison that catches over-reading. A reader
    that mistakes uninitialised storage for content -- Track 1 slot 4 is
    zero-filled in every known file -- still passes the note-by-note check
    above, because it invents notes in patterns the fixture never mentions.
    """
    fixture, project = case
    documented = {(p["track"], p["pattern"]) for p in fixture["patterns"]}
    for track in project.tracks:
        for pattern in track.patterns:
            if (track.number, pattern.number) in documented:
                continue
            assert pattern.notes == (), (
                f"track {track.number} pattern {pattern.number} decoded "
                f"{len(pattern.notes)} note(s), but the ground truth says it is empty"
            )


def test_unresolved_discrepancies_still_hold(case: tuple[dict[str, Any], Project]) -> None:
    """Known description-vs-file conflicts stay visible until re-checked.

    Each ``unresolved`` entry asserts the file really does disagree with the
    description. If someone re-confirms the value on the hardware and corrects
    one of the two, this fails and forces the fixture to be updated rather than
    letting the conflict evaporate unnoticed.
    """
    fixture, _ = case
    for entry in fixture["unresolved"]:
        assert entry["documented"] != entry["in_file"], (
            f"{entry['where']}: {entry['field']} is recorded as unresolved but the "
            f"documented and in-file values now agree; delete the entry"
        )
        assert entry["detail"].strip(), f"{entry['where']}: unresolved entry needs an explanation"


def test_project_5_time_shift_conflict_is_real(project_files_dir: Path) -> None:
    """Pin the one live discrepancy to the actual decoded value.

    ``project_5_description.txt`` gives Time Shift -1 for both kick hits; the
    file stores +1 for the second. Asserting the decoded value here means the
    fixture's ``unresolved`` entry is anchored to something real rather than to
    a comment nobody re-checks.
    """
    project = load(project_files_dir / "project_5.KeyStepPro")
    second_kick = project.track(1).pattern(1).notes[1]
    assert second_kick.step == 5
    assert second_kick.time_shift == 1, (
        "the file's value changed; re-check against project_5_description.txt"
    )
