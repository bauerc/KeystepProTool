"""The ``--segment-bars`` grammar for ``midi2ksp``: ``source:bar`` pairs, comma-separated."""

from ksp.midi_import import TrackSegments

#: The largest number a pair may spell. Python's ints are unbounded and Swift's
#: are not, so an oversized numeral is refused by the grammar.
_MAX_NUMBER = 2**31 - 1

SEGMENT_BARS_HELP = (
    "break named source tracks into patterns at named bars: source:bar pairs, comma-separated "
    "(e.g. 2:5,2:9,3:3), both counting from 1. Bar 1 begins the first pattern, so it is never a "
    "boundary, and a track's bars must ascend. Tracks no pair names are still cut at the "
    "device's 64 steps as before. Not usable with --midi-track"
)


def resolve_segments(single: int | None, spec: str | None) -> tuple[TrackSegments, ...]:
    """The segmentation *spec* names, gathered one entry per source track.
    Empty is how :class:`ImportOptions` spells "the automatic split, as before"."""
    if single is not None and spec is not None:
        raise ValueError(
            "--midi-track and --segment-bars contradict each other; --midi-track converts one "
            "source track into the one pattern the target names, and a segmentation cuts a "
            "track across several"
        )
    if spec is None:
        return ()
    # Ordered by the track's first mention, not by number: the summary and the
    # refusals read in the order the pairs were written.
    gathered: dict[int, list[int]] = {}
    for item in spec.split(","):
        item = item.strip()
        source, sep, bar = item.partition(":")
        if not sep or ":" in bar:
            raise ValueError(f"--segment-bars: '{item}' is not a source:bar pair")
        gathered.setdefault(_int(source, item), []).append(_int(bar, item))
    return tuple(TrackSegments(source, tuple(bars)) for source, bars in gathered.items())


def _int(text: str, item: str) -> int:
    # Spelled out rather than left to ``int``, which also takes underscores and
    # non-ASCII digits: both cores must refuse exactly the same input.
    body = text.strip()
    digits = body[1:] if body[:1] in ("+", "-") else body
    if not (digits.isascii() and digits.isdigit()):
        raise ValueError(f"--segment-bars: '{item}' is not a source:bar pair")
    # Counted before converting: past 4300 digits ``int`` raises its own message
    # about sys.set_int_max_str_digits, which is not something to show a user.
    too_long = len(digits.lstrip("0")) > len(str(_MAX_NUMBER))
    if too_long or abs(int(body)) > _MAX_NUMBER:
        raise ValueError(f"--segment-bars: '{item}' names a number too large to be one")
    return int(body)
