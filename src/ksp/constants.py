"""Item IDs, parameter IDs and encodings from the KeyStep Pro format spec."""

from typing import Final

#: The ``version`` string every user-saved project carries; the factory template lacks it (spec 2).
PROJECT_VERSION: Final = "2.5.20"

#: "Empty" marker in note-indexed arrays -- also a legal pitch and velocity, so
#: note existence is tested on the note->step parameter alone, never velocity (spec 4).
SENTINEL: Final = 127

ITEM_PROJECT: Final = 120
ITEM_SCENES: Final = 121
ITEM_CONTROL_TRACK: Final = 122

#: Sequencer tracks 1-4; track 1 also carries a full drum parameter set.
TRACK_ITEM_IDS: Final = (123, 124, 125, 126)
DRUM_TRACK_ITEM_ID: Final = 123

PATTERNS_PER_TRACK: Final = 16
MAX_STEPS: Final = 64

#: Project slots a user can name; the protocol's own slot byte is wider (``sysex.MAX_SLOT``).
PROJECT_SLOTS: Final = 16

SCENE_COUNT: Final = 16

#: Chain slots per (scene, track) -- one per pattern the chain can hold.
CHAIN_SLOTS: Final = 16

#: Tracks addressed by a scene key: 1-4 sequencer, 5 Control -- not the obvious item ordering.
SCENE_TRACK_COUNT: Final = 5
CONTROL_TRACK_INDEX: Final = 5

P_SCENE_CHAIN: Final = 84

#: Chain summary byte; ambiguous between two encodings, so nothing reads it.
P_SCENE_PATTERN_STATE: Final = 83

#: Pool chunks per track, not polyphony voices. Track 1's 4th is a phantom (spec 4).
SLOTS_BY_ITEM: Final = {123: 4, 124: 3, 125: 3, 126: 3}

#: Pool chunks a note may actually occupy, on every track.
POOL_SLOTS: Final = 3

#: Usable pool capacity, ignoring Track 1's phantom fourth chunk.
POOL_CAPACITY: Final = POOL_SLOTS * MAX_STEPS

P_TEMPO_LSB: Final = 70
P_TEMPO_MIDSB: Final = 71
P_TEMPO_MSB: Final = 72
P_GLOBAL_SWING: Final = 74
P_CURRENT_SCENE: Final = 75

#: Tempo is 21-bit little-endian in 7-bit chunks, holding BPM x 100.
TEMPO_CHUNK: Final = 128
TEMPO_SCALE: Final = 100

#: What the device will run at; the field is far wider, so its width is no guide.
TEMPO_RANGE_BPM: Final = (30.0, 240.0)

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

#: Parameter 40 is 3 where a pattern holds data and 2 where it does not.
PATTERN_HAS_DATA: Final = 3

#: Swing is stored with a +25 offset: stored 25 is 50% (spec 3.3).
SWING_OFFSET: Final = 25

#: The displayed swing range; 50% is straight and is the minimum, so swing only ever delays.
SWING_RANGE_PERCENT: Final = (50, 75)

#: Step counts are 0-based: stored 15 means a 16-step pattern.
STEP_COUNT_OFFSET: Final = 1

#: Bit 0. Displayed as Triplet.
TRIPLET_BIT: Final = 0

#: Bit 2. Set = Polyrhythm, clear = Monorhythm. Sequencer patterns default set, drum patterns clear.
POLYRHYTHM_BIT: Final = 2

#: Bits 3-4, indexing STEP_SIZE_DENOMINATORS.
STEP_SIZE_SHIFT: Final = 3
STEP_SIZE_MASK: Final = 0b11

#: Step size by stored index; 1/16 (index 2) is the device default.
STEP_SIZE_DENOMINATORS: Final = (4, 8, 16, 32)

#: Bits 5-6. 0 = Forward, 1 = Random, 2 = Walk; 3 has no known name.
DIRECTION_SHIFT: Final = 5
DIRECTION_MASK: Final = 0b11
DIRECTION_FORWARD: Final = 0
DIRECTION_RANDOM: Final = 1
DIRECTION_WALK: Final = 2

#: Bit 1 is set by nothing, in no sample project and no capture.
_ALLOCATED_BITS: Final = (
    1 << TRIPLET_BIT
    | 1 << POLYRHYTHM_BIT
    | STEP_SIZE_MASK << STEP_SIZE_SHIFT
    | DIRECTION_MASK << DIRECTION_SHIFT
)


def step_denominator(bits: int) -> int:
    """Step size as a note denominator: 16 means 1/16 steps."""
    return STEP_SIZE_DENOMINATORS[(bits >> STEP_SIZE_SHIFT) & STEP_SIZE_MASK]


def is_triplet(bits: int) -> bool:
    return bool(bits & 1 << TRIPLET_BIT)


def is_polyrhythm(bits: int) -> bool:
    return bool(bits & 1 << POLYRHYTHM_BIT)


