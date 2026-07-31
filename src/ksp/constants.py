"""Item IDs, parameter IDs and encodings from the KeyStep Pro format spec.

Every constant here traces to a table in ``analysis/KeyStepPro_Format_Spec.md``.
Nothing is inferred or invented -- where the encoding is not yet known (gate
length above the measured points) this module says so rather than guessing.
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

#: Polyphony slots per track. Track 1 has four addressable slots but the
#: fourth is zero-filled in every sample project rather than sentinel-filled,
#: i.e. the firmware never initialises it. See ``reader.slot_is_initialised``.
SLOTS_BY_ITEM: Final = {123: 4, 124: 3, 125: 3, 126: 3}

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
P_DRUM_STEP_ACTIVE: Final = 52  # packing not fully decoded, see reader
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

#: Step skip is a 4-bit mask over the four 16-step sequences a pattern can run
#: as. 15 (all four) is the default. Spec section 5.
SKIP_SEQUENCES: Final = (16, 32, 48, 64)

#: Gate length is non-linear and only partly measured. These six points are
#: hardware-confirmed; everything else is unknown and this module refuses to
#: interpolate. Resolving the rest is milestone M7 -- a wrong gate table
#: produces files that load cleanly and play with wrong note durations, which
#: is the worst available failure mode because nothing errors.
GATE_TABLE: Final = {7: 0.5, 11: 1.0, 19: 2.0, 27: 3.0, 29: 3.5, 31: 4.0}

# The displayed gate is a length in **steps**: project_5 documents the note
# placed on beat 9 and tied through beat 12 -- four steps -- as gate 4. That is
# what lets M2 turn a gate into a MIDI note duration.

#: A freshly placed note stores gate 7, i.e. half a step (spec section 6).
#: This is the fallback wherever an encoding is not in ``GATE_TABLE``: the
#: device's own default is the one length we can use without inventing one.
DEFAULT_GATE_STORED: Final = 7
DEFAULT_GATE_LENGTH: Final = GATE_TABLE[DEFAULT_GATE_STORED]


def decode_gate(stored: int) -> float | None:
    """Return the displayed gate length, or ``None`` if it is not yet known."""
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
