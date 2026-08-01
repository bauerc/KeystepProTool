"""M3 -- load a project file, re-emit it, get the identical bytes back.

Nothing downstream is trustworthy without this. M4 puts a written file on the
hardware and M5 generates one from MIDI; if the writer drifts from what MIDI
Control Center produces, both fail in ways that look like format bugs.

Capture B0.2 exported an untouched project twice and got identical files, so
MCC's writer is deterministic and there is no drift to chase -- any difference
these tests see is ours. See ROADMAP.md M3 and spec section 2.
"""

import hashlib
import json
from collections.abc import Callable
from pathlib import Path

import pytest

from conftest import SAMPLE_NAMES
from ksp import lenient_json
from ksp.constants import P_SEQ_PITCH
from ksp.keys import key

#: The sample the always-on instance of each sweep runs on. A real MCC user
#: export, and the only one carrying both string values -- ``Default`` has no
#: ``version`` key -- so it is the one sample that exercises every emit path.
FOUNDATIONAL = "initial_project.KeyStepPro"


def every_sample(argname: str = "name") -> pytest.MarkDecorator:
    """Parametrise over all five samples, marking all but :data:`FOUNDATIONAL`
    slow.

    The sweeps are near-duplicates of each other: five samples proving one
    property. One of them stays always-on so a regression cannot reach a commit
    unnoticed, and the other four run in CI, which does not filter ``slow``.
    """
    return pytest.mark.parametrize(
        argname,
        [
            pytest.param(name, marks=() if name == FOUNDATIONAL else (pytest.mark.slow,))
            for name in SAMPLE_NAMES
        ],
    )


@every_sample()
def test_round_trip_is_byte_identical(name: str, project_files_dir: Path) -> None:
    """The milestone, on every sample: parse and re-emit changes nothing.

    The ``initial_project`` instance is the suite's foundational regression
    guard and is deliberately never marked slow -- if the writer drifts by one
    byte, this is what says so.
    """
    original = (project_files_dir / name).read_bytes()
    assert lenient_json.dumps(lenient_json.loads(original.decode())).encode() == original


def test_round_trip_md5_matches(project_files_dir: Path) -> None:
    """The hash comparison issue #5 names, on the file it names."""
    path = project_files_dir / "Default.KeyStepPro"
    original = path.read_bytes()
    emitted = lenient_json.dumps(lenient_json.load_path(path)).encode()
    assert hashlib.md5(emitted).hexdigest() == hashlib.md5(original).hexdigest()


@every_sample()
def test_dump_path_writes_identical_bytes(
    name: str,
    load_sample: Callable[[str], dict[str, int | str]],
    project_files_dir: Path,
    tmp_path: Path,
) -> None:
    """Through the filesystem, where a platform could translate newlines."""
    destination = tmp_path / name
    lenient_json.dump_path(load_sample(name), destination)
    assert destination.read_bytes() == (project_files_dir / name).read_bytes()


def test_dump_path_replaces_an_existing_file_and_leaves_no_debris(tmp_path: Path) -> None:
    """The temp file is renamed into place, not left beside the result."""
    destination = tmp_path / "out.KeyStepPro"
    destination.write_text("stale")

    lenient_json.dump_path({"device": "KeyStepPro", "120_37": 3}, destination)

    assert destination.read_text() == '{\n\t"device": "KeyStepPro",\n\t"120_37": 3,\n}'
    assert list(tmp_path.iterdir()) == [destination]


@pytest.mark.slow
def test_dumps_is_idempotent(load_sample: Callable[[str], dict[str, int | str]]) -> None:
    """A second pass through the writer is a no-op."""
    once = lenient_json.dumps(load_sample("project_5.KeyStepPro"))
    assert lenient_json.dumps(lenient_json.loads(once)) == once


def test_dumps_shape() -> None:
    """Tab indent, ``": "`` separator, trailing comma, no final newline."""
    text = lenient_json.dumps({"device": "KeyStepPro", "120_101": 127})

    assert text == '{\n\t"device": "KeyStepPro",\n\t"120_101": 127,\n}'
    assert not text.endswith("\n")


