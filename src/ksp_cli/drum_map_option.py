"""Shared ``--drum-map`` handling for ``ksp-dump`` and ``ksp2midi``: one grammar, one config."""

import json
from pathlib import Path

from ksp.drum_map import DEFAULT_CHROMATIC_LOW, DrumMap
from ksp_cli.reporting import fail

#: Where a user's own drum map lives, if they have one.
CONFIG_PATH = Path.home() / ".config" / "keysteppro" / "drum_map.json"

DRUM_MAP_HELP = (
    "lane -> note mapping: chromatic:N, custom:a,b,c (24 notes) or none. "
    "The device's drum map is a global setting and is not in the project file, "
    f"so this defaults to chromatic:{DEFAULT_CHROMATIC_LOW}"
)


def parse_drum_map(spec: str) -> DrumMap | None:
    """Parse a ``chromatic:36`` | ``custom:36,38,...`` | ``none`` argument.
    ``None`` means do not resolve lanes at all, leaving the raw lane number."""
    if spec == "none":
        return None
    kind, _, rest = spec.partition(":")
    if kind == "chromatic":
        if not rest:
            return DrumMap.chromatic()
        return DrumMap.chromatic(_int(rest, "chromatic low note"))
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
    *config_path* is passed in so a test can point it somewhere harmless."""
    if spec is not None:
        return parse_drum_map(spec)
    path = CONFIG_PATH if config_path is None else config_path
    if path.is_file():
        return DrumMap.from_dict(json.loads(path.read_text(encoding="utf-8")))
    return DrumMap.chromatic(DEFAULT_CHROMATIC_LOW)


def resolve_drum_map_or_fail(spec: str | None, config_path: Path, *, prog: str) -> DrumMap | None:
    """:func:`resolve_drum_map`, with a bad map reported as the usage error it is.
    *config_path* is named in the message when it, not the flag, is malformed."""
    try:
        return resolve_drum_map(spec, config_path)
    except json.JSONDecodeError as exc:  # a ValueError, so it must come first
        fail(f"drum map: {config_path}: {exc}", prog=prog, code=2)
    except (OSError, ValueError) as exc:
        fail(f"drum map: {exc}", prog=prog, code=2)


def resolve_import_drum_map(spec: str | None, config_path: Path | None = None) -> DrumMap | None:
    """The same choice for ``midi2ksp``, where unset means *fit to the source*.
    ``none`` is refused: a drum note stores a lane, and there is no lane without a map."""
    if spec == "none":
        raise ValueError(
            "a drum note stores a lane, not a pitch, so importing drums needs a map; "
            "use chromatic:N or custom:a,b,c, or leave --drum-map off to fit one"
        )
    if spec is not None:
        return parse_drum_map(spec)
    path = CONFIG_PATH if config_path is None else config_path
    if path.is_file():
        return DrumMap.from_dict(json.loads(path.read_text(encoding="utf-8")))
    return None


def default_drum_map(config_path: Path, *, prog: str) -> DrumMap:
    """The map an export uses with no ``--drum-map``, for a command that has no such flag."""
    resolved = resolve_drum_map_or_fail(None, config_path, prog=prog)
    if resolved is None:  # pragma: no cover - only the literal "none" resolves to None
        fail("drum map: a MIDI file has to name a note for every drum lane", prog=prog, code=2)
    return resolved
