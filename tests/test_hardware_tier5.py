"""Tier 5 -- the per-pattern scalars, chaining, and what step skip means.

Ten captures, all diffed against ``B0-baseline``. Each test here reads one and
asserts the measurement, so a finding that reached the spec as prose also has
something executable behind it.

The captures are gitignored, so these skip on a fresh clone and on CI; they run
on the operator's machine. What they pin:

- **T5.1-T5.5** the ``99`` bitfield: triplet at bit 0, polyrhythm at bit 2,
  step size at bits 3-4 and playback direction at bits 5-6. Bit 1 is set by
  nothing. Swing is *not* in this field -- the swing-offset toggle moves ``97``.
- **the drum repeat** ``116`` decodes through the same layout, so the 20-vs-16
  default asymmetry the spec called unexplained is only a default.
- **T5.6** root note is a pitch class and scale indexes the device's own list,
  whose eighth entry (Root) the firmware declines to store.
- **T5.7** a chain is 0-based pattern numbers in order, sentinel-terminated,
  addressed by track number.
- **T5.8** the four 16/32/48/64 sequences are **repeats**, which is what
  ``--passes`` is built on.
"""

from collections.abc import Callable
from pathlib import Path

import pytest

from ksp import constants, lenient_json
from ksp.keys import key
from ksp.midi_export import ExportOptions, auto_passes, render_pattern
from ksp.model import NoteKind, PatternBits, PlaybackDirection
from ksp.reader import load

TRACK_1_ITEM = 123
TRACK_2_ITEM = 124
TRACK_3_ITEM = 125

BASELINE = "B0-baseline.KeyStepPro"
STEP_SIZE = "T5-99-stepsize.KeyStepPro"
TRIPLET = "T5-99-triplet.KeyStepPro"
MONORHYTHM = "T5-99-monorhythm.KeyStepPro"
SWING_OFFSET = "T5-99-swingoffset.KeyStepPro"
DIRECTION = "T5-99-direction.KeyStepPro"
DRUM = "T5-99-drum.KeyStepPro"
ROOT_NOTE = "T5-rootnote.KeyStepPro"
SCALE = "T5-scale.KeyStepPro"
CHAIN = "T5-chain-3.KeyStepPro"
SKIP = "T5-skip-16step.KeyStepPro"

#: The bitfield's own key, which is all these tests read.
BITS = constants.P_SEQ_PATTERN_BITS
DRUM_BITS = constants.P_DRUM_PATTERN_BITS

#: What an untouched pattern holds. The two differ by the polyrhythm bit.
SEQ_DEFAULT = 20
DRUM_DEFAULT = 16


def _changed(
    before: dict[str, int | str], after: dict[str, int | str]
) -> dict[str, tuple[object, object]]:
    keys = before.keys() | after.keys()
    return {k: (before.get(k), after.get(k)) for k in keys if before.get(k) != after.get(k)}


def _bits(raw: dict[str, int | str], item: int, param: int, pattern: int) -> int:
    value = raw[key(item, param, pattern)]
    assert isinstance(value, int)
    return value


# --- T5.1-T5.5 -- the 99 bitfield ------------------------------------------


@pytest.mark.hardware
def test_step_size_occupies_bits_3_and_4(require_capture: Callable[[str], Path]) -> None:
    """One capture, four patterns, one step size each."""
    raw = lenient_json.load_path(require_capture(STEP_SIZE))

    stored = [_bits(raw, TRACK_2_ITEM, BITS, p) for p in (1, 2, 3, 4)]
    assert stored == [4, 12, 20, 28]
    assert [constants.step_denominator(v) for v in stored] == [4, 8, 16, 32]

    # Nothing else in the field moved: the same three bits are set throughout.
    assert {v & ~(constants.STEP_SIZE_MASK << constants.STEP_SIZE_SHIFT) for v in stored} == {4}


@pytest.mark.hardware
def test_triplet_is_bit_0_and_is_independent_of_step_size(
    require_capture: Callable[[str], Path],
) -> None:
    """Track 2 toggles it alone; Track 3 sweeps it across every step size."""
    raw = lenient_json.load_path(require_capture(TRIPLET))

    assert _bits(raw, TRACK_2_ITEM, BITS, 1) == SEQ_DEFAULT + 1
    swept = [_bits(raw, TRACK_3_ITEM, BITS, p) for p in (1, 2, 3, 4)]
    assert swept == [5, 13, 21, 29]
    assert all(constants.is_triplet(v) for v in swept)
    assert [constants.step_denominator(v) for v in swept] == [4, 8, 16, 32]


