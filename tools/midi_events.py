"""Print a ``.mid`` file as one canonical line per event, for diffing.

``scripts/midi_parity.sh`` compares the two ports' MIDI output through this
rather than with ``cmp``, and the reason is not ours: ``mido`` emits MIDI
running status where ``swift-midi-file``'s encoder does not (its
``Track+Encoding.swift`` carries a ``TODO`` saying so). Consecutive note-ons on
one channel are ubiquitous, so the two writers disagree on the bytes of almost
every file while agreeing on every event in it. The issue anticipated this and
asked for the comparison to move up a level and the reason to be written down.

Everything a reader can observe is printed: the header, then each track's
events with **absolute** ticks, so an inserted event shows up as one added line
instead of shifting every line after it.
"""

import sys
from pathlib import Path

import mido

#: Message attributes worth printing, in a fixed order so two files line up.
FIELDS = (
    "channel",
    "note",
    "velocity",
    "program",
    "control",
    "value",
    "tempo",
    "numerator",
    "denominator",
    "clocks_per_click",
    "notated_32nd_notes_per_beat",
    "name",
    "text",
    "key",
)


def render(midi: mido.MidiFile) -> list[str]:
    """*midi* as comparable lines: the header, then every track's events."""
    lines = [f"format {midi.type} ticks_per_beat {midi.ticks_per_beat} tracks {len(midi.tracks)}"]
    for index, track in enumerate(midi.tracks):
        lines.append(f"track {index}")
        tick = 0
        for message in track:
            tick += message.time
            fields = " ".join(
                f"{name}={getattr(message, name)!r}" for name in FIELDS if hasattr(message, name)
            )
            lines.append(f"  {tick:>8} {message.type} {fields}".rstrip())
    return lines


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else list(argv)
    if len(args) != 1:
        print("usage: midi_events.py FILE.mid", file=sys.stderr)
        return 2
    try:
        midi = mido.MidiFile(Path(args[0]))
    except (OSError, EOFError, ValueError, IndexError) as exc:
        print(f"midi_events: {args[0]}: {exc}", file=sys.stderr)
        return 1
    print("\n".join(render(midi)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
