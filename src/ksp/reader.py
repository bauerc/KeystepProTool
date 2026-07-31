"""Decoding a flat ``.KeyStepPro`` dict into the object model.

The whole difficulty is in one place: within a single ``(track, pattern,
slot)`` the trailing index means two different things depending on the
parameter. 48/49 are indexed by physical step; 50/54 and 109-113 / 117-121 are
indexed by ordinal in a compact note list, with 50 saying which step each note
sits on. The device stores an event list, not a step grid.

Reading it with a single index space produces values that look almost right,
which is worse than values that look wrong. Spec 4.
"""

from collections.abc import Sequence
from pathlib import Path
from typing import Any

from ksp import constants, encoding, lenient_json
from ksp.model import Note, Pattern, PatternTiming, Project, Track
from ksp.params import NOTE_PARAMS, NoteParamSet
from ksp.raw import RawProject, as_raw
from ksp.types import ItemId, Lane, NoteIndex, NoteKind, ParamId, PatternMode, Pitch, Step


def load(path: Path | str) -> Project:
    """Read and decode a ``.KeyStepPro`` file."""
    path = Path(path)
    return read_project(lenient_json.load_path(path), source_name=path.name)


def read_project(source: RawProject | dict[str, Any], source_name: str = "") -> Project:
    """Decode an already-parsed project."""
    raw = as_raw(source)
    warnings: list[str] = []

    device = raw.text("device")
    if device is None:
        raise ValueError("not a KeyStepPro project: missing 'device'")

    version = raw.data.get("version")
    if version is None:
        # The factory Default.KeyStepPro omits it; user saves carry it. M5 has
        # to inject it when using the factory file as a template.
        warnings.append("no 'version' key (factory template rather than a saved project)")
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
        global_swing_percent=raw.int_at(
            constants.ITEM_PROJECT, constants.P_GLOBAL_SWING, default=50
        ),
        current_scene=raw.int_at(constants.ITEM_PROJECT, constants.P_CURRENT_SCENE, default=0) + 1,
        tracks=tracks,
        source_name=source_name,
        warnings=tuple(warnings),
    )


def _read_tempo(raw: RawProject) -> float:
    return encoding.decode_tempo(
        raw.int_at(constants.ITEM_PROJECT, constants.P_TEMPO_LSB, default=0),
        raw.int_at(constants.ITEM_PROJECT, constants.P_TEMPO_MIDSB, default=0),
        raw.int_at(constants.ITEM_PROJECT, constants.P_TEMPO_MSB, default=0),
    )


def _read_track(raw: RawProject, number: int, item_id: ItemId) -> Track:
    drum_mode = _read_drum_mode(raw, item_id)
    patterns = tuple(
        _read_pattern(raw, item_id, p, drum_mode=drum_mode)
        for p in range(1, constants.PATTERNS_PER_TRACK + 1)
    )
    return Track(number=number, item_id=item_id, patterns=patterns, drum_mode=drum_mode)


def _read_drum_mode(raw: RawProject, item_id: ItemId) -> bool:
    """Whether this track is in DRUM mode, from parameter 86 bit 6."""
    # Only Track 1 has a drum parameter set. MCC calls the field "Arp/Drum mode
    # state", so on tracks 2-4 it presumably means ARP -- reported as False
    # there rather than pretending it says something about drums.
    if item_id != constants.DRUM_TRACK_ITEM_ID:
        return False
    bits = raw.int_at(item_id, constants.P_TRACK_MODE_BITS, default=0)
    return bool(bits & (1 << constants.DRUM_MODE_BIT))


