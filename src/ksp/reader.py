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

The two parameter sets are also scanned by **different rules**, which is not a
typo. Spec section 4's "packed contiguously from index 1, with no gaps" is a
rule for *writers*; only the melodic set is observably compacted. The drum
array is a pool: deleting a note empties its entry and leaves later ones in
place, so a ``127`` marks an empty *entry*, not the end of the list. Melodic
therefore stops at the first sentinel and drum skips past it. Reading the drum
set with the melodic rule discards live notes -- 43 of them in
``initial_project`` alone -- and then reports their step-active flags as notes
the file has lost.
"""

from collections.abc import Sequence
from functools import lru_cache
from pathlib import Path
from typing import Any

from ksp import constants, lenient_json
from ksp.diagnostics import Code, Collector, Diagnostic, Site
from ksp.keys import get_int, read_array
from ksp.model import Note, NoteKind, Pattern, PatternMode, Project, Track


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
        # The factory Default.KeyStepPro omits it; user saves carry it. Worth
        # surfacing because M5 has to inject it when using the factory file as
        # a template.
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
        source_name=source_name,
        diagnostics=collector.report(),
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
        # Both sets hold notes, so the mode flag decides. The other set is
        # leftovers from before the track was switched over.
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
        diagnostics=collector.report(),
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
) -> tuple[tuple[Note, ...], list[Diagnostic]]:
    """Decode every pool chunk of one pattern for one parameter set.

    The step-active flags are pattern-wide, so they are decoded once here and
    handed to each chunk rather than re-read per chunk or per note.
    """
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

    Melodic (``48``) is one entry per step and lives wholly in chunk 1 in
    every file observed, so the result is a set of steps. Drum (``52``) is
    per lane, so the result is a set of ``(lane, step)`` pairs -- see
    ``constants.drum_step_active_indices`` for the packing.
    """
    if kind is NoteKind.SEQ:
        flags = read_array(
            raw, item_id, constants.P_SEQ_STEP_ACTIVE, pattern, 1, length=constants.MAX_STEPS
        )
        return frozenset(step for step, value in enumerate(flags) if value == 1)

    # Read the flat array once and unpack, rather than locating each bit
    # individually -- the same 256 entries back every one of the 24 x 64
    # lane/step questions.
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
    # Melodic step skip is step-indexed; the drum equivalent is note-indexed.
    # This asymmetry is not a typo -- it is what the files consistently show.
    skip = column(constants.P_DRUM_STEP_SKIP if drum else constants.P_SEQ_STEP_SKIP)

    notes: list[Note] = []
    diagnostics: list[Diagnostic] = []
    for i, step in enumerate(note_step):
        if step is None:  # ran off the end of the stored array
            break
        if step == constants.SENTINEL:
            if drum:
                # The drum array is a pool with holes, not a compacted list:
                # deleting a note empties its entry and leaves the ones after
                # it where they are. Skip the hole and keep scanning, or the
                # rest of the pattern is silently discarded.
                continue
            # Melodic lists really are compacted, so the first sentinel ends
            # the list and anything past it is stale from an earlier edit.
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
        # For drums the flags are per lane, so the note's own value selects
        # the row; melodic flags are a single per-step array.
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
        # The device has 24 lanes (MCC's Drum Map defines Note 1..Note 24), so
        # a lane outside 0-23 would mean parameter 117 is not the 0-based lane
        # index we think it is. Worth saying loudly rather than mapping it to
        # some note anyway.
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
    pattern: int, notes: list[Note], active: frozenset[Any], *, kind: NoteKind
) -> list[Diagnostic]:
    """Cross-check the note list against the step-active flags.

    The two are not redundant -- the device plays the flags, so a pooled note
    whose flag is clear is silent (capture D1). Two things are worth saying:
    a flag with no note behind it, and pooled notes that will not sound, which
    is the case that used to become phantom MIDI.

    Every flagged step having a pooled note is an *invariant*, verified across
    all five sample files. So a violation says our decode is wrong, not that
    the file is damaged -- which is exactly how it presented before the drum
    pool scan learned to skip holes.
    """
    diagnostics: list[Diagnostic] = []
    site = Site(pattern=pattern, kind=kind.value)

    # Drum flags are per lane, so compare (lane, step) pairs -- a union over
    # lanes would hide a flag whose lane holds nothing.
    if kind is NoteKind.SEQ:
        # Built once, as in the drum branch below: inside the comprehension's
        # condition it would be rebuilt for every flagged step, making the scan
        # cost |active| * |notes| rather than |active| + |notes|.
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
    """Assert a note field is present.

    A note exists only because its note->step entry was populated, so every
    sibling parameter must be too. If one is missing the file is structurally
    unlike anything we have seen and guessing a value would be worse than
    stopping.
    """
    if value is None:
        raise ValueError("note parameter missing where the note list says a note exists")
    return value
