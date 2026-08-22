"""Targeted edits to a parsed ``.KeyStepPro`` project."""

from collections.abc import Mapping, Sequence

from ksp import constants
from ksp.keys import item_for_track, key

#: Pool chunks a note may occupy. Track 1's fourth is a zero-filled phantom.
_SLOTS = constants.POOL_SLOTS

_NOTE_PARAMS = (
    constants.P_SEQ_NOTE_STEP,
    constants.P_SEQ_PITCH,
    constants.P_SEQ_GATE,
    constants.P_SEQ_VELOCITY,
    constants.P_SEQ_TIME_SHIFT,
    constants.P_SEQ_RANDOMNESS,
)

#: The drum set in the same order, so one recipe serves both (spec 3.2).
#: ``117`` holds a lane index where ``109`` holds a pitch.
_DRUM_NOTE_PARAMS = (
    constants.P_DRUM_NOTE_STEP,
    constants.P_DRUM_PITCH,
    constants.P_DRUM_GATE,
    constants.P_DRUM_VELOCITY,
    constants.P_DRUM_TIME_SHIFT,
    constants.P_DRUM_RANDOMNESS,
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


def _check_time_shift(stored: int) -> None:
    # Narrower than the 7-bit field: the encoder cannot reach past these.
    low, high = constants.TIME_SHIFT_STORED_MIN, constants.TIME_SHIFT_STORED_MAX
    if not low <= stored <= high:
        displayed = stored - constants.TIME_SHIFT_CENTRE
        raise ValueError(
            f"time shift {stored} (displayed {displayed:+d}) out of range {low}-{high} "
            f"(displayed {constants.TIME_SHIFT_RANGE[0]:+d}..{constants.TIME_SHIFT_RANGE[1]:+d})"
        )


def _with_values(raw: Mapping[str, int | str], updates: Mapping[str, int]) -> dict[str, int | str]:
    """Copy *raw* with *updates* applied, refusing any key it does not hold.
    The key set is fixed, so a missing key means the address was computed wrongly."""
    missing = [k for k in updates if k not in raw]
    if missing:
        raise KeyError(f"not in the file: {', '.join(sorted(missing))}")

    result = dict(raw)
    result.update(updates)
    return result


def merge_updates(raw: dict[str, int | str], updates: Mapping[str, int]) -> None:
    """Apply *updates* to *raw* in place, refusing any key it does not hold.
    The one exception to this module's copy-on-write rule, for bulk writers."""
    missing = [k for k in updates if k not in raw]
    if missing:
        raise KeyError(f"not in the file: {', '.join(sorted(missing))}")
    raw.update(updates)


def _slot_steps(raw: Mapping[str, int | str], item: int, pattern: int, slot: int) -> list[int]:
    """The live prefix of one slot's note->step column.
    The melodic pool is compacted (spec 4), so a hole is unmeasured territory."""
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
    An empty pool entry raises: it means the wrong ordinal was addressed."""
    _check_value("pitch", pitch)
    target = pitch_key(track=track, pattern=pattern, note=note, slot=slot)
    item = item_for_track(track)

    step = raw.get(key(item, constants.P_SEQ_NOTE_STEP, pattern, slot, note))
    if step == constants.SENTINEL:
        raise ValueError(
            f"track {track} pattern {pattern} slot {slot} has no note at ordinal {note}"
        )

    return _with_values(raw, {target: pitch})


def _drum_pool(raw: Mapping[str, int | str], pattern: int, slot: int) -> list[int | None]:
    """One drum pool chunk's note->step column, ``None`` where it is empty.
    Unlike the melodic list this one holds holes, so a writer fills the first gap."""
    entries: list[int | None] = []
    for i in range(constants.MAX_STEPS):
        value = raw.get(
            key(
                constants.DRUM_TRACK_ITEM_ID,
                constants.P_DRUM_NOTE_STEP,
                pattern,
                slot,
                i + 1,
            )
        )
        live = isinstance(value, int) and value != constants.SENTINEL
        entries.append(value if live and isinstance(value, int) else None)
    return entries


def drum_note_updates(
    raw: Mapping[str, int | str],
    *,
    pattern: int,
    lane: int,
    step: int,
    velocity: int = constants.FRESH_VELOCITY,
    gate: int = constants.DEFAULT_GATE_STORED,
    time_shift: int = constants.TIME_SHIFT_CENTRE,
    randomness: int = constants.FRESH_RANDOMNESS,
    slot: int | None = None,
    activate: bool = True,
) -> dict[str, int]:
    """The keys one drum hit writes, on Track 1 only. ``52`` packs seven steps to
    an entry, so its bit is or-ed in: assigning would clear the other lanes."""
    item = constants.DRUM_TRACK_ITEM_ID
    _check_pattern(pattern)
    if slot is not None:
        _check_slot(item, slot)
    if not 0 <= lane < constants.DRUM_LANE_COUNT:
        raise ValueError(f"drum lane {lane} out of range 0-{constants.DRUM_LANE_COUNT - 1}")
    if not 1 <= step <= constants.MAX_STEPS:
        raise ValueError(f"step {step} out of range 1-{constants.MAX_STEPS}")
    for name, value in (
        ("velocity", velocity),
        ("gate", gate),
        ("randomness", randomness),
    ):
        _check_value(name, value)
    _check_time_shift(time_shift)

    per_slot = [_drum_pool(raw, pattern, s) for s in range(1, _SLOTS + 1)]
    pooled = [v for chunk in per_slot for v in chunk if v is not None]
    if len(pooled) >= constants.POOL_CAPACITY:
        raise ValueError(
            f"drum pattern {pattern} already holds {constants.POOL_CAPACITY} hits, "
            "the firmware's per-pattern limit"
        )
    if pooled.count(step - 1) >= constants.MAX_NOTES_PER_STEP:
        raise ValueError(
            f"step {step} already holds {constants.MAX_NOTES_PER_STEP} hits, "
            "the firmware's per-step limit"
        )

    if slot is None:
        slot = next(
            (n for n, chunk in enumerate(per_slot, start=1) if None in chunk),
            _SLOTS,
        )
    chunk = per_slot[slot - 1]
    if None not in chunk:
        raise ValueError(f"drum pattern {pattern} slot {slot} is full")
    ordinal = chunk.index(None) + 1

    values = (step - 1, lane, gate, velocity, time_shift, randomness)
    updates = {
        key(item, param, pattern, slot, ordinal): value
        for param, value in zip(_DRUM_NOTE_PARAMS, values, strict=True)
    }
    updates[key(item, constants.P_PATTERN_DATA_STATE, pattern)] = constants.PATTERN_HAS_DATA

    if activate:
        i2, i3, bit = constants.drum_step_active_indices(lane, step - 1)
        target = key(item, constants.P_DRUM_STEP_ACTIVE, pattern, i2, i3)
        current = raw.get(target)
        if not isinstance(current, int):
            raise KeyError(f"not in the file: {target}")
        updates[target] = current | 1 << bit

    return updates


def place_drum_note(
    raw: Mapping[str, int | str],
    *,
    pattern: int,
    lane: int,
    step: int,
    velocity: int = constants.FRESH_VELOCITY,
    gate: int = constants.DEFAULT_GATE_STORED,
    time_shift: int = constants.TIME_SHIFT_CENTRE,
    randomness: int = constants.FRESH_RANDOMNESS,
    slot: int | None = None,
    activate: bool = True,
) -> dict[str, int | str]:
    """Add a drum hit on *lane* at *step* (1-based), at the first free ordinal."""
    return _with_values(
        raw,
        drum_note_updates(
            raw,
            pattern=pattern,
            lane=lane,
            step=step,
            velocity=velocity,
            gate=gate,
            time_shift=time_shift,
            randomness=randomness,
            slot=slot,
            activate=activate,
        ),
    )


def set_step_size(
    raw: Mapping[str, int | str],
    *,
    track: int,
    pattern: int,
    steps_per_beat: int,
    drum: bool = False,
) -> dict[str, int | str]:
    """Set one pattern's step size in ``99``, leaving the field's other bits.
    Read-modify-write: triplet, polyrhythm and direction are the user's settings."""
    item = item_for_track(track)
    _check_pattern(pattern)
    param = constants.P_DRUM_PATTERN_BITS if drum else constants.P_SEQ_PATTERN_BITS
    target = key(item, param, pattern)
    stored = raw.get(target)
    if not isinstance(stored, int):
        raise KeyError(f"not in the file: {target}")
    return _with_values(raw, {target: constants.steps_per_beat_bits(stored, steps_per_beat)})


def set_step_count(
    raw: Mapping[str, int | str],
    *,
    track: int,
    pattern: int,
    steps: int,
    drum: bool = False,
) -> dict[str, int | str]:
    """Set how many steps one pattern runs for. Stored 0-based (spec 3.3)."""
    item = item_for_track(track)
    _check_pattern(pattern)
    if not 1 <= steps <= constants.MAX_STEPS:
        raise ValueError(f"step count {steps} out of range 1-{constants.MAX_STEPS}")
    param = constants.P_DRUM_STEP_COUNT if drum else constants.P_SEQ_STEP_COUNT
    target = key(item, param, pattern)
    return _with_values(raw, {target: steps - constants.STEP_COUNT_OFFSET})


def set_swing(
    raw: Mapping[str, int | str],
    *,
    track: int,
    pattern: int,
    percent: int,
    drum: bool = False,
) -> dict[str, int | str]:
    """Set one pattern's swing, as the percentage the device displays.
    Never the global ``74``: the per-pattern value takes precedence on the device."""
    item = item_for_track(track)
    _check_pattern(pattern)
    low, high = constants.SWING_RANGE_PERCENT
    if not low <= percent <= high:
        raise ValueError(f"swing {percent}% out of range {low}-{high}%")
    param = constants.P_DRUM_SWING if drum else constants.P_SEQ_SWING
    target = key(item, param, pattern)
    return _with_values(raw, {target: percent - constants.SWING_OFFSET})


def set_drum_mode(raw: Mapping[str, int | str], *, track: int, on: bool) -> dict[str, int | str]:
    """Set ``86`` bit 6, the flag deciding which note set a track plays.
    Read-modify-write; on tracks 2-4 the bit means ARP, so turning it on raises."""
    item = item_for_track(track)
    if on and item != constants.DRUM_TRACK_ITEM_ID:
        raise ValueError(
            f"track {track} has no drum parameter set; bit 6 there is ARP, not DRUM (spec 5)"
        )
    target = key(item, constants.P_TRACK_MODE_BITS)
    stored = raw.get(target)
    if not isinstance(stored, int):
        raise KeyError(f"not in the file: {target}")
    bit = 1 << constants.DRUM_MODE_BIT
    return _with_values(raw, {target: stored | bit if on else stored & ~bit})


def set_tempo(raw: Mapping[str, int | str], *, bpm: float) -> dict[str, int | str]:
    """Set the project tempo, held as BPM x 100 in three 7-bit chunks."""
    hundredths = round(bpm * constants.TEMPO_SCALE)
    limit = constants.TEMPO_CHUNK**3
    if not 0 <= hundredths < limit:
        raise ValueError(f"tempo {bpm} BPM does not fit the three 7-bit chunks of 70-72")
    chunks = (
        constants.P_TEMPO_LSB,
        constants.P_TEMPO_MIDSB,
        constants.P_TEMPO_MSB,
    )
    return _with_values(
        raw,
        {
            key(constants.ITEM_PROJECT, param): (
                hundredths // constants.TEMPO_CHUNK**n % constants.TEMPO_CHUNK
            )
            for n, param in enumerate(chunks)
        },
    )


def set_chain(
    raw: Mapping[str, int | str],
    *,
    scene: int,
    track: int,
    patterns: Sequence[int],
) -> dict[str, int | str]:
    """Chain *patterns* (1-based, in play order) for one track of one scene.
    Written contiguously from slot 1, every remaining slot left at the sentinel."""
    if not 1 <= scene <= constants.SCENE_COUNT:
        raise ValueError(f"scene {scene} out of range 1-{constants.SCENE_COUNT}")
    if not 1 <= track <= constants.SCENE_TRACK_COUNT:
        raise ValueError(f"track {track} out of range 1-{constants.SCENE_TRACK_COUNT}")
    if len(patterns) > constants.CHAIN_SLOTS:
        raise ValueError(f"a chain holds at most {constants.CHAIN_SLOTS} patterns")
    for pattern in patterns:
        _check_pattern(pattern)

    stored = [p - 1 for p in patterns]
    padded = stored + [constants.SENTINEL] * (constants.CHAIN_SLOTS - len(stored))
    return _with_values(
        raw,
        {
            key(constants.ITEM_SCENES, constants.P_SCENE_CHAIN, scene, track, slot): value
            for slot, value in enumerate(padded, start=1)
        },
    )


def note_updates(
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
    slot: int | None = None,
    activate: bool = True,
) -> dict[str, int]:
    """The keys one melodic note writes, without copying the project.
    :func:`place_note` is this plus a copy."""
    item = item_for_track(track)
    _check_pattern(pattern)
    if slot is not None:
        _check_slot(item, slot)
    if not 1 <= step <= constants.MAX_STEPS:
        raise ValueError(f"step {step} out of range 1-{constants.MAX_STEPS}")
    for name, value in (
        ("pitch", pitch),
        ("velocity", velocity),
        ("gate", gate),
        ("randomness", randomness),
    ):
        _check_value(name, value)
    _check_time_shift(time_shift)

    per_slot = [_slot_steps(raw, item, pattern, s) for s in range(1, _SLOTS + 1)]
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

    # The pool is one flat list chunked into slots of 64, so the next free
    # ordinal spans them: a chord straddling a chunk boundary is ordinary.
    if slot is None:
        slot = next(
            (
                n
                for n, entries in enumerate(per_slot, start=1)
                if len(entries) < constants.MAX_STEPS
            ),
            _SLOTS,
        )
    if len(per_slot[slot - 1]) >= constants.MAX_STEPS:
        raise ValueError(f"track {track} pattern {pattern} slot {slot} is full")

    # _slot_steps has established the pool is compacted, so the live count is
    # the first free ordinal.
    ordinal = len(per_slot[slot - 1]) + 1

    values = (step - 1, pitch, gate, velocity, time_shift, randomness)
    updates = {
        key(item, param, pattern, slot, ordinal): value
        for param, value in zip(_NOTE_PARAMS, values, strict=True)
    }
    updates[key(item, constants.P_PATTERN_DATA_STATE, pattern)] = constants.PATTERN_HAS_DATA
    if activate:
        updates[key(item, constants.P_SEQ_STEP_ACTIVE, pattern, 1, step)] = 1

    return updates


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
    slot: int | None = None,
    activate: bool = True,
) -> dict[str, int | str]:
    """Add a melodic note at *step* (1-based), at the first free pool ordinal.
    ``activate=False`` places a note the device will not sound; a converter must not."""
    return _with_values(
        raw,
        note_updates(
            raw,
            track=track,
            pattern=pattern,
            step=step,
            pitch=pitch,
            velocity=velocity,
            gate=gate,
            time_shift=time_shift,
            randomness=randomness,
            slot=slot,
            activate=activate,
        ),
    )
