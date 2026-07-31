"""Which parameter IDs carry a note, per parameter set.

Track 1 holds a melodic and a drum set side by side with the same shape but
different IDs. Keeping that correspondence as a table rather than a branch
means the M5 writer addresses the same parameters the reader does instead of
re-deriving the mapping.
"""

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Final

from ksp import constants
from ksp.types import NoteKind, ParamId


@dataclass(frozen=True)
class NoteParamSet:
    """The parameter IDs of one note set, plus how its step-skip is indexed."""

    kind: NoteKind
    note_step: ParamId
    pitch: ParamId
    gate: ParamId
    velocity: ParamId
    time_shift: ParamId
    randomness: ParamId
    skip: ParamId

    #: Melodic step skip (49) is step-indexed; the drum equivalent (53) is
    #: note-indexed. Not a typo -- it is what the files consistently show.
    skip_is_note_indexed: bool

    #: Per-pattern scalars belonging to this set.
    step_count: ParamId
    swing: ParamId


SEQ_PARAMS: Final = NoteParamSet(
    kind=NoteKind.SEQ,
    note_step=constants.P_SEQ_NOTE_STEP,
    pitch=constants.P_SEQ_PITCH,
    gate=constants.P_SEQ_GATE,
    velocity=constants.P_SEQ_VELOCITY,
    time_shift=constants.P_SEQ_TIME_SHIFT,
    randomness=constants.P_SEQ_RANDOMNESS,
    skip=constants.P_SEQ_STEP_SKIP,
    skip_is_note_indexed=False,
    step_count=constants.P_SEQ_STEP_COUNT,
    swing=constants.P_SEQ_SWING,
)

DRUM_PARAMS: Final = NoteParamSet(
    kind=NoteKind.DRUM,
    note_step=constants.P_DRUM_NOTE_STEP,
    pitch=constants.P_DRUM_PITCH,
    gate=constants.P_DRUM_GATE,
    velocity=constants.P_DRUM_VELOCITY,
    time_shift=constants.P_DRUM_TIME_SHIFT,
    randomness=constants.P_DRUM_RANDOMNESS,
    skip=constants.P_DRUM_STEP_SKIP,
    skip_is_note_indexed=True,
    step_count=constants.P_DRUM_STEP_COUNT,
    swing=constants.P_DRUM_SWING,
)

NOTE_PARAMS: Final[Mapping[NoteKind, NoteParamSet]] = {
    NoteKind.SEQ: SEQ_PARAMS,
    NoteKind.DRUM: DRUM_PARAMS,
}
