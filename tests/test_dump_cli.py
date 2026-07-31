"""``ksp-dump`` end to end: argument handling and output shape."""

import json
from pathlib import Path

import pytest

from ksp_cli.dump import main


def test_dumps_a_project_as_a_tree(
    project_files_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert main([str(project_files_dir / "project_5.KeyStepPro")]) == 0
    out = capsys.readouterr().out
    assert "Track 1 (item 123)" in out
    assert "Track 3 (item 125)" in out
    # The documented drum hits and the melodic line that validates the two
    # index spaces both have to appear.
    assert "lane 0" in out
    assert "C#2 (49)" in out
    assert "tempo 120 BPM" in out


def test_empty_patterns_are_hidden_unless_asked_for(
    project_files_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """All 16 patterns always exist on disk; only some hold anything.

    Printing 64 empty patterns by default would bury the two that matter.
    """
    path = str(project_files_dir / "project_5.KeyStepPro")

    main([path])
    default_out = capsys.readouterr().out
    main([path, "--all"])
    all_out = capsys.readouterr().out

    assert default_out.count("Pattern ") == 2
    assert all_out.count("Pattern ") == 64


def test_selects_a_single_track_and_pattern(
    project_files_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [str(project_files_dir / "project_9.KeyStepPro"), "--track", "1", "--pattern", "3"]
    assert main(argv) == 0
    out = capsys.readouterr().out
    assert "Track 1" in out
    assert "Track 3" not in out
    assert out.count("Pattern ") == 1
    assert "seq 32" in out  # test 2's step skip


def test_json_output_round_trips(
    project_files_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert main([str(project_files_dir / "project_5.KeyStepPro"), "--json"]) == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["tempo_bpm"] == 120.0
    assert len(payload["tracks"]) == 4
    drum = payload["tracks"][0]["patterns"][0]["notes"]
    assert [n["step"] for n in drum] == [1, 5]


def test_json_and_text_agree_on_the_selection(
    project_files_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Filtering happens once, on the model, so both outputs cannot drift."""
    argv = [str(project_files_dir / "project_5.KeyStepPro"), "--track", "3"]
    main([*argv, "--json"])
    payload = json.loads(capsys.readouterr().out)
    assert [t["track"] for t in payload["tracks"]] == [3]

    main(argv)
    assert "Track 1" not in capsys.readouterr().out


def test_unknown_gate_values_are_marked_not_guessed(
    project_files_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """initial_project has a drum note whose gate encoding is unmeasured."""
    main([str(project_files_dir / "initial_project.KeyStepPro"), "--track", "1", "--pattern", "1"])
    assert "gate ?(2)" in capsys.readouterr().out


def test_empty_project_says_so(project_files_dir: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert main([str(project_files_dir / "user_empty_project.KeyStepPro")]) == 0
    assert "(no patterns hold notes)" in capsys.readouterr().out


def test_missing_file_reports_an_error(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    assert main([str(tmp_path / "nope.KeyStepPro")]) == 1
    assert "ksp-dump:" in capsys.readouterr().err


def test_a_file_that_is_not_a_project_reports_an_error(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    path = tmp_path / "wrong.KeyStepPro"
    path.write_text('{"device": 5}', encoding="utf-8")
    assert main([str(path)]) == 1
    assert "missing 'device'" in capsys.readouterr().err
