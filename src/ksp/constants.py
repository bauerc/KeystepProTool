"""Item IDs, parameter IDs and encodings from the KeyStep Pro format spec.

Every constant here traces to a table in ``analysis/KeyStepPro_Format_Spec.md``.
Nothing is inferred or invented -- where the encoding is not yet known (time
shift range and unit) this module says so rather than guessing.
"""

from typing import Final

#: The ``version`` string every user-saved project carries and the factory
#: ``Default.KeyStepPro`` lacks (spec section 2). A converter starting from the
#: factory template injects it; ``lenient_json.canonical`` puts it in position.
PROJECT_VERSION: Final = "2.5.20"

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

# --- Scenes and pattern chaining (item 121) --------------------------------
# Measured 2026-08-04, capture T5-chain-3: a 3-pattern chain on Track 2 in
# scene 1 stores 121_84_1_2_1..3 = 0, 1, 2 and leaves slots 4-16 at SENTINEL.
# Pattern numbers are 0-based; the track index in the key is the track number.

SCENE_COUNT: Final = 16

#: Chain slots per (scene, track) -- one per pattern the chain can hold.
CHAIN_SLOTS: Final = 16

#: Tracks addressed by a scene key: 1-4 are the sequencer tracks and 5 is the
#: Control track, which is the one place the item ordering is not the obvious
#: one. Confirmed on the sequencer side by T5-chain-3.
SCENE_TRACK_COUNT: Final = 5
CONTROL_TRACK_INDEX: Final = 5

P_SCENE_CHAIN: Final = 84

#: Moves 0 -> 32 alongside the chain above. One capture cannot separate
#: ``(last << 4) | first`` from ``(len - 1) << 4`` -- both give 32 for a chain
#: of patterns 1-3 -- so nothing reads it. Distinct from G_DRUM_MAP_NOTE_1,
#: which is 83 under a different item.
P_SCENE_PATTERN_STATE: Final = 83

#: Pool chunks per track -- *not* polyphony voices. idx2 splits one flat note
#: pool into blocks of MAX_STEPS entries, so real capacity is 3 x 64 = 192
#: events per pattern, which the device enforces with an on-screen error --
#: measured on drums (D3) and on the melodic set (T4.6), where the pool spills
#: into chunks 2 and 3 while the step-active array stays wholly in chunk 1.
#: Chords live inside one chunk as consecutive ordinals sharing
#: a step (capture D2), so there is no 3- or 4-note ceiling. Track 1's fourth
#: chunk is zero-filled rather than sentinel-filled and stays untouched even
#: when a fourth chord voice is added, i.e. the firmware never uses it. See
#: ``reader.slot_is_initialised``.
SLOTS_BY_ITEM: Final = {123: 4, 124: 3, 125: 3, 126: 3}

#: Pool chunks a note may actually occupy, on every track. SLOTS_BY_ITEM says 4
#: for item 123, but that fourth chunk is the phantom described above.
POOL_SLOTS: Final = 3

#: Usable pool capacity, ignoring Track 1's phantom fourth chunk.
POOL_CAPACITY: Final = POOL_SLOTS * MAX_STEPS

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

#: What the device itself will run at. The three chunks reach about 20,971 BPM,
#: so the field's width is no guide: anything outside this is a project the
#: hardware cannot play, however cleanly it stores.
TEMPO_RANGE_BPM: Final = (30.0, 240.0)

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

#: The displayed swing range. 50% is straight, and is both the minimum and the
#: default, so swing only ever delays.
SWING_RANGE_PERCENT: Final = (50, 75)

#: Step counts are 0-based: stored 15 means a 16-step pattern.
STEP_COUNT_OFFSET: Final = 1

# --- The per-pattern bitfield (99 / 116) -----------------------------------
# Measured 2026-08-04, protocol tier 5, against B0-baseline. The sequencer
# field and the drum field share one layout; only their defaults differ, which
# is the whole of the 20-vs-16 asymmetry that looked like two encodings:
#
#   T5-99-stepsize     patterns 1-4 = 4 / 12 / 20 / 28   1/4, 1/8, 1/16, 1/32
#   T5-99-triplet      124_99_1 = 21, and 5 / 13 / 21 / 29 across the sizes
#   T5-99-monorhythm   124_99_1 = 16, Monorhythm on
#   T5-99-direction    patterns 1-3 = 20 / 52 / 84       Fwd, Rand, Walk
#   T5-99-drum         11 drum patterns decode identically through 116
#
# T5-99-swingoffset moved 97 and left 99 alone, so the dictionary's "swing
# offset state" is not a bit here.

