"""Targeted edits to a parsed ``.KeyStepPro`` project.

Milestone M4. Two operations, each specified by a hardware capture diff rather
than inferred: placing a melodic note (8 keys, ``B0-baseline`` ->
``T1-note-place``) and changing one note's pitch (1 key, ``T1-note-place`` ->
``T1-note-pitch``).

Placing a note writes six note-indexed parameters, one **step**-indexed
step-active flag and the pattern's data-state latch::

    <item>_50_<pat>_<slot>_<ord>    step, 0-based
    <item>_109_<pat>_<slot>_<ord>   pitch
    <item>_110_<pat>_<slot>_<ord>   gate
    <item>_111_<pat>_<slot>_<ord>   velocity
    <item>_112_<pat>_<slot>_<ord>   time shift
    <item>_113_<pat>_<slot>_<ord>   randomness
    <item>_48_<pat>_1_<step>        step active -- slot 1, always
    <item>_40_<pat>                 pattern holds data

Step skip (``49``) is deliberately absent: an empty project already holds 15,
"plays on all four sequences", everywhere.

Every function returns a new dict and never adds or removes a key. The key set
is fixed (spec section 2), so an address the file does not already carry is an
error rather than something to create.

Melodic only. A drum note's lane lives in ``117``, but the drum step-active
array ``52`` is indexed *by lane*, so moving a lane moves its bit too. That is a
different operation and belongs to M6.
"""

from collections.abc import Mapping

from ksp import constants
from ksp.keys import item_for_track, key

#: Pool chunks a melodic note may occupy. Track 1's fourth chunk is a
#: zero-filled phantom the firmware never uses (capture D2-chord4-tr1), so the
#: real ceiling is 3 everywhere.
_SLOTS = constants.POOL_SLOTS

_NOTE_PARAMS = (
    constants.P_SEQ_NOTE_STEP,
    constants.P_SEQ_PITCH,
    constants.P_SEQ_GATE,
    constants.P_SEQ_VELOCITY,
    constants.P_SEQ_TIME_SHIFT,
    constants.P_SEQ_RANDOMNESS,
)


def _check_pattern(pattern: int) -> None:
    if not 1 <= pattern <= constants.PATTERNS_PER_TRACK:
        raise ValueError(f"pattern {pattern} out of range 1-{constants.PATTERNS_PER_TRACK}")


def _check_slot(item: int, slot: int) -> None:
    if item == constants.DRUM_TRACK_ITEM_ID and slot > _SLOTS:
        raise ValueError(
            f"item {item} slot {slot} is a zero-filled phantom the firmware never writes "
            "(spec section 4); a fourth chord voice goes to slot 1 like any other note"
        )
    if not 1 <= slot <= _SLOTS:
        raise ValueError(f"slot {slot} out of range 1-{_SLOTS}")


def _check_value(name: str, value: int) -> None:
    if not 0 <= value <= constants.SENTINEL:
        raise ValueError(f"{name} {value} out of range 0-{constants.SENTINEL}")


def _with_values(raw: Mapping[str, int | str], updates: Mapping[str, int]) -> dict[str, int | str]:
    """Copy *raw* with *updates* applied, refusing any key it does not hold.

    The refusal is the point: the key set is fixed, so a key that is not
    already there means the address was computed wrongly.
    """
    missing = [k for k in updates if k not in raw]
    if missing:
        raise KeyError(f"not in the file: {', '.join(sorted(missing))}")

    result = dict(raw)
    result.update(updates)
    return result


def _slot_steps(raw: Mapping[str, int | str], item: int, pattern: int, slot: int) -> list[int]:
    """The 0-based step of each pool entry in one slot, ``None`` past the end.

    Returns the live prefix, and raises if a sentinel is followed by a live
    entry. The melodic pool is compacted -- verified across every sample file
    (spec section 4) -- so a hole means this pool is not shaped the way every
    measurement says it should be, and appending to it is not something any
    capture covers.
    """
    entries = [
        raw.get(key(item, constants.P_SEQ_NOTE_STEP, pattern, slot, i + 1))
        for i in range(constants.MAX_STEPS)
    ]
    live = [v for v in entries if isinstance(v, int) and v != constants.SENTINEL]
    if entries[: len(live)] != live:
        raise ValueError(
            f"item {item} pattern {pattern} slot {slot} has a hole in its melodic pool; "
            "the melodic list is compacted in every sample, so this is unmeasured territory"
        )
    return live


