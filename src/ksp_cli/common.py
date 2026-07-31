"""Argument fragments, error handling and drum-map resolution shared by the CLIs.

``ksp-dump`` and ``ksp2midi`` take the same project selection and the same
``--drum-map`` grammar, and M5's ``midi2ksp`` will take them too. Defining them
once keeps the three commands consistent for a user who learns one of them.
"""

import json
import sys
from argparse import ArgumentParser, Namespace
from collections.abc import Callable
from pathlib import Path
from typing import Final

from ksp.drum_map import DEFAULT_CHROMATIC_LOW, DrumMap
from ksp.model import Project
from ksp.reader import load

#: Where a user's own drum map lives. Path resolution stays in the CLI: ``ksp``
#: must not decide where files are.
CONFIG_PATH: Final = Path.home() / ".config" / "keysteppro" / "drum_map.json"

DRUM_MAP_HELP: Final = (
    "lane -> note mapping: chromatic:N, custom:a,b,c (24 notes) or none. "
    "The device's drum map is a global setting and is not in the project file, "
    f"so this defaults to chromatic:{DEFAULT_CHROMATIC_LOW}"
)


class CliError(Exception):
    """A failure to report as one line on stderr rather than a traceback."""

    exit_code = 1


class UsageError(CliError):
    """The command was invoked wrongly. Nothing was read or written."""

    exit_code = 2


class DataError(CliError):
    """A file was missing, unreadable, or not what it claimed to be."""

    exit_code = 1


def run(prog: str, body: Callable[[], int]) -> int:
    """Run *body*, turning any :class:`CliError` into ``prog: message``."""
    try:
        return body()
    except CliError as exc:
        print(f"{prog}: {exc}", file=sys.stderr)
        return exc.exit_code


def add_path_arg(parser: ArgumentParser) -> None:
    parser.add_argument("path", type=Path, help="a .KeyStepPro project file")


def add_selection_args(parser: ArgumentParser, verb: str) -> None:
    """``--track`` / ``--pattern``, described with the command's own verb."""
    parser.add_argument("--track", type=int, choices=range(1, 5), help=f"{verb} only this track")
    parser.add_argument(
        "--pattern",
        type=int,
        choices=range(1, 17),
        metavar="{1..16}",
        help=f"{verb} only this pattern",
    )


def add_drum_map_arg(parser: ArgumentParser) -> None:
    parser.add_argument("--drum-map", metavar="SPEC", help=DRUM_MAP_HELP)


def parse_drum_map(spec: str) -> DrumMap | None:
    """Parse a ``--drum-map`` argument.

    ``chromatic:36`` | ``custom:36,38,42,...`` | ``none``. ``None`` means do not
    resolve lanes at all, the honest output when the user's device settings are
    unknown and they would rather see the raw lane number.
    """
    if spec == "none":
        return None
    kind, _, rest = spec.partition(":")
    if kind == "chromatic":
        return DrumMap.chromatic(_int(rest, "chromatic low note")) if rest else DrumMap.chromatic()
    if kind == "custom":
        return DrumMap.custom([_int(part, "custom note") for part in rest.split(",")])
    raise ValueError(f"unknown drum map {spec!r}; expected chromatic:N, custom:a,b,c or none")


def _int(text: str, what: str) -> int:
    try:
        return int(text.strip())
    except ValueError:
        raise ValueError(f"{what} {text.strip()!r} is not a number") from None


def resolve_drum_map(spec: str | None, config_path: Path | None = None) -> DrumMap | None:
    """Pick the drum map: the flag wins, then the config file, then the default.

    *config_path* is passed in rather than read from this module so a test can
    point it somewhere harmless instead of depending on the machine's own
    config.
    """
    if spec is not None:
        return parse_drum_map(spec)
    path = CONFIG_PATH if config_path is None else config_path
    if path.is_file():
        return DrumMap.from_dict(json.loads(path.read_text(encoding="utf-8")))
    return DrumMap.chromatic(DEFAULT_CHROMATIC_LOW)


def resolve_drum_map_arg(spec: str | None, config_path: Path | None) -> DrumMap | None:
    """:func:`resolve_drum_map`, reporting failures as a :class:`UsageError`."""
    shown = CONFIG_PATH if config_path is None else config_path
    try:
        return resolve_drum_map(spec, config_path)
    except json.JSONDecodeError as exc:  # a ValueError, so it must come first
        raise UsageError(f"drum map: {shown}: {exc}") from exc
    except (OSError, ValueError) as exc:
        raise UsageError(f"drum map: {exc}") from exc


def load_project(path: Path) -> Project:
    """Read a project, reporting failures as a :class:`DataError`."""
    try:
        return load(path)
    except OSError as exc:
        raise DataError(str(exc)) from exc
    except ValueError as exc:
        raise DataError(f"{path}: {exc}") from exc


def select(project: Project, args: Namespace) -> Project:
    """Narrow *project* by the shared ``--track`` / ``--pattern`` flags."""
    return project.select(track=args.track, pattern=args.pattern)
