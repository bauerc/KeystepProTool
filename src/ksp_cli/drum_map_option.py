"""Shared ``--drum-map`` handling for ``ksp-dump`` and ``ksp2midi``.

Both commands have to answer the same question -- which lane plays which MIDI
note -- and the answer is a device global the project file does not carry. One
grammar and one config file, so a user who sets it up once is understood by
both.
"""

import json
from pathlib import Path

from ksp.drum_map import DEFAULT_CHROMATIC_LOW, DrumMap

#: Where a user's own drum map lives, if they have one. Path resolution stays
#: in the CLI: ``ksp`` must not decide where files are.
CONFIG_PATH = Path.home() / ".config" / "keysteppro" / "drum_map.json"

DRUM_MAP_HELP = (
    "lane -> note mapping: chromatic:N, custom:a,b,c (24 notes) or none. "
    "The device's drum map is a global setting and is not in the project file, "
    f"so this defaults to chromatic:{DEFAULT_CHROMATIC_LOW}"
)


def parse_drum_map(spec: str) -> DrumMap | None:
    """Parse a ``--drum-map`` argument.

    ``chromatic:36`` | ``custom:36,38,42,...`` | ``none``. ``None`` means do
    not resolve lanes at all, which is the honest output when the user's device
    settings are unknown and they would rather see the raw lane number.
    """
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

    *config_path* is passed in by the caller rather than read from this module,
    so a test can point it somewhere harmless instead of depending on whether
    the machine running the suite happens to have a personal config.
    """
    if spec is not None:
        return parse_drum_map(spec)
    path = CONFIG_PATH if config_path is None else config_path
    if path.is_file():
        return DrumMap.from_dict(json.loads(path.read_text(encoding="utf-8")))
    return DrumMap.chromatic(DEFAULT_CHROMATIC_LOW)


def resolve_import_drum_map(spec: str | None, config_path: Path | None = None) -> DrumMap | None:
    """The same choice for ``midi2ksp``, where unset means *fit to the source*.

    Reading a lane back can fall through to the factory default and print what
    it assumed. Writing one cannot: a source whose drums sit anywhere but
    36-59 would have every hit dropped as unmapped. So an unconfigured import
    fits a map to the pitches it was given, and says so.

    ``none`` is refused rather than accepted, because a drum note stores a lane
    and there is no lane without a map.
    """
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
