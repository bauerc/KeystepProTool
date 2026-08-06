"""Writing one note, and writing one value on a note that is already there.

Milestone M4. Both operations are specified by a hardware capture diff rather
than inferred, and the two replay tests below hold them to the device's own
files byte for byte. Those captures are gitignored, so the replays skip when
they are absent; ``test_placing_a_note_writes_exactly_the_measured_recipe``
carries the same 8-key result against the committed ``baseline.KeyStepPro`` and
never skips.
"""

from collections.abc import Callable
from pathlib import Path

import pytest

from ksp import constants, lenient_json, mutate, reader
from ksp.keys import key
from ksp.model import NoteKind

Loader = Callable[[str], dict[str, int | str]]

TRACK_2_ITEM = 124
TRACK_3_ITEM = 125

#: B0-baseline -> T1-note-place: what the device wrote when a human placed one
#: note on Track 2, pattern 1, step 1, pitch 60, leaving every default alone.
PLACEMENT_RECIPE = {
    "124_40_1": (2, 3),
    "124_48_1_1_1": (0, 1),
    "124_50_1_1_1": (127, 0),
    "124_109_1_1_1": (127, 60),
    "124_110_1_1_1": (127, 7),
    "124_111_1_1_1": (127, 100),
    "124_112_1_1_1": (127, 49),
    "124_113_1_1_1": (127, 100),
}


def changed(before: dict[str, int | str], after: dict[str, int | str]) -> dict[str, object]:
    """Keys whose value moved, as ``{key: (before, after)}``."""
    return {k: (before.get(k), after[k]) for k in after if before.get(k) != after[k]}


# --- The measured recipe ---------------------------------------------------


def test_placing_a_note_writes_exactly_the_measured_recipe(load_sample: Loader) -> None:
    """The 8 keys of B0-baseline -> T1-note-place, and nothing else.

    ``baseline.KeyStepPro`` is byte-identical to that capture, so this runs
    everywhere the repository does rather than only on the operator's machine.
    """
    base = load_sample("baseline.KeyStepPro")
    placed = mutate.place_note(base, track=2, pattern=1, step=1, pitch=60)

    assert changed(base, placed) == PLACEMENT_RECIPE


def test_step_skip_is_not_written(load_sample: Loader) -> None:
    """49 already reads 15 -- "plays on all four sequences" -- everywhere."""
    base = load_sample("baseline.KeyStepPro")
    assert base[key(TRACK_2_ITEM, constants.P_SEQ_STEP_SKIP, 1, 1, 1)] == 15

    placed = mutate.place_note(base, track=2, pattern=1, step=1, pitch=60)
    assert not any(f"_{constants.P_SEQ_STEP_SKIP}_" in k for k in changed(base, placed))


def test_a_chord_sets_one_step_active_bit(load_sample: Loader) -> None:
    """Three notes on one step: three pool entries, one flag.

    48 is step-indexed while the pool is note-indexed (spec section 4), and the
    D2 chord captures show four voices on step 1 sharing a single 48 bit. A
    writer that indexed 48 by ordinal would light steps 1-3 instead.
    """
    project = load_sample("baseline.KeyStepPro")
    for pitch in (48, 52, 55):
        project = mutate.place_note(project, track=2, pattern=1, step=1, pitch=pitch)

    for ordinal, pitch in enumerate((48, 52, 55), start=1):
        assert project[key(TRACK_2_ITEM, constants.P_SEQ_PITCH, 1, 1, ordinal)] == pitch
        assert project[key(TRACK_2_ITEM, constants.P_SEQ_NOTE_STEP, 1, 1, ordinal)] == 0

    active = [k for k in changed(load_sample("baseline.KeyStepPro"), project) if "_48_" in k]
    assert active == [key(TRACK_2_ITEM, constants.P_SEQ_STEP_ACTIVE, 1, 1, 1)]


def test_place_note_fills_ordinals_from_one_without_gaps(load_sample: Loader) -> None:
    """The melodic pool is compacted, so a writer must pack it that way."""
    project = load_sample("baseline.KeyStepPro")
    for step in (1, 5, 9):
        project = mutate.place_note(project, track=2, pattern=1, step=step, pitch=60)

    steps = [project[key(TRACK_2_ITEM, constants.P_SEQ_NOTE_STEP, 1, 1, i)] for i in range(1, 5)]
    assert steps == [0, 4, 8, constants.SENTINEL]


