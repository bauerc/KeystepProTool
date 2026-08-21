"""Decoding a flat ``.KeyStepPro`` dict into the object model."""

from collections.abc import Sequence
from dataclasses import replace
from functools import lru_cache
from pathlib import Path
from typing import Any

from ksp import constants, lenient_json
from ksp.diagnostics import Code, Collector, Diagnostic, Site
from ksp.keys import get_int, read_array
from ksp.model import (
    Chain,
    Note,
    NoteKind,
    Pattern,
    PatternBits,
    PatternMode,
    Project,
    Scene,
    Track,
)


@lru_cache(maxsize=16)
def load(path: Path | str) -> Project:
    """Read and decode a ``.KeyStepPro`` file."""
    path = Path(path)
    return read_project(lenient_json.load_path(path), source_name=path.name)


def read_project(raw: dict[str, Any], source_name: str = "") -> Project:
    """Decode an already-parsed project dict."""
    collector = Collector()

    device = raw.get("device")
    if not isinstance(device, str):
        raise ValueError("not a KeyStepPro project: missing 'device'")

    version = raw.get("version")
    if version is None:
        collector.add(
            Code.NO_VERSION_KEY,
            "no 'version' key (factory template rather than a saved project)",
        )
    elif not isinstance(version, str):
        raise ValueError(f"'version' holds {type(version).__name__}, expected str")

    tracks = tuple(
        _read_track(raw, number, item_id)
        for number, item_id in enumerate(constants.TRACK_ITEM_IDS, start=1)
    )

    return Project(
        device=device,
        version=version,
        tempo_bpm=_read_tempo(raw),
        global_swing_percent=_scalar(
            raw, constants.ITEM_PROJECT, constants.P_GLOBAL_SWING, default=50
        ),
        current_scene=_scalar(raw, constants.ITEM_PROJECT, constants.P_CURRENT_SCENE, default=0)
        + 1,
        tracks=tracks,
        scenes=_read_scenes(raw, collector),
        source_name=source_name,
        diagnostics=collector.report(),
    )


def _scalar(raw: dict[str, Any], item: int, param: int, *indices: int, default: int) -> int:
    value = get_int(raw, item, param, *indices)
    return default if value is None else value


def _read_tempo(raw: dict[str, Any]) -> float:
    """Reassemble the project tempo from its three 7-bit chunks."""
    lsb = _scalar(raw, constants.ITEM_PROJECT, constants.P_TEMPO_LSB, default=0)
    midsb = _scalar(raw, constants.ITEM_PROJECT, constants.P_TEMPO_MIDSB, default=0)
    msb = _scalar(raw, constants.ITEM_PROJECT, constants.P_TEMPO_MSB, default=0)
    hundredths = lsb + midsb * constants.TEMPO_CHUNK + msb * constants.TEMPO_CHUNK**2
    return hundredths / constants.TEMPO_SCALE


def _read_scenes(raw: dict[str, Any], collector: Collector) -> tuple[Scene, ...]:
    """Decode each scene's pattern chains from parameter 84.
    Chains are contiguous and sentinel-terminated; a value after a sentinel is reported."""
    scenes = []
    for scene in range(1, constants.SCENE_COUNT + 1):
        chains = []
        for track in range(1, constants.SCENE_TRACK_COUNT + 1):
            stored = [
                get_int(raw, constants.ITEM_SCENES, constants.P_SCENE_CHAIN, scene, track, slot)
                for slot in range(1, constants.CHAIN_SLOTS + 1)
            ]
            patterns: list[int] = []
            for value in stored:
                if value is None or value == constants.SENTINEL:
                    break
                # Stored 0-based, reported the way the device numbers patterns.
                patterns.append(value + 1)
            if any(v is not None and v != constants.SENTINEL for v in stored[len(patterns) :]):
                collector.add(
                    Code.CHAIN_HAS_HOLE,
                    f"track {track}'s chain has a gap after {len(patterns)} pattern(s); "
                    f"everything after it was ignored",
                    site=Site(scene=scene, track=track),
                )
            if patterns:
                chains.append(Chain(track=track, patterns=tuple(patterns)))
        scenes.append(Scene(number=scene, chains=tuple(chains)))
    return tuple(scenes)


def _read_track(raw: dict[str, Any], number: int, item_id: int) -> Track:
    drum_mode = _read_drum_mode(raw, item_id)
    patterns = tuple(
        _read_pattern(raw, item_id, p, drum_mode=drum_mode)
        for p in range(1, constants.PATTERNS_PER_TRACK + 1)
    )
    return Track(number=number, item_id=item_id, patterns=patterns, drum_mode=drum_mode)


