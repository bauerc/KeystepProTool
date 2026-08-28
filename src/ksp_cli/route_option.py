"""The ``--route`` grammar for ``midi2ksp``: ``source:device`` pairs, comma-separated."""

from ksp.midi_import import TrackRoute
from ksp_cli.pair_number import pair_int

ROUTE_HELP = (
    "send named source tracks to named device tracks: source:device pairs, comma-separated "
    "(e.g. 3:1,1:2), both counting from 1. Tracks no pair names fill whatever is left, in "
    "source order as usual. Only KeyStep Pro track 1 carries a drum set, so a --drum-track may "
    "only be routed there and nothing else may be routed onto it. A route may only name a source "
    "track --midi-tracks reads. Not usable with --midi-track"
)


def resolve_routes(single: int | None, text: str | None) -> tuple[TrackRoute, ...]:
    """The routes *text* names, in the order it names them.
    Empty is how :class:`ImportOptions` spells "assign as before"."""
    if single is not None and text is not None:
        raise ValueError(
            "--midi-track and --route contradict each other; --midi-track converts one source "
            "track into the one pattern the target names, and a route says which device track a "
            "source track fills"
        )
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
