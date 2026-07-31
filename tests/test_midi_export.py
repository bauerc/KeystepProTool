"""MIDI export, checked against the hardware-confirmed project descriptions.

``project_5`` is the reference case: its notes, velocities, gates and step
positions were read off the device display, so the exported file can be
asserted note by note rather than against another piece of our own code.
"""

from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

import mido
import pytest

from ksp.midi_export import (
    DRUM_CHANNEL,
    DRUM_LANE_BASE,
    ExportOptions,
    ExportResult,
    export_project,
)
from ksp.model import Project
from ksp.reader import load

TICKS_PER_STEP = 120  # the 480/4 default: 1/16 steps at 480 ticks per beat


@dataclass(frozen=True)
class PlayedNote:
    """One note as a DAW would see it: absolute position and duration."""

    start: int
    duration: int
    note: int
    velocity: int
    channel: int


def played(midi: mido.MidiFile, track_name: str) -> list[PlayedNote]:
    """Read a named track back as absolute-time notes.

    Deliberately re-derives note lengths from the note_on/note_off pairs
    instead of trusting the writer's own bookkeeping -- a wrongly paired
    note-off is exactly the bug that makes a file play wrong in a DAW while
    looking fine in memory.
    """
    track = next(t for t in midi.tracks if t.name == track_name)
    open_notes: dict[tuple[int, int], tuple[int, int]] = {}
    notes: list[PlayedNote] = []
    tick = 0
    for message in track:
        tick += message.time
        if message.type == "note_on":
            key = (message.channel, message.note)
            assert key not in open_notes, f"{key} retriggered before its note-off"
            open_notes[key] = (tick, message.velocity)
        elif message.type == "note_off":
            start, velocity = open_notes.pop((message.channel, message.note))
            notes.append(
                PlayedNote(
                    start=start,
                    duration=tick - start,
                    note=message.note,
                    velocity=velocity,
                    channel=message.channel,
                )
            )
    assert not open_notes, f"note(s) left hanging: {sorted(open_notes)}"
    return sorted(notes, key=lambda n: (n.start, n.note))


@pytest.fixture
def project_5(project_files_dir: Path) -> Project:
    return load(project_files_dir / "project_5.KeyStepPro")


@pytest.fixture
def project_9(project_files_dir: Path) -> Project:
    return load(project_files_dir / "project_9.KeyStepPro")


@pytest.fixture
def exported_5(project_5: Project) -> ExportResult:
    return export_project(project_5)


def test_tempo_and_resolution_come_from_the_project(exported_5: ExportResult) -> None:
    conductor = exported_5.midi.tracks[0]
    tempo = next(m for m in conductor if m.type == "set_tempo")
    assert mido.tempo2bpm(tempo.tempo) == pytest.approx(120.0)
    assert exported_5.midi.ticks_per_beat == 480
    assert exported_5.midi.type == 1


def test_each_track_and_parameter_set_becomes_its_own_midi_track(
    exported_5: ExportResult,
) -> None:
    """Track 1's drum set and a melodic track cannot share a MIDI track.

    They need different channels and their pitch values mean different things
    -- a lane index is not a MIDI note.
    """
    assert exported_5.track_names == ("Track 1 (drum)", "Track 3")


def test_melodic_notes_match_the_documented_description(exported_5: ExportResult) -> None:
    """project_5 Track 3 pattern 1, straight from the description file.

    Beats 1-4 are C2 (48), 5-8 are C#2 (49), and two D (50) notes sit at beats
    9 and 13 -- the second of which is the note that proves the two index
    spaces, since it lives at note index 10 but step 13.
    """
    notes = played(exported_5.midi, "Track 3")

    assert [n.note for n in notes] == [48] * 4 + [49] * 4 + [50, 50]
    assert [n.velocity for n in notes] == [60, 70, 90, 100, 60, 70, 90, 100, 60, 120]
    steps = (0, 1, 2, 3, 4, 5, 6, 7, 8, 12)  # 0-based; the tenth note sits at step 13
    assert [n.start for n in notes] == [step * TICKS_PER_STEP for step in steps]
    assert {n.channel for n in notes} == {2}  # Track 3 -> MIDI channel 3


