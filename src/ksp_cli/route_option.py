"""The ``--route`` grammar for ``midi2ksp``: ``source:device`` pairs, comma-separated."""

from ksp.midi_import import TrackRoute
from ksp_cli.pair_number import pair_int

ROUTE_HELP = (
    "send named source tracks to named device tracks: source:device pairs, comma-separated "
    "(e.g. 3:1,1:2), both counting from 1. Tracks no pair names fill whatever is left, in "
    "source order as usual. Only KeyStep Pro track 1 carries a drum set, so a --drum-track may "
    "only be routed there and nothing else may be routed onto it. Not usable with --midi-track "
    "or --midi-tracks"
)


def parse_routes(text: str | None) -> tuple[TrackRoute, ...]:
    """Parse *text* into the routes it names, in the order it names them.
    ``None`` gives the empty tuple, which is how :class:`ImportOptions` spells "as before"."""
    if text is None:
        return ()
    routes = []
    for item in text.split(","):
        item = item.strip()
        malformed = f"--route: '{item}' is not a source:device pair"
        oversized = f"--route: '{item}' names a track number too large to be one"
        source, sep, device = item.partition(":")
        if not sep or ":" in device:
            raise ValueError(malformed)
        routes.append(
            TrackRoute(
                pair_int(source, malformed=malformed, oversized=oversized),
                pair_int(device, malformed=malformed, oversized=oversized),
            )
        )
    return tuple(routes)
