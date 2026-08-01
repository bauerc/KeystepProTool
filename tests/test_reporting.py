"""What each command prints by default, and what --verbose adds.

``initial_project`` is the case that motivated this: real user material where
the same finding recurs in ten patterns. The invariant both tools must hold is
that the default view never says anything ``--verbose`` does not support, and
never hides a *kind* of problem -- only repeats of one.
"""

from pathlib import Path

import pytest

from ksp_cli.dump import main as dump_main
from ksp_cli.export import main as export_main

NOISY = "initial_project.KeyStepPro"


def _warning_lines(text: str) -> list[str]:
    return [
        line for line in text.splitlines() if "warning:" in line or line.lstrip().startswith("!")
    ]


# --- ksp2midi -------------------------------------------------------------


def test_export_collapses_repeats_by_default(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [str(project_files_dir / NOISY), "-o", str(tmp_path / "out.mid"), "--dry-run"]
    assert export_main(argv) == 0
    err = capsys.readouterr().err

    assert export_main([*argv, "--verbose"]) == 0
    verbose_err = capsys.readouterr().err

    assert len(_warning_lines(err)) < len(_warning_lines(verbose_err))
    # The ten per-pattern repeats become one counted line.
    assert "116 notes across 10 patterns are disabled (step turned off)" in err


def test_export_says_how_much_it_hid(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    argv = [str(project_files_dir / NOISY), "-o", str(tmp_path / "out.mid"), "--dry-run"]
    assert export_main(argv) == 0
    assert "--verbose for detail" in capsys.readouterr().err


def test_export_verbose_adds_no_trailer(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Nothing is hidden, so there is nothing to announce."""
    argv = [str(project_files_dir / NOISY), "-o", str(tmp_path / "out.mid"), "--dry-run", "-v"]
    assert export_main(argv) == 0
    assert "--verbose for detail" not in capsys.readouterr().err


def test_every_kind_survives_collapsing(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Collapsing may drop repeats, never a whole class of problem."""
    argv = [str(project_files_dir / NOISY), "-o", str(tmp_path / "out.mid"), "--dry-run"]
    assert export_main(argv) == 0
    default = capsys.readouterr().err
    for phrase in (
        "disabled (step turned off)",
        "drum lanes resolved through",
        "gate encoding 2 is not measured",
        "past the last step of 48",
        "different total lengths",
        "16/32/48/64",
    ):
        assert phrase in default, phrase


def test_quiet_still_shows_the_caveats(
    project_files_dir: Path, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """--quiet is about the summary, not about hiding what we were unsure of."""
    argv = [str(project_files_dir / NOISY), "-o", str(tmp_path / "out.mid"), "--dry-run", "--quiet"]
    assert export_main(argv) == 0
    captured = capsys.readouterr()
    assert captured.out == ""
    assert "warning:" in captured.err


# --- ksp-dump -------------------------------------------------------------


def test_dump_summarises_at_the_end_by_default(
    project_files_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert dump_main([str(project_files_dir / NOISY), "--all"]) == 0
    out = capsys.readouterr().out
    lines = _warning_lines(out)
    assert lines
    # The block sits after the tree, not beside each pattern.
    assert out.index("!") > out.index("Pattern 16")
    assert "--verbose for detail" in out


def test_dump_verbose_puts_them_back_inline(
    project_files_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    assert dump_main([str(project_files_dir / NOISY), "--all"]) == 0
    default = capsys.readouterr().out
    assert dump_main([str(project_files_dir / NOISY), "--all", "--verbose"]) == 0
    verbose = capsys.readouterr().out

    assert len(_warning_lines(verbose)) > len(_warning_lines(default))
    # Inline means before the end of the tree.
    assert verbose.index("!") < verbose.index("Pattern 16")


def test_a_clean_project_says_nothing(
    project_files_dir: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """No trailing block, no empty section, when there is nothing to report."""
    assert dump_main([str(project_files_dir / "user_empty_project.KeyStepPro")]) == 0
    assert not _warning_lines(capsys.readouterr().out)