#: Bit 0. Displayed as Triplet.
TRIPLET_BIT: Final = 0

#: Bit 2. Set = Polyrhythm, clear = Monorhythm. On the drum side this is what
#: gives lanes independent lengths and makes 51 meaningful (capture D4);
#: sequencer patterns default to set, drum patterns to clear.
POLYRHYTHM_BIT: Final = 2

#: Bits 3-4, indexing STEP_SIZE_DENOMINATORS.
STEP_SIZE_SHIFT: Final = 3
STEP_SIZE_MASK: Final = 0b11

#: Step size by stored index: 1/4, 1/8, 1/16, 1/32. 1/16 (index 2) is the
#: device default and the only size any sample project uses.
STEP_SIZE_DENOMINATORS: Final = (4, 8, 16, 32)

#: Bits 5-6. 0 = Forward, 1 = Random, 2 = Walk; 3 was never produced by the
#: device and has no known name.
DIRECTION_SHIFT: Final = 5
DIRECTION_MASK: Final = 0b11
DIRECTION_FORWARD: Final = 0
DIRECTION_RANDOM: Final = 1
DIRECTION_WALK: Final = 2

#: Bit 1 is set by nothing: not in any sample project, not in any capture.
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
    """Bits set that tier 5 never accounted for. Non-zero means a value the
    captures did not produce, which callers report rather than interpret."""
    return bits & ~_ALLOCATED_BITS


#: Parameter 108 indexes the device's scale list in display order, transcribed
#: off the device during T5.6 and confirmed by T5-scale, which walks patterns
#: 1-10 down the list on two tracks and stores 0-9.
#:
#: Index 7 (Root) is in the list but **cannot be stored**: selecting it leaves
#: 108 at its previous value, so a file never holds 7. Kept in the tuple so the
#: remaining indices line up with what the display shows.
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

#: The one entry of SCALE_NAMES the device declines to store (T5.6).
UNSTORABLE_SCALE: Final = 7


def scale_name(stored: int) -> str | None:
    """Name parameter 108's value, or ``None`` if it is off the list."""
    if 0 <= stored < len(SCALE_NAMES):
        return SCALE_NAMES[stored]
    return None


#: Root note is a pitch class, 0-11: T5-rootnote selects D and stores 2, with
#: the octave the display shows kept nowhere in the file.
ROOT_NOTE_COUNT: Final = 12

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
P_SEQ_RANDOMNESS: Final = 113  # play probability, not timing jitter

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
#: stored 48 is -1. The drum field 120 shares it.
TIME_SHIFT_CENTRE: Final = 49

#: The displayed range of time shift, in steps of 1. Asymmetric by one: there
#: is no displayed -50.
TIME_SHIFT_RANGE: Final[tuple[int, int]] = (-49, 50)

#: The same bounds as stored in 112 / 120.
TIME_SHIFT_STORED_MIN: Final = TIME_SHIFT_CENTRE + TIME_SHIFT_RANGE[0]
TIME_SHIFT_STORED_MAX: Final = TIME_SHIFT_CENTRE + TIME_SHIFT_RANGE[1]

#: One unit is 1/400 of a beat -- a fraction of the *beat*, not of the step, so
#: the full +50 is 60 ticks at 480 PPQN whatever the step size. Measured
#: 2026-08-04 by tier 8, recordings R1-R3 and R6 (analysis/Timing_Calibration.md
#: section 6.1). At the 1/16 default that equals half a step, which is why a
#: step-relative reading fits the whole corpus and is still wrong.
TIME_SHIFT_UNITS_PER_BEAT: Final = 400


def time_shift_ticks(shift: int, ticks_per_beat: int) -> int:
    """Return the displacement of a signed *shift*, in MIDI ticks.

    Positive delays. The result is rounded because the usual 480 ticks per beat
    is not divisible by 400; the error is under half a tick, per note, and does
    not accumulate across a pattern.
    """
    return round(shift * ticks_per_beat / TIME_SHIFT_UNITS_PER_BEAT)


#: Step skip is a 4-bit mask over the four 16-step sequences a pattern can run
#: as. 15 (all four) is the default. Spec section 5.
SKIP_SEQUENCES: Final = (16, 32, 48, 64)

