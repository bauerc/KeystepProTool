"""Reading and writing MIDI Control Center's non-standard JSON dialect.

MCC parses its own files with Boost.PropertyTree, which tolerates a trailing
comma before a closing brace. ``json.loads`` does not, so every
``.KeyStepPro`` file in existence fails strict parsing. See
``analysis/KeyStepPro_Format_Spec.md`` section 2.

The writer reproduces MCC's bytes exactly rather than merely producing valid
JSON: tab indentation, the trailing comma, no final newline, and MCC's key
order. ``tests/test_round_trip.py`` holds it to that against all five sample
projects, which is the whole of milestone M3 -- M4 puts a written file on the
hardware and M5 generates one from MIDI, and neither is trustworthy if the
bytes drift.
"""

import json
import os
import re
import tempfile
from collections.abc import Mapping
from pathlib import Path
from typing import Any

# Matches a comma that is followed only by whitespace and a closing bracket.
# Anchoring on the bracket is what keeps it from touching commas inside string
# values -- MCC writes none, but the project files are large enough that a
# looser pattern would be hard to audit.
_TRAILING_COMMA = re.compile(r",(\s*[}\]])")

#: The two string-valued keys, in the order MCC writes them, ahead of every
#: numeric key. Everything else in the file is an integer parameter -- even
#: project names, which are stored as character codes.
LEADING_KEYS = ("device", "version")


def strip_trailing_commas(text: str) -> str:
    """Return *text* with trailing commas removed, making it strict JSON."""
    return _TRAILING_COMMA.sub(r"\1", text)


def loads(text: str) -> dict[str, Any]:
    """Parse MCC's JSON dialect from a string.

    Raises:
        ValueError: if the text does not parse, or parses to something other
            than an object. A ``.KeyStepPro`` file is always a flat object;
            anything else means the caller was handed the wrong file.
    """
    parsed = json.loads(strip_trailing_commas(text))
    if not isinstance(parsed, dict):
        raise ValueError(f"expected a JSON object, got {type(parsed).__name__}")
    return parsed


def load_path(path: Path | str) -> dict[str, Any]:
    """Parse a ``.KeyStepPro`` file from disk.

    Decoding uses ``errors="replace"``. These files are ASCII in practice, but
    they are hardware exports: refusing to open one because of a stray byte in
    a project name would be a poor trade when every key we care about is
    numeric.
    """
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    return loads(text)


def dumps(obj: Mapping[str, int | str], *, trailing_comma: bool = True) -> str:
    """Serialise *obj* in MCC's dialect, in the mapping's own iteration order.

    Order is preserved rather than sorted so this stays a faithful dumper and
    the round-trip test proves something; putting keys in MCC's order is
    :func:`canonical`'s job, chosen explicitly by the caller.

    ``trailing_comma=False`` produces strict JSON -- the candidate file for
    protocol test T6.2, which asks whether MCC requires the comma at all.

    Raises:
        TypeError: for a value that is not an ``int`` or a ``str``. A float
            would serialise as ``1.0`` and a bool as ``true``, neither of
            which the firmware has ever been shown.
    """
    parts = ["{\n"]
    for k, v in obj.items():
        if isinstance(v, bool) or not isinstance(v, int | str):
            raise TypeError(f"{k} holds {type(v).__name__}, expected int or str")
        parts.append(f"\t{json.dumps(k)}: {json.dumps(v)},\n")

    if not trailing_comma and len(parts) > 1:
        parts[-1] = parts[-1][:-2] + "\n"
    parts.append("}")
    return "".join(parts)


def dump_path(
    obj: Mapping[str, int | str], path: Path | str, *, trailing_comma: bool = True
) -> None:
    """Write *obj* to *path* as MCC would.

    Bytes rather than text, so no platform translates ``\\n`` into ``\\r\\n``
    or appends a final newline. The write goes to a temp file alongside the
    destination and is then renamed into place: these files are 3.5 MB and
    their destination is often MCC's Templates folder, where a half-written
    one would be found and parsed.
    """
    path = Path(path)
    data = dumps(obj, trailing_comma=trailing_comma).encode("utf-8")

    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name, suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def canonical(obj: Mapping[str, int | str]) -> dict[str, int | str]:
    """Return a new dict in MCC's key order: ``device``, ``version``, then the
    numeric keys sorted as strings.

    They sort as strings, not numbers -- ``126_99_16`` comes before
    ``126_99_2``.

    M5 is what needs this. ``Default.KeyStepPro`` has no ``version`` key, so a
    converter building on the factory template has to add one, and a plain
    assignment appends it at the end of the dict -- a key order no file MCC
    wrote has ever had.
    """
    leading = {k: obj[k] for k in LEADING_KEYS if k in obj}
    rest = sorted(k for k in obj if k not in leading)
    return leading | {k: obj[k] for k in rest}
