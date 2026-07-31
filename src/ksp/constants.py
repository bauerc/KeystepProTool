"""Item IDs, parameter IDs and cardinalities from the format spec.

Data only -- value encodings and the functions that decode them live in
:mod:`ksp.encoding`. Every constant traces to a table in
``analysis/KeyStepPro_Format_Spec.md``.
"""

from typing import Final

from ksp.types import ItemId, ParamId

#: "Empty" marker in note-indexed arrays. Also a legal pitch and a legal
#: velocity, so note existence is tested on the note->step parameter alone and
#: never on velocity. Spec 4.
SENTINEL: Final = 127

# --- Item IDs (spec 2) -----------------------------------------------------

ITEM_PROJECT: Final = ItemId(120)
ITEM_SCENES: Final = ItemId(121)
ITEM_CONTROL_TRACK: Final = ItemId(122)

#: Sequencer tracks 1-4. Track 1 carries a full drum parameter set as well.
TRACK_ITEM_IDS: Final = (ItemId(123), ItemId(124), ItemId(125), ItemId(126))
DRUM_TRACK_ITEM_ID: Final = ItemId(123)

PATTERNS_PER_TRACK: Final = 16
MAX_STEPS: Final = 64

#: Polyphony slots per track. Track 1's fourth is zero-filled rather than
#: sentinel-filled in every sample project -- see ``reader.slot_is_initialised``.
SLOTS_BY_ITEM: Final[dict[ItemId, int]] = {
    ItemId(123): 4,
    ItemId(124): 3,
    ItemId(125): 3,
    ItemId(126): 3,
}

#: The device has 24 drum lanes. Derived, not assumed: MCC's dictionary defines
#: exactly 24 "Note N" fields. No array in the file has this cardinality -- the
#: lane is a *value* of parameter 117, never an index. Spec 3.2.1.
DRUM_LANE_COUNT: Final = 24

# --- Project / global parameters (spec 3.4) --------------------------------

P_TEMPO_LSB: Final = ParamId(70)
P_TEMPO_MIDSB: Final = ParamId(71)
P_TEMPO_MSB: Final = ParamId(72)
P_GLOBAL_SWING: Final = ParamId(74)
P_CURRENT_SCENE: Final = ParamId(75)

# --- Per-pattern scalars (spec 3.3), indexed by pattern 1-16 ---------------

P_PATTERN_DATA_STATE: Final = ParamId(40)
P_SEQ_SWING: Final = ParamId(97)
P_SEQ_STEP_COUNT: Final = ParamId(98)
P_SEQ_PATTERN_BITS: Final = ParamId(99)
P_MODE_BITS: Final = ParamId(100)
P_ROOT_NOTE: Final = ParamId(107)
P_SCALE: Final = ParamId(108)
P_DRUM_SWING: Final = ParamId(114)
P_DRUM_STEP_COUNT: Final = ParamId(115)
P_DRUM_PATTERN_BITS: Final = ParamId(116)

#: ``40`` is 3 where a pattern holds data and 2 where it does not.
PATTERN_HAS_DATA: Final = 3

# --- Melodic note parameters (spec 3.1) ------------------------------------
# 48/49 are step-indexed; 50 and 109-113 are note-indexed. Spec 4.

P_SEQ_STEP_ACTIVE: Final = ParamId(48)
P_SEQ_STEP_SKIP: Final = ParamId(49)
P_SEQ_NOTE_STEP: Final = ParamId(50)
P_SEQ_PITCH: Final = ParamId(109)
P_SEQ_GATE: Final = ParamId(110)
P_SEQ_VELOCITY: Final = ParamId(111)
P_SEQ_TIME_SHIFT: Final = ParamId(112)
P_SEQ_RANDOMNESS: Final = ParamId(113)

# --- Drum note parameters, item 123 only (spec 3.2) ------------------------

P_DRUM_POLY_STEP_COUNT: Final = ParamId(51)
P_DRUM_STEP_ACTIVE: Final = ParamId(52)  # packing not fully decoded, spec 5
P_DRUM_STEP_SKIP: Final = ParamId(53)  # note-indexed, unlike the melodic 49
P_DRUM_NOTE_STEP: Final = ParamId(54)
P_DRUM_PITCH: Final = ParamId(117)  # drum lane index, 0-based (0 = kick)
P_DRUM_GATE: Final = ParamId(118)
P_DRUM_VELOCITY: Final = ParamId(119)
P_DRUM_TIME_SHIFT: Final = ParamId(120)
P_DRUM_RANDOMNESS: Final = ParamId(121)

#: Per-track bitfield; bit 6 is the Arp/Drum mode state. This is the flag
#: parameter 100 was expected to carry and does not -- 100 reads 26 everywhere.
#: Track-level, matching the device's Drum button. Spec 5.
P_TRACK_MODE_BITS: Final = ParamId(86)
DRUM_MODE_BIT: Final = 6

# --- Device global parameters (spec 3.4, 7) --------------------------------
# Addressed by globalParamId under deviceGlobalParametersId 65 and NOT present
# in any project file. Unreferenced by design: a registry for the SysEx path.

GLOBAL_PARAMS_ITEM: Final = ItemId(65)
G_DRUM_OUTPUT_CHANNEL: Final = ParamId(79)
G_DRUM_MAP_MODE: Final = ParamId(81)  # 0 = Chromatic, 1 = Custom
G_DRUM_MAP_LOW_NOTE: Final = ParamId(82)  # chromatic mode, 0-103
G_DRUM_MAP_NOTE_1: Final = ParamId(83)  # ..106 = Note 1..Note 24, custom mode