def test_dumps_of_an_empty_mapping() -> None:
    """No entries means no comma to trail."""
    assert lenient_json.dumps({}) == "{\n}"


def test_dumps_without_trailing_comma_drops_only_the_comma() -> None:
    """The always-on guard for ``trailing_comma=False``.

    Its whole-file counterpart below is slow-marked, and this is the only other
    coverage of the flag, so it stays cheap enough to never need marking.
    """
    assert lenient_json.dumps({"a": 1, "b": 2}, trailing_comma=False) == (
        '{\n\t"a": 1,\n\t"b": 2\n}'
    )


@pytest.mark.slow
def test_dumps_without_trailing_comma_is_strict_json(
    load_sample: Callable[[str], dict[str, int | str]],
) -> None:
    """The T6.2 candidate: one byte lighter, and ``json.loads`` accepts it.

    Whether MCC does is the open question -- it needs the application, not a
    test. Until it is answered the comma stays on by default.
    """
    project = load_sample("user_empty_project.KeyStepPro")
    lenient = lenient_json.dumps(project)
    strict = lenient_json.dumps(project, trailing_comma=False)

    assert strict == lenient[:-3] + "\n}"
    assert json.loads(strict) == project
    assert lenient_json.loads(strict) == project


@pytest.mark.parametrize("value", [1.0, None, True, {"nested": 1}, [1]])
def test_dumps_rejects_values_the_firmware_has_never_seen(value: object) -> None:
    """Only ints and strings. A float would emit ``1.0``, a bool ``true``."""
    with pytest.raises(TypeError, match="120_37"):
        lenient_json.dumps({"120_37": value})  # type: ignore[dict-item]


@every_sample()
def test_canonical_restores_mcc_key_order(
    name: str, load_sample: Callable[[str], dict[str, int | str]], project_files_dir: Path
) -> None:
    """Shuffled keys sort back to the order MCC wrote them in.

    Reversing is enough to break every rule at once: ``device`` and
    ``version`` end up last and the numeric keys run backwards.
    """
    reversed_keys = dict(reversed(list(load_sample(name).items())))

    assert (
        lenient_json.dumps(lenient_json.canonical(reversed_keys)).encode()
        == (project_files_dir / name).read_bytes()
    )


def test_canonical_sorts_numeric_keys_as_strings() -> None:
    """``126_99_16`` before ``126_99_2`` -- a numeric sort would disagree."""
    ordered = lenient_json.canonical({"126_99_2": 20, "126_99_16": 20, "126_99_13": 20})
    assert list(ordered) == ["126_99_13", "126_99_16", "126_99_2"]


def test_canonical_places_an_injected_version_second(
    load_sample: Callable[[str], dict[str, int | str]],
) -> None:
    """M5's case: the factory template has no ``version`` and needs one.

    Plain assignment appends it at the end of the dict, which is a key order
    no file MCC wrote has ever had.
    """
    template = load_sample("Default.KeyStepPro")
    template["version"] = "2.5.20"
    assert list(template)[-1] == "version"

    assert list(lenient_json.canonical(template))[:2] == ["device", "version"]


def test_a_single_value_edit_changes_exactly_one_line(
    load_sample: Callable[[str], dict[str, int | str]], project_files_dir: Path
) -> None:
    """The desk half of M4: one changed value is one changed line.

    Track 3's first note is C2 (48) in ``project_5``, hardware-confirmed in
    ``analysis/project_5_description.txt``. Moving it up a semitone must not
    disturb any of the other 153,496 lines.
    """
    original = (project_files_dir / "project_5.KeyStepPro").read_text()
    project = load_sample("project_5.KeyStepPro")

    pitch_key = key(125, P_SEQ_PITCH, 1, 1, 1)
    assert project[pitch_key] == 48
    project[pitch_key] = 49

    changed = [
        (before, after)
        for before, after in zip(
            original.split("\n"), lenient_json.dumps(project).split("\n"), strict=True
        )
        if before != after
    ]
    assert changed == [(f'\t"{pitch_key}": 48,', f'\t"{pitch_key}": 49,')]