@pytest.mark.hardware
def test_polyrhythm_is_bit_2_and_explains_the_two_defaults(
    require_capture: Callable[[str], Path],
) -> None:
    """Turning Monorhythm on clears the one bit the two defaults differ by.

    This is what settles the asymmetry: the sequencer field and the drum field
    share a layout, and 20 vs 16 is only what each ships with.
    """
    before = lenient_json.load_path(require_capture(BASELINE))
    after = lenient_json.load_path(require_capture(MONORHYTHM))

    flag = key(TRACK_2_ITEM, BITS, 1)
    latch = key(TRACK_2_ITEM, constants.P_PATTERN_DATA_STATE, 1)
    assert _changed(before, after) == {flag: (SEQ_DEFAULT, 16), latch: (2, 3)}

    assert constants.is_polyrhythm(SEQ_DEFAULT)
    assert not constants.is_polyrhythm(DRUM_DEFAULT)
    assert SEQ_DEFAULT ^ DRUM_DEFAULT == 1 << constants.POLYRHYTHM_BIT


@pytest.mark.hardware
def test_the_swing_offset_toggle_does_not_touch_the_bitfield(
    require_capture: Callable[[str], Path],
) -> None:
    """MCC's dictionary names a "swing offset state" bit. There is not one.

    The toggle moves the per-pattern swing parameter instead, which is why
    nothing in this field is read as swing.
    """
    before = lenient_json.load_path(require_capture(BASELINE))
    after = lenient_json.load_path(require_capture(SWING_OFFSET))

    swing = key(TRACK_2_ITEM, constants.P_SEQ_SWING, 1)
    latch = key(TRACK_2_ITEM, constants.P_PATTERN_DATA_STATE, 1)
    assert _changed(before, after) == {swing: (25, 50), latch: (2, 3)}


@pytest.mark.hardware
def test_playback_direction_occupies_bits_5_and_6(
    require_capture: Callable[[str], Path],
) -> None:
    """Fwd, Rand and Walk on patterns 1-3. The fourth value never appeared."""
    raw = lenient_json.load_path(require_capture(DIRECTION))

    stored = [_bits(raw, TRACK_2_ITEM, BITS, p) for p in (1, 2, 3)]
    assert stored == [SEQ_DEFAULT, 52, 84]
    assert [PatternBits.decode(v).direction for v in stored] == [
        PlaybackDirection.FORWARD,
        PlaybackDirection.RANDOM,
        PlaybackDirection.WALK,
    ]


@pytest.mark.hardware
def test_the_drum_field_shares_the_layout(require_capture: Callable[[str], Path]) -> None:
    """116 across 11 drum patterns: the same four fields, decoded the same way.

    Had the two halves differed, every drum pattern would need its own sweep.
    """
    raw = lenient_json.load_path(require_capture(DRUM))
    decoded = {p: PatternBits.decode(_bits(raw, TRACK_1_ITEM, DRUM_BITS, p)) for p in range(1, 12)}

    # Direction, on patterns 2 and 3.
    assert decoded[2].direction is PlaybackDirection.RANDOM
    assert decoded[3].direction is PlaybackDirection.WALK

    # Step size, on patterns 4-7, then the same four again with triplet on.
    assert [decoded[p].step_denominator for p in (4, 5, 6, 7)] == [4, 8, 16, 32]
    assert not any(decoded[p].triplet for p in (4, 5, 6, 7))
    assert [decoded[p].step_denominator for p in (8, 9, 10, 11)] == [4, 8, 16, 32]
    assert all(decoded[p].triplet for p in (8, 9, 10, 11))

    # Mono throughout -- the drum default, and the only field left untouched.
    assert not any(b.polyrhythm for b in decoded.values())


@pytest.mark.hardware
def test_no_capture_sets_the_unallocated_bit(require_capture: Callable[[str], Path]) -> None:
    """Bit 1 is named by the dictionary and set by nothing.

    Every value tier 5 produced, on both halves, is accounted for by the four
    measured fields -- which is what makes reporting a leftover bit meaningful.
    """
    for name in (STEP_SIZE, TRIPLET, MONORHYTHM, DIRECTION, DRUM, SWING_OFFSET):
        raw = lenient_json.load_path(require_capture(name))
        for item, param in ((TRACK_1_ITEM, DRUM_BITS), (TRACK_2_ITEM, BITS), (TRACK_3_ITEM, BITS)):
            for pattern in range(1, constants.PATTERNS_PER_TRACK + 1):
                stored = _bits(raw, item, param, pattern)
                assert constants.unallocated_bits(stored) == 0, f"{name} {item}_{param}_{pattern}"


# --- T5.6 -- root note and scale -------------------------------------------


@pytest.mark.hardware
def test_root_note_is_a_pitch_class(require_capture: Callable[[str], Path]) -> None:
    """Root D on Track 3 pattern 1 stores 2, and the octave is stored nowhere."""
    project = load(require_capture(ROOT_NOTE))
    pattern = project.track(3).pattern(1)

    assert pattern.root_note == 2
    assert constants.root_note_name(pattern.root_note) == "D"
    assert pattern.scale_name == "Minor"


