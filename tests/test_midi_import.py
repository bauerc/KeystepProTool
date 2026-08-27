"""Turning a MIDI file into patterns."""

from collections.abc import Callable
from pathlib import Path
from typing import Any

import mido
import pytest

from ksp import constants, midi_export, midi_import, mutate, reader
from ksp.diagnostics import Code
from ksp.drum_map import DrumMap
from ksp.keys import key
from ksp.midi_import import ImportOptions, TrackRoute, TrackSegments
from ksp.model import NoteKind
from test_mutate import PLACEMENT_RECIPE, TRACK_2_ITEM, changed

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


def test_one_note_writes_exactly_the_m4_recipe(load_sample: Loader) -> None:
    """A one-note clip produces the device's own 8-key placement diff."""
    base = load_sample("baseline.KeyStepPro")
    result = midi_import.convert(
        clip_of([(0, 60, 100)], length=TICKS_PER_STEP // 2), base, track=2, pattern=1
    )

    assert changed(base, result.raw) == PLACEMENT_RECIPE


def test_a_non_default_step_size_writes_the_pattern_bitfield(load_sample: Loader) -> None:
    """One key beyond the recipe, and only when the grid is not the default."""
    base = load_sample("baseline.KeyStepPro")
    options = ImportOptions(steps_per_beat=8)
    # Half a step at this grid, so only the bitfield differs from the recipe.
    result = midi_import.convert(
        clip_of([(0, 60, 100)], length=TICKS_PER_BEAT // 8 // 2),
        base,
        track=2,
        pattern=1,
        options=options,
    )

    bits = key(TRACK_2_ITEM, constants.P_SEQ_PATTERN_BITS, 1)
    assert changed(base, result.raw) == PLACEMENT_RECIPE | {bits: (20, 28)}
    assert constants.step_denominator(28) == 32


def test_the_default_step_size_leaves_the_bitfield_alone(load_sample: Loader) -> None:
    """1/16 is what the template already holds, so writing it moves nothing."""
    base = load_sample("baseline.KeyStepPro")
    result = midi_import.convert(
        clip_of([(0, 60, 100)], length=TICKS_PER_STEP // 2), base, track=2, pattern=1
    )

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


def tracks_of(pitches: list[int]) -> mido.MidiFile:
    """A type 1 file, one single-note track per pitch."""
    midi = mido.MidiFile(type=1, ticks_per_beat=TICKS_PER_BEAT)
    for pitch in pitches:
        track = mido.MidiTrack()
        midi.tracks.append(track)
        track.append(mido.Message("note_on", note=pitch, velocity=100, time=0))
        track.append(mido.Message("note_off", note=pitch, velocity=64, time=120))
    return midi


def test_midi_tracks_selects_one_track() -> None:
    midi = tracks_of([60, 72])

    second = midi_import.read_clip(midi, ImportOptions(midi_tracks=frozenset({2})))

    assert [n.pitch for n in second.notes] == [72]
    assert second.source_tracks == (2,)


def test_an_empty_selection_reads_every_track() -> None:
    midi = tracks_of([60, 72])

    both = midi_import.read_clip(midi, ImportOptions(midi_tracks=frozenset()))

    assert [n.pitch for n in both.notes] == [60, 72]
    assert both.source_tracks == (1, 2)


def test_a_selected_track_the_file_lacks_is_refused() -> None:
    midi = tracks_of([60, 72, 76])

    with pytest.raises(ValueError, match=r"source track 5 was selected; the file has 3 tracks"):
        midi_import.read_song(midi, ImportOptions(midi_tracks=frozenset({5})))


def test_the_lowest_missing_selected_track_is_named() -> None:
    """One offender at a time, as the selection grammar itself reports."""
    midi = tracks_of([60, 72, 76])

    with pytest.raises(ValueError, match=r"source track 5 was selected"):
        midi_import.read_clip(midi, ImportOptions(midi_tracks=frozenset({5, 9})))


def test_a_non_contiguous_selection_arrives_in_file_order() -> None:
    """A set has no order, so the order the clips arrive in is the file's."""
    midi = tracks_of([60, 62, 64, 65, 67])

    song = midi_import.read_song(midi, ImportOptions(midi_tracks=frozenset({5, 1, 2})))

    assert [clip.source_tracks for clip in song.clips] == [(1,), (2,), (5,)]
    assert [clip.notes[0].pitch for clip in song.clips] == [60, 62, 67]


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


def test_simultaneous_notes_are_all_kept(load_sample: Loader) -> None:
    """The pool is an event list, not a step grid, so a chord is just notes."""
    events = [(0, 60, 100), (0, 67, 90), (0, 64, 80)]
    result = midi_import.convert(clip_of(events), load_sample("Default.KeyStepPro"))

    assert sorted(steps_of(result)) == [(1, 60, 100), (1, 64, 80), (1, 67, 90)]


def test_notes_past_the_last_step_are_dropped(load_sample: Loader) -> None:
    """The device disables them rather than playing them, so they are not written."""
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(18)]
    result = midi_import.convert(clip_of(events), load_sample("Default.KeyStepPro"))

    assert result.step_count == 16
    assert [note.step for note in result.notes] == list(range(1, 17))
    dropped = [d for d in result.diagnostics if d.code is Code.PAST_PATTERN_END]
    assert [d.subjects for d in dropped] == [2]


def test_a_notes_length_becomes_its_gate(load_sample: Loader) -> None:
    """M5 wrote every note at the fresh gate."""
    midi = mido.MidiFile(type=0, ticks_per_beat=TICKS_PER_BEAT)
    track = mido.MidiTrack()
    midi.tracks.append(track)
    # One note four steps long, then one a single step long.
    track.append(mido.Message("note_on", note=60, velocity=100, time=0))
    track.append(mido.Message("note_off", note=60, velocity=64, time=4 * TICKS_PER_STEP))
    track.append(mido.Message("note_on", note=64, velocity=100, time=0))
    track.append(mido.Message("note_off", note=64, velocity=64, time=TICKS_PER_STEP))

    result = midi_import.convert(midi, load_sample("Default.KeyStepPro"))

    assert [constants.GATE_TABLE[note.gate] for note in result.notes] == [4.0, 1.0]


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


@pytest.mark.parametrize(
    "options",
    [
        {"steps_per_beat": 0},
        {"midi_tracks": frozenset({0})},
        {"drum_track": 0},
        {"routes": (TrackRoute(0, 1),)},
        {"routes": (TrackRoute(1, 0),)},
        {"routes": (TrackRoute(1, 5),)},
        {"routes": (TrackRoute(1, 2), TrackRoute(1, 3))},
        {"routes": (TrackRoute(1, 2), TrackRoute(2, 2))},
        {"flat_velocity": 0},
        {"flat_velocity": 128},
    ],
)
def test_options_refuse_impossible_values(options: dict[str, Any]) -> None:
    with pytest.raises(ValueError):
        ImportOptions(**options)


def test_a_mutable_selection_is_copied_rather_than_aliased() -> None:
    """Swift's ``Set`` is a value type, so the frozen options must be too: aliased, a later mutation
    would slip past the check that already ran.
    """
    given = {1}
    options = ImportOptions(midi_tracks=given)
    given.add(0)

    assert options.midi_tracks == frozenset({1})
    assert hash(options) == hash(ImportOptions(midi_tracks=frozenset({1})))


def test_a_selected_track_below_one_is_named_by_the_option() -> None:
    """The message names the CLI flag, not the field, so it does not move."""
    with pytest.raises(ValueError, match=r"^midi_track counts from 1$"):
        ImportOptions(midi_tracks=frozenset({1, 0}))


def test_the_step_active_flag_is_indexed_by_step(load_sample: Loader) -> None:
    """48 is step-indexed and lives in slot 1, while the pool is note-indexed."""
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


def test_the_simple_clip_becomes_sixteen_steps(simple_clip: Path, load_sample: Loader) -> None:
    result = midi_import.convert(
        mido.MidiFile(simple_clip), load_sample("Default.KeyStepPro"), track=1
    )

    assert steps_of(result) == [
        (step, pitch, 100) for step, pitch in enumerate(SIMPLE_PITCHES, start=1)
    ]


def test_the_chord_clip_keeps_every_voice(chord_clip: Path, load_sample: Loader) -> None:
    """M5 kept only the top line of each chord; M6 writes the whole thing."""
    result = midi_import.convert(mido.MidiFile(chord_clip), load_sample("Default.KeyStepPro"))

    assert len(result.notes) == 26
    assert [(note.step, note.pitch) for note in result.notes][:6] == [
        (1, 60),
        (1, 64),
        (1, 67),
        (2, 60),
        (2, 64),
        (2, 67),
    ]


def test_the_simple_clip_round_trips_through_the_reader(
    simple_clip: Path, load_sample: Loader
) -> None:
    """M5 out, M2's reader back in: the desk check issue #7 asks for."""
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


def song_of(
    tracks: list[list[tuple[int, int, int]]],
    *,
    length: int = TICKS_PER_STEP,
    channels: list[int] | None = None,
) -> mido.MidiFile:
    """A type 1 file, one track per list of ``(tick, pitch, velocity)``."""
    midi = mido.MidiFile(type=1, ticks_per_beat=TICKS_PER_BEAT)
    for number, events in enumerate(tracks):
        channel = channels[number] if channels else 0
        track = mido.MidiTrack()
        midi.tracks.append(track)
        timed: list[tuple[int, str, int, int]] = []
        for tick, pitch, velocity in events:
            timed.append((tick, "note_on", pitch, velocity))
            timed.append((tick + length, "note_off", pitch, 64))
        previous = 0
        for tick, kind, pitch, velocity in sorted(timed):
            track.append(
                mido.Message(
                    kind, note=pitch, velocity=velocity, time=tick - previous, channel=channel
                )
            )
            previous = tick
    return midi


def test_each_source_track_gets_its_own_device_track(load_sample: Loader) -> None:
    midi = song_of([[(0, 60, 100)], [(0, 64, 100)], [(0, 67, 100)]])
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    assert [plan.track for plan in result.plan.tracks] == [1, 2, 3]
    assert [plan.notes[0].pitch for plan in result.plan.tracks] == [60, 64, 67]


def test_a_fifth_source_track_is_reported_rather_than_written(load_sample: Loader) -> None:
    midi = song_of([[(0, 60 + n, 100)] for n in range(5)])
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    assert len(result.plan.tracks) == 4
    dropped = [d for d in result.diagnostics if d.code is Code.TRACKS_DROPPED]
    assert [d.subjects for d in dropped] == [1]
    assert dropped[0].detail == ("1 source track(s) had nowhere to go; the device has 4 tracks")


def test_a_selection_wider_than_the_device_is_reported(load_sample: Loader) -> None:
    """Five selected tracks are still four device tracks and one report."""
    midi = song_of([[(0, 60 + n, 100)] for n in range(6)])
    options = ImportOptions(midi_tracks=frozenset({1, 2, 3, 4, 5}))
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)

    assert len(result.plan.tracks) == 4
    dropped = [d for d in result.diagnostics if d.code is Code.TRACKS_DROPPED]
    assert [d.subjects for d in dropped] == [1]
    assert dropped[0].detail == (
        "1 selected source track(s) had nowhere to go; the device has 4 tracks"
    )


def test_a_track_longer_than_one_pattern_is_split_and_chained(load_sample: Loader) -> None:
    """128 steps is two patterns, not a truncation."""
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(128)]
    result = midi_import.convert_song(song_of([events]), load_sample("Default.KeyStepPro"))

    plan = result.plan.tracks[0]
    assert plan.patterns == (1, 2)
    assert [p.step_count for p in plan.placements] == [64, 64]
    assert [len(p.notes) for p in plan.placements] == [64, 64]
    # The second pattern restarts at step 1 rather than continuing to count.
    assert plan.placements[1].notes[0].step == 1
    assert Code.PATTERN_SPLIT in {d.code for d in result.diagnostics}

    project = reader.read_project(result.raw, source_name="split")
    assert project.scenes[0].chains[0].patterns == (1, 2)