def direction_index(bits: int) -> int:
    return (bits >> DIRECTION_SHIFT) & DIRECTION_MASK


def unallocated_bits(bits: int) -> int:
    """Bits no capture accounted for; callers report rather than interpret them."""
    return bits & ~_ALLOCATED_BITS


#: Parameter 108's scale list in display order. Index 7 (Root) cannot be stored, but
#: stays in the tuple so the remaining indices line up with the display.
SCALE_NAMES: Final = (
    "Chromatic",
    "Major",
    "Minor",
    "Dorian",
    "Mixolydian",
    "Harmonic Minor",
    "Blues",
    "Root",
    "User 1",
    "User 2",
)

#: The one entry of SCALE_NAMES the device declines to store.
UNSTORABLE_SCALE: Final = 7


def scale_name(stored: int) -> str | None:
    """Name parameter 108's value, or ``None`` if it is off the list."""
    if 0 <= stored < len(SCALE_NAMES):
        return SCALE_NAMES[stored]
    return None


#: Root note is a pitch class, 0-11; the octave the display shows is stored nowhere.
ROOT_NOTE_COUNT: Final = 12

# 48 and 49 are indexed by step; 50 and 109-113 are indexed by note ordinal.
# Conflating the two index spaces is the classic way to misread this format.

P_SEQ_STEP_ACTIVE: Final = 48  # step-indexed
P_SEQ_STEP_SKIP: Final = 49  # step-indexed
P_SEQ_NOTE_STEP: Final = 50  # note-indexed, 0-based step
P_SEQ_PITCH: Final = 109
P_SEQ_GATE: Final = 110
P_SEQ_VELOCITY: Final = 111
P_SEQ_TIME_SHIFT: Final = 112
P_SEQ_RANDOMNESS: Final = 113  # play probability, not timing jitter

P_DRUM_POLY_STEP_COUNT: Final = 51
P_DRUM_STEP_ACTIVE: Final = 52  # flattened lane-major bit array, see below
P_DRUM_STEP_SKIP: Final = 53  # note-indexed, unlike the melodic 49
P_DRUM_NOTE_STEP: Final = 54  # note-indexed, 0-based step
P_DRUM_PITCH: Final = 117  # drum lane index, 0-based (0 = kick)
P_DRUM_GATE: Final = 118
P_DRUM_VELOCITY: Final = 119
P_DRUM_TIME_SHIFT: Final = 120
P_DRUM_RANDOMNESS: Final = 121

#: Drum lanes. The lane is a *value* of parameter 117, never an array index.
DRUM_LANE_COUNT: Final = 24

#: Per-track bitfield; bit 6 is the Arp/Drum mode state. Track-level, not per-pattern.
P_TRACK_MODE_BITS: Final = 86
DRUM_MODE_BIT: Final = 6

# Parameter 52 is neither step- nor note-indexed: a flattened [lane][part] bit
# array, lane-major, whose trailing indices are storage geometry (spec 4).

#: Steps per stored entry. Seven, not eight -- the values are 7-bit.
DRUM_STEP_ACTIVE_BITS_PER_ENTRY: Final = 7

#: Entries per lane: 10 x 7 = 70, enough to cover all 64 steps.
DRUM_STEP_ACTIVE_PARTS_PER_LANE: Final = 10


def drum_step_active_indices(lane: int, step: int) -> tuple[int, int, int]:
    """Locate the step-active bit for *lane* at *step*, both 0-based.
    Returns the two 1-based file indices and the 0-based bit position."""
    flat = lane * DRUM_STEP_ACTIVE_PARTS_PER_LANE + step // DRUM_STEP_ACTIVE_BITS_PER_ENTRY
    return flat // MAX_STEPS + 1, flat % MAX_STEPS + 1, step % DRUM_STEP_ACTIVE_BITS_PER_ENTRY


# Addressed by globalParamId under item 65 and absent from every project file,
# so nothing in the reader consumes them.

GLOBAL_PARAMS_ITEM: Final = 65
G_DRUM_OUTPUT_CHANNEL: Final = 79
G_DRUM_MAP_MODE: Final = 81  # 0 = Chromatic, 1 = Custom
G_DRUM_MAP_LOW_NOTE: Final = 82  # chromatic mode, 0-103
G_DRUM_MAP_NOTE_1: Final = 83  # ..106 = Note 1..Note 24, custom mode

#: Time shift is an offset around a centre of 49; the drum field 120 shares it.
TIME_SHIFT_CENTRE: Final = 49

#: The displayed range, in steps of 1. Asymmetric by one: there is no displayed -50.
TIME_SHIFT_RANGE: Final[tuple[int, int]] = (-49, 50)

#: The same bounds as stored in 112 / 120.
TIME_SHIFT_STORED_MIN: Final = TIME_SHIFT_CENTRE + TIME_SHIFT_RANGE[0]
TIME_SHIFT_STORED_MAX: Final = TIME_SHIFT_CENTRE + TIME_SHIFT_RANGE[1]

