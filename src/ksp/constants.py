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

#: Polyphony slots per pattern -- three on every track, Track 1 included.
#: MCC's ``bulkOperation`` descriptors address the note parameters at index-2
#: ``[1, 2, 3]`` on all four items and never at 4. Item 123's arrays are
#: dimensioned 16x4x64 anyway, because parameter 52 needs the room (see
#: ``DRUM_STEP_ACTIVE_ENTRIES``), and every parameter in the item inherits
#: that shape -- which is why slot 4 of the note parameters is uniformly zero
#: rather than sentinel-filled. It was never a fourth voice. Spec section 4.
SLOTS_PER_PATTERN: Final = 3

#: Highest slot index that exists in the key space, as opposed to the highest
#: that holds notes. Item 123 is dimensioned to 4; tracks 2-4 stop at 3 and
#: have no slot-4 keys at all. Only tools enumerating raw keys need this --
#: anything reading notes wants ``SLOTS_PER_PATTERN``.
SLOT_INDEX_MAX: Final = 4

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

P_DRUM_POLY_STEP_COUNT: Final = 51  # lane-indexed 1-24, one length per lane
P_DRUM_STEP_ACTIVE: Final = 52  # flat 240-entry bitmask, see below
P_DRUM_STEP_SKIP: Final = 53  # note-indexed, unlike the melodic 49
P_DRUM_NOTE_STEP: Final = 54  # note-indexed, 0-based step, pooled not compacted
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

# --- The DRUM step-active bitmask (52), spec section 3.2 -------------------
# Sixteen bulkOperation descriptors spell this layout out in words -- "DRUM 1
# part 1 to 10, DRUM 2 part 1 to 6" for the first sixteen entries, running on
# to "DRUM 23 part 5 to 10, DRUM 24 part 1 to 10" at slot 4. Read in order they
# describe one flat 240-entry array laid out lane-major, spilling across the
# slot index rather than restarting at each slot. That spill is why the values
# looked scattered while 52 was read as a per-slot array.

#: Parts per lane. 10 parts x 7 bits covers 70 steps, enough for the 64 maximum.
DRUM_PARTS_PER_LANE: Final = 10

#: Bits per entry -- 7, the natural width for a format whose values are MIDI
#: 7-bit. Part *p* covers steps ``7p+1`` to ``7p+7``, LSB first.
DRUM_STEPS_PER_PART: Final = 7

#: 24 lanes x 10 parts. Occupies slots 1-3 entirely plus slot 4 indices 1-48,
#: which is the reason item 123 is dimensioned for a fourth slot at all.
DRUM_STEP_ACTIVE_ENTRIES: Final = DRUM_LANE_COUNT * DRUM_PARTS_PER_LANE


def drum_step_active_address(lane: int, part: int) -> tuple[int, int]:
    """Return the ``(slot, index)`` key indices holding *lane*'s *part*.

    Both returned values are 1-based, matching the file's own indexing.
    """
    n = lane * DRUM_PARTS_PER_LANE + part
    slot, index = divmod(n, MAX_STEPS)
    return slot + 1, index + 1


def drum_step_active_lane_part(entry: int) -> tuple[int, int]:
    """Inverse of :func:`drum_step_active_address`, from a 0-based flat index."""
    return divmod(entry, DRUM_PARTS_PER_LANE)


def decode_drum_step_active(entry: int, value: int) -> tuple[int, tuple[int, ...]]:
    """Decode one flat entry into its lane and the 1-based steps it flags."""
    lane, part = drum_step_active_lane_part(entry)
    steps = tuple(
        part * DRUM_STEPS_PER_PART + bit + 1
        for bit in range(DRUM_STEPS_PER_PART)
        if value >> bit & 1
    )
    return lane, steps


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
