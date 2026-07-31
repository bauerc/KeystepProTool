"""How stored integers turn into displayed values.

The decode direction only; M5 adds ``encode_*`` beside each function here.
Where an encoding is not yet measured this module returns ``None`` rather than
interpolating -- a wrong timing table produces files that load cleanly and play
wrong, which is the worst failure mode available because nothing errors.
"""

from typing import Final

#: Tempo is a 21-bit little-endian value in 7-bit chunks holding BPM x 100.
#: 96 + 93*128 = 12000 -> 120.00 BPM; 16 + 103*128 = 13200 -> 132.00 BPM.
TEMPO_CHUNK: Final = 128
TEMPO_SCALE: Final = 100

#: Swing is stored with a +25 offset: stored 25 is 50% (no swing). Spec 3.3.
SWING_OFFSET: Final = 25

#: Step counts are 0-based: stored 15 means a 16-step pattern.
STEP_COUNT_OFFSET: Final = 1

#: Time shift is an offset around a centre of 49, so stored 50 is +1. Confirmed
#: by the +-4 ramp in project_5.
TIME_SHIFT_CENTRE: Final = 49

#: Displayed range of time shift. Unmeasured -- project_5's ramp reaches +-4 and
#: nothing establishes that as the limit. Protocol T7.1.
TIME_SHIFT_RANGE: Final[tuple[int, int] | None] = None

#: What one unit of time shift is worth as a fraction of a step. Unmeasured: it
#: may instead be a fixed tick count or an absolute time, which needs a
#: recording of the device's MIDI output to tell apart. See
#: analysis/Timing_Calibration.md.
TIME_SHIFT_UNIT: Final[float | None] = None

#: Step skip is a 4-bit mask over the four 16-step sequences a pattern runs as.
#: 15 (all four) is the default. Spec 5.
SKIP_SEQUENCES: Final = (16, 32, 48, 64)

#: Gate length is non-linear and only partly measured. These six points are
#: hardware-confirmed; everything else is unknown and this module refuses to
#: interpolate. Resolving the rest is M7. Spec 6.1.
GATE_TABLE: Final[dict[int, float]] = {7: 0.5, 11: 1.0, 19: 2.0, 27: 3.0, 29: 3.5, 31: 4.0}

#: A freshly placed note stores gate 7, i.e. half a step. The fallback wherever
#: an encoding is not in GATE_TABLE: the device's own default is the one length
#: we can use without inventing one.
DEFAULT_GATE_STORED: Final = 7
DEFAULT_GATE_LENGTH: Final = GATE_TABLE[DEFAULT_GATE_STORED]

_NOTE_NAMES: Final = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")


def decode_gate(stored: int) -> float | None:
    """Displayed gate length in steps, or ``None`` if not yet measured."""
    return GATE_TABLE.get(stored)


def decode_swing(stored: int) -> int:
    """Swing percentage from its +25 offset."""
    return stored + SWING_OFFSET


def decode_step_count(stored: int) -> int:
    """Step count from its 0-based storage."""
    return stored + STEP_COUNT_OFFSET


def decode_time_shift(stored: int) -> int:
    """Signed time shift, offset from the stored centre."""
    return stored - TIME_SHIFT_CENTRE


def decode_tempo(lsb: int, midsb: int, msb: int) -> float:
    """Reassemble BPM from three little-endian 7-bit chunks."""
    return (lsb + midsb * TEMPO_CHUNK + msb * TEMPO_CHUNK**2) / TEMPO_SCALE


def time_shift_fraction(shift: int) -> float | None:
    """*shift* as a fraction of a step, or ``None`` while unmeasured."""
    if TIME_SHIFT_UNIT is None:
        return None
    return shift * TIME_SHIFT_UNIT


def decode_skip_mask(mask: int) -> tuple[int, ...]:
    """The 16/32/48/64 sequences a note plays in: 15 -> all four, 5 -> (16, 48)."""
    return tuple(seq for bit, seq in enumerate(SKIP_SEQUENCES) if mask & (1 << bit))


def note_name(pitch: int) -> str:
    """Render a MIDI pitch as the hardware labels it: 48 -> ``C2``."""
    # The KeyStep Pro displays middle C (60) as C3, confirmed by project_5
    # (pitch 48 = C2) and project_9 (pitch 60 = C3).
    return f"{_NOTE_NAMES[pitch % 12]}{pitch // 12 - 2}"