def test_a_note_past_the_first_pool_chunk_still_plays_on_every_pass(
    load_sample: Loader,
) -> None:
    """``49`` is step-indexed and lives wholly in chunk 1, like ``48``."""
    events = [(step * TICKS_PER_STEP, 60 + voice, 100) for step in range(32) for voice in range(3)]
    result = midi_import.convert_song(song_of([events]), load_sample("Default.KeyStepPro"))
    project = reader.read_project(result.raw, source_name="spilled")

    notes = project.track(1).pattern(1).notes_of(NoteKind.SEQ)
    assert len(notes) == 96
    assert {note.slot for note in notes} == {1, 2}
    assert all(note.skip == constants.SKIP_SEQUENCES for note in notes)


#: Every fault the segmentation grammar refuses, with the wording both ports use.
SEGMENT_ILLEGAL = [
    pytest.param(
        (TrackSegments(1, (1,)),),
        "segment bar 1 of source track 1 is not a boundary; bar 1 begins the first pattern",
        id="bar-one-is-not-a-boundary",
    ),
    pytest.param(
        (TrackSegments(1, (5, 3)),),
        "segment bars of source track 1 must ascend, and 3 does not follow 5",
        id="descending",
    ),
    pytest.param(
        (TrackSegments(1, (5, 5)),),
        "segment bars of source track 1 must ascend, and 5 does not follow 5",
        id="repeated",
    ),
    pytest.param(
        (TrackSegments(0, (2,)),),
        "segment counts source tracks from 1, so 0 is not one",
        id="source-below-one",
    ),
    pytest.param(
        (TrackSegments(1, (2,)), TrackSegments(1, (3,))),
        "segment names source track 1 twice",
        id="source-named-twice",
    ),
]


def test_explicit_bar_boundaries_cut_a_track_where_they_are_asked_for(
    load_sample: Loader,
) -> None:
    """Six bars cut at bar 4 is 48 and 48, where the automatic split gives 64 and 32."""
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(96)]
    options = ImportOptions(segments=(TrackSegments(source=1, bars=(4,)),))
    result = midi_import.convert_song(
        song_of([events]), load_sample("Default.KeyStepPro"), options=options
    )

    plan = result.plan.tracks[0]
    assert plan.patterns == (1, 2)
    assert [placement.step_count for placement in plan.placements] == [48, 48]
    assert [len(placement.notes) for placement in plan.placements] == [48, 48]
    # The second pattern restarts at step 1 rather than continuing to count.
    assert plan.placements[1].notes[0].step == 1
    segmented = [d for d in result.diagnostics if d.code == Code.PATTERN_SEGMENTED]
    assert [d.detail for d in segmented] == [
        "track 1 was cut at bar(s) 4 across patterns 1-2 and chained"
    ]
    assert Code.PATTERN_SPLIT not in {d.code for d in result.diagnostics}

    project = reader.read_project(result.raw, source_name="segmented")
    assert project.scenes[0].chains[0].patterns == (1, 2)


