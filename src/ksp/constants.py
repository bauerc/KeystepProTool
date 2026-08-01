"""Item IDs, parameter IDs and encodings from the KeyStep Pro format spec.

Every constant here traces to a table in ``analysis/KeyStepPro_Format_Spec.md``.
Nothing is inferred or invented -- where the encoding is not yet known (time
shift range and unit) this module says so rather than guessing.
"""

from typing import Final

#: "Empty" marker in note-indexed arrays. Also a legal pitch and a legal
#: velocity, which is why note existence is tested on the note->step parameter
#: alone and never on velocity. Spec section 4.
SENTINEL: Final = 127

# --- Item IDs (spec section 2) ---------------------------------------------

ITEM_PROJECT: Final = 120
ITEM_SCENES: Final = 121
ITEM_CONTROL_TRACK: Final = 122

#: Sequencer tracks 1-4. Track 1 (item 123) carries a full drum parameter set
#: in addition to the melodic one.
TRACK_ITEM_IDS: Final = (123, 124, 125, 126)
DRUM_TRACK_ITEM_ID: Final = 123

PATTERNS_PER_TRACK: Final = 16
MAX_STEPS: Final = 64

#: Pool chunks per track -- *not* polyphony voices. idx2 splits one flat note
#: pool into blocks of MAX_STEPS entries, so real capacity is 3 x 64 = 192
#: events per pattern, which the device enforces with an on-screen error
#: (capture D3). Chords live inside one chunk as consecutive ordinals sharing
#: a step (capture D2), so there is no 3- or 4-note ceiling. Track 1's fourth
#: chunk is zero-filled rather than sentinel-filled and stays untouched even
#: when a fourth chord voice is added, i.e. the firmware never uses it. See
#: ``reader.slot_is_initialised``.
SLOTS_BY_ITEM: Final = {123: 4, 124: 3, 125: 3, 126: 3}

#: Usable pool capacity, ignoring Track 1's phantom fourth chunk.
POOL_CAPACITY: Final = 3 * MAX_STEPS

# --- Project / global parameters (spec section 3.4) ------------------------

P_TEMPO_LSB: Final = 70
P_TEMPO_MIDSB: Final = 71
P_TEMPO_MSB: Final = 72
P_GLOBAL_SWING: Final = 74
P_CURRENT_SCENE: Final = 75

#: Tempo is a 21-bit little-endian value in 7-bit chunks, holding BPM x 100.
#: Confirmed: project_5 = 96 + 93*128 = 12000 -> 120.00 BPM; initial_project
#: = 16 + 103*128 = 13200 -> 132.00 BPM.
TEMPO_CHUNK: Final = 128
TEMPO_SCALE: Final = 100

# --- Per-pattern scalars (spec section 3.3), indexed by pattern 1-16 -------

P_PATTERN_DATA_STATE: Final = 40
P_SEQ_SWING: Final = 97
P_SEQ_STEP_COUNT: Final = 98
P_SEQ_PATTERN_BITS: Final = 99
P_MODE_BITS: Final = 100
P_ROOT_NOTE: Final = 107
P_SCALE: Final = 108
P_DRUM_SWING: Final = 114
P_DRUM_STEP_COUNT: Final = 115
P_DRUM_PATTERN_BITS: Final = 116

#: ``40`` is 3 where a pattern holds data and 2 where it does not. Observed
#: across all three sample projects, and it agrees with the note lists.
PATTERN_HAS_DATA: Final = 3

#: Swing is stored with a +25 offset: stored 25 is 50% (no swing), stored 50
#: is 75%. Spec section 3.3.
SWING_OFFSET: Final = 25

#: Step counts are 0-based: stored 15 means a 16-step pattern.
STEP_COUNT_OFFSET: Final = 1

# --- Melodic note parameters (spec section 3.1) ----------------------------
# 48 and 49 are indexed by step; 50 and 109-113 are indexed by note ordinal.
# Conflating the two index spaces is the classic way to misread this format.

P_SEQ_STEP_ACTIVE: Final = 48  # step-indexed
P_SEQ_STEP_SKIP: Final = 49  # step-indexed
P_SEQ_NOTE_STEP: Final = 50  # note-indexed, 0-based step
P_SEQ_PITCH: Final = 109
P_SEQ_GATE: Final = 110
P_SEQ_VELOCITY: Final = 111
P_SEQ_TIME_SHIFT: Final = 112
P_SEQ_RANDOMNESS: Final = 113

# --- Drum note parameters, item 123 only (spec section 3.2) ---------------