def test_gate_becomes_note_length_in_steps(exported_5: ExportResult) -> None:
    """The tie from beat 9 to beat 12 is stored as gate 4 and lasts 4 steps.

    That is the evidence the displayed gate is a count of steps, which is what
    makes a duration derivable at all.
    """
    tied = played(exported_5.midi, "Track 3")[8]
    assert tied.start == 8 * TICKS_PER_STEP
    assert tied.duration == 4 * TICKS_PER_STEP

    last = played(exported_5.midi, "Track 3")[9]
    assert last.duration == round(3.5 * TICKS_PER_STEP)  # gate 3.5


def test_a_gate_running_into_the_next_note_is_shortened_not_overlapped(
    exported_5: ExportResult,
) -> None:
    """Beat 1 has gate 2 but beat 2 repeats the same pitch.

    The device retriggers; MIDI would be left holding one note-on too many.
    Shortening the earlier note is what keeps the two equivalent.
    """
    first, second = played(exported_5.midi, "Track 3")[:2]
    assert first.note == second.note == 48
    assert first.duration == TICKS_PER_STEP
    assert first.start + first.duration == second.start
    assert any("shortened" in w for w in exported_5.warnings)


def test_drum_lanes_map_onto_the_general_midi_percussion_channel(
    exported_5: ExportResult,
) -> None:
    """Kick on beats 1 and 5, velocities 127 and 50, gates 1 and 2."""
    notes = played(exported_5.midi, "Track 1 (drum)")

    assert [n.note for n in notes] == [DRUM_LANE_BASE, DRUM_LANE_BASE]  # lane 0
    assert [n.channel for n in notes] == [DRUM_CHANNEL, DRUM_CHANNEL]
    assert [n.start for n in notes] == [0, 4 * TICKS_PER_STEP]
    assert [n.velocity for n in notes] == [127, 50]
    assert [n.duration for n in notes] == [1 * TICKS_PER_STEP, 2 * TICKS_PER_STEP]


def test_the_drum_map_convention_is_declared_not_implied(exported_5: ExportResult) -> None:
    """The device's drum map is a global setting, not project data (spec 3.4).

    Exporting lane 0 as MIDI 36 is therefore our choice, and a choice the
    output has to own up to.
    """
    assert any("drum map is a device global" in w for w in exported_5.warnings)


def test_unapplied_time_shift_is_reported(exported_5: ExportResult) -> None:
    """project_5's melodic notes ramp +1..+4 and -1..-4.

    How many ticks a shift unit is worth has never been measured, so the
    export leaves the grid alone and says so rather than inventing a scale.
    """
    assert any("time shift" in w for w in exported_5.warnings)


def test_patterns_are_laid_end_to_end_and_stay_aligned_across_tracks(
    project_9: Project,
) -> None:
    """project_9 uses patterns 2 and 3, and pattern 2 on two different tracks.

    Both tracks' pattern 2 must start together, and pattern 3 must follow one
    16-step pattern later -- not at its own pattern index, which would leave a
    bar of silence for the pattern nobody used.
    """
    result = export_project(project_9)
    assert result.pattern_numbers == (2, 3)

    drums = played(result.midi, "Track 1 (drum)")
    melodic = played(result.midi, "Track 3")

    assert drums[0].start == melodic[0].start == 0
    assert drums[1].start == 16 * TICKS_PER_STEP
    assert melodic[0].note == 60  # C3, as documented
    assert drums[0].duration == 4 * TICKS_PER_STEP  # test 1 sets gate 4


def test_the_file_lasts_as_long_as_its_patterns(project_9: Project) -> None:
    """Two 16-step patterns at 120 BPM in 1/16 steps: two bars, four seconds."""
    assert export_project(project_9).midi.length == pytest.approx(4.0)


def test_an_unmeasured_gate_falls_back_to_the_device_default_and_says_so(
    project_files_dir: Path,
) -> None:
    """initial_project holds a gate encoding of 2, which is not in the table.

    Interpolating it would produce a file that loads cleanly and plays wrong,
    so the export uses the length a freshly placed note has and warns.
    """
    result = export_project(load(project_files_dir / "initial_project.KeyStepPro"))
    assert any("gate encoding 2 is not measured" in w for w in result.warnings)


