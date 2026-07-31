"""Decoding a flat ``.KeyStepPro`` dict into the object model.

The whole difficulty of this milestone is in one place: within a single
``(track, pattern, slot)`` the trailing index means two different things
depending on the parameter.

* **Step-indexed** -- 48 (step active) and 49 (melodic step skip): the index
  is a physical step, 1-64.
* **Note-indexed** -- 50/54 (note -> step) and 109-113 / 117-121: the index is
  an ordinal in a compact note list, and 50 (or 54 for drums) says which step
  that note sits on.

So the device does not store a step grid of note data. It stores an event list
plus a separate per-step activity array. Reading it with a single index space
produces values that look almost right, which is worse than values that look
wrong. Spec section 4.
"""

from collections.abc import Sequence
from pathlib import Path
from typing import Any

from ksp import constants, lenient_json
from ksp.keys import get_int, read_array
from ksp.model import Note, NoteKind, Pattern, PatternMode, Project, Track


def load(path: Path | str) -> Project:
    """Read and decode a ``.KeyStepPro`` file."""
    path = Path(path)
    return read_project(lenient_json.load_path(path), source_name=path.name)


def read_project(raw: dict[str, Any], source_name: str = "") -> Project:
    """Decode an already-parsed project dict."""
    warnings: list[str] = []

    device = raw.get("device")
    if not isinstance(device, str):
        raise ValueError("not a KeyStepPro project: missing 'device'")

    version = raw.get("version")
    if version is None:
        # The factory Default.KeyStepPro omits it; user saves carry it. Worth
        # surfacing because M5 has to inject it when using the factory file as
        # a template.
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
        global_swing_percent=_scalar(
            raw, constants.ITEM_PROJECT, constants.P_GLOBAL_SWING, default=50
        ),
        current_scene=_scalar(raw, constants.ITEM_PROJECT, constants.P_CURRENT_SCENE, default=0)
        + 1,
        tracks=tracks,
        source_name=source_name,
        warnings=tuple(warnings),
    )


def _scalar(raw: dict[str, Any], item: int, param: int, *indices: int, default: int) -> int:
    value = get_int(raw, item, param, *indices)
    return default if value is None else value


def _read_tempo(raw: dict[str, Any]) -> float:
    """Reassemble the project tempo from its three 7-bit chunks.

    Little-endian, holding BPM x 100. Verified against both saved projects:
    96 + 93*128 = 12000 -> 120.00, and 16 + 103*128 = 13200 -> 132.00.
    """
    lsb = _scalar(raw, constants.ITEM_PROJECT, constants.P_TEMPO_LSB, default=0)
    midsb = _scalar(raw, constants.ITEM_PROJECT, constants.P_TEMPO_MIDSB, default=0)
    msb = _scalar(raw, constants.ITEM_PROJECT, constants.P_TEMPO_MSB, default=0)
    hundredths = lsb + midsb * constants.TEMPO_CHUNK + msb * constants.TEMPO_CHUNK**2
    return hundredths / constants.TEMPO_SCALE


def _read_track(raw: dict[str, Any], number: int, item_id: int) -> Track:
    drum_mode = _read_drum_mode(raw, item_id)
    patterns = tuple(
        _read_pattern(raw, item_id, p, drum_mode=drum_mode)
        for p in range(1, constants.PATTERNS_PER_TRACK + 1)
    )
    return Track(number=number, item_id=item_id, patterns=patterns, drum_mode=drum_mode)


def _read_drum_mode(raw: dict[str, Any], item_id: int) -> bool:
    """Whether this track is in DRUM mode, from parameter 86 bit 6.

    Only Track 1 has a drum parameter set, so the bit is only meaningful
    there; MCC names the field "Arp/Drum mode state : bit 6", which on tracks
    2-4 presumably means ARP. Reported as False for those rather than
    pretending it says something about drums.
    """
    if item_id != constants.DRUM_TRACK_ITEM_ID:
        return False
    bits = _scalar(raw, item_id, constants.P_TRACK_MODE_BITS, default=0)
    return bool(bits & (1 << constants.DRUM_MODE_BIT))


def _read_pattern(
    raw: dict[str, Any], item_id: int, pattern: int, *, drum_mode: bool = False
) -> Pattern:
    """Decode one pattern from whichever parameter set(s) hold notes.

    Track 1 carries a melodic and a drum set side by side and plays one or the
    other. The mode bitfield documented for this (parameter 100) does not
    work -- it reads 26 in every pattern of every sample project, including
    ones that are unambiguously melodic and ones that are unambiguously drum.
    The flag that *does* work is parameter 86 bit 6, read per track and passed
    in as *drum_mode*.

    Note content alone is not always decisive: ``initial_project`` Track 1
    pattern 1 holds a real 64-note melody *and* a real 12-note drum pattern.
    The mode flag resolves which of those the device plays, but every note is
    still reported and the leftover set is called out in a warning -- a reader
    that silently discarded real user data would hide exactly the surprises
    this milestone exists to find.
    """
    warnings: list[str] = []

    seq_notes, seq_warnings = _read_note_lists(raw, item_id, pattern, kind=NoteKind.SEQ)
    drum_notes: tuple[Note, ...] = ()
    drum_warnings: list[str] = []
    if item_id == constants.DRUM_TRACK_ITEM_ID:
        drum_notes, drum_warnings = _read_note_lists(raw, item_id, pattern, kind=NoteKind.DRUM)

    notes = seq_notes + drum_notes
    warnings += seq_warnings + drum_warnings

    if seq_notes and drum_notes:
        # Both sets hold notes, so the mode flag decides. The other set is
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
        _scalar(raw, item_id, constants.P_PATTERN_DATA_STATE, pattern, default=0)
        == constants.PATTERN_HAS_DATA
    )
    if notes and not has_data:
        warnings.append(
            f"pattern {pattern} holds {len(notes)} notes but parameter 40 says it has no data"
        )

    is_drum_track = item_id == constants.DRUM_TRACK_ITEM_ID
    return Pattern(
        number=pattern,
        mode=mode,
        has_data=has_data,
        seq_step_count=_step_count(raw, item_id, constants.P_SEQ_STEP_COUNT, pattern),
        seq_swing_percent=_swing(raw, item_id, constants.P_SEQ_SWING, pattern),
        drum_step_count=(
            _step_count(raw, item_id, constants.P_DRUM_STEP_COUNT, pattern)
            if is_drum_track
            else None
        ),
        drum_swing_percent=(
            _swing(raw, item_id, constants.P_DRUM_SWING, pattern) if is_drum_track else None
        ),
        notes=notes,
        warnings=tuple(warnings),
    )


