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

from ksp.diagnostics import Code
from ksp.drum_map import DEFAULT_CHROMATIC_LOW, DrumMap
from ksp.midi_export import (
    DRUM_CHANNEL,
    ExportOptions,
    ExportResult,
    arrange,
    build_midi_file,
    export_project,
    export_split,
    render_pattern,
    render_project,
)
from ksp.model import NoteKind, Pattern, PatternBits, Project
from ksp.reader import load

TICKS_PER_STEP = 120  # the 480/4 default: 1/16 steps at 480 ticks per beat

#: project_5 and project_9 carry real skip masks, so anything asserting one
#: pattern's own content has to say which repeat it means.
ONE_PASS = ExportOptions(passes=1)


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
    """One pass, so these assertions read the pattern rather than the cycle.

    project_5's notes carry real skip masks, so the default export repeats it
    four times; the expansion has its own tests below.
    """
    return export_project(project_5, ExportOptions(passes=1))


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

    # Lane 0 under the default chromatic-36 map is the GM bass drum.
    assert [n.note for n in notes] == [DEFAULT_CHROMATIC_LOW, DEFAULT_CHROMATIC_LOW]
    assert [n.channel for n in notes] == [DRUM_CHANNEL, DRUM_CHANNEL]
    assert [n.start for n in notes] == [0, 4 * TICKS_PER_STEP]
    assert [n.velocity for n in notes] == [127, 50]
    assert [n.duration for n in notes] == [1 * TICKS_PER_STEP, 2 * TICKS_PER_STEP]


def test_the_drum_map_is_named_in_the_output_not_left_implied(
    exported_5: ExportResult,
) -> None:
    """The map is a device global, not project data (spec 3.2.1).

    Which one was used is therefore an assumption, and one the output has to
    own up to on every export.
    """
    assert any("chromatic from 36 (assumed - not in file)" in w for w in exported_5.warnings)


def test_a_custom_drum_map_moves_the_exported_notes(project_5: Project) -> None:
    """The same lane must follow whatever map the user's device actually has."""
    options = ExportOptions(drum_map=DrumMap.custom(range(60, 84)), passes=1)
    result = export_project(project_5, options)
    assert [n.note for n in played(result.midi, "Track 1 (drum)")] == [60, 60]
    assert any("custom (assumed - not in file)" in w for w in result.warnings)


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
    result = export_project(project_9, ExportOptions(passes=1))
    assert result.pattern_numbers == (2, 3)

    drums = played(result.midi, "Track 1 (drum)")
    melodic = played(result.midi, "Track 3")

    assert drums[0].start == melodic[0].start == 0
    assert drums[1].start == 16 * TICKS_PER_STEP
    assert melodic[0].note == 60  # C3, as documented
    assert drums[0].duration == 4 * TICKS_PER_STEP  # test 1 sets gate 4


def test_the_file_lasts_as_long_as_its_patterns(project_9: Project) -> None:
    """Two 16-step patterns at 120 BPM in 1/16 steps: two bars, four seconds."""
    assert export_project(project_9, ExportOptions(passes=1)).midi.length == pytest.approx(4.0)


def test_a_masked_note_lands_on_the_repeat_it_plays_in(project_9: Project) -> None:
    """project_9 pattern 3's only hit is masked to 32, i.e. the second repeat.

    The device runs the four sequences as repeats of the pattern (spec 5,
    protocol T5.8), so that note is silent on the first pass and sounds on the
    second -- which is the whole difference between the repeats reading and
    the pages one.
    """
    result = export_project(project_9)
    drums = played(result.midi, "Track 1 (drum)")

    # Pattern 2 has no masks and stays one pass; pattern 3 expands to four,
    # and its note sits one pass into them.
    assert [n.start for n in drums] == [0, 32 * TICKS_PER_STEP]
    assert any("rendered as 4 repeats" in w for w in result.warnings)
    # 16 steps of pattern 2, then four 16-step repeats of pattern 3.
    assert result.midi.length == pytest.approx(10.0)


def _drum_gates_off_the_ladder(pattern: Pattern, raw: int = 200) -> Pattern:
    """Corrupt every drum gate in *pattern*.

    The ladder covers all of 0-127 (spec 6.1), so no sample project can
    exercise the fallback any more -- the only way in is a value the device
    could not have written.
    """
    notes = tuple(
        replace(note, gate_raw=raw, gate=None) if note.kind is NoteKind.DRUM else note
        for note in pattern.notes
    )
    return replace(pattern, notes=notes)


