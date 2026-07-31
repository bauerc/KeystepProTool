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
