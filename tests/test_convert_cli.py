"""``midi2ksp`` end to end: paths, exit codes and what lands on each stream."""

from pathlib import Path

import mido
import pytest

from ksp import lenient_json, reader
from ksp.model import NoteKind
from ksp_cli.convert import default_template, main


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
    assert "note lengths are not carried" in captured.err
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
    chord_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [str(chord_clip), "-o", str(tmp_path / "out.KeyStepPro"), "-v"]
    assert main(argv) == 0

    assert "shared a step with a higher one" in capsys.readouterr().err


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