P_DRUM_POLY_STEP_COUNT: Final = 51
P_DRUM_STEP_ACTIVE: Final = 52  # flattened lane-major bit array, see below
P_DRUM_STEP_SKIP: Final = 53  # note-indexed, unlike the melodic 49
P_DRUM_NOTE_STEP: Final = 54  # note-indexed, 0-based step
P_DRUM_PITCH: Final = 117  # drum lane index, 0-based (0 = kick)
P_DRUM_GATE: Final = 118
P_DRUM_VELOCITY: Final = 119
P_DRUM_TIME_SHIFT: Final = 120
P_DRUM_RANDOMNESS: Final = 121

#: The device has 24 drum lanes. This is derived rather than assumed: MCC's
#: parameter dictionary defines exactly 24 "Note N" fields in its Drum Map
#: group (``globalParamId`` 83-106). No array in the project file has this
#: cardinality -- the lane is a *value* of parameter 117, never an index.
DRUM_LANE_COUNT: Final = 24

#: Per-track bitfield. Bit 6 is the Arp/Drum mode state, named as such by
#: MCC's dictionary ("Arp/Drum mode state : bit 6", paramId 86), and the data
#: agrees: ``123_86`` is 66 (bit 6 set) in exactly the three sample projects
#: holding drum data and 2 in both empty baselines, while tracks 2-4 never set
#: it. This is the flag parameter 100 was expected to carry and does not.
#: Track-level, not per-pattern, which matches the device's Drum button.
P_TRACK_MODE_BITS: Final = 86
DRUM_MODE_BIT: Final = 6

# --- The drum step-active bit array (parameter 52) -------------------------
# Neither step-indexed nor note-indexed: a flattened [lane][part] bit array,
# lane-major, whose two trailing indices are storage geometry rather than
# lane and step. Decoded from captures D1 and D3 and cross-checked against
# initial_project, where it explains the 17, 34 that the earlier
# 8-bits-per-entry reading could not. See spec section 4.

#: Steps per stored entry. Seven, not eight -- the values are 7-bit like every
#: other field in the format.
DRUM_STEP_ACTIVE_BITS_PER_ENTRY: Final = 7

#: Entries per lane: 10 x 7 = 70, enough to cover all 64 steps.
DRUM_STEP_ACTIVE_PARTS_PER_LANE: Final = 10


def drum_step_active_indices(lane: int, step: int) -> tuple[int, int, int]:
    """Locate the step-active bit for *lane* (0-based) at *step* (0-based).

    Returns the two 1-based file indices and the 0-based bit position, i.e.
    the bit lives in ``123_52_<pattern>_<i2>_<i3>`` at ``1 << bit``.
    """
    flat = lane * DRUM_STEP_ACTIVE_PARTS_PER_LANE + step // DRUM_STEP_ACTIVE_BITS_PER_ENTRY
    return flat // MAX_STEPS + 1, flat % MAX_STEPS + 1, step % DRUM_STEP_ACTIVE_BITS_PER_ENTRY


# --- Device global parameters (spec section 3.4) ---------------------------
# Recorded for documentation and the eventual SysEx path. These are addressed
# by globalParamId under deviceGlobalParametersId 65 and are NOT present in
# any project file, so nothing in the reader consumes them.

GLOBAL_PARAMS_ITEM: Final = 65
G_DRUM_OUTPUT_CHANNEL: Final = 79
G_DRUM_MAP_MODE: Final = 81  # 0 = Chromatic, 1 = Custom
G_DRUM_MAP_LOW_NOTE: Final = 82  # chromatic mode, 0-103
G_DRUM_MAP_NOTE_1: Final = 83  # ..106 = Note 1..Note 24, custom mode

# --- Value encodings -------------------------------------------------------

#: Time shift is an offset around a centre of 49, so stored 50 is +1 and
#: stored 48 is -1. Confirmed by the +1..+4 / -1..-4 ramp in project_5.
TIME_SHIFT_CENTRE: Final = 49

#: The displayed range of time shift. Unmeasured -- project_5's ramp only
#: reaches +-4 and nothing establishes it is the limit. Protocol T7.1.
TIME_SHIFT_RANGE: Final[tuple[int, int] | None] = None

#: What one unit of time shift is worth, as a fraction of a step. Unmeasured:
#: it may instead be a fixed tick count or an absolute time, which needs a
#: recording of the device's MIDI output to tell apart (protocol tier 8; see
#: analysis/Timing_Calibration.md). None until then, and never guessed -- a
#: wrong timing constant produces files that load cleanly and play wrong.
TIME_SHIFT_UNIT: Final[float | None] = None