def _read_drum_mode(raw: dict[str, Any], item_id: int) -> bool:
    """Whether this track is in DRUM mode, from parameter 86 bit 6.
    Only Track 1 has a drum parameter set, so tracks 2-4 always report False."""
    if item_id != constants.DRUM_TRACK_ITEM_ID:
        return False
    bits = _scalar(raw, item_id, constants.P_TRACK_MODE_BITS, default=0)
    return bool(bits & (1 << constants.DRUM_MODE_BIT))


def _read_pattern(
    raw: dict[str, Any], item_id: int, pattern: int, *, drum_mode: bool = False
) -> Pattern:
    """Decode one pattern from whichever parameter set(s) hold notes.
    *drum_mode* is parameter 86 bit 6, not the 100 bitfield documented for it (spec 5)."""
    collector = Collector()
    site = Site(pattern=pattern)

    seq_notes, seq_diagnostics = _read_note_lists(raw, item_id, pattern, kind=NoteKind.SEQ)
    drum_notes: tuple[Note, ...] = ()
    drum_diagnostics: list[Diagnostic] = []
    if item_id == constants.DRUM_TRACK_ITEM_ID:
        drum_notes, drum_diagnostics = _read_note_lists(raw, item_id, pattern, kind=NoteKind.DRUM)

    notes = seq_notes + drum_notes
    collector.extend(seq_diagnostics)
    collector.extend(drum_diagnostics)

    if seq_notes and drum_notes:
        mode = PatternMode.DRUM if drum_mode else PatternMode.SEQ
        stale, live = (
            (f"melodic ({len(seq_notes)})", f"drum ({len(drum_notes)})")
            if drum_mode
            else (f"drum ({len(drum_notes)})", f"melodic ({len(seq_notes)})")
        )
        collector.add(
            Code.MIXED_NOTE_SETS,
            f"holds both melodic ({len(seq_notes)}) and drum ({len(drum_notes)}) notes; "
            f"parameter 86 bit 6 says {live} plays and {stale} is stale. Both are reported",
            site=site,
        )
    elif drum_notes:
        mode = PatternMode.DRUM
        if not drum_mode:
            collector.add(
                Code.DRUM_MODE_FLAG_DISAGREES,
                "holds drum notes but parameter 86 bit 6 is clear",
                site=site,
            )
    elif seq_notes:
        mode = PatternMode.SEQ
        if drum_mode:
            collector.add(
                Code.DRUM_MODE_FLAG_DISAGREES,
                "holds only melodic notes but parameter 86 bit 6 says the track is in drum mode",
                site=site,
            )
    else:
        mode = PatternMode.EMPTY

    has_data = (
        _scalar(raw, item_id, constants.P_PATTERN_DATA_STATE, pattern, default=0)
        == constants.PATTERN_HAS_DATA
    )
    if notes and not has_data:
        collector.add(
            Code.HAS_DATA_FLAG_DISAGREES,
            f"holds {len(notes)} notes but parameter 40 says it has no data",
            site=site,
        )

    is_drum_track = item_id == constants.DRUM_TRACK_ITEM_ID
    scale = _scalar(raw, item_id, constants.P_SCALE, pattern, default=0)
    if constants.scale_name(scale) is None:
        collector.add(
            Code.SCALE_OFF_LIST,
            f"parameter 108 holds {scale}, past the end of the device's scale list",
            site=site,
        )
    return Pattern(
        number=pattern,
        mode=mode,
        has_data=has_data,
        seq_step_count=_step_count(raw, item_id, constants.P_SEQ_STEP_COUNT, pattern),
        seq_swing_percent=_swing(raw, item_id, constants.P_SEQ_SWING, pattern),
        seq_bits=_pattern_bits(
            raw, item_id, constants.P_SEQ_PATTERN_BITS, pattern, collector, site
        ),
        drum_step_count=(
            _step_count(raw, item_id, constants.P_DRUM_STEP_COUNT, pattern)
            if is_drum_track
            else None
        ),
        drum_swing_percent=(
            _swing(raw, item_id, constants.P_DRUM_SWING, pattern) if is_drum_track else None
        ),
        drum_bits=(
            _pattern_bits(
                raw, item_id, constants.P_DRUM_PATTERN_BITS, pattern, collector, site, kind="drum"
            )
            if is_drum_track
            else None
        ),
        root_note=_scalar(raw, item_id, constants.P_ROOT_NOTE, pattern, default=0),
        scale=scale,
        notes=notes,
        diagnostics=collector.report(),
    )


