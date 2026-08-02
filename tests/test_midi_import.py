"""Turning a MIDI clip into a pattern.

Milestone M5. Assertions are on :class:`~ksp.midi_import.Placement` data rather
than on a re-parsed project, with two exceptions that are the point of the
milestone: the changed-key diff is held to M4's hardware-measured 8-key recipe,
and one round trip goes back out through the M2 reader.
"""

from collections.abc import Callable
from pathlib import Path

import mido
import pytest

from ksp import constants, midi_import, reader
from ksp.diagnostics import Code
from ksp.midi_import import ImportOptions
from ksp.model import NoteKind
from test_mutate import PLACEMENT_RECIPE, changed

Loader = Callable[[str], dict[str, int | str]]

TICKS_PER_BEAT = 480
TICKS_PER_STEP = TICKS_PER_BEAT // 4

#: The 16 pitches of ``test_file_simple.mid``, in step order.
SIMPLE_PITCHES = [60, 62, 64, 60, 60, 61, 59, 60, 60, 72, 71, 69, 60, 62, 64, 60]


def clip_of(
    events: list[tuple[int, int, int]],
    *,
    ticks_per_beat: int = TICKS_PER_BEAT,
    length: int = TICKS_PER_STEP,
) -> mido.MidiFile:
    """A one-track file from ``(tick, pitch, velocity)`` triples."""
    midi = mido.MidiFile(type=0, ticks_per_beat=ticks_per_beat)
    track = mido.MidiTrack()
    midi.tracks.append(track)

    timed: list[tuple[int, str, int, int]] = []
    for tick, pitch, velocity in events:
        timed.append((tick, "note_on", pitch, velocity))
        timed.append((tick + length, "note_off", pitch, 64))

    previous = 0
    for tick, kind, pitch, velocity in sorted(timed):
        track.append(
            mido.Message(kind, note=pitch, velocity=velocity, time=tick - previous, channel=0)
        )
        previous = tick
    return midi


def steps_of(result: midi_import.ImportResult) -> list[tuple[int, int, int]]:
    return [(note.step, note.pitch, note.velocity) for note in result.notes]


# --- The measured recipe ---------------------------------------------------


def test_one_note_writes_exactly_the_m4_recipe(load_sample: Loader) -> None:
    """A one-note clip produces the device's own 8-key placement diff.

    ``PLACEMENT_RECIPE`` is what the KeyStep Pro wrote when a human placed one
    note, so this ties the converter to a hardware measurement rather than to
    our own idea of what a note is.
    """
    base = load_sample("baseline.KeyStepPro")
    result = midi_import.convert(clip_of([(0, 60, 100)]), base, track=2, pattern=1)

    assert changed(base, result.raw) == PLACEMENT_RECIPE


def test_conversion_never_adds_or_removes_a_key(load_sample: Loader) -> None:
    template = load_sample("Default.KeyStepPro")
    result = midi_import.convert(clip_of([(0, 60, 100), (TICKS_PER_STEP, 64, 90)]), template)

    assert result.raw.keys() == template.keys()


def test_conversion_leaves_the_template_untouched(load_sample: Loader) -> None:
    template = load_sample("Default.KeyStepPro")
    before = dict(template)
    midi_import.convert(clip_of([(0, 60, 100)]), template)

    assert template == before


# --- Reading a MIDI file ---------------------------------------------------


def test_read_clip_pairs_note_offs() -> None:
    clip = midi_import.read_clip(clip_of([(0, 60, 100), (240, 64, 90)]))

    assert [(n.tick, n.duration_ticks, n.pitch, n.velocity) for n in clip.notes] == [
        (0, 120, 60, 100),
        (240, 120, 64, 90),
    ]


def test_read_clip_treats_a_zero_velocity_note_on_as_a_note_off() -> None:
    midi = mido.MidiFile(type=0, ticks_per_beat=TICKS_PER_BEAT)
    track = mido.MidiTrack()
    midi.tracks.append(track)
    track.append(mido.Message("note_on", note=60, velocity=100, time=0))
    track.append(mido.Message("note_on", note=60, velocity=0, time=120))

    clip = midi_import.read_clip(midi)

    assert [(n.pitch, n.duration_ticks) for n in clip.notes] == [(60, 120)]


def test_read_clip_closes_a_note_the_file_never_ends() -> None:
    """A dangling note-on sounded, so it becomes a note rather than vanishing."""
    midi = mido.MidiFile(type=0, ticks_per_beat=TICKS_PER_BEAT)
    track = mido.MidiTrack()
    midi.tracks.append(track)
    track.append(mido.Message("note_on", note=60, velocity=100, time=0))
    track.append(mido.Message("note_on", note=64, velocity=100, time=240))
    track.append(mido.Message("note_off", note=64, velocity=64, time=120))

    clip = midi_import.read_clip(midi)

    assert sorted((n.pitch, n.duration_ticks) for n in clip.notes) == [(60, 360), (64, 120)]


