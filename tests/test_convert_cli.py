"""``midi2ksp`` end to end: paths, exit codes and what lands on each stream."""

from pathlib import Path

import mido
import pytest

from ksp import lenient_json, reader
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


def test_a_bad_template_is_a_runtime_error(
    simple_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    template = tmp_path / "broken.KeyStepPro"
    template.write_text("[]")
    argv = [str(simple_clip), "-o", str(tmp_path / "out.KeyStepPro"), "--template", str(template)]

    assert main(argv) == 1
    assert "template" in capsys.readouterr().err


def two_tracks() -> mido.MidiFile:
    """A type 1 file whose note-bearing tracks are 1 and 2."""
    midi = mido.MidiFile(type=1)
    for pitch in (60, 64):
        track = mido.MidiTrack()
        track.append(mido.Message("note_on", note=pitch, velocity=100, time=0))
        track.append(mido.Message("note_off", note=pitch, velocity=0, time=480))
        midi.tracks.append(track)
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
    assert "contradict each other" in capsys.readouterr().err