def test_boundaries_that_land_on_the_track_end_exactly_fill_their_patterns(
    load_sample: Loader,
) -> None:
    """Eight bars cut at bar 5 is two full patterns with nothing left over."""
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(128)]
    options = ImportOptions(segments=(TrackSegments(source=1, bars=(5,)),))
    result = midi_import.convert_song(
        song_of([events]), load_sample("Default.KeyStepPro"), options=options
    )

    plan = result.plan.tracks[0]
    assert [placement.step_count for placement in plan.placements] == [64, 64]
    assert plan.patterns == (1, 2)


def test_a_single_bar_segment_is_a_pattern_of_its_own(load_sample: Loader) -> None:
    """The smallest cut the device can chain, and three patterns is still one sequence."""
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(48)]
    options = ImportOptions(segments=(TrackSegments(source=1, bars=(2, 3)),))
    result = midi_import.convert_song(
        song_of([events]), load_sample("Default.KeyStepPro"), options=options
    )

    plan = result.plan.tracks[0]
    assert [placement.step_count for placement in plan.placements] == [16, 16, 16]
    assert plan.patterns == (1, 2, 3)

    project = reader.read_project(result.raw, source_name="segmented")
    assert project.scenes[0].chains[0].patterns == (1, 2, 3)


def test_a_segment_longer_than_the_device_plays_is_refused(load_sample: Loader) -> None:
    """Cutting eight bars at bar 6 leaves 80 steps in front of it, past the device's 64."""
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(128)]
    options = ImportOptions(segments=(TrackSegments(source=1, bars=(6,)),))

    with pytest.raises(ValueError) as caught:
        midi_import.convert_song(
            song_of([events]), load_sample("Default.KeyStepPro"), options=options
        )
    assert str(caught.value) == (
        "segmenting track 1 makes a pattern of 80 steps from bar 1, past the device's 64; cut "
        "it again before the tail runs over"
    )


def test_a_boundary_past_the_tracks_content_is_refused(load_sample: Loader) -> None:
    """A pattern beginning after the last bar would be an empty link in the chain."""
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(48)]
    options = ImportOptions(segments=(TrackSegments(source=1, bars=(9,)),))

    with pytest.raises(ValueError) as caught:
        midi_import.convert_song(
            song_of([events]), load_sample("Default.KeyStepPro"), options=options
        )
    assert str(caught.value) == (
        "segment bar 9 of track 1 is past the track's 3 bar(s); a boundary is where a pattern "
        "begins, so it has to fall inside the track"
    )


def test_segments_that_outrun_the_free_patterns_are_refused(load_sample: Loader) -> None:
    """Three patterns cannot be chained from pattern 15; the automatic split drops a
    tail here, but a boundary that was asked for is refused instead."""
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(48)]
    options = ImportOptions(segments=(TrackSegments(source=1, bars=(2, 3)),))

    with pytest.raises(ValueError) as caught:
        midi_import.convert_song(
            song_of([events]),
            load_sample("Default.KeyStepPro"),
            options=options,
            first_pattern=15,
        )
    assert str(caught.value) == (
        "segmenting track 1 makes 3 patterns but only 2 are free from pattern 15; a chain runs "
        "to pattern 16 at most"
    )


@pytest.mark.parametrize(("segments", "message"), SEGMENT_ILLEGAL)
def test_illegal_boundaries_are_refused_before_a_file_is_read(
    segments: tuple[TrackSegments, ...], message: str
) -> None:
    """Faults a segmentation has without knowing the song are refused as options.
    Compared whole: the Swift port has to refuse in the very same words."""
    with pytest.raises(ValueError) as caught:
        ImportOptions(segments=segments)
    assert str(caught.value) == message


def test_a_segmentation_naming_a_silent_source_track_is_refused(load_sample: Loader) -> None:
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(48)]
    options = ImportOptions(segments=(TrackSegments(source=3, bars=(2,)),))

    with pytest.raises(ValueError) as caught:
        midi_import.convert_song(
            song_of([events]), load_sample("Default.KeyStepPro"), options=options
        )
    assert str(caught.value) == (
        "track 3 of the source holds no notes; a segmentation counts every track of the file "
        "from 1, including ones that carry only tempo or a name"
    )


def test_a_track_no_segmentation_names_is_still_split_automatically(
    load_sample: Loader,
) -> None:
    """Absent boundaries the automatic split is untouched, track by track."""
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(96)]
    options = ImportOptions(segments=(TrackSegments(source=1, bars=(4,)),))
    result = midi_import.convert_song(
        song_of([events, events]), load_sample("Default.KeyStepPro"), options=options
    )

    assert [p.step_count for p in result.plan.tracks[0].placements] == [48, 48]
    assert [p.step_count for p in result.plan.tracks[1].placements] == [64, 32]
    assert Code.PATTERN_SPLIT in {d.code for d in result.diagnostics}


def test_a_tracks_length_rounds_up_to_the_bar(load_sample: Loader) -> None:
    """A loop that stops mid-bar drifts against every other track."""
    # Content ends at step 17 of a 16-step bar, so the pattern is two bars.
    events = [(0, 60, 100), (16 * TICKS_PER_STEP, 64, 100)]
    result = midi_import.convert_song(song_of([events]), load_sample("Default.KeyStepPro"))

    assert result.plan.tracks[0].placements[0].step_count == 32


def test_a_drum_track_is_written_to_track_one_in_drum_mode(load_sample: Loader) -> None:
    midi = song_of([[(0, 64, 100)], [(0, 36, 100), (TICKS_PER_STEP, 38, 100)]])
    options = ImportOptions(drum_track=2, drum_map=DrumMap.chromatic(36))
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)

    drum = next(plan for plan in result.plan.tracks if plan.is_drum)
    assert drum.track == 1
    assert [note.lane for note in drum.notes] == [0, 2]

    project = reader.read_project(result.raw, source_name="drums")
    assert project.track(1).drum_mode
    notes = project.track(1).pattern(1).notes_of(NoteKind.DRUM)
    assert [(note.step, note.pitch) for note in notes] == [(1, 0), (2, 2)]
    assert all(note.active for note in notes)


def test_a_percussion_channel_track_is_found_without_being_named(load_sample: Loader) -> None:
    """Channel 10 is what GM reserves, so it needs no flag when a file uses it."""
    midi = mido.MidiFile(type=1, ticks_per_beat=TICKS_PER_BEAT)
    track = mido.MidiTrack()
    midi.tracks.append(track)
    track.append(mido.Message("note_on", note=36, velocity=100, time=0, channel=9))
    track.append(mido.Message("note_off", note=36, velocity=64, time=TICKS_PER_STEP, channel=9))

    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    assert result.plan.tracks[0].is_drum


def test_a_drum_pitch_outside_the_map_is_dropped_and_counted(load_sample: Loader) -> None:
    midi = song_of([[(0, 36, 100), (TICKS_PER_STEP, 120, 100)]])
    options = ImportOptions(drum_track=1, drum_map=DrumMap.chromatic(36))
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)

    assert [note.lane for note in result.notes] == [0]
    unmapped = [d for d in result.diagnostics if d.code is Code.DRUM_PITCH_UNMAPPED]
    assert [d.subjects for d in unmapped] == [1]


