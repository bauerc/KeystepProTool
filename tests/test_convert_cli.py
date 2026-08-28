"""``midi2ksp`` end to end: paths, exit codes and what lands on each stream."""

from pathlib import Path

import mido
import pytest

from ksp import lenient_json, reader
from ksp.midi_export import DEFAULT_FLAT_VELOCITY
from ksp.model import NoteKind
from ksp_cli.convert import main
from ksp_cli.loading import default_template


def test_writes_a_project_next_to_its_input(
    simple_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    source = tmp_path / "clip.mid"
    source.write_bytes(simple_clip.read_bytes())

    assert main([str(source)]) == 0

    written = tmp_path / "clip.KeyStepPro"
    project = reader.load(written)
    notes = project.track(1).pattern(1).notes_of(NoteKind.SEQ)
    assert [note.step for note in notes] == list(range(1, 17))
    assert "16 note(s) onto track 1, pattern 1" in capsys.readouterr().out


def test_the_bundled_template_is_the_factory_default(project_files_dir: Path) -> None:
    """The shipped copy and the sample must not drift apart."""
    assert (
        default_template().read_bytes() == (project_files_dir / "Default.KeyStepPro").read_bytes()
    )


def test_the_bundled_template_is_used_by_default(simple_clip: Path, tmp_path: Path) -> None:
    """The installed command has to work without the repository around it."""
    destination = tmp_path / "out.KeyStepPro"
    assert main([str(simple_clip), "-o", str(destination)]) == 0

    assert default_template().exists()
    assert lenient_json.load_path(destination).keys() == (
        lenient_json.load_path(default_template()).keys() | {"version"}
    )


def test_the_version_key_is_injected_in_mcc_position(simple_clip: Path, tmp_path: Path) -> None:
    """The factory template has no version key; every saved project has one."""
    destination = tmp_path / "out.KeyStepPro"
    assert main([str(simple_clip), "-o", str(destination)]) == 0

    written = lenient_json.load_path(destination)
    assert list(written)[:2] == ["device", "version"]
    assert written["version"] == "2.5.20"


def test_a_template_can_be_supplied(
    simple_clip: Path, project_files_dir: Path, tmp_path: Path
) -> None:
    """A clip goes into a spare pattern of a project you already have."""
    destination = tmp_path / "out.KeyStepPro"
    argv = [
        str(simple_clip),
        "-o",
        str(destination),
        "--template",
        str(project_files_dir / "project_5.KeyStepPro"),
        "--track",
        "3",
        "--pattern",
        "2",
    ]

    assert main(argv) == 0

    project = reader.load(destination)
    assert len(project.track(3).pattern(2).notes_of(NoteKind.SEQ)) == 16
    # The notes that were already in pattern 1 are still there.
    assert project.track(3).pattern(1).notes_of(NoteKind.SEQ)


def test_track_and_pattern_are_selectable(simple_clip: Path, tmp_path: Path) -> None:
    destination = tmp_path / "out.KeyStepPro"
    assert main([str(simple_clip), "-o", str(destination), "--track", "4", "--pattern", "3"]) == 0

    project = reader.load(destination)
    assert len(project.track(4).pattern(3).notes_of(NoteKind.SEQ)) == 16
    assert not project.track(1).pattern(1).notes_of(NoteKind.SEQ)


def test_an_existing_file_is_not_overwritten_without_force(
    simple_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    destination = tmp_path / "out.KeyStepPro"
    destination.write_bytes(b"not a project")
    argv = [str(simple_clip), "-o", str(destination)]

    assert main(argv) == 1
    assert destination.read_bytes() == b"not a project"
    assert "already exists" in capsys.readouterr().err

    assert main([*argv, "--force"]) == 0
    assert destination.read_bytes() != b"not a project"


def test_dry_run_writes_nothing_but_still_catches_a_collision(
    simple_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    destination = tmp_path / "out.KeyStepPro"
    argv = [str(simple_clip), "-o", str(destination), "--dry-run"]

    assert main(argv) == 0
    assert not destination.exists()
    assert "would write" in capsys.readouterr().out

    destination.write_bytes(b"in the way")
    assert main(argv) == 1
    assert "already exists" in capsys.readouterr().err


def test_warnings_go_to_stderr_and_the_summary_to_stdout(
    simple_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert main([str(simple_clip), "-o", str(tmp_path / "out.KeyStepPro")]) == 0

    captured = capsys.readouterr()
    assert "the project tempo was set" in captured.err
    assert "midi2ksp: warning:" not in captured.out
    assert "wrote" in captured.out


def test_quiet_keeps_the_warnings(
    simple_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert main([str(simple_clip), "-o", str(tmp_path / "out.KeyStepPro"), "--quiet"]) == 0

    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err


def test_verbose_lists_every_warning(
    m6_song: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [str(m6_song), "-o", str(tmp_path / "out.KeyStepPro"), "--drum-track", "3", "-v"]
    assert main(argv) == 0

    err = capsys.readouterr().err
    assert "fitted to the source" in err
    assert "split across patterns" in err


def test_a_chord_keeps_every_note(
    chord_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """M5 kept the top line. The pool is an event list, so M6 keeps the chord."""
    destination = tmp_path / "out.KeyStepPro"
    assert main([str(chord_clip), "-o", str(destination)]) == 0

    notes = reader.load(destination).track(1).pattern(1).notes_of(NoteKind.SEQ)
    assert len(notes) == 26
    assert sorted(note.pitch for note in notes if note.step == 1) == [60, 64, 67]
    # The four-voice chord too: nothing about the pool caps a step at three.
    assert sorted(note.pitch for note in notes if note.step == 13) == [60, 61, 62, 63]
    assert "shared a step" not in capsys.readouterr().err


def test_a_missing_input_is_a_runtime_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert main([str(tmp_path / "absent.mid"), "-o", str(tmp_path / "out.KeyStepPro")]) == 1
    assert "midi2ksp:" in capsys.readouterr().err


def test_a_file_that_is_not_midi_is_a_runtime_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    source = tmp_path / "not.mid"
    source.write_bytes(b"this is not a MIDI file")

    assert main([str(source), "-o", str(tmp_path / "out.KeyStepPro")]) == 1
    assert "not a readable MIDI file" in capsys.readouterr().err


def one_note(type: int = 0) -> mido.MidiFile:
    midi = mido.MidiFile(type=type)
    track = mido.MidiTrack()
    midi.tracks.append(track)
    track.append(mido.Message("note_on", note=60, velocity=100, time=0))
    track.append(mido.Message("note_off", note=60, velocity=64, time=120))
    return midi


def test_a_timecode_file_is_refused(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    """It converted in silence, with the whole clip piled onto step 1."""
    source = tmp_path / "smpte.mid"
    midi = one_note()
    midi.ticks_per_beat = -7600
    midi.save(source)

    assert main([str(source), "-o", str(tmp_path / "out.KeyStepPro")]) == 1
    assert "SMPTE timecode" in capsys.readouterr().err
    assert not (tmp_path / "out.KeyStepPro").exists()


def test_a_type_two_file_is_refused(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    source = tmp_path / "async.mid"
    one_note(type=2).save(source)

    assert main([str(source), "-o", str(tmp_path / "out.KeyStepPro")]) == 1
    assert "type 2" in capsys.readouterr().err
    assert not (tmp_path / "out.KeyStepPro").exists()


def test_a_clip_with_no_notes_is_refused(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A silent project would look like success and play nothing."""
    source = tmp_path / "silent.mid"
    empty = mido.MidiFile(type=0)
    empty.tracks.append(mido.MidiTrack())
    empty.save(source)

    assert main([str(source), "-o", str(tmp_path / "out.KeyStepPro")]) == 1
    assert "no notes to convert" in capsys.readouterr().err


def test_an_occupied_pattern_is_refused(
    simple_clip: Path, project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [
        str(simple_clip),
        "-o",
        str(tmp_path / "out.KeyStepPro"),
        "--template",
        str(project_files_dir / "project_5.KeyStepPro"),
        "--track",
        "3",
    ]

    assert main(argv) == 1
    assert "already holds notes" in capsys.readouterr().err


def test_a_bad_step_size_is_an_argument_error(
    simple_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [str(simple_clip), "-o", str(tmp_path / "out.KeyStepPro"), "--steps-per-beat", "0"]

    assert main(argv) == 2
    assert "steps_per_beat" in capsys.readouterr().err


def _written_velocities(project: Path) -> set[int]:
    notes = reader.load(project).track(1).pattern(1).notes_of(NoteKind.SEQ)
    return {note.velocity for note in notes}


def test_flat_velocity_fresh_writes_the_measured_default(simple_clip: Path, tmp_path: Path) -> None:
    destination = tmp_path / "out.KeyStepPro"
    argv = [str(simple_clip), "-o", str(destination), "--flat-velocity", "fresh"]

    assert main(argv) == 0
    assert _written_velocities(destination) == {DEFAULT_FLAT_VELOCITY}


def test_flat_velocity_accepts_an_explicit_value(simple_clip: Path, tmp_path: Path) -> None:
    destination = tmp_path / "out.KeyStepPro"
    argv = [str(simple_clip), "-o", str(destination), "--flat-velocity", "64"]

    assert main(argv) == 0
    assert _written_velocities(destination) == {64}


@pytest.mark.parametrize("value", ["0", "128"])
def test_flat_velocity_outside_the_range_is_an_argument_error(
    value: str, simple_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [str(simple_clip), "-o", str(tmp_path / "out.KeyStepPro"), "--flat-velocity", value]

    assert main(argv) == 2
    assert "flat_velocity must be 1-127" in capsys.readouterr().err


def test_flat_velocity_neither_fresh_nor_a_number_is_an_argument_error(
    simple_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [str(simple_clip), "-o", str(tmp_path / "out.KeyStepPro"), "--flat-velocity", "loud"]

    assert main(argv) == 2
    assert "is not 'fresh' or a velocity" in capsys.readouterr().err


def test_a_bad_template_is_a_runtime_error(
    simple_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    template = tmp_path / "broken.KeyStepPro"
    template.write_text("[]")
    argv = [str(simple_clip), "-o", str(tmp_path / "out.KeyStepPro"), "--template", str(template)]

    assert main(argv) == 1
    assert "template" in capsys.readouterr().err


def note_track(pitch: int) -> mido.MidiTrack:
    track = mido.MidiTrack()
    track.append(mido.Message("note_on", note=pitch, velocity=100, time=0))
    track.append(mido.Message("note_off", note=pitch, velocity=0, time=480))
    return track


def two_tracks() -> mido.MidiFile:
    """A type 1 file whose note-bearing tracks are 1 and 2."""
    midi = mido.MidiFile(type=1)
    midi.tracks.extend(note_track(pitch) for pitch in (60, 64))
    return midi


def routed(tmp_path: Path, *args: str) -> tuple[Path, list[str]]:
    source = tmp_path / "two.mid"
    two_tracks().save(source)
    output = tmp_path / "out.KeyStepPro"
    return output, [str(source), "-o", str(output), *args]


def test_a_route_puts_a_source_track_where_it_says(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    output, argv = routed(tmp_path, "--route", "2:1,1:2")

    assert main(argv) == 0

    project = reader.load(output)
    # Source track 2 is the E, source track 1 the C, and the route swaps them.
    assert [n.pitch for n in project.track(1).pattern(1).notes_of(NoteKind.SEQ)] == [64]
    assert [n.pitch for n in project.track(2).pattern(1).notes_of(NoteKind.SEQ)] == [60]


def test_a_route_names_its_sources_in_the_summary(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _, argv = routed(tmp_path, "--route", "2:1,1:2")

    assert main(argv) == 0

    out = capsys.readouterr().out
    assert "track 1 [source 2]" in out
    assert "track 2 [source 1]" in out


def test_without_a_route_the_summary_names_no_source(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The default output is unchanged, which is what keeps the parity corpus still."""
    _, argv = routed(tmp_path)

    assert main(argv) == 0
    assert "source" not in capsys.readouterr().out


@pytest.mark.parametrize(
    ("spec", "expected"),
    [
        ("bad", "'bad' is not a source:device pair"),
        ("1:2:3", "'1:2:3' is not a source:device pair"),
        ("1:2,3:2", "both name device track 2"),
        ("1:9", "the device has 4 tracks"),
        ("1:2,1:3", "names source track 1 twice"),
    ],
)
def test_a_bad_route_is_an_argument_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], spec: str, expected: str
) -> None:
    _, argv = routed(tmp_path, "--route", spec)

    assert main(argv) == 2
    assert expected in capsys.readouterr().err


def test_a_route_with_midi_track_is_an_argument_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """--midi-track already decides the destination, so a route has nothing to place."""
    _, argv = routed(tmp_path, "--midi-track", "1", "--route", "1:2")

    assert main(argv) == 2
    assert "--midi-track and --route contradict each other" in capsys.readouterr().err


def test_midi_tracks_converts_the_tracks_it_names(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    output, argv = routed(tmp_path, "--midi-tracks", "2")

    assert main(argv) == 0

    project = reader.load(output)
    # Source track 2 is the E, and a selection places from --track upwards.
    assert [n.pitch for n in project.track(1).pattern(1).notes_of(NoteKind.SEQ)] == [64]
    assert project.track(2).pattern(1).notes_of(NoteKind.SEQ) == ()


def test_midi_tracks_takes_a_range(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    output, argv = routed(tmp_path, "--midi-tracks", "1-2")

    assert main(argv) == 0

    project = reader.load(output)
    assert [n.pitch for n in project.track(1).pattern(1).notes_of(NoteKind.SEQ)] == [60]
    assert [n.pitch for n in project.track(2).pattern(1).notes_of(NoteKind.SEQ)] == [64]


def test_midi_track_still_writes_one_pattern(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The singular spelling keeps its own path, whatever the plural one does."""
    output, argv = routed(tmp_path, "--midi-track", "2", "--track", "3")

    assert main(argv) == 0

    project = reader.load(output)
    assert [n.pitch for n in project.track(3).pattern(1).notes_of(NoteKind.SEQ)] == [64]


@pytest.mark.parametrize(
    ("spec", "expected"),
    [
        ("bad", "'bad' is not a number or a range"),
        ("3-1", "'3-1' ends before it starts"),
        ("0", "0 is out of range 1-65535"),
        ("99", "source track 99 was selected; the file has 2 tracks"),
    ],
)
def test_a_bad_midi_tracks_is_an_argument_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str], spec: str, expected: str
) -> None:
    _, argv = routed(tmp_path, "--midi-tracks", spec)

    assert main(argv) == 2
    assert expected in capsys.readouterr().err


def test_both_track_spellings_are_an_argument_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _, argv = routed(tmp_path, "--midi-track", "1", "--midi-tracks", "1")

    assert main(argv) == 2
    assert "--midi-track and --midi-tracks contradict each other" in capsys.readouterr().err


def test_a_route_inside_the_selection_is_applied(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    output, argv = routed(tmp_path, "--midi-tracks", "1,2", "--route", "2:1")

    assert main(argv) == 0

    project = reader.load(output)
    assert [n.pitch for n in project.track(1).pattern(1).notes_of(NoteKind.SEQ)] == [64]


def test_a_route_outside_the_selection_is_an_argument_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _, argv = routed(tmp_path, "--midi-tracks", "1", "--route", "2:1")

    assert main(argv) == 2
    assert "route 2:1 names source track 2, which is not in the selection" in (
        capsys.readouterr().err
    )


def one_track(pitch: int) -> mido.MidiFile:
    """A file whose single note-bearing track holds one note."""
    midi = mido.MidiFile(type=1)
    midi.tracks.append(note_track(pitch))
    return midi


def two_files(tmp_path: Path, *args: str) -> tuple[Path, list[str]]:
    one_track(60).save(tmp_path / "first.mid")
    one_track(64).save(tmp_path / "second.mid")
    output = tmp_path / "out.KeyStepPro"
    return output, [
        str(tmp_path / "first.mid"),
        str(tmp_path / "second.mid"),
        "-o",
        str(output),
        *args,
    ]


def test_several_sources_fill_tracks_in_argument_order(tmp_path: Path) -> None:
    output, argv = two_files(tmp_path)

    assert main(argv) == 0

    project = reader.load(output)
    assert [n.pitch for n in project.track(1).pattern(1).notes_of(NoteKind.SEQ)] == [60]
    assert [n.pitch for n in project.track(2).pattern(1).notes_of(NoteKind.SEQ)] == [64]


def test_the_argument_order_decides_which_track_a_file_lands_on(tmp_path: Path) -> None:
    """The same two files the other way round swap the tracks they fill."""
    output, argv = two_files(tmp_path)
    argv[0], argv[1] = argv[1], argv[0]

    assert main(argv) == 0

    project = reader.load(output)
    assert [n.pitch for n in project.track(1).pattern(1).notes_of(NoteKind.SEQ)] == [64]
    assert [n.pitch for n in project.track(2).pattern(1).notes_of(NoteKind.SEQ)] == [60]


def test_several_sources_name_their_file_in_the_summary(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _, argv = two_files(tmp_path)

    assert main(argv) == 0

    out = capsys.readouterr().out
    assert "track 1 [source 1, first.mid]" in out
    assert "track 2 [source 2, second.mid]" in out


def test_one_source_names_no_file_in_the_summary(
    simple_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A single path prints what it printed before, which is what holds the parity corpus still."""
    argv = [str(simple_clip), "-o", str(tmp_path / "out.KeyStepPro")]

    assert main(argv) == 0
    assert ".mid" not in capsys.readouterr().out


def test_the_default_output_is_named_after_the_first_source(tmp_path: Path) -> None:
    one_track(60).save(tmp_path / "first.mid")
    one_track(64).save(tmp_path / "second.mid")

    assert main([str(tmp_path / "first.mid"), str(tmp_path / "second.mid")]) == 0

    assert (tmp_path / "first.KeyStepPro").exists()
    assert not (tmp_path / "second.KeyStepPro").exists()


def test_an_unreadable_source_fails_the_whole_run(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Naming the path that failed, and writing nothing: a half-converted project is worse."""
    one_track(60).save(tmp_path / "first.mid")
    output = tmp_path / "out.KeyStepPro"
    argv = [str(tmp_path / "first.mid"), str(tmp_path / "missing.mid"), "-o", str(output)]

    assert main(argv) == 1
    assert "missing.mid" in capsys.readouterr().err
    assert not output.exists()


def test_a_route_reaches_across_the_files(tmp_path: Path) -> None:
    """Source numbering runs on through the files, so a route addresses either of them."""
    output, argv = two_files(tmp_path, "--route", "2:1,1:2")

    assert main(argv) == 0

    project = reader.load(output)
    assert [n.pitch for n in project.track(1).pattern(1).notes_of(NoteKind.SEQ)] == [64]
    assert [n.pitch for n in project.track(2).pattern(1).notes_of(NoteKind.SEQ)] == [60]


def test_a_selection_reaches_across_the_files(tmp_path: Path) -> None:
    output, argv = two_files(tmp_path, "--midi-tracks", "2")

    assert main(argv) == 0

    project = reader.load(output)
    assert [n.pitch for n in project.track(1).pattern(1).notes_of(NoteKind.SEQ)] == [64]
    assert project.track(2).pattern(1).notes_of(NoteKind.SEQ) == ()


def test_a_selection_past_the_files_counts_them_all(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    _, argv = two_files(tmp_path, "--midi-tracks", "9")

    assert main(argv) == 2
    assert "the 2 files hold 2 tracks between them" in capsys.readouterr().err


def test_midi_track_with_several_sources_is_an_argument_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """--midi-track writes one track into one pattern; several files have no such track."""
    _, argv = two_files(tmp_path, "--midi-track", "1")

    assert main(argv) == 2
    assert "--midi-track reads one file" in capsys.readouterr().err


def _chained_steps(project: Path, track: int) -> list[int]:
    """The step count of each pattern the track's chain runs through, in chain order."""
    loaded = reader.load(project)
    chain = next(c for c in loaded.chained_scenes[0].chains if c.track == track)
    return [loaded.track(track).pattern(number).seq_step_count for number in chain.patterns]


def test_segment_bars_cuts_a_source_track_where_it_is_asked_to(
    m6_song: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Source track 3 is four bars, which the automatic split leaves whole."""
    destination = tmp_path / "out.KeyStepPro"
    argv = [str(m6_song), "-o", str(destination), "--segment-bars", "3:3"]

    assert main(argv) == 0
    assert _chained_steps(destination, 1) == [32, 32]
    captured = capsys.readouterr()
    assert "track 1 was cut at bar(s) 3 across patterns 1-2 and chained" in captured.err
    assert "track 1: 64 note(s), patterns 1-2 (32, 32 steps)" in captured.out


def test_segment_bars_gathers_the_pairs_naming_one_track(m6_song: Path, tmp_path: Path) -> None:
    destination = tmp_path / "out.KeyStepPro"
    argv = [str(m6_song), "-o", str(destination), "--segment-bars", "3:2,3:3"]

    assert main(argv) == 0
    assert _chained_steps(destination, 1) == [16, 16, 32]


def test_segment_bars_leaves_the_tracks_it_does_not_name_alone(
    m6_song: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Source track 6 still runs past 64 steps and still says so in the split's words."""
    destination = tmp_path / "out.KeyStepPro"
    argv = [str(m6_song), "-o", str(destination), "--segment-bars", "3:3"]

    assert main(argv) == 0
    assert _chained_steps(destination, 4) == [64, 64]
    assert "track 4 runs 128 steps, past the device's 64" in capsys.readouterr().err


@pytest.mark.parametrize(
    ("spec", "reason"),
    [
        ("5:4", "segment bar 4 of source track 5 is past the track's 2 bar(s)"),
        (
            "6:2",
            "source track 6 makes a pattern of 112 steps from bar 2, past the device's 64",
        ),
        ("9:2", "track 9 of the source carries nothing to segment"),
    ],
)
def test_a_boundary_the_song_refuses_is_an_argument_error(
    spec: str, reason: str, m6_song: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A boundary is an argument, so it leaves by the usage door and not the conversion's."""
    argv = [str(m6_song), "-o", str(tmp_path / "out.KeyStepPro"), "--segment-bars", spec]

    assert main(argv) == 2
    assert reason in capsys.readouterr().err


def test_more_segments_than_the_chain_holds_is_an_argument_error(
    m6_song: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [
        str(m6_song),
        "-o",
        str(tmp_path / "out.KeyStepPro"),
        "--midi-tracks",
        "6",
        "--pattern",
        "12",
        "--segment-bars",
        "6:2,6:3,6:4,6:5,6:6,6:7,6:8",
    ]

    assert main(argv) == 2
    assert "source track 6 makes 8 patterns but only 5 are free" in capsys.readouterr().err


@pytest.mark.parametrize(
    ("spec", "reason"),
    [
        ("bad", "--segment-bars: 'bad' is not a source:bar pair"),
        ("0:3", "segment counts source tracks from 1, so 0 is not one"),
        ("3:1", "segment bar 1 of source track 3 is not a boundary"),
        ("3:5,3:3", "segment bars of source track 3 must ascend, and 3 does not follow 5"),
    ],
)
def test_a_malformed_segmentation_is_an_argument_error(
    spec: str, reason: str, m6_song: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [str(m6_song), "-o", str(tmp_path / "out.KeyStepPro"), "--segment-bars", spec]

    assert main(argv) == 2
    assert reason in capsys.readouterr().err


def test_segment_bars_with_a_single_target_is_an_argument_error(
    m6_song: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """--midi-track writes the one pattern the target names, which no boundary can cut."""
    argv = [
        str(m6_song),
        "-o",
        str(tmp_path / "out.KeyStepPro"),
        "--midi-track",
        "3",
        "--segment-bars",
        "3:2",
    ]

    assert main(argv) == 2
    assert "--midi-track and --segment-bars contradict each other" in capsys.readouterr().err
