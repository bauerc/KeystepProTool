"""Reading MIDI Control Center's non-standard JSON dialect.

MCC parses its own files with Boost.PropertyTree, which tolerates a trailing
comma before a closing brace. ``json.loads`` does not, so every
``.KeyStepPro`` file in existence fails strict parsing. See
``analysis/KeyStepPro_Format_Spec.md`` section 2.

Only reading lives here. Writing is deliberately absent: M3 is the milestone
that has to reproduce MCC's bytes exactly (tabs, the trailing comma, no final
newline), and a dumper written before there is a byte-identity test to hold it
honest is a dumper nobody can trust.
"""

import json
import re
from pathlib import Path
from typing import Any

# Matches a comma that is followed only by whitespace and a closing bracket.
# Anchoring on the bracket is what keeps it from touching commas inside string
# values -- MCC writes none, but the project files are large enough that a
# looser pattern would be hard to audit.
_TRAILING_COMMA = re.compile(r",(\s*[}\]])")


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