def _pattern_bits(
    raw: dict[str, Any],
    item_id: int,
    param: int,
    pattern: int,
    collector: Collector,
    site: Site,
    *,
    kind: str = "seq",
) -> PatternBits:
    """Decode 99 or 116 -- step size, triplet, polyrhythm and direction.
    Both fields share a layout (spec 3.3), so the caller varies only the parameter."""
    bits = PatternBits.decode(_scalar(raw, item_id, param, pattern, default=0))
    if bits.unallocated:
        collector.add(
            Code.PATTERN_BITS_UNKNOWN,
            f"parameter {param} holds {bits.raw} ({bits.raw:#09b}), whose bit "
            f"{bits.unallocated:#b} no capture accounted for",
            site=replace(site, kind=kind),
        )
    return bits


def _step_count(raw: dict[str, Any], item_id: int, param: int, pattern: int) -> int:
    """Step counts are stored 0-based: 15 means a 16-step pattern."""
    return _scalar(raw, item_id, param, pattern, default=0) + constants.STEP_COUNT_OFFSET


def _swing(raw: dict[str, Any], item_id: int, param: int, pattern: int) -> int:
    """Swing is stored with a +25 offset: 25 means 50%, i.e. no swing."""
    return (
        _scalar(raw, item_id, param, pattern, default=constants.SWING_OFFSET)
        + constants.SWING_OFFSET
    )


def _read_note_lists(
    raw: dict[str, Any], item_id: int, pattern: int, *, kind: NoteKind
) -> tuple[tuple[Note, ...], list[Diagnostic]]:
    """Decode every pool chunk of one pattern for one parameter set."""
    active = _read_step_active(raw, item_id, pattern, kind=kind)

    notes: list[Note] = []
    diagnostics: list[Diagnostic] = []
    for slot in range(1, constants.SLOTS_BY_ITEM[item_id] + 1):
        slot_notes, slot_diagnostics = _read_slot(
            raw, item_id, pattern, slot, kind=kind, active=active
        )
        notes.extend(slot_notes)
        diagnostics.extend(slot_diagnostics)

    diagnostics.extend(_check_step_active(pattern, notes, active, kind=kind))
    return tuple(notes), diagnostics


def _read_step_active(
    raw: dict[str, Any], item_id: int, pattern: int, *, kind: NoteKind
) -> frozenset[Any]:
    """Decode which steps the device will actually play, 0-based.
    Melodic (``48``) yields steps; drum (``52``) yields ``(lane, step)`` pairs."""
    if kind is NoteKind.SEQ:
        # Chunk 1 is the whole array: one entry per step fills it exactly, so a
        # pool spilling into chunks 2-3 leaves these flags behind.
        flags = read_array(
            raw, item_id, constants.P_SEQ_STEP_ACTIVE, pattern, 1, length=constants.MAX_STEPS
        )
        return frozenset(step for step, value in enumerate(flags) if value == 1)

    flat: list[int | None] = []
    for chunk in range(1, constants.SLOTS_BY_ITEM[item_id] + 1):
        flat.extend(
            read_array(
                raw,
                item_id,
                constants.P_DRUM_STEP_ACTIVE,
                pattern,
                chunk,
                length=constants.MAX_STEPS,
            )
        )

    pairs: set[tuple[int, int]] = set()
    for offset, value in enumerate(flat):
        if not value:
            continue
        lane, part = divmod(offset, constants.DRUM_STEP_ACTIVE_PARTS_PER_LANE)
        if lane >= constants.DRUM_LANE_COUNT:
            continue
        base = part * constants.DRUM_STEP_ACTIVE_BITS_PER_ENTRY
        for bit in range(constants.DRUM_STEP_ACTIVE_BITS_PER_ENTRY):
            step = base + bit
            if step < constants.MAX_STEPS and value >> bit & 1:
                pairs.add((lane, step))
    return frozenset(pairs)