#: One unit is 1/400 of a *beat*, not of the step, so the displacement is
#: independent of step size (analysis/Timing_Calibration.md 6.1).
TIME_SHIFT_UNITS_PER_BEAT: Final = 400


def time_shift_ticks(shift: int, ticks_per_beat: int) -> int:
    """Displacement of a signed *shift* in MIDI ticks; positive delays.
    Rounded because 480 is not divisible by 400; the error does not accumulate."""
    return round(shift * ticks_per_beat / TIME_SHIFT_UNITS_PER_BEAT)


#: Step skip is a 4-bit mask over the four 16-step sequences a pattern can run as (spec 5).
SKIP_SEQUENCES: Final = (16, 32, 48, 64)

#: Gate length is an **index**, not a curve: ``stored = encoder detent - 1``. The
#: non-linearity lives in the display (spec 6.1, analysis/gate_ladder.txt).
GATE_RUNS: Final = ((8, 0.0625), (20, 0.125), (20, 0.25), (48, 0.5), (32, 1.0))


def _build_gate_table() -> dict[int, float]:
    """Every increment is an exact binary fraction, so the running total needs no rounding."""
    table: dict[int, float] = {}
    value = 0.0
    for count, increment in GATE_RUNS:
        for _ in range(count):
            value += increment
            table[len(table)] = value
    return table


#: stored 0-127 -> gate length in steps. Complete: nothing is interpolated.
GATE_TABLE: Final = _build_gate_table()

#: A freshly placed note stores gate 7, i.e. half a step (spec 6.1).
DEFAULT_GATE_STORED: Final = 7
DEFAULT_GATE_LENGTH: Final = GATE_TABLE[DEFAULT_GATE_STORED]

#: The other two values a freshly placed note carries.
FRESH_VELOCITY: Final = 100
FRESH_RANDOMNESS: Final = 100

#: The per-step ceiling inside POOL_CAPACITY, enforced by the firmware on screen.
MAX_NOTES_PER_STEP: Final = 16


def decode_gate(stored: int) -> float | None:
    """Gate length in steps, or ``None`` if *stored* is outside 0-127.
    Every legal 7-bit value decodes, so ``None`` means corrupt input."""
    return GATE_TABLE.get(stored)


def encode_gate(length: float) -> int:
    """The ladder rung nearest *length* steps. The ladder is coarse above 3 steps,
    so callers compare the result against what they asked for and report the gap."""
    return min(GATE_TABLE, key=lambda stored: (abs(GATE_TABLE[stored] - length), stored))


#: The four sequences run as **repeats**, not pages: one pass is the pattern's own
#: declared length, so every mask is meaningful even far below 64 steps.
SKIP_CYCLE_PASSES: Final = len(SKIP_SEQUENCES)

#: Every sequence set, i.e. a note that plays on all four passes.
SKIP_MASK_ALL: Final = (1 << SKIP_CYCLE_PASSES) - 1

#: Steps per beat at the 1/16 default. Only *import* chooses this; export reads 99 / 116.
DEFAULT_STEPS_PER_BEAT: Final = 4


def check_steps_per_beat(value: int) -> None:
    """Shared by every caller that lets a user pick one, so the message cannot drift."""
    if value < 1:
        raise ValueError("steps_per_beat must be at least 1")


def steps_per_beat_bits(bits: int, steps_per_beat: int) -> int:
    """Set the step-size field of *bits*, leaving the rest.
    Raises for a step size the two-bit field cannot express."""
    denominator = steps_per_beat * 4
    if denominator not in STEP_SIZE_DENOMINATORS:
        sizes = ", ".join(f"1/{d}" for d in STEP_SIZE_DENOMINATORS)
        raise ValueError(
            f"1/{denominator} steps cannot be stored; the device holds {sizes} "
            f"in parameter 99 (spec 3.3)"
        )
    index = STEP_SIZE_DENOMINATORS.index(denominator)
    return bits & ~(STEP_SIZE_MASK << STEP_SIZE_SHIFT) | index << STEP_SIZE_SHIFT


def decode_skip_mask(mask: int) -> tuple[int, ...]:
    """Return the 16/32/48/64 sequences a note plays in.
    ``15`` -> all four (the default); ``5`` -> (16, 48); ``12`` -> (48, 64)."""
    return tuple(seq for bit, seq in enumerate(SKIP_SEQUENCES) if mask & (1 << bit))


#: The KeyStep Pro displays middle C (MIDI 60) as C3.
_NOTE_NAMES: Final = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")


def note_name(pitch: int) -> str:
    """Render a MIDI pitch the way the hardware labels it, e.g. 48 -> ``C2``."""
    return f"{_NOTE_NAMES[pitch % 12]}{pitch // 12 - 2}"


def root_note_name(root: int) -> str:
    """Name parameter 107's pitch class, e.g. 2 -> ``D``. No octave: the file stores none."""
    return _NOTE_NAMES[root % ROOT_NOTE_COUNT]
