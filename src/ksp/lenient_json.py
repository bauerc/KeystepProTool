"""Reading and writing MIDI Control Center's non-standard JSON dialect.

The read side tolerates MCC's trailing comma; the write side omits it, which is
the only part of the dialect shown to be optional. The full byte-level rules are
in spec section 2.
"""

import os
import re
import tempfile
from collections.abc import Mapping
from json.encoder import encode_basestring_ascii as _escape
from pathlib import Path
from typing import Any

import orjson

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


def strip_trailing_comma_fast(data: bytes) -> bytes:
    """Remove MCC's trailing comma, scanning back from the end.

    The comma sits just before the final ``}``, so searching backwards avoids
    walking the 3.5 MB body.
    """
    closing_brace = data.rfind(b"}")
    if closing_brace == -1:
        return data

    comma_pos = data.rfind(b",", 0, closing_brace)
    if comma_pos == -1:
        return data

    between = data[comma_pos + 1 : closing_brace]
    if between.strip() == b"":
        return data[:comma_pos] + data[comma_pos + 1 :]

    return data


def loads(text_or_bytes: str | bytes) -> dict[str, Any]:
    """Parse MCC's JSON dialect from a string or bytes using orjson."""
    data = text_or_bytes.encode("utf-8") if isinstance(text_or_bytes, str) else text_or_bytes

    cleaned_data = strip_trailing_comma_fast(data)
    parsed = orjson.loads(cleaned_data)

    if not isinstance(parsed, dict):
        raise ValueError(f"expected a JSON object, got {type(parsed).__name__}")

    return parsed


def load_path(path: Path | str) -> dict[str, Any]:
    """Parse a ``.KeyStepPro`` file from disk as raw bytes."""
    data = Path(path).read_bytes()
    return loads(data)


def dumps(obj: Mapping[str, int | str]) -> str:
    """Serialise *obj* in MCC's dialect, in the mapping's own iteration order.

    Ordering is :func:`canonical`'s job, so this stays a faithful dumper.
    Rejects anything but ``int`` and ``str``: a float would serialise as
    ``1.0`` and a bool as ``true``, neither of which the firmware accepts.
    """
    _escape_fn = _escape
    lines: list[str] = []
    append = lines.append

    for k, v in obj.items():
        if isinstance(v, bool) or not isinstance(v, _INT_OR_STR):
            raise TypeError(f"{k} holds {type(v).__name__}, expected int or str")
        elif isinstance(v, int):
            append(f"\t{_escape_fn(k)}: {v}")
        else:
            append(f"\t{_escape_fn(k)}: {_escape_fn(v)}")

    return "{\n" + ",\n".join(lines) + ("\n}" if lines else "}")


def dump_path(obj: Mapping[str, int | str], path: Path | str) -> None:
    """Write *obj* to *path* as MCC would.

    Bytes rather than text, so no platform rewrites the line endings or appends
    a final newline (spec section 2). Written to a temp file and renamed into
    place: the destination is often MCC's Templates folder, where a half-written
    3.5 MB file would be found and parsed. ``mkstemp`` creates 0600, so the mode
    is widened to the usual 0644 as the umask allows.
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
    numeric keys sorted **as strings** -- ``126_99_16`` before ``126_99_2``
    (spec section 2).

    A converter starting from ``Default.KeyStepPro`` has to add the ``version``
    key it lacks, and a plain assignment would leave it last.
    """
    leading_dict = {k: obj[k] for k in LEADING_KEYS if k in obj}
    leading_set = set(leading_dict)
    rest_keys = sorted(k for k in obj if k not in leading_set)

    return leading_dict | {k: obj[k] for k in rest_keys}
