"""The ``--route`` grammar for ``midi2ksp``.

A comma-separated list of ``source:device`` pairs, which
:class:`ksp.midi_import.ImportOptions` already takes as an ordered sequence.
Parsing lives here rather than in the option declaration so both cores refuse
the same input with the same words: Typer's own conversion and ArgumentParser's
word their messages quite differently, and the two CLIs' output is a
byte-for-byte contract.

Only the grammar is checked here. Range, duplicate and drum clashes belong to
``ImportOptions``, which words them once for the CLI, the app and the library.
"""

from ksp.midi_import import TrackRoute

#: The largest track number a pair may spell. Python's ints are unbounded and
#: Swift's are not, so an oversized numeral is refused by the grammar rather
#: than reaching a range message that would have to print it.
_MAX_TRACK = 2**31 - 1

ROUTE_HELP = (
    "send named source tracks to named device tracks: source:device pairs, comma-separated "
    "(e.g. 3:1,1:2), both counting from 1. Tracks no pair names fill whatever is left, in "
    "source order as usual. Only KeyStep Pro track 1 carries a drum set, so a --drum-track may "
    "only be routed there and nothing else may be routed onto it. Not usable with --midi-track"
)


def parse_routes(text: str | None) -> tuple[TrackRoute, ...]:
    """Parse *text* into the routes it names, in the order it names them.

    ``None`` gives the empty tuple, which is how :class:`ImportOptions` already
    spells "assign as before".
    """
    if text is None:
        return ()
    routes = []
    for item in text.split(","):
        item = item.strip()
        source, sep, device = item.partition(":")
        if not sep or ":" in device:
            raise ValueError(f"--route: '{item}' is not a source:device pair")
        routes.append(TrackRoute(_int(source, item), _int(device, item)))
    return tuple(routes)


def _int(text: str, item: str) -> int:
    # Spelled out rather than left to ``int``, which also takes underscores and
    # non-ASCII digits. Swift's ``Int`` takes neither, and the two cores have to
    # refuse the same input.
    body = text.strip()
    digits = body[1:] if body[:1] in ("+", "-") else body
    if not (digits.isascii() and digits.isdigit()):
        raise ValueError(f"--route: '{item}' is not a source:device pair")
    # Counted before converting: past 4300 digits ``int`` raises its own message about
    # sys.set_int_max_str_digits, which is not something to show a user, and is not what
    # Swift's failed parse says.
    too_long = len(digits.lstrip("0")) > len(str(_MAX_TRACK))
    if too_long or abs(int(body)) > _MAX_TRACK:
        raise ValueError(f"--route: '{item}' names a track number too large to be one")
    return int(body)