def test_an_unset_drum_map_is_fitted_to_the_source(load_sample: Loader) -> None:
    """The real map is device state, so writing drums means assuming one."""
    midi = song_of([[(0, 31, 100), (TICKS_PER_STEP, 34, 100)]])
    result = midi_import.convert_song(
        midi, load_sample("Default.KeyStepPro"), options=ImportOptions(drum_track=1)
    )

    assert result.plan.drum_map is not None
    assert result.plan.drum_map.note_for_lane(0) == 31
    assert [note.lane for note in result.notes] == [0, 3]
    assert Code.DRUM_MAP_FITTED in {d.code for d in result.diagnostics}


@pytest.mark.parametrize("velocity", [1, 127])
def test_the_flat_velocity_bounds_are_accepted(velocity: int) -> None:
    assert ImportOptions(flat_velocity=velocity).flat_velocity == velocity


def test_a_flat_velocity_replaces_every_written_velocity(load_sample: Loader) -> None:
    events = [(0, 60, 20), (TICKS_PER_STEP, 62, 90), (TICKS_PER_STEP * 2, 64, 127)]
    result = midi_import.convert(
        clip_of(events),
        load_sample("Default.KeyStepPro"),
        options=ImportOptions(flat_velocity=64),
    )

    assert [note.velocity for note in result.notes] == [64, 64, 64]


def test_an_unset_flat_velocity_keeps_the_source_velocities(load_sample: Loader) -> None:
    events = [(0, 60, 20), (TICKS_PER_STEP, 62, 90), (TICKS_PER_STEP * 2, 64, 127)]
    result = midi_import.convert(clip_of(events), load_sample("Default.KeyStepPro"))

    assert [note.velocity for note in result.notes] == [20, 90, 127]


def test_a_flat_velocity_reaches_drum_triggers(load_sample: Loader) -> None:
    """Drums are written through a different mutate call, off the same PlacedNote."""
    midi = song_of([[(0, 36, 20), (TICKS_PER_STEP, 37, 90)]])
    options = ImportOptions(
        drum_track=1,
        drum_map=DrumMap.chromatic(36),
        flat_velocity=midi_export.DEFAULT_FLAT_VELOCITY,
    )
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)

    assert [note.lane for note in result.notes] == [0, 1]
    assert [note.velocity for note in result.notes] == [midi_export.DEFAULT_FLAT_VELOCITY] * 2


def test_the_source_tempo_is_written(load_sample: Loader) -> None:
    midi = song_of([[(0, 60, 100)]])
    midi.tracks[0].insert(0, mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(96), time=0))

    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    assert reader.read_project(result.raw, source_name="tempo").tempo_bpm == 96.0


def test_the_template_tempo_is_kept_when_asked(load_sample: Loader) -> None:
    template = load_sample("Default.KeyStepPro")
    midi = song_of([[(0, 60, 100)]])
    midi.tracks[0].insert(0, mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(96), time=0))

    result = midi_import.convert_song(midi, template, options=ImportOptions(carry_tempo=False))

    before = reader.read_project(template, source_name="before").tempo_bpm
    assert reader.read_project(result.raw, source_name="after").tempo_bpm == before


def test_a_pattern_over_the_pool_ceiling_is_reported(load_sample: Loader) -> None:
    """192 events per pattern, enforced by the firmware with an on-screen error."""
    events = [(step * TICKS_PER_STEP, 60 + voice, 100) for step in range(16) for voice in range(13)]
    result = midi_import.convert_song(song_of([events]), load_sample("Default.KeyStepPro"))

    assert len(result.notes) == constants.POOL_CAPACITY
    overflow = [d for d in result.diagnostics if d.code is Code.POOL_OVERFLOW]
    assert [d.subjects for d in overflow] == [16 * 13 - constants.POOL_CAPACITY]


def test_every_target_pattern_is_checked_before_anything_is_written(
    load_sample: Loader,
) -> None:
    """A half-converted file is worse than a refused one."""
    template = load_sample("Default.KeyStepPro")
    occupied = midi_import.apply(
        template,
        midi_import.SongPlan(
            tracks=(
                midi_import.TrackPlan(
                    track=1,
                    placements=(
                        midi_import.Placement(
                            notes=(midi_import.PlacedNote(step=1, pitch=60, velocity=100),),
                            step_count=16,
                            pattern=2,
                        ),
                    ),
                ),
            )
        ),
    )
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(128)]

    with pytest.raises(ValueError, match="already holds notes"):
        midi_import.convert_song(song_of([events]), occupied)


def swung(percent: int, steps: int = 16) -> mido.MidiFile:
    """One note per step, displaced exactly as the export would displace it."""
    events = []
    for step in range(steps):
        delay = 0 if not step % 2 else round(TICKS_PER_STEP * (2 * percent / 100 - 1))
        events.append((step * TICKS_PER_STEP + delay, 60, 100))
    return song_of([events])


@pytest.mark.parametrize("percent", [50, 54, 58, 62, 66, 75])
def test_a_swung_clip_comes_back_as_the_swing_it_was_made_with(
    percent: int, load_sample: Loader
) -> None:
    """The fit inverts ``midi_export.swing_delay``, so the two agree by construction rather than by
    coincidence (Timing_Calibration 3.2).
    """
    result = midi_import.convert_song(swung(percent), load_sample("Default.KeyStepPro"))

    assert result.plan.tracks[0].placements[0].swing_percent == percent


@pytest.mark.parametrize("percent", [50, 58, 66, 75])
def test_swing_survives_a_round_trip_through_the_exporter(
    percent: int, load_sample: Loader
) -> None:
    """Out through ksp2midi and back in, which is the real check."""
    template = load_sample("Default.KeyStepPro")
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(16)]
    written = midi_import.convert_song(song_of([events]), template)
    swung_project = mutate.set_swing(written.raw, track=1, pattern=1, percent=percent)

    exported = midi_export.export_project(reader.read_project(swung_project, source_name="swung"))
    back = midi_import.convert_song(exported.midi, template)

    assert back.plan.tracks[0].placements[0].swing_percent == percent


def test_a_fitted_groove_leaves_nothing_for_time_shift(load_sample: Loader) -> None:
    """That is the point of fitting swing first: one pattern-level value expresses the groove, so
    the scarce per-note field stays unspent.
    """
    result = midi_import.convert_song(swung(66), load_sample("Default.KeyStepPro"))

    assert {note.time_shift for note in result.notes} == {constants.TIME_SHIFT_CENTRE}


def test_swing_can_be_left_alone(load_sample: Loader) -> None:
    result = midi_import.convert_song(
        swung(66), load_sample("Default.KeyStepPro"), options=ImportOptions(fit_swing=False)
    )

    assert result.plan.tracks[0].placements[0].swing_percent == 50
    # With no swing to explain it, the groove goes to time shift instead.
    assert {note.time_shift for note in result.notes} != {constants.TIME_SHIFT_CENTRE}