def test_a_gate_off_the_ladder_falls_back_to_the_device_default_and_says_so(
    project_files_dir: Path,
) -> None:
    """Rounding an undecodable gate to the nearest rung would produce a file
    that loads cleanly and plays wrong, so the export uses the length a freshly
    placed note has and warns."""
    pattern = load(project_files_dir / "initial_project.KeyStepPro").track(1).pattern(1)
    rendering = render_pattern(
        _drum_gates_off_the_ladder(pattern), track_number=1, kind=NoteKind.DRUM
    )

    assert rendering.notes
    assert any("gate encoding 200 is off the 0-127 ladder" in w for w in rendering.warnings)
    assert all(n.duration_ticks == round(0.5 * TICKS_PER_STEP) for n in rendering.notes)


def test_reader_warnings_survive_into_the_export(project_files_dir: Path) -> None:
    """Anything the reader could not resolve makes a MIDI file that may lie."""
    project = load(project_files_dir / "initial_project.KeyStepPro")
    result = export_project(project, ExportOptions(include_stale=True, include_disabled=True))
    assert any("holds both melodic" in w for w in result.warnings)
    assert any("disabled note(s), step turned off" in w for w in result.warnings)


def test_the_export_replaces_a_reader_line_rather_than_echoing_it(
    project_files_dir: Path,
) -> None:
    """One finding, one line.

    The export's versions of these two say what the reader's say *and* name
    the flag that undoes them, so printing both would be pure repetition.
    Each must still be said exactly once.
    """
    project = load(project_files_dir / "initial_project.KeyStepPro")
    diagnostics = export_project(project).diagnostics

    for reader_code, export_code in (
        (Code.DISABLED_STEP_OFF, Code.DISABLED_NOT_EXPORTED),
        (Code.MIXED_NOTE_SETS, Code.STALE_NOTE_SET),
    ):
        spoken_for = {d.site.pattern for d in diagnostics if d.code is export_code}
        assert spoken_for, f"{export_code} should fire on initial_project"
        clashes = {d.site.pattern for d in diagnostics if d.code is reader_code} & spoken_for
        assert not clashes, f"{reader_code} repeated at pattern(s) {sorted(clashes)}"

    # And the surviving line is the one that names the flag.
    assert any("--include-stale exports both" in w for w in diagnostics.messages)
    assert any("--include-disabled exports them" in w for w in diagnostics.messages)


def test_only_the_set_the_device_plays_is_exported(project_files_dir: Path) -> None:
    """initial_project Track 1 pattern 1 holds a melody *and* a drum pattern.

    Parameter 86 bit 6 says the track is in drum mode, so the 64-note melody is
    leftovers from before it was switched over -- notes no hardware would play.
    Exporting them would put phantom material in a file meant to be listened to.
    """
    project = load(project_files_dir / "initial_project.KeyStepPro").select(track=1, pattern=1)

    live = export_project(project)
    assert live.track_names == ("Track 1 (drum)",)
    assert any("not exported (--include-stale" in w for w in live.warnings)

    both = export_project(project, ExportOptions(include_stale=True))
    assert both.track_names == ("Track 1", "Track 1 (drum)")
    assert both.note_count > live.note_count


def test_a_pattern_holding_one_set_is_exported_whatever_the_mode_flag_says(
    project_5: Project,
) -> None:
    """The flag only decides when *both* sets are populated.

    A track left in drum mode whose pattern holds only a melody must still
    export that melody -- filtering on the flag alone would silently drop real
    user data. No sample project has this combination, so it is constructed.
    """
    melodic = project_5.select(track=3)
    in_drum_mode = replace(melodic, tracks=(replace(melodic.tracks[0], drum_mode=True),))

    result = export_project(in_drum_mode, ExportOptions(passes=1))
    assert result.track_names == ("Track 3",)
    assert result.note_count == 10


def test_an_empty_project_exports_nothing(project_files_dir: Path) -> None:
    result = export_project(load(project_files_dir / "Default.KeyStepPro"))
    assert result.is_empty
    assert result.track_names == ()


def test_selection_narrows_what_is_exported(project_5: Project) -> None:
    result = export_project(project_5.select(track=3), ExportOptions(passes=1))
    assert result.track_names == ("Track 3",)
    assert result.note_count == 10


def test_swing_delays_the_second_step_of_each_pair(project_5: Project) -> None:
    """Swing percent is decoded; its timing meaning is the standard one.

    75% gives the first step of a pair three quarters of the pair, so the
    second starts half a step late.
    """
    swung = _with_swing(project_5, 75)
    flat = export_project(swung, ExportOptions(apply_swing=False, passes=1))
    result = export_project(swung, ONE_PASS)

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


def test_step_size_comes_from_the_pattern_itself(project_5: Project) -> None:
    """Bits 3-4 of 99, measured by T5.1 -- so nobody has to supply it."""
    eighths = export_project(_with_bits(project_5, raw=12))
    assert [n.start for n in played(eighths.midi, "Track 3")][:2] == [0, 240]