def test_place_note_without_activate_leaves_the_step_dark(load_sample: Loader) -> None:
    """The M4.1 control note: pooled, fully formed, and not flagged."""
    base = load_sample("baseline.KeyStepPro")
    placed = mutate.place_note(base, track=2, pattern=1, step=5, pitch=60, activate=False)

    assert placed[key(TRACK_2_ITEM, constants.P_SEQ_NOTE_STEP, 1, 1, 1)] == 4
    assert placed[key(TRACK_2_ITEM, constants.P_SEQ_STEP_ACTIVE, 1, 1, 5)] == 0
    assert not any("_48_" in k for k in changed(base, placed))


def test_the_reader_sees_a_placed_note(load_sample: Loader) -> None:
    """Round-trip through the decoder, which is the half M1 already proved."""
    base = load_sample("baseline.KeyStepPro")
    placed = mutate.place_note(base, track=2, pattern=1, step=5, pitch=61, velocity=90)

    pattern = reader.read_project(placed).track(2).pattern(1)
    notes = pattern.notes_of(NoteKind.SEQ)
    assert len(notes) == 1
    assert (notes[0].step, notes[0].pitch, notes[0].velocity) == (5, 61, 90)
    assert notes[0].active


# --- Changing one value ----------------------------------------------------


def test_set_pitch_changes_exactly_one_line(load_sample: Loader) -> None:
    """project_5 Track 3 note 5 is C#2, hardware-confirmed. Move it an octave."""
    base = load_sample("project_5.KeyStepPro")
    target = mutate.pitch_key(track=3, pattern=1, note=5)
    assert base[target] == 49

    edited = mutate.set_pitch(base, track=3, pattern=1, note=5, pitch=61)
    assert changed(base, edited) == {target: (49, 61)}


def test_set_pitch_leaves_its_neighbours_alone(load_sample: Loader) -> None:
    """Ordinals 6-8 share pitch 49, so an off-by-one would show here."""
    edited = mutate.set_pitch(
        load_sample("project_5.KeyStepPro"), track=3, pattern=1, note=5, pitch=61
    )
    pitches = [edited[key(TRACK_3_ITEM, constants.P_SEQ_PITCH, 1, 1, i)] for i in range(4, 9)]
    assert pitches == [48, 61, 49, 49, 49]


def test_the_reader_sees_the_new_pitch(load_sample: Loader) -> None:
    edited = mutate.set_pitch(
        load_sample("project_5.KeyStepPro"), track=3, pattern=1, note=5, pitch=61
    )
    notes = reader.read_project(edited).track(3).pattern(1).notes_of(NoteKind.SEQ)

    assert [n.pitch for n in notes[:8]] == [48, 48, 48, 48, 61, 49, 49, 49]
    assert notes[4].step == 5 and notes[4].velocity == 60 and notes[4].active


def test_pitch_key_addresses_the_documented_key() -> None:
    assert mutate.pitch_key(track=3, pattern=1, note=5) == "125_109_1_1_5"


# --- The fixed key set -----------------------------------------------------


@pytest.mark.parametrize("operation", ["place", "pitch"])
def test_mutation_never_adds_or_removes_a_key(load_sample: Loader, operation: str) -> None:
    """153,497 keys in, 153,497 keys out. Spec section 2."""
    base = load_sample("project_5.KeyStepPro")
    if operation == "place":
        after = mutate.place_note(base, track=2, pattern=1, step=1, pitch=60)
    else:
        after = mutate.set_pitch(base, track=3, pattern=1, note=5, pitch=61)

    assert after.keys() == base.keys()


def test_mutation_leaves_the_source_untouched(load_sample: Loader) -> None:
    base = load_sample("project_5.KeyStepPro")
    target = mutate.pitch_key(track=3, pattern=1, note=5)

    mutate.set_pitch(base, track=3, pattern=1, note=5, pitch=61)
    assert base[target] == 49


# --- Refusals --------------------------------------------------------------


def test_set_pitch_refuses_a_note_that_is_not_in_the_pool(load_sample: Loader) -> None:
    """A pitch on an absent note is a pitch nothing plays."""
    base = load_sample("project_5.KeyStepPro")
    assert base["124_50_16_1_1"] == constants.SENTINEL

    with pytest.raises(ValueError, match="no note at ordinal"):
        mutate.set_pitch(base, track=2, pattern=16, note=1, pitch=60)