def test_an_off_grid_note_within_reach_is_stored_as_a_time_shift(load_sample: Loader) -> None:
    """One unit is 1/400 of a beat -- 1.2 ticks at 480 PPQN, so 12 ticks is exactly 10 of them (spec
    6.4).
    """
    midi = song_of([[(0, 60, 100), (2 * TICKS_PER_STEP + 12, 64, 100)]])
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    shifts = [note.time_shift for note in result.notes]
    assert shifts == [constants.TIME_SHIFT_CENTRE, constants.TIME_SHIFT_CENTRE + 10]
    assert Code.TIMING_RESIDUAL not in {d.code for d in result.diagnostics}


def test_a_residual_past_the_shift_range_is_reported(load_sample: Loader) -> None:
    """The range is a fixed 60 ticks either way, not half a step, so at a 1/4 grid most residuals do
    not fit and the report is the whole point.
    """
    options = ImportOptions(steps_per_beat=1, fit_swing=False)
    midi = song_of([[(0, 60, 100), (TICKS_PER_BEAT + 200, 64, 100)]], length=TICKS_PER_BEAT)
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)

    assert max(note.time_shift for note in result.notes) == constants.TIME_SHIFT_STORED_MAX
    assert Code.TIMING_RESIDUAL in {d.code for d in result.diagnostics}


def test_time_shift_can_be_turned_off(load_sample: Loader) -> None:
    midi = song_of([[(0, 60, 100), (2 * TICKS_PER_STEP + 12, 64, 100)]])
    result = midi_import.convert_song(
        midi, load_sample("Default.KeyStepPro"), options=ImportOptions(fit_time_shift=False)
    )

    assert {note.time_shift for note in result.notes} == {constants.TIME_SHIFT_CENTRE}


def test_the_m6_song_converts_whole(m6_song: Path, load_sample: Loader) -> None:
    """The acceptance file: four tracks, chords, tied notes and a split."""
    result = midi_import.convert_song(
        mido.MidiFile(m6_song),
        load_sample("Default.KeyStepPro"),
        options=ImportOptions(drum_track=3),
    )

    shape = [
        (plan.track, plan.is_drum, plan.patterns, tuple(len(p.notes) for p in plan.placements))
        for plan in result.plan.tracks
    ]
    assert shape == [
        (1, True, (1,), (64,)),
        (2, False, (1,), (160,)),
        (3, False, (1,), (3,)),
        (4, False, (1, 2), (32, 32)),
    ]


def test_the_m6_song_round_trips_through_the_reader(m6_song: Path, load_sample: Loader) -> None:
    """Out through the writer, back in through M1, with nothing to report."""
    result = midi_import.convert_song(
        mido.MidiFile(m6_song),
        load_sample("Default.KeyStepPro"),
        options=ImportOptions(drum_track=3),
    )
    # Through saveable, which is what a caller writes: it injects the version
    # key the factory template lacks and every saved project has.
    project = reader.read_project(midi_import.saveable(result.raw), source_name="m6")

    assert not project.diagnostics
    assert project.tempo_bpm == 120.0

    drums = project.track(1).pattern(1)
    assert project.track(1).drum_mode
    assert len(drums.notes_of(NoteKind.DRUM)) == 64
    assert drums.drum_step_count == 64
    assert sorted({note.pitch for note in drums.notes_of(NoteKind.DRUM)}) == [0, 1, 2, 3]

    # The chords: 160 events over 48 steps, three and four to a step.
    chords = project.track(2).pattern(1)
    assert chords.seq_step_count == 48
    assert len(chords.notes_of(NoteKind.SEQ)) == 160
    assert sorted({note.pitch for note in chords.notes_of(NoteKind.SEQ) if note.step == 41}) == [
        60,
        62,
        64,
        66,
    ]

    # The tied notes, carried onto the gate ladder.
    held = project.track(3).pattern(1)
    assert held.seq_step_count == 32
    assert [note.gate for note in held.notes_of(NoteKind.SEQ)] == [8.0, 8.0, 16.0]

    # The split, and the chain that makes it one sequence.
    assert [len(project.track(4).pattern(n).notes_of(NoteKind.SEQ)) for n in (1, 2)] == [32, 32]
    chain = next(c for c in project.scenes[0].chains if c.track == 4)
    assert chain.patterns == (1, 2)


def test_the_m6_song_is_all_audible(m6_song: Path, load_sample: Loader) -> None:
    """Existence is not audibility: a pooled note whose step-active bit is clear is silent."""
    result = midi_import.convert_song(
        mido.MidiFile(m6_song),
        load_sample("Default.KeyStepPro"),
        options=ImportOptions(drum_track=3),
    )
    project = reader.read_project(result.raw, source_name="m6")

    written = [note for track in project.tracks for p in track.patterns for note in p.notes]
    assert len(written) == result.note_count
    assert all(note.active for note in written)


def test_the_m6_song_never_adds_or_removes_a_key(m6_song: Path, load_sample: Loader) -> None:
    template = load_sample("Default.KeyStepPro")
    result = midi_import.convert_song(
        mido.MidiFile(m6_song), template, options=ImportOptions(drum_track=3)
    )

    assert result.raw.keys() == template.keys()


def mixed_of(
    events: list[tuple[int, int, int]], *, length: int = TICKS_PER_STEP, type: int = 0
) -> mido.MidiFile:
    """A one-track file from ``(tick, pitch, channel)`` triples."""
    midi = mido.MidiFile(type=type, ticks_per_beat=TICKS_PER_BEAT)
    track = mido.MidiTrack()
    midi.tracks.append(track)

    timed: list[tuple[int, str, int, int]] = []
    for tick, pitch, channel in events:
        timed.append((tick, "note_on", pitch, channel))
        timed.append((tick + length, "note_off", pitch, channel))

    previous = 0
    for tick, kind, pitch, channel in sorted(timed):
        velocity = 100 if kind == "note_on" else 64
        track.append(
            mido.Message(kind, note=pitch, velocity=velocity, time=tick - previous, channel=channel)
        )
        previous = tick
    return midi


def test_a_track_that_enters_late_keeps_its_place_against_the_others(
    load_sample: Loader,
) -> None:
    """Anchoring each track on its own first note stacked them all on step 1."""
    bar = 16 * TICKS_PER_STEP
    midi = song_of([[(0, 60, 100)], [(2 * bar, 72, 100)]])

    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    first, second = result.plan.tracks
    assert [(n.step, n.pitch) for n in first.notes] == [(1, 60)]
    assert [(n.step, n.pitch) for n in second.notes] == [(33, 72)]


def test_a_part_past_the_first_pattern_lands_in_a_later_one(load_sample: Loader) -> None:
    """Past 64 steps the offset can only be kept by leaving patterns empty."""
    bar = 16 * TICKS_PER_STEP
    midi = song_of([[(0, 60, 100)], [(5 * bar, 72, 100)]])

    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    second = result.plan.tracks[1]
    assert second.patterns == (1, 2)
    assert [len(p.notes) for p in second.placements] == [0, 1]
    assert second.placements[1].notes[0].step == 17


def test_a_short_track_keeps_its_own_length_beside_a_long_one(load_sample: Loader) -> None:
    """The device loops each track's chain on its own, so a one-bar part under an eight-bar one
    repeats against it.
    """
    events = [(step * TICKS_PER_STEP, 60, 100) for step in range(128)]
    midi = song_of([events, [(0, 72, 100)]])

    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    long_part, short_part = result.plan.tracks
    assert long_part.patterns == (1, 2)
    assert [p.step_count for p in long_part.placements] == [64, 64]
    assert short_part.patterns == (1,)
    assert [p.step_count for p in short_part.placements] == [16]