def test_read_clip_takes_the_files_tempo() -> None:
    midi = clip_of([(0, 60, 100)])
    midi.tracks[0].insert(0, mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(140), time=0))

    # bpm2tempo rounds to whole microseconds, so the round trip is not exact.
    assert midi_import.read_clip(midi).tempo_bpm == pytest.approx(140, abs=0.01)


def test_midi_track_selects_one_track() -> None:
    midi = mido.MidiFile(type=1, ticks_per_beat=TICKS_PER_BEAT)
    for pitch in (60, 72):
        track = mido.MidiTrack()
        midi.tracks.append(track)
        track.append(mido.Message("note_on", note=pitch, velocity=100, time=0))
        track.append(mido.Message("note_off", note=pitch, velocity=64, time=120))

    both = midi_import.read_clip(midi)
    second = midi_import.read_clip(midi, ImportOptions(midi_track=2))

    assert [n.pitch for n in both.notes] == [60, 72]
    assert [n.pitch for n in second.notes] == [72]
    assert second.source_tracks == (2,)


# --- Quantising ------------------------------------------------------------


def test_notes_land_on_their_steps(load_sample: Loader) -> None:
    events = [(step * TICKS_PER_STEP, 60 + step, 100) for step in range(4)]
    result = midi_import.convert(clip_of(events), load_sample("Default.KeyStepPro"))

    assert steps_of(result) == [(1, 60, 100), (2, 61, 100), (3, 62, 100), (4, 63, 100)]


def test_steps_per_beat_changes_the_grid(load_sample: Loader) -> None:
    """At 1/8 steps a note one 1/16 in rounds onto step 1, not step 2."""
    template = load_sample("Default.KeyStepPro")
    events = [(0, 60, 100), (240, 64, 100)]

    eighths = midi_import.convert(
        clip_of(events), template, options=ImportOptions(steps_per_beat=2)
    )

    assert [note.step for note in eighths.notes] == [1, 2]


def test_an_off_grid_note_is_moved_to_the_nearest_step(load_sample: Loader) -> None:
    result = midi_import.convert(
        clip_of([(0, 60, 100), (130, 64, 100)]), load_sample("Default.KeyStepPro")
    )

    assert [note.step for note in result.notes] == [1, 2]
    assert Code.NOTES_QUANTISED in {d.code for d in result.diagnostics}


def test_a_clip_that_starts_late_is_anchored_to_step_one(load_sample: Loader) -> None:
    """DAWs export a clip with its session ticks intact; a loop has no lead-in."""
    result = midi_import.convert(
        clip_of([(1920, 60, 100), (2040, 64, 100)]), load_sample("Default.KeyStepPro")
    )

    assert steps_of(result) == [(1, 60, 100), (2, 64, 100)]
    assert Code.CLIP_ANCHORED in {d.code for d in result.diagnostics}


def test_a_clip_starting_at_zero_is_not_anchored(load_sample: Loader) -> None:
    result = midi_import.convert(clip_of([(0, 60, 100)]), load_sample("Default.KeyStepPro"))

    assert Code.CLIP_ANCHORED not in {d.code for d in result.diagnostics}


def test_simultaneous_notes_keep_the_highest(load_sample: Loader) -> None:
    events = [(0, 60, 100), (0, 67, 90), (0, 64, 80)]
    result = midi_import.convert(clip_of(events), load_sample("Default.KeyStepPro"))

    assert steps_of(result) == [(1, 67, 90)]
    dropped = [d for d in result.diagnostics if d.code is Code.CHORD_REDUCED]
    assert [d.subjects for d in dropped] == [2]


def test_notes_past_the_last_step_are_dropped(load_sample: Loader) -> None:
    """The device disables them rather than playing them, so they are not written."""
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(18)]
    result = midi_import.convert(clip_of(events), load_sample("Default.KeyStepPro"))

    assert result.step_count == 16
    assert [note.step for note in result.notes] == list(range(1, 17))
    dropped = [d for d in result.diagnostics if d.code is Code.PAST_PATTERN_END]
    assert [d.subjects for d in dropped] == [2]


def test_gate_and_tempo_are_reported_as_not_carried(load_sample: Loader) -> None:
    result = midi_import.convert(clip_of([(0, 60, 100)]), load_sample("Default.KeyStepPro"))
    codes = {d.code for d in result.diagnostics}

    assert Code.GATE_NOT_CARRIED in codes
    assert Code.TEMPO_NOT_CARRIED in codes


def test_an_empty_clip_warns_about_nothing(load_sample: Loader) -> None:
    """No notes means no decisions, so no caveats about what was not carried."""
    result = midi_import.convert(clip_of([]), load_sample("Default.KeyStepPro"))

    assert result.note_count == 0
    assert not result.diagnostics


