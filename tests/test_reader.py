"""Unit tests for the individual encodings and the two index spaces.

``test_ground_truth.py`` proves the reader reproduces real files. These tests
cover the pieces in isolation, so that a failure points at *which* encoding
broke rather than just reporting that a note came out wrong.
"""

from pathlib import Path

import pytest

from ksp import constants
from ksp.keys import key, read_array
from ksp.model import NoteKind, PatternMode
from ksp.reader import load, read_project, slot_is_initialised


class TestEncodings:
    @pytest.mark.parametrize(
        ("stored", "expected"), [(7, 0.5), (11, 1.0), (19, 2.0), (27, 3.0), (29, 3.5), (31, 4.0)]
    )
    def test_known_gate_values_decode(self, stored: int, expected: float) -> None:
        assert constants.decode_gate(stored) == expected

    @pytest.mark.parametrize("stored", [0, 2, 8, 15, 23, 40, 127])
    def test_unmeasured_gate_values_are_not_guessed(self, stored: int) -> None:
        """Interpolating would produce files that play wrong and never error.

        Gate is non-linear -- it fits 8g+3 up to gate 3 and then compresses --
        so a plausible formula is exactly the trap. Unknown stays unknown
        until the M7 hardware sweep measures it.
        """
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
        """The narrow test matters: step 1 with pitch 0 is a legal drum note.

        project_5's kick is exactly that -- note->step 0, lane 0 -- so only
        velocity separates it from uninitialised storage. Requiring all three
        arrays to be uniformly zero is what keeps a real note readable.
        """
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


class TestAgainstRealFiles:
    """The behaviours that only show up in files, kept close to their evidence."""

    def test_velocity_127_is_a_note_not_a_sentinel(self, project_files_dir: Path) -> None:
        """project_5's first kick has velocity 127, a legal value.

        Existence is decided by the note->step parameter alone. A reader that
        tested velocity would drop this note entirely.
        """
        project = load(project_files_dir / "project_5.KeyStepPro")
        first_kick = project.track(1).pattern(1).notes[0]
        assert first_kick.velocity == constants.SENTINEL
        assert first_kick.kind is NoteKind.DRUM

    def test_note_index_and_step_index_diverge(self, project_files_dir: Path) -> None:
        """The tenth note sits on step 13, and its skip mask comes from step 13.

        This is the whole point of M1. Reading the skip mask at note index 10
        instead would give 15 (the default) rather than the correct 12.
        """
        project = load(project_files_dir / "project_5.KeyStepPro")
        tenth = project.track(3).pattern(1).notes[9]
        assert (tenth.index, tenth.step) == (10, 13)
        assert tenth.skip == (48, 64)

    def test_drum_skip_is_note_indexed_unlike_the_melodic_one(
        self, project_files_dir: Path
    ) -> None:
        """project_9 test 2: one kick at step 1, playing only in sequence 32."""
        project = load(project_files_dir / "project_9.KeyStepPro")
        note = project.track(1).pattern(3).notes[0]
        assert (note.step, note.skip) == (1, (32,))

    def test_a_pattern_can_hold_both_parameter_sets(self, project_files_dir: Path) -> None:
        """Track 1 pattern 1 of initial_project has a real melody and real drums.

        Parameter 100 reads 26 in every pattern of every sample and cannot say
        which plays, but parameter 86 bit 6 can: it is set on this track. So
        the mode resolves to DRUM and the melody is leftovers -- and every
        note is still reported, because a reader that silently dropped 64 real
        user notes would hide exactly the surprise this test exists to keep
        visible.
        """
        project = load(project_files_dir / "initial_project.KeyStepPro")
        pattern = project.track(1).pattern(1)
        assert project.track(1).drum_mode is True
        assert pattern.mode is PatternMode.DRUM
        assert len(pattern.notes_of(NoteKind.SEQ)) == 64
        assert len(pattern.notes_of(NoteKind.DRUM)) == 12
        assert any("is stale. Both are reported" in w for w in pattern.warnings)

    def test_drum_mode_bit_tracks_which_projects_hold_drums(self, project_files_dir: Path) -> None:
        """Parameter 86 bit 6 is the drum-mode flag that 100 was expected to be.

        MCC's dictionary names it ("Arp/Drum mode state : bit 6", paramId 86)
        and the data agrees exactly: set on Track 1 in every sample holding
        drum notes, clear in both empty baselines, and never set on tracks
        2-4, which have no drum parameter set at all.
        """
        with_drums = ("project_5", "project_9", "initial_project")
        without = ("Default", "user_empty_project")
        for name in with_drums:
            project = load(project_files_dir / f"{name}.KeyStepPro")
            assert project.track(1).drum_mode is True, name
        for name in without:
            project = load(project_files_dir / f"{name}.KeyStepPro")
            assert project.track(1).drum_mode is False, name
        for name in with_drums + without:
            project = load(project_files_dir / f"{name}.KeyStepPro")
            assert [t.drum_mode for t in project.tracks[1:]] == [False] * 3, name

    def test_step_active_flags_agree_with_the_note_list(self, project_files_dir: Path) -> None:
        """The redundant step-active array is a free cross-check on the decode.

        Where it disagrees the reader warns rather than reconciling, so this
        asserts the hardware-confirmed projects produce no such warnings.
        """
        for name in ("project_5.KeyStepPro", "project_9.KeyStepPro"):
            project = load(project_files_dir / name)
            disagreements = [
                w
                for track in project.tracks
                for pattern in track.patterns
                for w in pattern.warnings
                if "step-active flags disagree" in w
            ]
            assert disagreements == [], f"{name}: {disagreements}"