def test_a_track_holding_several_channels_becomes_one_device_track_each(
    load_sample: Loader,
) -> None:
    """A type 0 file tells its instruments apart by channel and nothing else."""
    midi = mixed_of([(0, 60, 0), (0, 72, 1), (TICKS_PER_STEP, 62, 0)])

    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    assert [[n.pitch for n in plan.notes] for plan in result.plan.tracks] == [[60, 62], [72]]
    split = [d for d in result.diagnostics if d.code is Code.TRACK_SPLIT_BY_CHANNEL]
    assert [d.subjects for d in split] == [2]


def test_a_selection_still_splits_a_mixed_track_by_channel(load_sample: Loader) -> None:
    """The subset selects tracks, never channels: the split happens after it."""
    midi = mixed_of([(0, 60, 0), (0, 72, 1)])
    options = ImportOptions(midi_tracks=frozenset({1}))

    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)

    assert [[n.pitch for n in plan.notes] for plan in result.plan.tracks] == [[60], [72]]
    split = [d for d in result.diagnostics if d.code is Code.TRACK_SPLIT_BY_CHANNEL]
    assert [d.subjects for d in split] == [2]

    # Channel 1 is not source track 2: the file has one track and the selection says so.
    with pytest.raises(ValueError, match=r"source track 2 was selected; the file has 1 tracks"):
        midi_import.read_song(midi, ImportOptions(midi_tracks=frozenset({2})))


def test_the_percussion_channel_of_a_mixed_track_is_still_found(load_sample: Loader) -> None:
    midi = mixed_of([(0, 60, 0), (0, 36, 9)])

    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    drum = next(plan for plan in result.plan.tracks if plan.is_drum)
    assert drum.track == 1
    assert [note.lane for note in drum.notes] == [0]
    assert not any(plan.is_drum for plan in result.plan.tracks if plan.track != 1)


def test_a_named_drum_track_keeps_every_channel_it_holds(load_sample: Loader) -> None:
    """--drum-track names a track of the file, so splitting it by channel must not leave half its
    kit behind on another device track.
    """
    midi = mixed_of([(0, 36, 0), (TICKS_PER_STEP, 38, 3)])
    options = ImportOptions(drum_track=1, drum_map=DrumMap.chromatic(36))

    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)

    assert [plan.is_drum for plan in result.plan.tracks] == [True]
    assert [note.lane for note in result.notes] == [0, 2]


def test_more_notes_on_a_step_than_the_firmware_holds_is_refused_in_planning(
    load_sample: Loader,
) -> None:
    """The writer refused this from underneath, after every decision was made."""
    events = [(0, 40 + voice, 100) for voice in range(constants.MAX_NOTES_PER_STEP + 1)]

    with pytest.raises(ValueError, match="step 1"):
        midi_import.convert_song(song_of([events]), load_sample("Default.KeyStepPro"))


def test_a_timecode_division_file_is_refused() -> None:
    """mido reads the division field signed, so an SMPTE file arrives with a negative ticks_per_beat
    and every tick calculation inverts.
    """
    midi = song_of([[(0, 60, 100), (TICKS_PER_STEP, 62, 100)]])
    midi.ticks_per_beat = -7600

    with pytest.raises(ValueError, match="timecode"):
        midi_import.read_song(midi)


def test_a_type_two_file_is_refused() -> None:
    """Its tracks are independent sequences, not parts of one arrangement."""
    midi = mixed_of([(0, 60, 0)], type=2)

    with pytest.raises(ValueError, match="type 2"):
        midi_import.read_song(midi)


@pytest.mark.parametrize(
    ("source", "written"),
    [(20.0, 30.0), (300.0, 240.0), (30.0, 30.0), (240.0, 240.0)],
)
def test_a_tempo_the_device_cannot_run_is_held_to_its_range(
    source: float, written: float, load_sample: Loader
) -> None:
    """The three chunks store about 20,971 BPM, so the field is no guide to what the hardware will
    play.
    """
    midi = song_of([[(0, 60, 100)]])
    midi.tracks[0].insert(0, mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(source), time=0))

    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    assert reader.read_project(result.raw, source_name="tempo").tempo_bpm == written
    held = [d for d in result.diagnostics if d.code is Code.TEMPO_OUT_OF_RANGE]
    assert bool(held) is (source != written)


def test_events_the_device_cannot_store_are_reported(load_sample: Loader) -> None:
    midi = song_of([[(0, 60, 100)]])
    midi.tracks[0].insert(0, mido.Message("control_change", control=7, value=100, time=0))
    midi.tracks[0].insert(0, mido.Message("pitchwheel", pitch=2000, time=0))

    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    dropped = [d for d in result.diagnostics if d.code is Code.CONTROLLERS_DROPPED]
    assert [d.subjects for d in dropped] == [2]


def routed(result: midi_import.ImportResult) -> list[tuple[int, int | None]]:
    """Each plan's device track beside the source track it came from."""
    return [(plan.track, plan.source_track) for plan in result.plan.tracks]


def test_a_route_puts_a_source_track_where_it_says(load_sample: Loader) -> None:
    midi = song_of([[(0, 60, 100)], [(0, 64, 100)], [(0, 67, 100)]])
    options = ImportOptions(routes=(TrackRoute(3, 1), TrackRoute(1, 2)))
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)

    assert routed(result) == [(1, 3), (2, 1), (3, 2)]
    assert [plan.notes[0].pitch for plan in result.plan.tracks] == [67, 60, 64]


def test_unrouted_tracks_fill_the_device_tracks_a_route_left(load_sample: Loader) -> None:
    midi = song_of([[(0, 60, 100)], [(0, 64, 100)], [(0, 67, 100)]])
    options = ImportOptions(routes=(TrackRoute(1, 3),))
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)

    assert routed(result) == [(1, 2), (2, 3), (3, 1)]


def test_without_routes_assignment_is_unchanged(load_sample: Loader) -> None:
    """The fill-upwards rule, drum clip included, with the layer switched off."""
    midi = song_of([[(0, 60, 100)], [(0, 36, 100)], [(0, 67, 100)]], channels=[0, 9, 0])
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    assert routed(result) == [(1, 2), (2, 1), (3, 3)]
    assert [plan.is_drum for plan in result.plan.tracks] == [True, False, False]


def test_a_route_may_not_send_the_drum_track_off_device_track_one() -> None:
    with pytest.raises(ValueError, match=r"route 2:3 sends the drum track to device track 3"):
        ImportOptions(drum_track=2, routes=(TrackRoute(2, 3),))


def test_a_route_may_not_take_device_track_one_from_the_drums(load_sample: Loader) -> None:
    midi = song_of([[(0, 36, 100)], [(0, 60, 100)]], channels=[9, 0])
    options = ImportOptions(routes=(TrackRoute(2, 1),))

    with pytest.raises(ValueError, match=r"route 2:1 collides with the drum track"):
        midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)


def test_a_route_may_not_send_an_auto_detected_drum_track_elsewhere(load_sample: Loader) -> None:
    """The clash is only visible once the percussion channel has been found."""
    midi = song_of([[(0, 36, 100)], [(0, 60, 100)]], channels=[9, 0])
    options = ImportOptions(routes=(TrackRoute(1, 2),))

    with pytest.raises(ValueError, match=r"route 1:2 sends the drum track to device track 2"):
        midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)