#: Gate length is an **index**, not a curve: ``stored = encoder detent - 1``.
#: Measured 2026-07-31, capture ``T2-gate-table``, protocol tier 2; the full
#: transcription is ``analysis/gate_ladder.txt`` and the reading is spec
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
#: (T2.2), and stored 36 -- once derived, because its sweep note was over-turned
#: by a detent -- was pinned by capture D25-gate-capture, one note at display
#: 5.25. Everything from 65 up is enumerated from the increment rule and
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

#: The other two values a freshly placed note carries. Measured, not assumed:
#: captures T1-note-place, D25-gate-capture and both D2 chords agree on
#: velocity 100 and randomness 100, alongside gate 7 and time shift
#: TIME_SHIFT_CENTRE. Together these are what ksp.mutate.place_note writes when
#: the caller says nothing.
FRESH_VELOCITY: Final = 100
FRESH_RANDOMNESS: Final = 100

#: The firmware's two ceilings, both enforced with an on-screen message
#: (capture T4-melodic-overflow-v2). POOL_CAPACITY above is the per-pattern
#: one; this is the per-step limit that sits inside it, so a pattern can hold
#: 192 events only if they are spread across at least 12 steps.
MAX_NOTES_PER_STEP: Final = 16


def decode_gate(stored: int) -> float | None:
    """Return the gate length in steps, or ``None`` if *stored* is off the
    ladder.

    Every legal 7-bit value decodes. ``None`` now means corrupt input -- a
    value outside 0-127 -- not an unmeasured encoding, and callers still handle
    it rather than substituting a length the file never asked for.
    """
    return GATE_TABLE.get(stored)


def encode_gate(length: float) -> int:
    """The ladder rung nearest *length* steps, for a writer carrying durations.

    The ladder is coarse above 3 steps and its runs are not uniform, so an
    arbitrary MIDI duration rarely lands on a rung. Returning the nearest one
    and letting the caller compare it against what it asked for is what keeps
    the approximation reportable rather than silent.
    """
    return min(GATE_TABLE, key=lambda stored: (abs(GATE_TABLE[stored] - length), stored))


#: How the four sequences run: as **repeats**, not pages. Measured by ear over
#: eight loops during T5.8 -- a 16-step pattern with one note per mask played
#: beat 1 on pass 1, beat 5 on pass 2, beat 9 on pass 3, beat 13 on pass 4,
#: then cycled. A pass is the pattern's own declared length at any length, so
#: every mask is meaningful even on a pattern far shorter than 64 steps.
SKIP_CYCLE_PASSES: Final = len(SKIP_SEQUENCES)

#: Every sequence set, i.e. a note that plays on all four passes. The value 49
#: and 53 hold unless the user says otherwise, which is why a writer placing a
#: note leaves them alone.
SKIP_MASK_ALL: Final = (1 << SKIP_CYCLE_PASSES) - 1

#: Steps per beat when the pattern runs at 1/16, the device default. Only the
#: *import* direction has to choose this -- an export reads the pattern's own
#: step size out of 99 / 116.
DEFAULT_STEPS_PER_BEAT: Final = 4


def check_steps_per_beat(value: int) -> None:
    """Shared by every caller that lets a user pick one, so the message cannot
    drift."""
    if value < 1:
        raise ValueError("steps_per_beat must be at least 1")


def steps_per_beat_bits(bits: int, steps_per_beat: int) -> int:
    """Set the step-size field of *bits* to *steps_per_beat*, leaving the rest.

    Raises for a step size the device cannot express: the field is two bits
    wide and holds 1/4 through 1/32 only.
    """
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

    ``15`` -> all four (the default); ``5`` -> (16, 48); ``12`` -> (48, 64).
    """
    return tuple(seq for bit, seq in enumerate(SKIP_SEQUENCES) if mask & (1 << bit))


#: The KeyStep Pro displays middle C (MIDI 60) as C3: project_5 documents
#: pitch 48 as C2 and project_9 documents pitch 60 as C3.
_NOTE_NAMES: Final = ("C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B")


def note_name(pitch: int) -> str:
    """Render a MIDI pitch the way the hardware labels it, e.g. 48 -> ``C2``."""
    return f"{_NOTE_NAMES[pitch % 12]}{pitch // 12 - 2}"


def root_note_name(root: int) -> str:
    """Name parameter 107's pitch class, e.g. 2 -> ``D``.

    No octave: the display shows one but the file does not store it (T5.6).
    """
    return _NOTE_NAMES[root % ROOT_NOTE_COUNT]