def test_notes_from_two_tracks_are_reported(load_sample: Loader) -> None:
    midi = mido.MidiFile(type=1, ticks_per_beat=TICKS_PER_BEAT)
    for index, pitch in enumerate((60, 72)):
        track = mido.MidiTrack()
        midi.tracks.append(track)
        track.append(mido.Message("note_on", note=pitch, velocity=100, time=index * TICKS_PER_STEP))
        track.append(mido.Message("note_off", note=pitch, velocity=64, time=120))

    result = midi_import.convert(midi, load_sample("Default.KeyStepPro"))

    assert Code.MULTIPLE_SOURCES in {d.code for d in result.diagnostics}


def test_quantise_refuses_a_step_count_the_device_cannot_hold() -> None:
    clip = midi_import.read_clip(clip_of([(0, 60, 100)]))

    with pytest.raises(ValueError, match="out of range"):
        midi_import.quantise(clip, step_count=constants.MAX_STEPS + 1)


@pytest.mark.parametrize("options", [{"steps_per_beat": 0}, {"midi_track": 0}])
def test_options_refuse_impossible_values(options: dict[str, int]) -> None:
    with pytest.raises(ValueError):
        ImportOptions(**options)


# --- Writing into a project ------------------------------------------------


def test_the_step_active_flag_is_indexed_by_step(load_sample: Loader) -> None:
    """48 is step-indexed and lives in slot 1, while the pool is note-indexed.

    Two notes two steps apart light steps 1 and 3, never 1 and 2.
    """
    result = midi_import.convert(
        clip_of([(0, 60, 100), (2 * TICKS_PER_STEP, 64, 100)]),
        load_sample("Default.KeyStepPro"),
        track=2,
    )
    flags = {step: result.raw[f"124_48_1_1_{step}"] for step in range(1, 5)}

    assert flags == {1: 1, 2: 0, 3: 1, 4: 0}


def test_a_track_in_drum_or_arp_mode_is_refused(load_sample: Loader) -> None:
    template = load_sample("initial_project.KeyStepPro")

    with pytest.raises(ValueError, match="86 bit 6"):
        midi_import.convert(clip_of([(0, 60, 100)]), template, track=1)


def test_a_pattern_that_already_holds_notes_is_refused(load_sample: Loader) -> None:
    template = load_sample("project_5.KeyStepPro")

    with pytest.raises(ValueError, match="already holds notes"):
        midi_import.convert(clip_of([(0, 60, 100)]), template, track=3, pattern=1)


def test_an_empty_pattern_of_a_used_project_is_accepted(load_sample: Loader) -> None:
    result = midi_import.convert(
        clip_of([(0, 60, 100)]), load_sample("project_5.KeyStepPro"), track=3, pattern=2
    )

    assert steps_of(result) == [(1, 60, 100)]


@pytest.mark.parametrize("track", [0, 5])
def test_track_must_be_one_of_the_devices_four(load_sample: Loader, track: int) -> None:
    with pytest.raises(ValueError, match="out of range"):
        midi_import.convert(clip_of([(0, 60, 100)]), load_sample("Default.KeyStepPro"), track=track)


# --- The committed clips ---------------------------------------------------


def test_the_simple_clip_becomes_sixteen_steps(simple_clip: Path, load_sample: Loader) -> None:
    result = midi_import.convert(
        mido.MidiFile(simple_clip), load_sample("Default.KeyStepPro"), track=1
    )

    assert steps_of(result) == [
        (step, pitch, 100) for step, pitch in enumerate(SIMPLE_PITCHES, start=1)
    ]


def test_the_chord_clip_keeps_its_top_line(chord_clip: Path, load_sample: Loader) -> None:
    result = midi_import.convert(mido.MidiFile(chord_clip), load_sample("Default.KeyStepPro"))

    assert [(note.step, note.pitch) for note in result.notes][:4] == [
        (1, 67),
        (2, 67),
        (3, 69),
        (4, 69),
    ]


def test_the_simple_clip_round_trips_through_the_reader(
    simple_clip: Path, load_sample: Loader
) -> None:
    """M5 out, M2's reader back in: the desk check issue #7 asks for.

    Step, pitch and velocity only -- note lengths are not carried, by design.
    """
    result = midi_import.convert(
        mido.MidiFile(simple_clip), load_sample("Default.KeyStepPro"), track=1
    )
    project = reader.read_project(result.raw, source_name="round-trip")
    pattern = project.track(1).pattern(1)
    notes = pattern.notes_of(NoteKind.SEQ)

    assert [(n.step, n.pitch, n.velocity) for n in notes] == [
        (step, pitch, 100) for step, pitch in enumerate(SIMPLE_PITCHES, start=1)
    ]
    assert all(note.active for note in notes)