def test_place_note_refuses_track_1_slot_4(load_sample: Loader) -> None:
    """Zero-filled phantom; capture D2-chord4-tr1 put a 4th voice in slot 1."""
    with pytest.raises(ValueError, match="phantom"):
        mutate.place_note(
            load_sample("baseline.KeyStepPro"), track=1, pattern=1, step=1, pitch=60, slot=4
        )


@pytest.mark.parametrize(
    ("kwargs", "match"),
    [
        ({"track": 5}, "track 5"),
        ({"pattern": 17}, "pattern 17"),
        ({"step": 65}, "step 65"),
        ({"pitch": 128}, "pitch 128"),
        ({"pitch": -1}, "pitch -1"),
        ({"velocity": 128}, "velocity 128"),
        ({"slot": 4}, "slot 4"),
        # Narrower than the 7-bit field: tier 7 found the encoder stops at
        # stored 0 and 99, so 100 is a value no display can reach.
        ({"time_shift": 100}, "time shift 100"),
        ({"time_shift": -1}, "time shift -1"),
    ],
)
def test_place_note_refuses_out_of_range(
    load_sample: Loader, kwargs: dict[str, int], match: str
) -> None:
    args: dict[str, int] = {"track": 2, "pattern": 1, "step": 1, "pitch": 60, **kwargs}
    with pytest.raises(ValueError, match=match):
        mutate.place_note(load_sample("baseline.KeyStepPro"), **args)  # type: ignore[arg-type]


@pytest.mark.parametrize("stored", [0, 99])
def test_place_note_accepts_both_time_shift_extremes(load_sample: Loader, stored: int) -> None:
    """The ends of the measured range are reachable, not off-by-one rejected."""
    raw = mutate.place_note(
        load_sample("baseline.KeyStepPro"), track=2, pattern=1, step=1, pitch=60, time_shift=stored
    )
    assert raw[f"124_{constants.P_SEQ_TIME_SHIFT}_1_1_1"] == stored


def test_place_note_refuses_a_seventeenth_note_on_one_step(load_sample: Loader) -> None:
    """The firmware refuses it with an on-screen message (capture T4.6)."""
    project = load_sample("baseline.KeyStepPro")
    for _ in range(constants.MAX_NOTES_PER_STEP):
        project = mutate.place_note(project, track=2, pattern=1, step=1, pitch=60)

    with pytest.raises(ValueError, match="per-step limit"):
        mutate.place_note(project, track=2, pattern=1, step=1, pitch=60)


def test_place_note_refuses_a_full_slot(load_sample: Loader) -> None:
    project = load_sample("baseline.KeyStepPro")
    for step in range(1, constants.MAX_STEPS + 1):
        project = mutate.place_note(project, track=2, pattern=1, step=step, pitch=60)

    with pytest.raises(ValueError, match="is full"):
        mutate.place_note(project, track=2, pattern=1, step=1, pitch=60)


def test_a_bad_address_is_a_key_error() -> None:
    """The fixed key set is what catches an address the file cannot hold."""
    with pytest.raises(KeyError):
        mutate.set_pitch({"125_50_1_1_1": 0}, track=3, pattern=1, note=1, pitch=61)


# --- Replays against the device's own files --------------------------------


def test_place_note_reproduces_the_devices_own_placement(
    load_sample: Loader, require_capture: Callable[[str], Path]
) -> None:
    """B0-baseline -> T1-note-place, made by a human at the device.

    Compared through the writer rather than as raw bytes: M3 already holds
    ``dumps(loads(x)) == x`` on every sample, so this asserts the same thing
    while staying indifferent to how the writer punctuates.
    """
    expected = lenient_json.load_path(require_capture("T1-note-place.KeyStepPro"))
    placed = mutate.place_note(
        load_sample("baseline.KeyStepPro"), track=2, pattern=1, step=1, pitch=60
    )

    assert lenient_json.dumps(placed) == lenient_json.dumps(expected)


def test_set_pitch_reproduces_the_devices_own_pitch_edit(
    require_capture: Callable[[str], Path],
) -> None:
    """T1-note-place -> T1-note-pitch: the same edit, made on the hardware."""
    source = lenient_json.load_path(require_capture("T1-note-place.KeyStepPro"))
    expected = lenient_json.load_path(require_capture("T1-note-pitch.KeyStepPro"))

    edited = mutate.set_pitch(source, track=2, pattern=1, note=1, pitch=64)
    assert lenient_json.dumps(edited) == lenient_json.dumps(expected)
