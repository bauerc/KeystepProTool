"""The loader for MCC's non-standard JSON dialect."""

from pathlib import Path

import pytest

from ksp.lenient_json import load_path, loads, strip_trailing_commas


def test_parses_a_trailing_comma_before_a_closing_brace() -> None:
    assert loads('{\n\t"a": 1,\n}') == {"a": 1}


def test_parses_a_file_without_a_trailing_comma() -> None:
    """Strict JSON still has to work -- MCC's dialect is a superset."""
    assert loads('{"a": 1}') == {"a": 1}


def test_leaves_commas_inside_strings_alone() -> None:
    """The pattern anchors on a closing bracket, not on the comma alone."""
    assert loads('{"name": "kick, snare"}') == {"name": "kick, snare"}


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("[1, 2, ]", "[1, 2 ]"),
        ('{"a": 1,\n}', '{"a": 1\n}'),
        ('{"a": 1}', '{"a": 1}'),
    ],
)
def test_strip_trailing_commas(text: str, expected: str) -> None:
    assert strip_trailing_commas(text) == expected


def test_rejects_json_that_is_not_an_object() -> None:
    with pytest.raises(ValueError, match="expected a JSON object"):
        loads("[1, 2, 3]")


def test_loads_every_sample_project(project_files_dir: Path) -> None:
    for path in sorted(project_files_dir.glob("*.KeyStepPro")):
        raw = load_path(path)
        assert raw["device"] == "KeyStepPro"
        # Spec section 2: the numeric key set is fixed at 153,495 entries, plus
        # "device" and, in user saves, "version".
        assert len(raw) in {153_496, 153_497}, f"{path.name} has {len(raw)} keys"