def test_a_triplet_pattern_renders_two_thirds_of_the_step(project_5: Project) -> None:
    """Bit 0, and why the default resolution is divisible by 3."""
    triplets = export_project(_with_bits(project_5, raw=21))
    assert [n.start for n in played(triplets.midi, "Track 3")][:2] == [0, 80]


def test_a_non_forward_direction_is_reported_not_reordered(project_5: Project) -> None:
    """Rand and Walk have no MIDI equivalent, so the export says so (T5.5)."""
    walking = export_project(_with_bits(project_5, raw=84))
    assert [n.start for n in played(walking.midi, "Track 3")][:2] == [0, TICKS_PER_STEP]
    assert any("walk" in w for w in walking.warnings)


def _with_bits(project: Project, *, raw: int) -> Project:
    """A copy of *project* with track 3 pattern 1's 99 field overridden.

    Every sample project holds the same 20, so a non-default step size,
    triplet or direction can only be covered by building the case.
    """
    track = project.track(3)
    pattern = replace(track.pattern(1), seq_bits=PatternBits.decode(raw))
    patterns = tuple(pattern if p.number == 1 else p for p in track.patterns)
    tracks = tuple(replace(t, patterns=patterns) if t.number == 3 else t for t in project.tracks)
    return replace(project, tracks=tracks)


def test_the_chromatic_drum_map_base_is_configurable(project_5: Project) -> None:
    result = export_project(project_5, ExportOptions(drum_map=DrumMap.chromatic(60), passes=1))
    assert played(result.midi, "Track 1 (drum)")[0].note == 60


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"ticks_per_beat": 0}, "at least 1"),
        ({"ticks_per_beat": 100}, "not divisible"),
        ({"passes": 5}, "passes must be 1-4"),
        ({"drum_channel": 16}, "0-15"),
        ({"default_gate": 0}, "greater than 0"),
    ],
)
def test_options_that_cannot_produce_exact_timing_are_rejected(
    kwargs: dict[str, Any], message: str
) -> None:
    """A step that does not land on a whole tick would drift over 64 steps."""
    with pytest.raises(ValueError, match=message):
        ExportOptions(**kwargs)


class TestRenderLayer:
    """The arithmetic layer, asserted as plain data rather than parsed MIDI.

    This is the half the M8/M9 Swift port has to reproduce; keeping it free of
    ``mido`` is what makes the port a translation rather than a redesign.
    """

    def test_a_pattern_renders_from_its_own_tick_zero(self, project_5: Project) -> None:
        """Same description values as the merged export, minus the timeline.

        project_5 track 3 pattern 1: beats 1-4 C2, 5-8 C#2, then D at beats 9
        and 13 -- the second sitting at note index 10 but step 13.
        """
        rendering = render_pattern(
            project_5.track(3).pattern(1),
            track_number=3,
            kind=NoteKind.SEQ,
            options=ONE_PASS,
        )

        assert rendering.pattern_number == 1
        assert rendering.length_ticks == 16 * TICKS_PER_STEP
        assert rendering.midi_track_name == "Track 3"
        assert [n.pitch for n in rendering.notes] == [48] * 4 + [49] * 4 + [50, 50]
        assert [n.tick for n in rendering.notes] == [
            step * TICKS_PER_STEP for step in (0, 1, 2, 3, 4, 5, 6, 7, 8, 12)
        ]
        assert [n.velocity for n in rendering.notes] == [60, 70, 90, 100, 60, 70, 90, 100, 60, 120]
        assert {n.channel for n in rendering.notes} == {2}

    def test_gate_is_a_duration_in_steps(self, project_5: Project) -> None:
        """The tie from beat 9 to beat 12 stores gate 4 and lasts four steps."""
        rendering = render_pattern(
            project_5.track(3).pattern(1),
            track_number=3,
            kind=NoteKind.SEQ,
            options=ONE_PASS,
        )
        assert rendering.notes[8].duration_ticks == 4 * TICKS_PER_STEP
        assert rendering.notes[9].duration_ticks == round(3.5 * TICKS_PER_STEP)

    def test_the_drum_set_renders_onto_the_drum_channel(self, project_5: Project) -> None:
        rendering = render_pattern(
            project_5.track(1).pattern(1), track_number=1, kind=NoteKind.DRUM, options=ONE_PASS
        )
        assert rendering.midi_track_name == "Track 1 (drum)"
        assert [n.pitch for n in rendering.notes] == [DEFAULT_CHROMATIC_LOW] * 2
        assert {n.channel for n in rendering.notes} == {DRUM_CHANNEL}

    def test_an_arrangement_can_be_built_without_touching_mido(self, project_5: Project) -> None:
        """render -> arrange -> build: only the last step knows about MIDI."""
        arrangement = arrange(render_project(project_5, ONE_PASS))

        assert [t.name for t in arrangement.tracks] == ["Track 1 (drum)", "Track 3"]
        assert arrangement.note_count == 12
        assert arrangement.length_ticks == 16 * TICKS_PER_STEP
        assert arrangement.pattern_numbers == (1,)
        assert arrangement.track_numbers == (1, 3)

        midi = build_midi_file(arrangement, name="x", tempo_bpm=120.0, ticks_per_beat=480)
        assert [t.name for t in midi.tracks] == ["x", "Track 1 (drum)", "Track 3"]
        assert len(played(midi, "Track 3")) == 10