def _read_pattern(
    raw: RawProject, item_id: ItemId, pattern: int, *, drum_mode: bool = False
) -> Pattern:
    """Decode one pattern from whichever parameter set(s) hold notes.

    Note content alone is not decisive -- a pattern can hold a real melody
    *and* a real drum pattern -- so parameter 86 bit 6 resolves which the
    device plays. Every note is still reported and the leftover set warned
    about. Spec 5, "drum mode is 86 bit 6, not 100".
    """
    warnings: list[str] = []
    is_drum_track = item_id == constants.DRUM_TRACK_ITEM_ID

    seq_notes, seq_warnings = _read_note_lists(raw, item_id, pattern, kind=NoteKind.SEQ)
    drum_notes: tuple[Note, ...] = ()
    drum_warnings: list[str] = []
    if is_drum_track:
        drum_notes, drum_warnings = _read_note_lists(raw, item_id, pattern, kind=NoteKind.DRUM)

    notes = seq_notes + drum_notes
    warnings += seq_warnings + drum_warnings

    if seq_notes and drum_notes:
        # Both sets hold notes, so the mode flag decides; the other set is
        # leftovers from before the track was switched over.
        mode = PatternMode.DRUM if drum_mode else PatternMode.SEQ
        stale, live = (
            (f"melodic ({len(seq_notes)})", f"drum ({len(drum_notes)})")
            if drum_mode
            else (f"drum ({len(drum_notes)})", f"melodic ({len(seq_notes)})")
        )
        warnings.append(
            f"pattern {pattern} holds both melodic ({len(seq_notes)}) and drum "
            f"({len(drum_notes)}) notes; parameter 86 bit 6 says {live} plays and "
            f"{stale} is stale. Both are reported"
        )
    elif drum_notes:
        mode = PatternMode.DRUM
        if not drum_mode:
            warnings.append(f"pattern {pattern} holds drum notes but parameter 86 bit 6 is clear")
    elif seq_notes:
        mode = PatternMode.SEQ
        if drum_mode:
            warnings.append(
                f"pattern {pattern} holds only melodic notes but parameter 86 bit 6 "
                f"says the track is in drum mode"
            )
    else:
        mode = PatternMode.EMPTY

    has_data = (
        raw.int_at(item_id, constants.P_PATTERN_DATA_STATE, pattern, default=0)
        == constants.PATTERN_HAS_DATA
    )
    if notes and not has_data:
        warnings.append(
            f"pattern {pattern} holds {len(notes)} notes but parameter 40 says it has no data"
        )

    timing = {NoteKind.SEQ: _read_timing(raw, item_id, pattern, NOTE_PARAMS[NoteKind.SEQ])}
    if is_drum_track:
        timing[NoteKind.DRUM] = _read_timing(raw, item_id, pattern, NOTE_PARAMS[NoteKind.DRUM])

    return Pattern(
        number=pattern,
        mode=mode,
        has_data=has_data,
        timing=timing,
        notes=notes,
        warnings=tuple(warnings),
    )


def _read_timing(
    raw: RawProject, item_id: ItemId, pattern: int, params: NoteParamSet
) -> PatternTiming:
    # Swing is unverified: MCC labels 97/114 a signed offset (-25..+25), which
    # would make it relative to the global 74 rather than absolute. Both
    # readings agree while the global is 50, true of every sample. T7.5.
    return PatternTiming(
        step_count=encoding.decode_step_count(
            raw.int_at(item_id, params.step_count, pattern, default=0)
        ),
        swing_percent=encoding.decode_swing(
            raw.int_at(item_id, params.swing, pattern, default=encoding.SWING_OFFSET)
        ),
    )


def _read_note_lists(
    raw: RawProject, item_id: ItemId, pattern: int, *, kind: NoteKind
) -> tuple[tuple[Note, ...], list[str]]:
    """Decode every polyphony slot of one pattern for one parameter set."""
    notes: list[Note] = []
    warnings: list[str] = []
    for slot in range(1, constants.SLOTS_BY_ITEM[item_id] + 1):
        slot_notes, slot_warnings = _read_slot(raw, item_id, pattern, slot, kind=kind)
        notes.extend(slot_notes)
        warnings.extend(slot_warnings)
    return tuple(notes), warnings


