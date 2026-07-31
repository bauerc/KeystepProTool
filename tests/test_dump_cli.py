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


class TestDrumMapFlag:
    """Drum lanes are resolved through an assumed map, or not at all.

    The map is a device global setting that no project file contains, so the
    CLI's job is to be explicit about which one it used and to let the user
    say otherwise.
    """

    @pytest.fixture(autouse=True)
    def _no_personal_config(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        """Keep the suite independent of whoever's machine it runs on."""
        monkeypatch.setattr("ksp_cli.dump.CONFIG_PATH", tmp_path / "absent.json")

    def test_lanes_resolve_by_default(
        self, project_files_dir: Path, capsys: pytest.CaptureFixture[str]
    ) -> None:
        main([str(project_files_dir / "project_5.KeyStepPro"), "--track", "1"])
        out = capsys.readouterr().out
        assert "lane 0 -> C1 (36) Bass Drum 1" in out
        assert "drum map: chromatic from 36 (assumed - not in file)" in out

    def test_none_reproduces_the_unresolved_output(
        self, project_files_dir: Path, capsys: pytest.CaptureFixture[str]
    ) -> None:
        """The new default must not quietly rewrite what --drum-map none shows."""
        path = str(project_files_dir / "project_5.KeyStepPro")
        main([path, "--drum-map", "none"])
        out = capsys.readouterr().out
        assert "lane 0 " in out
        assert "->" not in out
        assert "drum map:" not in out

    def test_a_custom_map_changes_the_note(
        self, project_files_dir: Path, capsys: pytest.CaptureFixture[str]
    ) -> None:
        notes = ",".join(str(n) for n in range(60, 84))
        main([str(project_files_dir / "project_5.KeyStepPro"), "--drum-map", f"custom:{notes}"])
        out = capsys.readouterr().out
        assert "lane 0 -> C3 (60) Hi Bongo" in out
        assert "drum map: custom (assumed - not in file)" in out

    def test_json_carries_the_map_and_the_resolved_notes(
        self, project_files_dir: Path, capsys: pytest.CaptureFixture[str]
    ) -> None:
        main([str(project_files_dir / "project_5.KeyStepPro"), "--json"])
        payload = json.loads(capsys.readouterr().out)
        assert payload["drum_map"]["name"] == "chromatic-36"
        drum = payload["tracks"][0]["patterns"][0]["notes"]
        assert [n["drum_note"] for n in drum] == [36, 36]
        assert [n["drum_note_name"] for n in drum] == ["C1", "C1"]

    def test_json_omits_the_map_when_lanes_are_not_resolved(
        self, project_files_dir: Path, capsys: pytest.CaptureFixture[str]
    ) -> None:
        argv = [str(project_files_dir / "project_5.KeyStepPro"), "--json", "--drum-map", "none"]
        main(argv)
        payload = json.loads(capsys.readouterr().out)
        assert "drum_map" not in payload
        assert "drum_note" not in payload["tracks"][0]["patterns"][0]["notes"][0]

    def test_melodic_notes_are_untouched_by_the_map(
        self, project_files_dir: Path, capsys: pytest.CaptureFixture[str]
    ) -> None:
        main([str(project_files_dir / "project_5.KeyStepPro"), "--track", "3"])
        assert "C#2 (49)" in capsys.readouterr().out

    def test_drum_mode_is_shown_on_the_track(
        self, project_files_dir: Path, capsys: pytest.CaptureFixture[str]
    ) -> None:
        main([str(project_files_dir / "project_5.KeyStepPro"), "--track", "1"])
        assert "Track 1 (item 123)  [drum mode]" in capsys.readouterr().out

    def test_a_bad_map_reports_an_error(
        self, project_files_dir: Path, capsys: pytest.CaptureFixture[str]
    ) -> None:
        argv = [str(project_files_dir / "project_5.KeyStepPro"), "--drum-map", "chromatic:200"]
        assert main(argv) == 1
        assert "drum map:" in capsys.readouterr().err

    def test_a_config_file_is_used_when_no_flag_is_given(
        self,
        project_files_dir: Path,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
        capsys: pytest.CaptureFixture[str],
    ) -> None:
        config = tmp_path / "drum_map.json"
        config.write_text(json.dumps({"mode": "chromatic", "low": 60}), encoding="utf-8")
        monkeypatch.setattr("ksp_cli.dump.CONFIG_PATH", config)
        main([str(project_files_dir / "project_5.KeyStepPro"), "--track", "1"])
        assert "lane 0 -> C3 (60) Hi Bongo" in capsys.readouterr().out


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
