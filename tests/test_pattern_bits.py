"""The 99 / 116 bitfield decode, and what the committed corpus holds."""

from pathlib import Path

import pytest

from ksp import constants, lenient_json
from ksp.model import PatternBits, PlaybackDirection

#: Every value tier 5 produced, on both halves of the field, with what the
#: device displayed for it. Ordered as (raw, denominator, triplet, direction).
MEASURED = [
    (4, 4, False, PlaybackDirection.FORWARD),
    (12, 8, False, PlaybackDirection.FORWARD),
    (20, 16, False, PlaybackDirection.FORWARD),
    (28, 32, False, PlaybackDirection.FORWARD),
    (5, 4, True, PlaybackDirection.FORWARD),
    (13, 8, True, PlaybackDirection.FORWARD),
    (21, 16, True, PlaybackDirection.FORWARD),
    (29, 32, True, PlaybackDirection.FORWARD),
    (52, 16, False, PlaybackDirection.RANDOM),
    (84, 16, False, PlaybackDirection.WALK),
    (16, 16, False, PlaybackDirection.FORWARD),
    (0, 4, False, PlaybackDirection.FORWARD),
    (8, 8, False, PlaybackDirection.FORWARD),
    (24, 32, False, PlaybackDirection.FORWARD),
]


@pytest.mark.parametrize(("raw", "denominator", "triplet", "direction"), MEASURED)
def test_every_measured_value_decodes_to_what_the_device_displayed(
    raw: int, denominator: int, triplet: bool, direction: PlaybackDirection
) -> None:
    bits = PatternBits.decode(raw)
    assert bits.step_denominator == denominator
    assert bits.triplet is triplet
    assert bits.direction is direction
    assert bits.unallocated == 0


def test_the_fields_do_not_overlap() -> None:
    """Each field must move its own bits and nobody else's."""
    covered = 0
    for shift, mask in (
        (constants.TRIPLET_BIT, 1),
        (constants.POLYRHYTHM_BIT, 1),
        (constants.STEP_SIZE_SHIFT, constants.STEP_SIZE_MASK),
        (constants.DIRECTION_SHIFT, constants.DIRECTION_MASK),
    ):
        field = mask << shift
        assert not covered & field
        covered |= field
    # Seven bits, one of which nothing has ever set.
    assert covered == 0b1111101


def test_the_two_defaults_differ_only_by_polyrhythm() -> None:
    """20 on the sequencer half, 16 on the drum half (spec 3.3)."""
    seq, drum = PatternBits.decode(20), PatternBits.decode(16)
    assert seq.polyrhythm and not drum.polyrhythm
    assert (seq.step_denominator, seq.triplet, seq.direction) == (
        drum.step_denominator,
        drum.triplet,
        drum.direction,
    )


def test_the_fourth_direction_is_reported_as_unknown() -> None:
    """Two bits allow it; the device never produced it, so it gets no name."""
    assert PatternBits.decode(20 | 3 << constants.DIRECTION_SHIFT).direction is (
        PlaybackDirection.UNKNOWN
    )


def test_the_unallocated_bit_is_surfaced_not_absorbed() -> None:
    bits = PatternBits.decode(20 | 0b10)
    assert bits.unallocated == 0b10
    assert bits.step_denominator == 16
    assert bits.direction is PlaybackDirection.FORWARD


def test_setting_the_step_size_leaves_the_other_fields_alone() -> None:
    """What ``mutate.set_step_size`` relies on when writing into a template."""
    triplet_walk = 21 | 2 << constants.DIRECTION_SHIFT
    updated = constants.steps_per_beat_bits(triplet_walk, 8)

    before, after = PatternBits.decode(triplet_walk), PatternBits.decode(updated)
    assert after.step_denominator == 32
    assert (after.triplet, after.polyrhythm, after.direction) == (
        before.triplet,
        before.polyrhythm,
        before.direction,
    )


def test_a_step_size_the_device_cannot_hold_is_refused() -> None:
    """The field is two bits wide: 1/4 to 1/32 and nothing else."""
    with pytest.raises(ValueError, match="1/12 steps cannot be stored"):
        constants.steps_per_beat_bits(20, 3)


def test_the_label_is_what_the_device_writes() -> None:
    assert PatternBits.decode(20).label == "1/16"
    assert PatternBits.decode(21).label == "1/16T"


def test_no_committed_file_sets_the_unallocated_bit(project_files_dir: Path) -> None:
    """Bit 1 is set by nothing -- in the captures, and here in real material."""
    for path in sorted(project_files_dir.glob("*.KeyStepPro")):
        raw = lenient_json.load_path(path)
        for name, value in raw.items():
            parts = name.split("_")
            if len(parts) == 3 and parts[1] in (
                str(constants.P_SEQ_PATTERN_BITS),
                str(constants.P_DRUM_PATTERN_BITS),
            ):
                assert isinstance(value, int)
                assert constants.unallocated_bits(value) == 0, f"{path.name} {name}"


def test_every_sample_project_plays_at_one_sixteenth(project_files_dir: Path) -> None:
    """Which is why decoding the field changes no existing export."""
    for path in sorted(project_files_dir.glob("*.KeyStepPro")):
        raw = lenient_json.load_path(path)
        for name, value in raw.items():
            parts = name.split("_")
            if len(parts) == 3 and parts[1] == str(constants.P_SEQ_PATTERN_BITS):
                assert isinstance(value, int)
                bits = PatternBits.decode(value)
                assert (bits.step_denominator, bits.triplet) == (16, False), f"{path.name} {name}"