def _read_slot(
    raw: dict[str, Any],
    item_id: int,
    pattern: int,
    slot: int,
    *,
    kind: NoteKind,
    active: frozenset[Any],
) -> tuple[list[Note], list[Diagnostic]]:
    drum = kind is NoteKind.DRUM
    if drum:
        p_step, p_pitch = constants.P_DRUM_NOTE_STEP, constants.P_DRUM_PITCH
        p_gate, p_velocity = constants.P_DRUM_GATE, constants.P_DRUM_VELOCITY
        p_shift, p_random = constants.P_DRUM_TIME_SHIFT, constants.P_DRUM_RANDOMNESS
    else:
        p_step, p_pitch = constants.P_SEQ_NOTE_STEP, constants.P_SEQ_PITCH
        p_gate, p_velocity = constants.P_SEQ_GATE, constants.P_SEQ_VELOCITY
        p_shift, p_random = constants.P_SEQ_TIME_SHIFT, constants.P_SEQ_RANDOMNESS

    def column(param: int) -> list[int | None]:
        return read_array(raw, item_id, param, pattern, slot, length=constants.MAX_STEPS)

    note_step = column(p_step)
    if note_step[0] is None:  # parameter set absent for this item
        return [], []

    pitch = column(p_pitch)
    velocity = column(p_velocity)
    if not slot_is_initialised(note_step, pitch, velocity):
        return [], []

    gate = column(p_gate)
    shift = column(p_shift)
    random = column(p_random)
    # Melodic step skip is step-indexed and lives wholly in chunk 1; the drum
    # equivalent is note-indexed and per chunk. The asymmetry is not a typo.
    skip = (
        column(constants.P_DRUM_STEP_SKIP)
        if drum
        else read_array(
            raw, item_id, constants.P_SEQ_STEP_SKIP, pattern, 1, length=constants.MAX_STEPS
        )
    )

    notes: list[Note] = []
    diagnostics: list[Diagnostic] = []
    for i, step in enumerate(note_step):
        if step is None:  # ran off the end of the stored array
            break
        if step == constants.SENTINEL:
            if drum:
                # The drum array is a pool with holes, so a sentinel is an empty
                # entry, not the end of the list. Melodic lists are compacted.
                continue
            trailing = [v for v in note_step[i + 1 :] if v is not None and v != constants.SENTINEL]
            if trailing:
                diagnostics.append(
                    Diagnostic(
                        Code.TRAILING_POOL_VALUES,
                        f"{len(trailing)} value(s) after the end of the note list were ignored",
                        site=Site(pattern=pattern, slot=slot),
                        subjects=len(trailing),
                    )
                )
            break

        skip_index = i if drum else step
        skip_mask = skip[skip_index]
        value = _required(pitch[i])
        notes.append(
            Note(
                kind=kind,
                slot=slot,
                index=i + 1,
                step=step + 1,
                active=(value, step) in active if drum else step in active,
                pitch=value,
                velocity=_required(velocity[i]),
                gate_raw=_required(gate[i]),
                gate=constants.decode_gate(_required(gate[i])),
                time_shift=_required(shift[i]) - constants.TIME_SHIFT_CENTRE,
                randomness=_required(random[i]),
                skip=constants.decode_skip_mask(skip_mask if skip_mask is not None else 0),
            )
        )

    if drum:
        out_of_range = sorted({n.pitch for n in notes if n.pitch >= constants.DRUM_LANE_COUNT})
        if out_of_range:
            diagnostics.append(
                Diagnostic(
                    Code.DRUM_LANE_OUT_OF_RANGE,
                    f"drum lane(s) {out_of_range} are outside 0-{constants.DRUM_LANE_COUNT - 1}",
                    site=Site(pattern=pattern, slot=slot),
                    subjects=len(out_of_range),
                )
            )
    return notes, diagnostics


def slot_is_initialised(
    note_step: Sequence[int | None], pitch: Sequence[int | None], velocity: Sequence[int | None]
) -> bool:
    """Distinguish a genuinely empty slot from an uninitialised one.
    Track 1's slot 4 is zero-filled, so the ``!= 127`` rule alone sees phantom notes (spec 4)."""
    return not (
        all(v == 0 for v in note_step)
        and all(v == 0 for v in pitch)
        and all(v == 0 for v in velocity)
    )


def _check_step_active(
    pattern: int, notes: list[Note], active: frozenset[Any], *, kind: NoteKind
) -> list[Diagnostic]:
    """Cross-check the note list against the step-active flags.
    The device plays the flags, so a pooled note whose flag is clear is silent (spec 4)."""
    diagnostics: list[Diagnostic] = []
    site = Site(pattern=pattern, kind=kind.value)

    # Drum flags are per lane, so compare (lane, step) pairs, never a union.
    if kind is NoteKind.SEQ:
        held_steps = {n.step for n in notes}
        orphaned = sorted(step + 1 for step in active if step + 1 not in held_steps)
    else:
        held = {(n.pitch, n.step) for n in notes}
        orphaned = sorted({step + 1 for lane, step in active if (lane, step + 1) not in held})
    if orphaned:
        diagnostics.append(
            Diagnostic(
                Code.FLAG_WITHOUT_NOTE,
                f"step(s) {orphaned} are flagged active but hold no note. Every flagged step "
                f"should have a pooled note, so this means the note pool was decoded wrongly "
                f"rather than that the file is damaged",
                site=site,
                subjects=len(orphaned),
            )
        )

    silent = [n for n in notes if not n.active]
    if silent:
        diagnostics.append(
            Diagnostic(
                Code.DISABLED_STEP_OFF,
                f"{len(silent)} disabled note(s), step turned off, so they do not play on "
                f"the device (step(s) {sorted({n.step for n in silent})})",
                site=site,
                subjects=len(silent),
            )
        )
    return diagnostics


def _required(value: int | None) -> int:
    """Assert a note field is present; a populated note->step entry implies every sibling."""
    if value is None:
        raise ValueError("note parameter missing where the note list says a note exists")
    return value
