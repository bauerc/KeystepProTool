"""``ksp2midi`` end to end: paths, exit codes and what lands on each stream."""

from pathlib import Path

import mido
import pytest

from ksp_cli.export import main


def test_writes_a_midi_file_next_to_its_input(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    source = tmp_path / "project_5.KeyStepPro"
    source.write_bytes((project_files_dir / "project_5.KeyStepPro").read_bytes())

    assert main([str(source)]) == 0

    written = tmp_path / "project_5.mid"
    assert written.exists()
    assert [t.name for t in mido.MidiFile(written).tracks] == [
        "project_5.KeyStepPro",
        "Track 1 (drum)",
        "Track 3",
    ]
    assert "12 note(s)" in capsys.readouterr().out


def test_output_path_can_be_given(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    destination = tmp_path / "nested" / "out.mid"
    destination.parent.mkdir()
    assert main([str(project_files_dir / "project_5.KeyStepPro"), "-o", str(destination)]) == 0
    assert destination.exists()
    assert str(destination) in capsys.readouterr().out


def test_an_existing_file_is_not_overwritten_without_force(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Silently replacing an edited MIDI file would lose a DAW session's work."""
    destination = tmp_path / "out.mid"
    destination.write_bytes(b"not a midi file")
    argv = [str(project_files_dir / "project_5.KeyStepPro"), "-o", str(destination)]

    assert main(argv) == 1
    assert destination.read_bytes() == b"not a midi file"
    assert "already exists" in capsys.readouterr().err

    assert main([*argv, "--force"]) == 0
    assert destination.read_bytes() != b"not a midi file"


def test_warnings_go_to_stderr_and_the_summary_to_stdout(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """A pipeline consuming the summary should not have to filter caveats out."""
    argv = [str(project_files_dir / "project_5.KeyStepPro"), "-o", str(tmp_path / "out.mid")]
    assert main(argv) == 0

    captured = capsys.readouterr()
    assert "warning:" in captured.err
    assert "drum map is a device global" in captured.err
    assert "warning:" not in captured.out
    assert "wrote" in captured.out


def test_quiet_suppresses_the_summary_but_not_the_warnings(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [
        str(project_files_dir / "project_5.KeyStepPro"),
        "-o",
        str(tmp_path / "out.mid"),
        "--quiet",
    ]
    assert main(argv) == 0
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "warning:" in captured.err


def test_selecting_a_track_and_pattern(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    destination = tmp_path / "out.mid"
    argv = [
        str(project_files_dir / "project_9.KeyStepPro"),
        "-o",
        str(destination),
        "--track",
        "1",
        "--pattern",
        "2",
    ]
    assert main(argv) == 0
    assert [t.name for t in mido.MidiFile(destination).tracks] == [
        "project_9.KeyStepPro",
        "Track 1 (drum)",
    ]
    assert "1 note(s)" in capsys.readouterr().out


def test_a_selection_holding_no_notes_is_an_error_not_an_empty_file(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """An empty .mid looks like success until someone opens it."""
    destination = tmp_path / "out.mid"
    argv = [
        str(project_files_dir / "project_5.KeyStepPro"),
        "-o",
        str(destination),
        "--pattern",
        "7",
    ]
    assert main(argv) == 1
    assert not destination.exists()
    assert "nothing to export" in capsys.readouterr().err


def test_an_empty_project_is_an_error(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [
        str(project_files_dir / "user_empty_project.KeyStepPro"),
        "-o",
        str(tmp_path / "out.mid"),
    ]
    assert main(argv) == 1
    assert "nothing to export" in capsys.readouterr().err


def test_step_size_can_be_overridden(project_files_dir: Path, tmp_path: Path) -> None:
    destination = tmp_path / "out.mid"
    argv = [
        str(project_files_dir / "project_5.KeyStepPro"),
        "-o",
        str(destination),
        "--steps-per-beat",
        "2",
    ]
    assert main(argv) == 0
    assert mido.MidiFile(destination).length == pytest.approx(4.0)  # 16 eighths at 120 BPM


def test_impossible_timing_options_are_rejected_before_any_file_is_read(
    project_files_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [str(project_files_dir / "project_5.KeyStepPro"), "--steps-per-beat", "7"]
    assert main(argv) == 2
    assert "not divisible" in capsys.readouterr().err


def test_missing_file_reports_an_error(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert main([str(tmp_path / "nope.KeyStepPro")]) == 1
    assert "ksp2midi:" in capsys.readouterr().err


def test_a_file_that_is_not_a_project_reports_an_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "wrong.KeyStepPro"
    path.write_text('{"device": 5}', encoding="utf-8")
    assert main([str(path)]) == 1
    assert "missing 'device'" in capsys.readouterr().err