def test_the_fallback_length_is_the_caller_s_to_name(project_files_dir: Path) -> None:
    """``default_gate`` names the fallback instead of burying it in the code,
    and it only ever applies to gates that did not decode -- a measured one is
    never overridden."""
    real = load(project_files_dir / "initial_project.KeyStepPro").track(1).pattern(1)
    corrupt = _drum_gates_off_the_ladder(real)
    options = ExportOptions(default_gate=1.0)

    measured = render_pattern(real, track_number=1, kind=NoteKind.DRUM, options=options)
    doubled = render_pattern(corrupt, track_number=1, kind=NoteKind.DRUM, options=options)

    # Every gate in the real pattern decodes now, so --default-gate moves nothing.
    assert not any("default length" in w for w in measured.warnings)
    assert all(n.duration_ticks == TICKS_PER_STEP for n in doubled.notes)
    assert any("1-step default" in w for w in doubled.warnings)


class TestSplit:
    """One file per non-empty (track, pattern), each from its own tick 0."""

    def test_one_result_per_track_and_pattern(self, project_9: Project) -> None:
        """project_9 uses pattern 2 on two tracks and pattern 3 on one."""
        results = export_split(project_9)

        assert [(r.track_numbers, r.pattern_numbers) for r in results] == [
            ((1,), (2,)),
            ((1,), (3,)),
            ((3,), (2,)),
        ]
        assert all(r.note_count == 1 for r in results)

    def test_each_file_starts_at_tick_zero(self, project_9: Project) -> None:
        """Merged, pattern 3 sits a pattern late; split, it stands alone."""
        merged = played(export_project(project_9, ONE_PASS).midi, "Track 1 (drum)")
        assert [n.start for n in merged] == [0, 16 * TICKS_PER_STEP]

        pattern_3 = next(r for r in export_split(project_9, ONE_PASS) if r.pattern_numbers == (3,))
        assert [n.start for n in played(pattern_3.midi, "Track 1 (drum)")] == [0]

    def test_a_split_file_holds_only_its_own_track(self, project_5: Project) -> None:
        results = export_split(project_5)
        assert [r.track_names for r in results] == [("Track 1 (drum)",), ("Track 3",)]

    def test_both_note_sets_of_one_pattern_stay_in_one_file(self, project_files_dir: Path) -> None:
        """--include-stale adds a MIDI track, not a file: same (track, pattern)."""
        project = load(project_files_dir / "initial_project.KeyStepPro").select(track=1, pattern=1)
        (result,) = export_split(project, ExportOptions(include_stale=True))
        assert result.track_names == ("Track 1", "Track 1 (drum)")

    def test_an_empty_project_produces_no_files(self, project_files_dir: Path) -> None:
        assert export_split(load(project_files_dir / "Default.KeyStepPro")) == ()


def test_tracks_of_different_total_lengths_are_reported(project_9: Project) -> None:
    """Merged, every track restarts at each pattern boundary.

    The device loops each track on its own, so once the totals differ the file
    and the hardware stop agreeing about what plays together -- worth saying
    out loud, because nothing in the .mid reveals it.
    """
    result = export_project(project_9)
    assert any("different total lengths" in w and "drift apart" in w for w in result.warnings)

    # One track cannot disagree with itself, so the line must not appear.
    alone = export_project(project_9.select(track=1))
    assert not any("different total lengths" in w for w in alone.warnings)


def test_the_written_file_reads_back_identically(
    project_5: Project, exported_5: ExportResult, tmp_path: Path
) -> None:
    """Everything above inspects an in-memory object; a DAW reads bytes."""
    path = tmp_path / "out.mid"
    exported_5.midi.save(path)

    reloaded = mido.MidiFile(path)
    assert played(reloaded, "Track 3") == played(exported_5.midi, "Track 3")
    assert played(reloaded, "Track 1 (drum)") == played(exported_5.midi, "Track 1 (drum)")
