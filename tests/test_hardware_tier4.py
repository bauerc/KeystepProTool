"""Tier 4 -- melodic step-active, melodic pool chunking, and the drum map.

Four questions the files on disk could not answer, all now captured. Each test
here reads a capture and asserts the measurement, so a finding that reached the
spec as prose also has something executable behind it.

The captures are gitignored, so these skip on a fresh clone and on CI; they run
on the operator's machine. What they pin:

- **T4.5** a melodic note whose step-active flag is clear stays in the pool and
  does not sound, exactly as capture D1 showed for drums. ``midi_export`` drops
  such notes on both parameter sets and had measured ground only under the drum
  half until this capture.
- **T4.6** the melodic pool chunks at 64 events like the drum pool, while ``48``
  stays wholly in chunk 1 -- which is what ``reader._read_step_active`` assumes
  when it reads slot 1 and treats the result as pattern-wide.
- **D5** the device's drum map is chromatic from 36, lane *i* playing ``low + i``.
  This is the only test in the suite that reads the hardware's own MIDI output.
"""

from collections.abc import Callable
from pathlib import Path

import mido
import pytest

from ksp import constants, lenient_json
from ksp.drum_map import DEFAULT_CHROMATIC_LOW, DrumMap
from ksp.keys import key
from ksp.midi_export import DRUM_CHANNEL
from ksp.model import NoteKind
from ksp.reader import load

TRACK_1_ITEM = 123
TRACK_2_ITEM = 124

TWO_NOTES = "T4-melodic-two-notes.KeyStepPro"
STEP_OFF = "T4-melodic-step-off.KeyStepPro"
OVERFLOW = "T4-melodic-overflow-v2.KeyStepPro"
DRUM_MAP = "D5-drum-map.KeyStepPro"
DRUM_MAP_MIDI = "D5-drum-map.mid"

#: The step the operator toggled off, 1-based as the device numbers beats.
STEP_OFF_BEAT = 5

#: The drum map capture puts lane *i* on step *i+1* across all 24 lanes, so one
#: pass emits every mapping in order and the pitch heard on step *n* is the note
#: for lane *n-1*.
DRUM_MAP_LANES = tuple(range(constants.DRUM_LANE_COUNT))


def _changed(
    before: dict[str, int | str], after: dict[str, int | str]
) -> dict[str, tuple[object, object]]:
    keys = before.keys() | after.keys()
    return {k: (before.get(k), after.get(k)) for k in keys if before.get(k) != after.get(k)}


# --- T4.5 -- melodic step-off ---------------------------------------------


@pytest.mark.hardware
def test_toggling_a_melodic_step_off_moves_one_key(
    require_capture: Callable[[str], Path],
) -> None:
    """The flag alone, and the pool entry survives it.

    This is the file-side half of T4.5: had the device cleared the pool entry
    too, melodic deletion and deactivation would be the same operation and
    ``include_disabled`` would have nothing to restore.
    """
    before = lenient_json.load_path(require_capture(TWO_NOTES))
    after = lenient_json.load_path(require_capture(STEP_OFF))

    flag = key(TRACK_2_ITEM, constants.P_SEQ_STEP_ACTIVE, 1, 1, STEP_OFF_BEAT)
    assert _changed(before, after) == {flag: (1, 0)}


@pytest.mark.hardware
def test_the_unflagged_melodic_note_reads_as_disabled(
    require_capture: Callable[[str], Path],
) -> None:
    """And the device agreed: the operator reports beat 5 did not sound."""
    pattern = load(require_capture(STEP_OFF)).tracks[1].patterns[0]
    by_step = {n.step: n for n in pattern.notes if n.kind is NoteKind.SEQ}

    assert by_step[1].active
    assert not by_step[STEP_OFF_BEAT].active
    # Both are still fully formed -- same pitch, same velocity, one bit apart.
    assert by_step[1].pitch == by_step[STEP_OFF_BEAT].pitch
    assert by_step[1].velocity == by_step[STEP_OFF_BEAT].velocity


# --- T4.6 -- melodic pool overflow ----------------------------------------


@pytest.mark.hardware
def test_the_melodic_pool_spills_across_all_three_chunks(
    require_capture: Callable[[str], Path],
) -> None:
    """192 events, 64 per chunk -- the drum result from D3 on the melodic set."""
    raw = lenient_json.load_path(require_capture(OVERFLOW))

    for chunk in range(1, constants.POOL_SLOTS + 1):
        live = [
            step
            for ordinal in range(1, constants.MAX_STEPS + 1)
            if (step := raw[key(TRACK_2_ITEM, constants.P_SEQ_NOTE_STEP, 1, chunk, ordinal)])
            != constants.SENTINEL
        ]
        assert len(live) == constants.MAX_STEPS, f"chunk {chunk} is not full"