def time_shift_fraction(shift: int) -> float | None:
    """Return *shift* as a fraction of a step, or ``None`` while unmeasured."""
    if TIME_SHIFT_UNIT is None:
        return None
    return shift * TIME_SHIFT_UNIT


#: Step skip is a 4-bit mask over the four 16-step sequences a pattern can run
#: as. 15 (all four) is the default. Spec section 5.
SKIP_SEQUENCES: Final = (16, 32, 48, 64)

#: Gate length is an **index**, not a curve: ``stored = encoder detent - 1``.
#: Measured 2026-07-31, capture ``T2-gate-table``, protocol tier 2; the full
#: transcription is ``analysis/gate_display_sweep.txt`` and the reading is spec
#: section 6.1. The earlier ``8*g + 3`` / ``4*g`` piecewise fit was six
#: scattered samples of a linear index mistaken for a non-linear encoding, and
#: is superseded.
#:
#: All the non-linearity lives in the *display*, which walks five runs of
#: constant increment and closes exactly on stored 127. Each entry is the
#: previous one plus its run's increment, starting from 0:
#:
#:     count  increment   display span   stored
#:         8      1/16    0.0625 -> 0.5    0-7
#:        20      1/8     0.625  -> 3      8-27
#:        20      1/4     3.25   -> 8      28-47
#:        48      1/2     8.5    -> 32     48-95
#:        32      1       33     -> 64     96-127
#:
#: Provenance, which must not be lost: stored 0-35 and 37-63 were transcribed
#: detent by detent (T2.1), stored 63/64/79/95/96/126/127 probed directly
#: (T2.2), and stored 36 is *derived* -- its sweep note was over-turned by one,
#: so 5.25 is read off the confirmed 0.25 run between measured 35 = 5 and
#: 37 = 5.5. Everything from 65 up is enumerated from the increment rule and
#: count-verified by the exact closure on 127. The drum ladder (``118``) is the
#: same table, spot-checked at five points (T2.3).
GATE_RUNS: Final = ((8, 0.0625), (20, 0.125), (20, 0.25), (48, 0.5), (32, 1.0))


def _build_gate_table() -> dict[int, float]:
    """Enumerate the ladder. Every increment is an exact binary fraction, so
    the running total is exact in float and needs no rounding."""
    table: dict[int, float] = {}
    value = 0.0
    for count, increment in GATE_RUNS:
        for _ in range(count):
            value += increment
            table[len(table)] = value
    return table


#: stored 0-127 -> gate length in steps. Complete: every legal 7-bit value has
#: a measured length, so nothing is interpolated and nothing is guessed.
GATE_TABLE: Final = _build_gate_table()

# The displayed gate is a length in **steps**: project_5 documents the note
# placed on beat 9 and tied through beat 12 -- four steps -- as gate 4. That is
# what lets M2 turn a gate into a MIDI note duration.

#: A freshly placed note stores gate 7, i.e. half a step (spec section 6.1).
#: The ladder is complete, so this is no longer a fallback for unmeasured
#: encodings -- it is what a writer puts on a note the caller said nothing
#: about, and what the export falls back to for a value off the ladder.
DEFAULT_GATE_STORED: Final = 7
DEFAULT_GATE_LENGTH: Final = GATE_TABLE[DEFAULT_GATE_STORED]


def decode_gate(stored: int) -> float | None:
    """Return the gate length in steps, or ``None`` if *stored* is off the
    ladder.

    Every legal 7-bit value decodes. ``None`` now means corrupt input -- a
    value outside 0-127 -- not an unmeasured encoding, and callers still handle
    it rather than substituting a length the file never asked for.
    """
    return GATE_TABLE.get(stored)


def decode_skip_mask(mask: int) -> tuple[int, ...]:
    """Return the 16/32/48/64 sequences a note plays in.

    ``15`` -> all four (the default); ``5`` -> (16, 48); ``12`` -> (48, 64).
    """
    return tuple(seq for bit, seq in enumerate(SKIP_SEQUENCES) if mask & (1 << bit))


#: The KeyStep Pro displays middle C (MIDI 60) as C3: project_5 documents
#: pitch 48 as C2 and project_9 documents pitch 60 as C3.
_NOTE_NAMES: Final = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")


def note_name(pitch: int) -> str:
    """Render a MIDI pitch the way the hardware labels it, e.g. 48 -> ``C2``."""
    return f"{_NOTE_NAMES[pitch % 12]}{pitch // 12 - 2}"
