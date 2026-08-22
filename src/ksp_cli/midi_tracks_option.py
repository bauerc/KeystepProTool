"""The ``--midi-tracks`` grammar for ``midi2ksp``: which source tracks to read."""

from ksp_cli.selection import SELECTION_HELP, parse_selection

# A Standard MIDI File counts its tracks in 16 bits, and parse_selection walks
# every number of a range, so this is both the real cap and a cheap one.
_MAX_MIDI_TRACKS = 65535

MIDI_TRACKS_HELP = (
    "read only these tracks of the source file, counting from 1 over every track of the file, "
    f"including ones that carry only tempo or a name: {SELECTION_HELP}. Not usable with "
    "--midi-track or --route"
)


def resolve_midi_tracks(single: int | None, listed: str | None) -> frozenset[int]:
    """The source tracks the two spellings name between them.
    Empty is how :class:`ImportOptions` spells "all of them"."""
    if single is not None and listed is not None:
        raise ValueError(
            "--midi-track and --midi-tracks contradict each other; --midi-track converts one "
            "source track into the one pattern the target names, and --midi-tracks reads a "
            "selection as a song"
        )
    if single is not None:
        # Range is ImportOptions' refusal to word, as it was before --midi-tracks existed.
        return frozenset({single})
    return parse_selection(listed, option="--midi-tracks", limit=_MAX_MIDI_TRACKS)
