"""Distinct integer types for the values this format makes easy to confuse.

All of these are plain ``int`` at runtime. They exist so mypy rejects the two
mixups the spec warns about: a drum lane used as a MIDI pitch (spec 3.2.1) and
a physical step used as a note-list ordinal (spec 4).
"""

from enum import StrEnum
from typing import NewType

ItemId = NewType("ItemId", int)
ParamId = NewType("ParamId", int)

#: 0-23 drum lane, the *value* of parameter 117. Not a pitch.
Lane = NewType("Lane", int)

#: 0-127 MIDI note.
Pitch = NewType("Pitch", int)

#: Physical step, 1-based. Indexes parameters 48/49.
Step = NewType("Step", int)

#: Ordinal in a slot's compact note list, 1-based. Indexes 50/54 and 109-113 /
#: 117-121. The other of the two index spaces.
NoteIndex = NewType("NoteIndex", int)


class NoteKind(StrEnum):
    """Which parameter set a note came from.

    Track 1 carries both, and they mean different things: a SEQ note's value is
    a pitch, a DRUM note's is a lane.
    """

    SEQ = "seq"
    DRUM = "drum"


class PatternMode(StrEnum):
    """Which parameter set(s) of a pattern hold notes.

    ``BOTH`` is not a hardware mode -- the device plays one or the other. It
    means both sets hold notes and the reader is reporting everything rather
    than guessing which is live.
    """

    SEQ = "seq"
    DRUM = "drum"
    BOTH = "both"
    EMPTY = "empty"