def _read_slot(
    raw: RawProject, item_id: ItemId, pattern: int, slot: int, *, kind: NoteKind
) -> tuple[list[Note], list[str]]:
    params = NOTE_PARAMS[kind]
    drum = kind is NoteKind.DRUM

    def column(param: ParamId) -> list[int | None]:
        return raw.array(item_id, param, pattern, slot, length=constants.MAX_STEPS)

    note_step = column(params.note_step)
    if note_step[0] is None:  # parameter set absent for this item
        return [], []

    pitch = column(params.pitch)
    velocity = column(params.velocity)
    if not slot_is_initialised(note_step, pitch, velocity):
        return [], []

    gate = column(params.gate)
    shift = column(params.time_shift)
    random = column(params.randomness)
    skip = column(params.skip)

    notes: list[Note] = []
    warnings: list[str] = []
    for i, step in enumerate(note_step):
        if step is None or step == constants.SENTINEL:
            # Note lists are packed contiguously from index 1, so the first
            # sentinel ends the list. Anything past it is stale data from an
            # earlier edit and must not be reported as a playing note.
            trailing = [v for v in note_step[i + 1 :] if v is not None and v != constants.SENTINEL]
            if trailing:
                warnings.append(
                    f"pattern {pattern} slot {slot}: {len(trailing)} value(s) after the "
                    f"end of the note list were ignored"
                )
            break

        raw_pitch = _required(pitch[i])
        skip_mask = skip[i if params.skip_is_note_indexed else step]
        notes.append(
            Note(
                kind=kind,
                slot=slot,
                index=NoteIndex(i + 1),
                step=Step(step + 1),
                pitch=Lane(raw_pitch) if drum else Pitch(raw_pitch),
                velocity=_required(velocity[i]),
                gate_raw=_required(gate[i]),
                gate=encoding.decode_gate(_required(gate[i])),
                time_shift=encoding.decode_time_shift(_required(shift[i])),
                randomness=_required(random[i]),
                skip=encoding.decode_skip_mask(skip_mask if skip_mask is not None else 0),
            )
        )

    if drum:
        # A lane outside 0-23 would mean parameter 117 is not the 0-based lane
        # index we think it is -- worth saying loudly rather than mapping it to
        # some note anyway.
        out_of_range = sorted({n.pitch for n in notes if n.pitch >= constants.DRUM_LANE_COUNT})
        if out_of_range:
            warnings.append(
                f"pattern {pattern} slot {slot}: drum lane(s) {out_of_range} are outside "
                f"0-{constants.DRUM_LANE_COUNT - 1}"
            )
    else:
        warnings.extend(_check_step_active(raw, item_id, pattern, slot, notes))
    return notes, warnings


def slot_is_initialised(
    note_step: Sequence[int | None], pitch: Sequence[int | None], velocity: Sequence[int | None]
) -> bool:
    """Distinguish a genuinely empty slot from an uninitialised one."""
    # Track 1's slot 4 is zero-filled rather than sentinel-filled, so read
    # literally it is 64 notes at step 1 with velocity 0. Spec 4, "the
    # zero-fill trap". The test is narrow on purpose: a real note list cannot
    # be uniformly zero across all three arrays.
    return not (
        all(v == 0 for v in note_step)
        and all(v == 0 for v in pitch)
        and all(v == 0 for v in velocity)
    )


def _check_step_active(
    raw: RawProject, item_id: ItemId, pattern: int, slot: int, notes: list[Note]
) -> list[str]:
    """Cross-check the note list against the redundant step-active array."""
    # Parameter 48 duplicates what the note list already carries, so comparing
    # them is close to free and catches a misread index space immediately. The
    # drum equivalent (52) is deliberately not checked: its packing does not
    # account for initial_project's values, so it is not understood well enough
    # to raise warnings from. Spec 5.
    active = raw.array(
        item_id, constants.P_SEQ_STEP_ACTIVE, pattern, slot, length=constants.MAX_STEPS
    )
    from_flags = {i + 1 for i, v in enumerate(active) if v == 1}
    from_notes = {n.step for n in notes}
    if from_flags == from_notes:
        return []
    return [
        f"pattern {pattern} slot {slot}: step-active flags disagree with the note list "
        f"(only in flags: {sorted(from_flags - from_notes)}, "
        f"only in notes: {sorted(from_notes - from_flags)})"
    ]


def _required(value: int | None) -> int:
    """Assert a note field is present."""
    # A note exists only because its note->step entry was populated, so every
    # sibling parameter must be too. A missing one means the file is unlike
    # anything we have seen, and guessing would be worse than stopping.
    if value is None:
        raise ValueError("note parameter missing where the note list says a note exists")
    return value
