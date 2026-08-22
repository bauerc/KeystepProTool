"""Unit tests for the individual encodings and the two index spaces."""

from functools import lru_cache
from pathlib import Path
from typing import Any

import pytest

from ksp import constants
from ksp.diagnostics import Code
from ksp.keys import key, read_array
from ksp.model import NoteKind, PatternMode, Project
from ksp.reader import load, read_project, slot_is_initialised


@lru_cache(maxsize=16)
def cached_load(file_path: Path | str) -> Project:
    return load(file_path)


class TestEncodings:
    @pytest.mark.parametrize(
        ("stored", "expected"), [(7, 0.5), (11, 1.0), (19, 2.0), (27, 3.0), (29, 3.5), (31, 4.0)]
    )
    def test_known_gate_values_decode(self, stored: int, expected: float) -> None:
        assert constants.decode_gate(stored) == expected

    @pytest.mark.parametrize(
        ("stored", "expected"),
        [(0, 0.0625), (2, 0.1875), (8, 0.625), (15, 1.5), (28, 3.25), (48, 8.5), (127, 64.0)],
    )
    def test_the_rest_of_the_ladder_decodes(self, stored: int, expected: float) -> None:
        """One value from each of the five display runs, plus both extremes."""
        assert constants.decode_gate(stored) == expected

    @pytest.mark.parametrize("stored", [-1, 128, 255])
    def test_a_gate_off_the_ladder_is_not_guessed(self, stored: int) -> None:
        """The ladder covers every legal 7-bit value, so anything outside it is corrupt input."""
        assert constants.decode_gate(stored) is None

    @pytest.mark.parametrize(
        ("mask", "expected"),
        [
            (15, (16, 32, 48, 64)),
            (0, ()),
            (1, (16,)),
            (2, (32,)),
            (5, (16, 48)),
            (10, (32, 64)),
            (12, (48, 64)),
            (3, (16, 32)),
        ],
    )
    def test_skip_mask_decodes(self, mask: int, expected: tuple[int, ...]) -> None:
        assert constants.decode_skip_mask(mask) == expected

    @pytest.mark.parametrize(
        ("pitch", "name"), [(48, "C2"), (49, "C#2"), (50, "D2"), (60, "C3"), (72, "C4")]
    )
    def test_note_names_use_the_hardware_octave_convention(self, pitch: int, name: str) -> None:
        """48 displays as C2 and 60 as C3, per the two ground truth documents."""
        assert constants.note_name(pitch) == name


class TestKeys:
    def test_key_builds_the_grammar(self) -> None:
        assert key(125, 109, 1, 1, 10) == "125_109_1_1_10"
        assert key(120, 74) == "120_74"

    def test_read_array_is_zero_based_over_one_based_keys(self) -> None:
        raw = {"125_50_1_1_1": 0, "125_50_1_1_2": 4}
        assert read_array(raw, 125, 50, 1, 1, length=3) == [0, 4, None]


class TestSlotInitialisation:
    """Track 1 slot 4 is zero-filled, not sentinel-filled, in every known file."""

    def test_zero_filled_slot_is_uninitialised(self) -> None:
        zeros = [0] * constants.MAX_STEPS
        assert not slot_is_initialised(zeros, zeros, zeros)

    def test_sentinel_filled_slot_is_initialised_but_empty(self) -> None:
        sentinels = [constants.SENTINEL] * constants.MAX_STEPS
        assert slot_is_initialised(sentinels, sentinels, sentinels)

    def test_a_real_note_at_step_zero_is_not_mistaken_for_zero_fill(self) -> None:
        """The narrow test matters: step 1 with pitch 0 is a legal drum note."""
        note_step = [0] + [constants.SENTINEL] * (constants.MAX_STEPS - 1)
        pitch = [0] + [constants.SENTINEL] * (constants.MAX_STEPS - 1)
        velocity = [127] + [constants.SENTINEL] * (constants.MAX_STEPS - 1)
        assert slot_is_initialised(note_step, pitch, velocity)


class TestProjectLevel:
    def test_rejects_a_file_that_is_not_a_keysteppro_project(self) -> None:
        with pytest.raises(ValueError, match="missing 'device'"):
            read_project({"some": "other json"})

    def test_tempo_reassembles_from_three_seven_bit_chunks(self) -> None:
        """96 + 93*128 = 12000 hundredths of a BPM."""
        raw = {"device": "KeyStepPro", "120_70": 96, "120_71": 93, "120_72": 0}
        assert read_project(raw).tempo_bpm == 120.0

    def test_swing_carries_a_plus_25_offset(self) -> None:
        raw = {"device": "KeyStepPro", "120_74": 50}
        assert read_project(raw).global_swing_percent == 50


