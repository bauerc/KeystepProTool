"""The decoded model's own behaviour, with no MIDI in it.

Mirrors ``swift/Tests/KSPKitTests/ModelTests.swift``. Every project holds four
tracks of sixteen patterns whether or not they hold notes (existence is not
audibility, spec section 4), so selection can be asserted on any sample.
"""

from pathlib import Path

import pytest

from ksp.model import Project
from ksp.reader import load


@pytest.fixture
def project(project_files_dir: Path) -> Project:
    return load(project_files_dir / "project_9.KeyStepPro")


def numbers(project: Project) -> list[int]:
    return [t.number for t in project.tracks]


def patterns_of(project: Project, track: int) -> list[int]:
    return [p.number for p in project.tracks[track].patterns]


class TestSelect:
    def test_one_track(self, project: Project) -> None:
        assert numbers(project.select(tracks={3})) == [3]

    def test_several_tracks(self, project: Project) -> None:
        assert numbers(project.select(tracks={1, 3})) == [1, 3]

    def test_a_contiguous_pattern_range(self, project: Project) -> None:
        narrowed = project.select(patterns={2, 3, 4, 5})
        assert numbers(narrowed) == [1, 2, 3, 4]  # patterns narrow, tracks do not
        assert patterns_of(narrowed, 0) == [2, 3, 4, 5]

    def test_a_non_contiguous_pattern_set(self, project: Project) -> None:
        assert patterns_of(project.select(patterns={1, 5, 9}), 0) == [1, 5, 9]

    def test_an_empty_selection_means_everything(self, project: Project) -> None:
        narrowed = project.select()
        assert numbers(narrowed) == numbers(project)
        assert patterns_of(narrowed, 0) == patterns_of(project, 0)

    def test_both_sets_at_once(self, project: Project) -> None:
        narrowed = project.select(tracks={1, 4}, patterns={2})
        assert numbers(narrowed) == [1, 4]
        assert [patterns_of(narrowed, i) for i in (0, 1)] == [[2], [2]]

    def test_selection_keeps_the_project_order(self, project: Project) -> None:
        """A set has no order; the project's own order is what survives."""
        assert numbers(project.select(tracks={4, 2, 1})) == [1, 2, 4]

    def test_a_number_no_track_has_selects_nothing(self, project: Project) -> None:
        """Range checking belongs to the CLI, not here."""
        assert project.select(tracks={9}).tracks == ()

    def test_fields_that_are_not_narrowed_survive(self, project: Project) -> None:
        narrowed = project.select(tracks={1}, patterns={1})
        assert narrowed.tempo_bpm == project.tempo_bpm
        assert narrowed.tracks[0].drum_mode == project.tracks[0].drum_mode
        assert narrowed.diagnostics == project.diagnostics