def _step_count(raw: dict[str, Any], item_id: int, param: int, pattern: int) -> int:
    """Step counts are stored 0-based: 15 means a 16-step pattern."""
    return _scalar(raw, item_id, param, pattern, default=0) + constants.STEP_COUNT_OFFSET


def _swing(raw: dict[str, Any], item_id: int, param: int, pattern: int) -> int:
    """Swing is stored with a +25 offset: 25 means 50%, i.e. no swing.

    Unverified: MCC labels 97/114 a *signed offset* (-25%..+25%), which would
    make this an offset from the global 74 rather than an absolute percentage.
    Both readings agree while the global is 50 -- true of every sample file --
    so nothing here distinguishes them. Protocol T7.5 decides it.
    """
    return (
        _scalar(raw, item_id, param, pattern, default=constants.SWING_OFFSET)
        + constants.SWING_OFFSET
    )


def _read_note_lists(
    raw: dict[str, Any], item_id: int, pattern: int, *, kind: NoteKind
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
    raw: dict[str, Any], item_id: int, pattern: int, slot: int, *, kind: NoteKind
) -> tuple[list[Note], list[str]]:
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
    # Melodic step skip is step-indexed; the drum equivalent is note-indexed.
    # This asymmetry is not a typo -- it is what the files consistently show.
    skip = column(constants.P_DRUM_STEP_SKIP if drum else constants.P_SEQ_STEP_SKIP)

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

        skip_index = i if drum else step
        skip_mask = skip[skip_index]
        notes.append(
            Note(
                kind=kind,
                slot=slot,
                index=i + 1,
                step=step + 1,
                pitch=_required(pitch[i]),
                velocity=_required(velocity[i]),
                gate_raw=_required(gate[i]),
                gate=constants.decode_gate(_required(gate[i])),
                time_shift=_required(shift[i]) - constants.TIME_SHIFT_CENTRE,
                randomness=_required(random[i]),
                skip=constants.decode_skip_mask(skip_mask if skip_mask is not None else 0),
            )
        )

    if drum:
        # The device has 24 lanes (MCC's Drum Map defines Note 1..Note 24), so
        # a lane outside 0-23 would mean parameter 117 is not the 0-based lane
        # index we think it is. Worth saying loudly rather than mapping it to
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
    """Distinguish a genuinely empty slot from an uninitialised one.

    An unused slot is normally sentinel-filled, and the ``127`` in its first
    note->step entry ends the list immediately. Slot 4 of Track 1 is the
    exception: it is filled with **zeros**, in all 16 patterns of all five
    sample projects -- including both empty baselines and real user material --
    for both the melodic and drum parameter sets. Taken at face value that
    reads as 64 notes at step 1 with velocity 0, i.e. 128 phantom notes per
    pattern in a file that holds nothing.

    Zero-fill is therefore treated as uninitialised. The test is deliberately
    narrow: all three of note->step, pitch and velocity uniformly zero. A real
    note list cannot look like that, because a note with velocity 0 makes no
    sound and 64 notes cannot all share step 1.
    """
    return not (
        all(v == 0 for v in note_step)
        and all(v == 0 for v in pitch)
        and all(v == 0 for v in velocity)
    )


def _check_step_active(
    raw: dict[str, Any], item_id: int, pattern: int, slot: int, notes: list[Note]
) -> list[str]:
    """Cross-check the note list against the redundant step-active array.

    Parameter 48 marks which steps are active and duplicates information the
    note list already carries. Comparing them is close to free and catches a
    misread index space immediately, so it runs on every slot.

    The drum equivalent (parameter 52, a packed bitmask) is deliberately not
    checked. Its 8-steps-per-index packing reproduces exactly on the two
    hardware-confirmed projects but does not account for the values in
    ``initial_project``, which is real user material rather than throwaway
    data -- so the packing is not understood well enough to raise warnings
    from. Notes come from the note list, which is the authoritative source.
    """
    active = read_array(
        raw, item_id, constants.P_SEQ_STEP_ACTIVE, pattern, slot, length=constants.MAX_STEPS
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
    """Assert a note field is present.

    A note exists only because its note->step entry was populated, so every
    sibling parameter must be too. If one is missing the file is structurally
    unlike anything we have seen and guessing a value would be worse than
    stopping.
    """
    if value is None:
        raise ValueError("note parameter missing where the note list says a note exists")
    return value