def pitch_key(*, track: int, pattern: int, note: int, slot: int = 1) -> str:
    """The key holding one melodic note's pitch, by 1-based pool ordinal."""
    item = item_for_track(track)
    _check_pattern(pattern)
    _check_slot(item, slot)
    if not 1 <= note <= constants.MAX_STEPS:
        raise ValueError(f"note ordinal {note} out of range 1-{constants.MAX_STEPS}")

    return key(item, constants.P_SEQ_PITCH, pattern, slot, note)


def set_pitch(
    raw: Mapping[str, int | str],
    *,
    track: int,
    pattern: int,
    note: int,
    pitch: int,
    slot: int = 1,
) -> dict[str, int | str]:
    """Change one existing note's pitch. Exactly one key moves.

    Raises:
        ValueError: if that pool entry is empty. A pitch on a note that is not
            there is a pitch nothing plays, so it means the wrong ordinal was
            addressed -- which is the failure this is meant to surface.
    """
    _check_value("pitch", pitch)
    target = pitch_key(track=track, pattern=pattern, note=note, slot=slot)
    item = item_for_track(track)

    step = raw.get(key(item, constants.P_SEQ_NOTE_STEP, pattern, slot, note))
    if step == constants.SENTINEL:
        raise ValueError(
            f"track {track} pattern {pattern} slot {slot} has no note at ordinal {note}"
        )

    return _with_values(raw, {target: pitch})


def place_note(
    raw: Mapping[str, int | str],
    *,
    track: int,
    pattern: int,
    step: int,
    pitch: int,
    velocity: int = constants.FRESH_VELOCITY,
    gate: int = constants.DEFAULT_GATE_STORED,
    time_shift: int = constants.TIME_SHIFT_CENTRE,
    randomness: int = constants.FRESH_RANDOMNESS,
    slot: int = 1,
    activate: bool = True,
) -> dict[str, int | str]:
    """Add a melodic note at *step* (1-based), at the first free pool ordinal.

    ``activate=False`` leaves the step-active flag clear, which places a note
    the device will not sound. It exists to build the M4.1 control note and a
    converter must never use it.

    Raises:
        ValueError: if the slot is full, if the step or the pattern is already
            at a firmware ceiling, or if any value is out of range.
    """
    item = item_for_track(track)
    _check_pattern(pattern)
    _check_slot(item, slot)
    if not 1 <= step <= constants.MAX_STEPS:
        raise ValueError(f"step {step} out of range 1-{constants.MAX_STEPS}")
    for name, value in (
        ("pitch", pitch),
        ("velocity", velocity),
        ("gate", gate),
        ("time shift", time_shift),
        ("randomness", randomness),
    ):
        _check_value(name, value)

    per_slot = [_slot_steps(raw, item, pattern, s) for s in range(1, _SLOTS + 1)]
    if len(per_slot[slot - 1]) >= constants.MAX_STEPS:
        raise ValueError(f"track {track} pattern {pattern} slot {slot} is full")

    pooled = [s for slot_steps in per_slot for s in slot_steps]
    if len(pooled) >= constants.POOL_CAPACITY:
        raise ValueError(
            f"track {track} pattern {pattern} already holds {constants.POOL_CAPACITY} notes, "
            "the firmware's per-pattern limit"
        )
    if pooled.count(step - 1) >= constants.MAX_NOTES_PER_STEP:
        raise ValueError(
            f"step {step} already holds {constants.MAX_NOTES_PER_STEP} notes, "
            "the firmware's per-step limit"
        )

    # _slot_steps has already established the pool is compacted, so the live
    # count is the first free ordinal.
    ordinal = len(per_slot[slot - 1]) + 1

    values = (step - 1, pitch, gate, velocity, time_shift, randomness)
    updates = {
        key(item, param, pattern, slot, ordinal): value
        for param, value in zip(_NOTE_PARAMS, values, strict=True)
    }
    updates[key(item, constants.P_PATTERN_DATA_STATE, pattern)] = constants.PATTERN_HAS_DATA
    if activate:
        updates[key(item, constants.P_SEQ_STEP_ACTIVE, pattern, 1, step)] = 1

    return _with_values(raw, updates)