@pytest.mark.hardware
@pytest.mark.parametrize("pattern", [1, 2])
def test_step_active_never_leaves_chunk_1(
    require_capture: Callable[[str], Path], pattern: int
) -> None:
    """The assumption behind reading ``48`` from slot 1 and stopping.

    It is structural rather than lucky: ``48`` holds one entry per step, a
    pattern has at most 64 steps, and a chunk is 64 entries -- so a full set of
    flags fills chunk 1 exactly and has nothing left to spill.
    """
    raw = lenient_json.load_path(require_capture(OVERFLOW))

    for chunk in range(2, constants.POOL_SLOTS + 1):
        flags = [
            raw[key(TRACK_2_ITEM, constants.P_SEQ_STEP_ACTIVE, pattern, chunk, step)]
            for step in range(1, constants.MAX_STEPS + 1)
        ]
        assert set(flags) == {0}, f"pattern {pattern} chunk {chunk} carries step-active flags"


@pytest.mark.hardware
@pytest.mark.parametrize(
    ("pattern", "notes_per_step"),
    [
        # Chords four deep across 48 steps, then the device refused step 49.
        (1, 4),
        # And the per-step ceiling reached head-on: 12 steps of 16.
        (2, constants.MAX_NOTES_PER_STEP),
    ],
)
def test_both_firmware_ceilings_are_what_the_device_enforced(
    require_capture: Callable[[str], Path], pattern: int, notes_per_step: int
) -> None:
    """Two routes to 192, each stopped by its own on-screen message."""
    raw = lenient_json.load_path(require_capture(OVERFLOW))

    steps = [
        step
        for chunk in range(1, constants.POOL_SLOTS + 1)
        for ordinal in range(1, constants.MAX_STEPS + 1)
        if (step := raw[key(TRACK_2_ITEM, constants.P_SEQ_NOTE_STEP, pattern, chunk, ordinal)])
        != constants.SENTINEL
    ]

    assert len(steps) == constants.POOL_CAPACITY
    assert max(steps.count(s) for s in set(steps)) == notes_per_step


@pytest.mark.hardware
def test_the_reader_returns_every_note_of_a_full_pattern(
    require_capture: Callable[[str], Path],
) -> None:
    """The regression net for the slot-1-only decode.

    A reader that took step-active from chunk 1 but stopped reading the *pool*
    there would return 64; one that mistook the all-zero ``48`` chunks for a
    lane of cleared flags would return 192 notes with most of them disabled.
    """
    pattern = load(require_capture(OVERFLOW)).tracks[1].patterns[0]
    notes = [n for n in pattern.notes if n.kind is NoteKind.SEQ]

    assert len(notes) == constants.POOL_CAPACITY
    assert all(n.active for n in notes)


# --- D5 -- the drum map ---------------------------------------------------


@pytest.mark.hardware
def test_the_capture_puts_one_lane_on_each_step(
    require_capture: Callable[[str], Path],
) -> None:
    """Lane *i* on step *i+1*, which is what makes the recording readable.

    Read through the reader rather than off the keys, because the pattern also
    holds five superseded hits on lanes 19-23 that the operator replaced. The
    step-active decode is what tells them apart, so this doubles as a check
    that it does.
    """
    pattern = load(require_capture(DRUM_MAP)).tracks[0].patterns[0]
    sounding = sorted(
        (n.step, n.pitch) for n in pattern.notes if n.kind is NoteKind.DRUM and n.active
    )

    assert sounding == [(lane + 1, lane) for lane in DRUM_MAP_LANES]


@pytest.mark.hardware
def test_the_device_transmits_chromatic_from_36(
    require_capture: Callable[[str], Path],
) -> None:
    """The one measurement in this suite taken off the hardware's MIDI output.

    Settles both halves of D5 at once. Lane 0 firing 36 with the low note at
    36 is what rules out ``low + i + 1``; MCC's ``defaultValue`` of 0 for Low
    note is its detached-UI fallback and does not describe the device.
    """
    played = [
        message.note
        for message in mido.MidiFile(require_capture(DRUM_MAP_MIDI))
        if message.type == "note_on" and message.velocity
    ]

    heard = played[: constants.DRUM_LANE_COUNT]
    assert heard == [DEFAULT_CHROMATIC_LOW + lane for lane in DRUM_MAP_LANES]

    factory = DrumMap.chromatic()
    assert [factory.note_for_lane(lane) for lane in DRUM_MAP_LANES] == heard


@pytest.mark.hardware
def test_the_recording_is_on_the_drum_channel(
    require_capture: Callable[[str], Path],
) -> None:
    """Channel 10, the drum output global's default, 0-based in the file."""
    channels = {
        message.channel
        for message in mido.MidiFile(require_capture(DRUM_MAP_MIDI))
        if message.type in ("note_on", "note_off")
    }

    assert channels == {DRUM_CHANNEL}