def test_routing_the_drum_track_to_device_track_one_is_allowed(load_sample: Loader) -> None:
    midi = song_of([[(0, 60, 100)], [(0, 36, 100)]])
    options = ImportOptions(
        drum_track=2, drum_map=DrumMap.chromatic(36), routes=(TrackRoute(2, 1),)
    )
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)

    assert routed(result) == [(1, 2), (2, 1)]
    assert [plan.is_drum for plan in result.plan.tracks] == [True, False]


def test_a_route_onto_device_track_one_is_refused_beside_a_named_drum_track() -> None:
    """--drum-track spoke for device track 1 before the file was opened."""
    with pytest.raises(ValueError, match=r"route 3:1 collides with the drum track"):
        ImportOptions(drum_track=2, routes=(TrackRoute(3, 1),))


def test_a_route_is_honoured_below_the_starting_track(load_sample: Loader) -> None:
    """--track parameterises the fill-upwards rule, which a route replaces."""
    midi = song_of([[(0, 60, 100)], [(0, 64, 100)]])
    options = ImportOptions(routes=(TrackRoute(1, 1),))
    plan = midi_import.plan_song(midi_import.read_song(midi, options), options, first_track=3)

    assert [(track.track, track.source_track) for track in plan.tracks] == [(1, 1), (3, 2)]


def test_a_drum_track_outside_the_selection_is_refused() -> None:
    """Otherwise _assign reports it as holding no notes, which sends the user to fix the file."""
    with pytest.raises(ValueError, match=r"drum_track 5 is not in the selection"):
        ImportOptions(midi_tracks=frozenset({2, 3}), drum_track=5)


def test_a_drum_track_inside_the_selection_is_allowed() -> None:
    assert ImportOptions(midi_tracks=frozenset({2, 5}), drum_track=5).drum_track == 5


def test_a_route_with_a_source_track_selection_is_refused() -> None:
    with pytest.raises(
        ValueError, match=r"routes and a source-track selection contradict each other"
    ):
        ImportOptions(midi_tracks=frozenset({1}), routes=(TrackRoute(1, 2),))


def test_two_sources_on_one_device_track_are_refused() -> None:
    with pytest.raises(ValueError, match=r"routes 1:2 and 3:2 both name device track 2"):
        ImportOptions(routes=(TrackRoute(1, 2), TrackRoute(3, 2)))


@pytest.mark.parametrize("device", [0, 5])
def test_a_route_outside_the_devices_four_tracks_is_refused(device: int) -> None:
    with pytest.raises(ValueError, match=rf"names device track {device}; the device has 4 tracks"):
        ImportOptions(routes=(TrackRoute(1, device),))


def test_a_route_naming_a_track_with_no_notes_is_refused(load_sample: Loader) -> None:
    midi = song_of([[(0, 60, 100)], [(0, 64, 100)]])
    options = ImportOptions(routes=(TrackRoute(3, 1),))

    with pytest.raises(ValueError, match=r"track 3 of the source holds no notes"):
        midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)


def test_a_routed_track_split_across_channels_is_merged(load_sample: Loader) -> None:
    """Naming a track and getting one of its channels would be the surprise."""
    midi = mixed_of([(0, 60, 0), (0, 72, 1), (TICKS_PER_STEP, 62, 0)])
    options = ImportOptions(routes=(TrackRoute(1, 2),))
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)

    assert routed(result) == [(2, 1)]
    assert [note.pitch for note in result.notes] == [60, 72, 62]


def test_routes_do_not_change_the_dropped_track_report(load_sample: Loader) -> None:
    midi = song_of([[(0, 60 + n, 100)] for n in range(5)])
    options = ImportOptions(routes=(TrackRoute(5, 1),))
    result = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"), options=options)

    assert routed(result) == [(1, 5), (2, 1), (3, 2), (4, 3)]
    dropped = [d for d in result.diagnostics if d.code is Code.TRACKS_DROPPED]
    assert [d.subjects for d in dropped] == [1]


def source_of(
    name: str,
    tracks: list[list[tuple[int, int, int]]],
    *,
    ticks_per_beat: int = TICKS_PER_BEAT,
    tempo_bpm: float | None = None,
    signature: tuple[int, int] | None = None,
    length: int = TICKS_PER_STEP,
) -> midi_import.Source:
    """A named type 1 file, one track per list of ``(tick, pitch, velocity)``."""
    midi = mido.MidiFile(type=1, ticks_per_beat=ticks_per_beat)
    for number, events in enumerate(tracks):
        track = mido.MidiTrack()
        midi.tracks.append(track)
        if number == 0 and tempo_bpm is not None:
            track.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(tempo_bpm), time=0))
        if number == 0 and signature is not None:
            numerator, denominator = signature
            track.append(
                mido.MetaMessage(
                    "time_signature", numerator=numerator, denominator=denominator, time=0
                )
            )
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
    return midi_import.Source(name, midi)


def test_two_files_become_one_song() -> None:
    first = source_of("a.mid", [[(0, 60, 100)], [(0, 64, 100)]])
    second = source_of("b.mid", [[(0, 67, 100)]])

    song = midi_import.read_songs((first, second))

    assert [clip.notes[0].pitch for clip in song.clips] == [60, 64, 67]


def test_every_clip_records_the_file_it_came_from() -> None:
    first = source_of("a.mid", [[(0, 60, 100)], [(0, 64, 100)]])
    second = source_of("b.mid", [[(0, 67, 100)]])

    song = midi_import.read_songs((first, second))

    assert [clip.source_file for clip in song.clips] == ["a.mid", "a.mid", "b.mid"]


def test_source_tracks_number_on_through_the_files() -> None:
    """One numbering across the run, so --route and --midi-tracks still address a track."""
    first = source_of("a.mid", [[(0, 60, 100)], [(0, 64, 100)]])
    second = source_of("b.mid", [[(0, 67, 100)], [(0, 71, 100)]])

    song = midi_import.read_songs((first, second))

    assert [clip.source_tracks for clip in song.clips] == [(1,), (2,), (3,), (4,)]


def test_a_selection_reaches_into_the_second_file() -> None:
    first = source_of("a.mid", [[(0, 60, 100)], [(0, 64, 100)]])
    second = source_of("b.mid", [[(0, 67, 100)], [(0, 71, 100)]])

    song = midi_import.read_songs((first, second), ImportOptions(midi_tracks=frozenset({3})))

    assert [clip.notes[0].pitch for clip in song.clips] == [67]
    assert [clip.source_file for clip in song.clips] == ["b.mid"]


def test_a_selection_past_every_file_is_refused_naming_the_total() -> None:
    first = source_of("a.mid", [[(0, 60, 100)], [(0, 64, 100)]])
    second = source_of("b.mid", [[(0, 67, 100)]])

    with pytest.raises(ValueError, match=r"source track 4 was selected; the 2 files hold 3"):
        midi_import.read_songs((first, second), ImportOptions(midi_tracks=frozenset({4})))


def test_a_later_file_at_another_resolution_is_rescaled_onto_the_firsts() -> None:
    """One beat is one beat: 96 ticks at 96 PPQ has to land on 480 at 480 PPQ."""
    first = source_of("a.mid", [[(0, 60, 100)]])
    second = source_of("b.mid", [[(96, 67, 100)]], ticks_per_beat=96, length=24)

    song = midi_import.read_songs((first, second))

    assert song.ticks_per_beat == TICKS_PER_BEAT
    assert [clip.notes[0].tick for clip in song.clips] == [0, TICKS_PER_BEAT]
    assert song.resolution_conflicts == 1


