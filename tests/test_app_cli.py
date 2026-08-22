"""``kspplus`` -- that a subcommand is the standalone command, not a copy of it."""

import re
from pathlib import Path

import pytest

from ksp_cli import app, convert, dump, export

_ANSI = re.compile(r"\x1b\[[0-9;]*m")


def plain(text: str) -> str:
    """Help text without styling."""
    return _ANSI.sub("", text)


def test_ksp2midi_is_the_same_command_either_way(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    source = project_files_dir / "project_5.KeyStepPro"
    direct = tmp_path / "direct.mid"
    umbrella = tmp_path / "umbrella.mid"

    assert export.main([str(source), "-o", str(direct)]) == 0
    expected = capsys.readouterr()

    assert app.main(["ksp2midi", str(source), "-o", str(umbrella)]) == 0
    actual = capsys.readouterr()

    assert umbrella.read_bytes() == direct.read_bytes()
    # The destination is the one thing that legitimately differs.
    assert actual.out.replace(str(umbrella), "DEST") == expected.out.replace(str(direct), "DEST")
    assert actual.err == expected.err


def test_midi2ksp_is_the_same_command_either_way(
    simple_clip: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    direct = tmp_path / "direct.KeyStepPro"
    umbrella = tmp_path / "umbrella.KeyStepPro"

    assert convert.main([str(simple_clip), "-o", str(direct)]) == 0
    expected = capsys.readouterr()

    assert app.main(["midi2ksp", str(simple_clip), "-o", str(umbrella)]) == 0
    actual = capsys.readouterr()

    assert umbrella.read_bytes() == direct.read_bytes()
    assert actual.out.replace(str(umbrella), "DEST") == expected.out.replace(str(direct), "DEST")
    assert actual.err == expected.err


def test_ksp_dump_is_the_same_command_either_way(
    project_files_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    source = project_files_dir / "project_5.KeyStepPro"

    assert dump.main([str(source)]) == 0
    expected = capsys.readouterr()

    assert app.main(["ksp-dump", str(source)]) == 0
    actual = capsys.readouterr()

    assert actual.out == expected.out
    assert actual.err == expected.err


def test_options_reach_the_subcommand(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The form the issue asks for: flags after the subcommand name."""
    source = project_files_dir / "project_9.KeyStepPro"
    argv = ["ksp2midi", str(source), "-o", str(tmp_path), "--force", "--split"]

    assert app.main(argv) == 0

    written = sorted(p.name for p in tmp_path.glob("*.mid"))
    assert written, "--split wrote nothing"
    assert all(name.startswith("project_9_track") for name in written)
    assert str(tmp_path) in capsys.readouterr().out


def test_a_failing_subcommand_keeps_its_exit_code(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """1 for a bad file, not the 2 the group would give for a bad invocation."""
    assert app.main(["ksp2midi", str(tmp_path / "absent.KeyStepPro")]) == 1
    assert "ksp2midi:" in capsys.readouterr().err


def test_help_lists_every_subcommand(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    # Rich wraps to the terminal width, which would break a name across lines.
    monkeypatch.setenv("COLUMNS", "120")

    assert app.main(["--help"]) == 0

    out = plain(capsys.readouterr().out)
    assert "ksp-dump" in out
    assert "ksp2midi" in out
    assert "midi2ksp" in out


def test_subcommand_help_is_its_own(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("COLUMNS", "120")

    assert app.main(["ksp2midi", "--help"]) == 0

    out = plain(capsys.readouterr().out)
    assert "kspplus ksp2midi" in out  # the usage line names the way in
    # An option no other option's help text mentions, so this cannot pass on prose.
    assert "--include-disabled" in out
    for panel in ("Selection", "Timing", "Drum mapping", "Output"):
        assert panel in out


def test_an_unknown_subcommand_is_a_usage_error(capsys: pytest.CaptureFixture[str]) -> None:
    assert app.main(["nonesuch"]) == 2
    assert "nonesuch" in plain(capsys.readouterr().err)


def test_an_unknown_option_is_a_usage_error(
    project_files_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The path through runner.run that argparse used to take by raising."""
    source = project_files_dir / "project_5.KeyStepPro"
    assert app.main(["ksp2midi", str(source), "--bogus"]) == 2
    assert "--bogus" in plain(capsys.readouterr().err)