@pytest.mark.hardware
def test_scale_indexes_the_device_list_in_display_order(
    require_capture: Callable[[str], Path],
) -> None:
    """Patterns 1-10 walk the list on both a melodic track and the drum one.

    Pattern 8 is the exception and the finding: selecting **Root** stores
    nothing, so it stays at whatever the pattern already held.
    """
    raw = lenient_json.load_path(require_capture(SCALE))

    for item in (TRACK_1_ITEM, TRACK_2_ITEM):
        stored = {p: raw[key(item, constants.P_SCALE, p)] for p in range(1, 11)}
        expected = {p: p - 1 for p in range(1, 11)}
        expected[constants.UNSTORABLE_SCALE + 1] = 0
        assert stored == expected, f"item {item}"

    assert constants.SCALE_NAMES[constants.UNSTORABLE_SCALE] == "Root"
    assert [constants.scale_name(i) for i in (0, 1, 2)] == ["Chromatic", "Major", "Minor"]


# --- T5.7 -- pattern chaining ----------------------------------------------


@pytest.mark.hardware
def test_a_chain_is_zero_based_pattern_numbers_in_order(
    require_capture: Callable[[str], Path],
) -> None:
    """Patterns 1-3 chained on Track 2 in scene 1.

    Two things are being pinned: the values are 0-based and contiguous with
    the rest left at the sentinel, and the track index in the key really is
    the track number -- the one place the item ordering is not the obvious one.
    """
    raw = lenient_json.load_path(require_capture(CHAIN))

    slots = [
        raw[key(constants.ITEM_SCENES, constants.P_SCENE_CHAIN, 1, 2, s)]
        for s in range(1, constants.CHAIN_SLOTS + 1)
    ]
    assert slots[:3] == [0, 1, 2]
    assert set(slots[3:]) == {constants.SENTINEL}

    project = load(require_capture(CHAIN))
    scene = project.scenes[0]
    assert [(c.track, c.patterns) for c in scene.chains] == [(2, (1, 2, 3))]
    # No other scene or track chains anything.
    assert project.chained_scenes == (scene,)


@pytest.mark.hardware
def test_the_scene_pattern_state_moves_but_is_not_read(
    require_capture: Callable[[str], Path],
) -> None:
    """83 goes 0 -> 32 alongside the chain, and one capture cannot say why.

    ``(last << 4) | first`` and ``(len - 1) << 4`` both give 32 for a chain of
    patterns 1-3, so this records the observation and nothing decodes it.
    """
    before = lenient_json.load_path(require_capture(BASELINE))
    after = lenient_json.load_path(require_capture(CHAIN))

    state = key(constants.ITEM_SCENES, constants.P_SCENE_PATTERN_STATE, 1, 2)
    assert (before[state], after[state]) == (0, 32)


# --- T5.8 -- step skip is repeats ------------------------------------------


@pytest.mark.hardware
def test_the_skip_mask_selects_a_repeat_not_a_page(
    require_capture: Callable[[str], Path],
) -> None:
    """Four notes in a 16-step pattern, one per sequence.

    The file half of T5.8: bit *i* of ``49`` is sequence *i*, held at the
    **step** the note sits on. The audible half -- beat 1 on pass 1, beat 5 on
    pass 2, and so on over eight loops -- is what the repeats reading rests on
    and cannot be asserted from a file.
    """
    raw = lenient_json.load_path(require_capture(SKIP))

    masks = {
        step: raw[key(TRACK_2_ITEM, constants.P_SEQ_STEP_SKIP, 1, 1, step)]
        for step in (1, 5, 9, 13)
    }
    assert masks == {1: 1, 5: 2, 9: 4, 13: 8}
    assert [constants.decode_skip_mask(masks[s]) for s in (1, 5, 9, 13)] == [
        (16,),
        (32,),
        (48,),
        (64,),
    ]

    # A 16-step pattern carrying a mask for sequence 4 is only coherent under
    # the repeats reading; under pages that note could never sound.
    pattern = load(require_capture(SKIP)).track(2).pattern(1)
    assert pattern.seq_step_count == 16


@pytest.mark.hardware
def test_the_capture_renders_one_note_per_pass(require_capture: Callable[[str], Path]) -> None:
    """What --passes does with the capture that defined it.

    Four repeats of a 16-step pattern, each holding exactly the note whose
    mask names it, in the order the operator heard them.
    """
    pattern = load(require_capture(SKIP)).track(2).pattern(1)
    assert auto_passes(pattern.notes) == constants.SKIP_CYCLE_PASSES

    rendering = render_pattern(
        pattern, track_number=2, kind=NoteKind.SEQ, options=ExportOptions(passes=4)
    )
    # Step 1 in the first repeat, step 5 in the second, and so on: each note
    # one whole pattern further on than the last.
    ticks_per_step = ExportOptions().ticks_per_beat // 4
    assert [n.tick for n in rendering.notes] == [
        0,
        (16 + 4) * ticks_per_step,
        (32 + 8) * ticks_per_step,
        (48 + 12) * ticks_per_step,
    ]
    assert rendering.length_ticks == 64 * ticks_per_step