class TestScenes:
    """Pattern chains, measured by T5.7. Item 121, parameter 84."""

    def test_a_chain_is_read_in_order_and_stops_at_the_sentinel(self) -> None:
        raw: dict[str, Any] = {"device": "KeyStepPro", "121_84_1_2_1": 0, "121_84_1_2_2": 2}
        raw |= {f"121_84_1_2_{s}": constants.SENTINEL for s in range(3, 17)}

        (chain,) = read_project(raw).scenes[0].chains
        # Stored 0-based, reported the way the device numbers patterns.
        assert (chain.track, chain.patterns) == (2, (1, 3))

    def test_a_chain_with_a_hole_is_reported_rather_than_absorbed(self) -> None:
        """Not something the device produces, so it is not quietly repaired."""
        raw: dict[str, Any] = {"device": "KeyStepPro", "121_84_1_2_1": 0}
        raw |= {f"121_84_1_2_{s}": constants.SENTINEL for s in range(2, 17)}
        raw["121_84_1_2_4"] = 5

        project = read_project(raw)
        (chain,) = project.scenes[0].chains
        assert chain.patterns == (1,)
        assert any("gap" in w for w in project.warnings)

    def test_no_sample_project_chains_anything(self, project_files_dir: Path) -> None:
        """84 reads the sentinel in every slot of every file we have."""
        for path in sorted(project_files_dir.glob("*.KeyStepPro")):
            assert cached_load(path).chained_scenes == (), path.name


class TestAgainstRealFiles:
    """The behaviours that only show up in files, kept close to their evidence."""

    def test_velocity_127_is_a_note_not_a_sentinel(self, project_files_dir: Path) -> None:
        """project_5's first kick has velocity 127, a legal value."""
        project = cached_load(project_files_dir / "project_5.KeyStepPro")
        first_kick = project.track(1).pattern(1).notes[0]
        assert first_kick.velocity == constants.SENTINEL
        assert first_kick.kind is NoteKind.DRUM

    def test_note_index_and_step_index_diverge(self, project_files_dir: Path) -> None:
        """The tenth note sits on step 13, and its skip mask comes from step 13."""
        project = cached_load(project_files_dir / "project_5.KeyStepPro")
        tenth = project.track(3).pattern(1).notes[9]
        assert (tenth.index, tenth.step) == (10, 13)
        assert tenth.skip == (48, 64)

    def test_drum_skip_is_note_indexed_unlike_the_melodic_one(
        self, project_files_dir: Path
    ) -> None:
        """project_9 test 2: one kick at step 1, playing only in sequence 32."""
        project = cached_load(project_files_dir / "project_9.KeyStepPro")
        note = project.track(1).pattern(3).notes[0]
        assert (note.step, note.skip) == (1, (32,))

    def test_a_pattern_can_hold_both_parameter_sets(self, project_files_dir: Path) -> None:
        """Track 1 pattern 1 of initial_project has a real melody and real drums."""
        project = cached_load(project_files_dir / "initial_project.KeyStepPro")
        pattern = project.track(1).pattern(1)
        assert project.track(1).drum_mode is True
        assert pattern.mode is PatternMode.DRUM
        assert len(pattern.notes_of(NoteKind.SEQ)) == 64
        assert len(pattern.notes_of(NoteKind.DRUM)) == 12
        assert any("is stale. Both are reported" in w for w in pattern.warnings)

    def test_drum_mode_bit_tracks_which_projects_hold_drums(self, project_files_dir: Path) -> None:
        """Parameter 86 bit 6 is the drum-mode flag that 100 was expected to be."""
        with_drums = ("project_5", "project_9", "initial_project")
        without = ("Default", "user_empty_project")

        for name in with_drums:
            project = cached_load(project_files_dir / f"{name}.KeyStepPro")
            assert project.track(1).drum_mode is True, name
            assert [t.drum_mode for t in project.tracks[1:]] == [False] * 3, name

        for name in without:
            project = cached_load(project_files_dir / f"{name}.KeyStepPro")
            assert project.track(1).drum_mode is False, name
            assert [t.drum_mode for t in project.tracks[1:]] == [False] * 3, name

    def test_step_active_flags_agree_with_the_note_list(self, project_files_dir: Path) -> None:
        """The redundant step-active array is a free cross-check on the decode."""
        for name in ("project_5.KeyStepPro", "project_9.KeyStepPro"):
            project = cached_load(project_files_dir / name)
            disagreements = [
                d.message
                for track in project.tracks
                for pattern in track.patterns
                for d in pattern.diagnostics
                if d.code is Code.FLAG_WITHOUT_NOTE
            ]
            assert disagreements == [], f"{name}: {disagreements}"