def test_reader_warnings_survive_into_the_export(project_files_dir: Path) -> None:
    """A pattern the reader could not resolve makes a MIDI file that lies.

    initial_project's Track 1 pattern 1 holds both a melody and a drum
    pattern, and nothing in the file says which one the device plays.
    """
    result = export_project(load(project_files_dir / "initial_project.KeyStepPro"))
    assert any("holds both melodic" in w for w in result.warnings)
    assert "Track 1" in result.track_names and "Track 1 (drum)" in result.track_names


def test_an_empty_project_exports_nothing(project_files_dir: Path) -> None:
    result = export_project(load(project_files_dir / "Default.KeyStepPro"))
    assert result.is_empty
    assert result.track_names == ()


def test_selection_narrows_what_is_exported(project_5: Project) -> None:
    result = export_project(project_5.select(track=3))
    assert result.track_names == ("Track 3",)
    assert result.note_count == 10


def test_swing_delays_the_second_step_of_each_pair(project_5: Project) -> None:
    """Swing percent is decoded; its timing meaning is the standard one.

    75% gives the first step of a pair three quarters of the pair, so the
    second starts half a step late.
    """
    swung = _with_swing(project_5, 75)
    flat = export_project(swung, ExportOptions(apply_swing=False))
    result = export_project(swung)

    offsets = [
        s.start - f.start
        for s, f in zip(played(result.midi, "Track 3"), played(flat.midi, "Track 3"), strict=True)
    ]
    steps = [1, 2, 3, 4, 5, 6, 7, 8, 9, 13]
    assert offsets == [TICKS_PER_STEP // 2 if step % 2 == 0 else 0 for step in steps]
    assert any("75% swing" in w for w in result.warnings)


def _with_swing(project: Project, percent: int) -> Project:
    """A copy of *project* with one pattern's melodic swing overridden.

    None of the sample projects use swing, so the only way to cover it is to
    build the case; doing it on the model keeps the sample files untouched.
    """
    track = project.track(3)
    pattern = replace(track.pattern(1), seq_swing_percent=percent)
    patterns = tuple(pattern if p.number == 1 else p for p in track.patterns)
    tracks = tuple(replace(t, patterns=patterns) if t.number == 3 else t for t in project.tracks)
    return replace(project, tracks=tracks)


def test_step_size_is_configurable_because_the_file_does_not_say(project_5: Project) -> None:
    """Step size lives in the undecoded 99/116 bitfield (spec 3.3)."""
    eighths = export_project(project_5, ExportOptions(steps_per_beat=2))
    assert [n.start for n in played(eighths.midi, "Track 3")][:2] == [0, 240]


def test_the_drum_map_base_is_configurable(project_5: Project) -> None:
    result = export_project(project_5, ExportOptions(drum_lane_base=60))
    assert played(result.midi, "Track 1 (drum)")[0].note == 60


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"steps_per_beat": 0}, "at least 1"),
        ({"ticks_per_beat": 0}, "at least 1"),
        ({"ticks_per_beat": 100, "steps_per_beat": 3}, "not divisible"),
        ({"drum_channel": 16}, "0-15"),
        ({"drum_lane_base": 128}, "0-127"),
    ],
)
def test_options_that_cannot_produce_exact_timing_are_rejected(
    kwargs: dict[str, Any], message: str
) -> None:
    """A step that does not land on a whole tick would drift over 64 steps."""
    with pytest.raises(ValueError, match=message):
        ExportOptions(**kwargs)


def test_the_written_file_reads_back_identically(
    project_5: Project, exported_5: ExportResult, tmp_path: Path
) -> None:
    """Everything above inspects an in-memory object; a DAW reads bytes."""
    path = tmp_path / "out.mid"
    exported_5.midi.save(path)

    reloaded = mido.MidiFile(path)
    assert played(reloaded, "Track 3") == played(exported_5.midi, "Track 3")
    assert played(reloaded, "Track 1 (drum)") == played(exported_5.midi, "Track 1 (drum)")