def test_rescaling_down_leaves_a_short_note_a_tick_long() -> None:
    """Rounding a sub-tick note to nothing would silently delete it."""
    first = source_of("a.mid", [[(0, 60, 100)]], ticks_per_beat=96, length=24)
    second = source_of("b.mid", [[(0, 67, 100)]], length=1)

    song = midi_import.read_songs((first, second))

    assert song.clips[1].notes[0].duration_ticks == 1


def test_a_later_files_resolution_is_reported(load_sample: Loader) -> None:
    first = source_of("a.mid", [[(0, 60, 100)]])
    second = source_of("b.mid", [[(0, 67, 100)]], ticks_per_beat=96, length=24)

    result = midi_import.convert_songs((first, second), load_sample("Default.KeyStepPro"))

    assert Code.SOURCE_RESOLUTION_DIFFERS in {d.code for d in result.diagnostics}


def test_the_first_files_tempo_is_written_and_the_disagreement_reported(
    load_sample: Loader,
) -> None:
    first = source_of("a.mid", [[(0, 60, 100)]], tempo_bpm=140)
    second = source_of("b.mid", [[(0, 67, 100)]], tempo_bpm=90)

    result = midi_import.convert_songs((first, second), load_sample("Default.KeyStepPro"))

    assert result.plan.tempo_bpm == pytest.approx(140, abs=0.01)
    assert Code.SOURCE_TEMPO_DIFFERS in {d.code for d in result.diagnostics}


def test_a_tempo_disagreement_is_silent_when_no_tempo_is_carried(load_sample: Loader) -> None:
    """Nothing was overridden if nothing was written."""
    first = source_of("a.mid", [[(0, 60, 100)]], tempo_bpm=140)
    second = source_of("b.mid", [[(0, 67, 100)]], tempo_bpm=90)
    options = ImportOptions(carry_tempo=False)

    result = midi_import.convert_songs(
        (first, second), load_sample("Default.KeyStepPro"), options=options
    )

    assert Code.SOURCE_TEMPO_DIFFERS not in {d.code for d in result.diagnostics}


def test_the_first_files_meter_sets_the_bar_and_the_disagreement_is_reported(
    load_sample: Loader,
) -> None:
    first = source_of("a.mid", [[(0, 60, 100)]], signature=(4, 4))
    second = source_of("b.mid", [[(0, 67, 100)]], signature=(3, 4))

    song = midi_import.read_songs((first, second))
    result = midi_import.convert_songs((first, second), load_sample("Default.KeyStepPro"))

    assert song.beats_per_bar == 4
    assert song.meter_conflicts == 1
    assert Code.SOURCE_METER_DIFFERS in {d.code for d in result.diagnostics}


def test_agreeing_files_report_nothing(load_sample: Loader) -> None:
    first = source_of("a.mid", [[(0, 60, 100)]])
    second = source_of("b.mid", [[(0, 67, 100)]])

    result = midi_import.convert_songs((first, second), load_sample("Default.KeyStepPro"))
    raised = {d.code for d in result.diagnostics}

    assert Code.SOURCE_TEMPO_DIFFERS not in raised
    assert Code.SOURCE_RESOLUTION_DIFFERS not in raised
    assert Code.SOURCE_METER_DIFFERS not in raised


def test_a_device_track_records_the_file_it_came_from(load_sample: Loader) -> None:
    first = source_of("a.mid", [[(0, 60, 100)]])
    second = source_of("b.mid", [[(0, 67, 100)]])

    result = midi_import.convert_songs((first, second), load_sample("Default.KeyStepPro"))

    assert [plan.source_file for plan in result.plan.tracks] == ["a.mid", "b.mid"]


def test_one_source_reads_exactly_as_a_single_file_does() -> None:
    midi = song_of([[(0, 60, 100)], [(TICKS_PER_STEP, 64, 100)]])

    assert midi_import.read_songs((midi_import.Source("", midi),)) == midi_import.read_song(midi)


def test_one_source_converts_exactly_as_a_single_file_does(load_sample: Loader) -> None:
    midi = song_of([[(0, 60, 100)], [(TICKS_PER_STEP, 64, 100)]])
    sources = (midi_import.Source("", midi),)

    together = midi_import.convert_songs(sources, load_sample("Default.KeyStepPro"))
    alone = midi_import.convert_song(midi, load_sample("Default.KeyStepPro"))

    assert together.raw == alone.raw


def test_two_constant_tempo_files_are_not_a_tempo_change(load_sample: Loader) -> None:
    """Counting the run's tempo events rather than one file's would claim a change."""
    first = source_of("a.mid", [[(0, 60, 100)]], tempo_bpm=120)
    second = source_of("b.mid", [[(0, 67, 100)]], tempo_bpm=120)

    result = midi_import.convert_songs((first, second), load_sample("Default.KeyStepPro"))

    assert Code.TEMPO_CHANGES_IGNORED not in {d.code for d in result.diagnostics}


def test_a_file_that_really_changes_tempo_is_still_reported(load_sample: Loader) -> None:
    first = source_of("a.mid", [[(0, 60, 100)]], tempo_bpm=120)
    first.midi.tracks[0].append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(90), time=480))
    second = source_of("b.mid", [[(0, 67, 100)]], tempo_bpm=120)

    result = midi_import.convert_songs((first, second), load_sample("Default.KeyStepPro"))

    assert Code.TEMPO_CHANGES_IGNORED in {d.code for d in result.diagnostics}


def test_a_wholly_deselected_file_reports_no_disagreement(load_sample: Loader) -> None:
    """It supplied no note to rescale, so there is nothing to have overridden."""
    first = source_of("a.mid", [[(0, 60, 100)]], tempo_bpm=120)
    second = source_of("b.mid", [[(0, 67, 100)]], ticks_per_beat=96, length=24, tempo_bpm=90)
    options = ImportOptions(midi_tracks=frozenset({1}))

    song = midi_import.read_songs((first, second), options)
    result = midi_import.convert_songs(
        (first, second), load_sample("Default.KeyStepPro"), options=options
    )
    raised = {d.code for d in result.diagnostics}

    assert [clip.source_file for clip in song.clips] == ["a.mid"]
    assert (song.tempo_conflicts, song.resolution_conflicts) == (0, 0)
    assert Code.SOURCE_TEMPO_DIFFERS not in raised
    assert Code.SOURCE_RESOLUTION_DIFFERS not in raised


def test_a_zero_length_note_stays_zero_length_through_a_rescale() -> None:
    """Otherwise the same file would gate differently for the company it keeps."""
    first = source_of("a.mid", [[(0, 60, 100)]], ticks_per_beat=96, length=24)
    second = source_of("b.mid", [[(0, 67, 100)]], length=0)

    alone = midi_import.read_songs((second,))
    rescaled = midi_import.read_songs((first, second))

    assert alone.clips[0].notes[0].duration_ticks == 0
    assert rescaled.clips[1].notes[0].duration_ticks == 0


def test_no_source_at_all_is_refused() -> None:
    with pytest.raises(ValueError, match=r"no source file was given"):
        midi_import.read_songs(())
