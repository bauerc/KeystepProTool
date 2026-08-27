"""The ``--segment-bars`` grammar for ``midi2ksp``: ``source:bar`` pairs, comma-separated."""

from ksp.midi_import import TrackSegments
from ksp_cli.pair_number import pair_int

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
        malformed = f"--segment-bars: '{item}' is not a source:bar pair"
        oversized = f"--segment-bars: '{item}' names a number too large to be one"
        source, sep, bar = item.partition(":")
        if not sep or ":" in bar:
            raise ValueError(malformed)
        track = pair_int(source, malformed=malformed, oversized=oversized)
        gathered.setdefault(track, []).append(
            pair_int(bar, malformed=malformed, oversized=oversized)
        )
    return tuple(TrackSegments(source, tuple(bars)) for source, bars in gathered.items())
