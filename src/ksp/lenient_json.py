"""Reading and writing MIDI Control Center's non-standard JSON dialect.

MCC parses its own files with Boost.PropertyTree, which tolerates a trailing
comma before a closing brace. ``json.loads`` does not, so every
``.KeyStepPro`` file in existence fails strict parsing. See
``analysis/KeyStepPro_Format_Spec.md`` section 2.

The writer reproduces MCC's bytes -- tab indentation, no final newline, MCC's
key order -- with one deliberate exception: it omits the trailing comma, so its
output is strict JSON. Protocol test T6.2 established that MCC does not need
it; a file differing from a known-good export by that one byte loaded in MCC
and transferred to the device. Nothing else about the dialect is optional,
because nothing else has been tested.

``tests/test_round_trip.py`` holds the writer to MCC's bytes (minus that comma)
against all five sample projects, which is the whole of milestone M3 -- M4 puts
a written file on the hardware and M5 generates one from MIDI, and neither is
trustworthy if the bytes drift.
"""

import json
import os
import re
import tempfile
from collections.abc import Mapping
from json.encoder import encode_basestring_ascii as _escape
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

# A tuple, not ``int | str``: the union form rebuilds a UnionType per call.
_INT_OR_STR = (int, str)


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


def dumps(obj: Mapping[str, int | str]) -> str:
    """Serialise *obj* in MCC's dialect, in the mapping's own iteration order.

    Order is preserved rather than sorted so this stays a faithful dumper and
    the round-trip test proves something; putting keys in MCC's order is
    :func:`canonical`'s job, chosen explicitly by the caller.

    Raises:
        TypeError: for a value that is not an ``int`` or a ``str``. A float
            would serialise as ``1.0`` and a bool as ``true``, neither of
            which the firmware has ever been shown.
    """
    lines = []
    for k, v in obj.items():
        # ``_escape`` is what ``json.dumps`` reaches for anyway, minus the
        # encoder set-up. Keys keep it: one holding a quote would break.
        if v.__class__ is int:
            value = repr(v)
        elif isinstance(v, str):
            value = _escape(v)
        elif isinstance(v, bool) or not isinstance(v, _INT_OR_STR):
            raise TypeError(f"{k} holds {type(v).__name__}, expected int or str")
        else:
            value = json.dumps(v)  # an int subclass may override __repr__
        lines.append(f"\t{_escape(k)}: {value}")

    return "{\n" + ",\n".join(lines) + ("\n}" if lines else "}")


def dump_path(obj: Mapping[str, int | str], path: Path | str) -> None:
    """Write *obj* to *path* as MCC would.

    Bytes rather than text, so no platform translates ``\\n`` into ``\\r\\n``
    or appends a final newline. The write goes to a temp file alongside the
    destination and is then renamed into place: these files are 3.5 MB and
    their destination is often MCC's Templates folder, where a half-written
    one would be found and parsed.

    ``mkstemp`` creates its file 0600, which is not what writing a file
    normally gives you and not what MCC should find, so the mode is set to the
    usual 0644 as the umask allows.
    """
    path = Path(path)
    data = dumps(obj).encode("utf-8")

    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name, suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        umask = os.umask(0)
        os.umask(umask)
        os.chmod(tmp, 0o666 & ~umask)
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
