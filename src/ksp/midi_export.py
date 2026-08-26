"""Rendering a decoded project as one or more Standard MIDI files."""

from collections.abc import Sequence
from dataclasses import dataclass, field, replace
from typing import Final

import mido

from ksp import constants
from ksp.diagnostics import EMPTY_REPORT, Code, Collector, Diagnostic, Report, Site
from ksp.drum_map import DEFAULT_DRUM_CHANNEL, DrumMap
from ksp.model import (
    Disablement,
    Note,
    NoteKind,
    Pattern,
    PlaybackDirection,
    Project,
    Track,
    disablement,
)

#: Divides by 3 and 4, so every step size and its triplet lands on a whole tick.
DEFAULT_TICKS_PER_BEAT: Final = 480

#: 1/32 needs 8 and a triplet needs 3, so ``ticks_per_beat`` must divide by 24.
TICKS_PER_BEAT_DIVISOR: Final = 24


#: The device's channel 10 default, rebased: MIDI counts channels from 0.
DRUM_CHANNEL: Final = DEFAULT_DRUM_CHANNEL - 1

#: Velocity 0 is silent on the device but a note-off in MIDI, so it exports as 1.
MIN_VELOCITY: Final = 1

#: The loudest a MIDI note-on can be. ``constants.SENTINEL`` is 127 too but
#: marks an empty slot, so this limit must not be spelled with it.
MAX_VELOCITY: Final = 127

#: What a flat render substitutes: the velocity a freshly placed note carries.
DEFAULT_FLAT_VELOCITY: Final = constants.FRESH_VELOCITY

#: How many times an arrangement may be laid down end to end. Not ``passes``.
MAX_REPEAT: Final = 10


def check_flat_velocity(velocity: int | None) -> None:
    """Shared by both directions; ``None`` means "leave every velocity alone"."""
    if velocity is not None and not MIN_VELOCITY <= velocity <= MAX_VELOCITY:
        raise ValueError(
            f"flat_velocity must be {MIN_VELOCITY}-{MAX_VELOCITY}; "
            "0 is a MIDI note-off, not a silent note"
        )


@dataclass(frozen=True)
class ExportOptions:
    """Everything the project file cannot tell us about timing and mapping."""

    ticks_per_beat: int = DEFAULT_TICKS_PER_BEAT
    drum_map: DrumMap = field(default_factory=DrumMap.chromatic)
    drum_channel: int = DRUM_CHANNEL
    default_gate: float = constants.DEFAULT_GATE_LENGTH
    """Length in steps for a gate off the 0-127 ladder, i.e. only on a corrupt file."""

    apply_swing: bool = True
    """Swing is applied with the standard meaning, which is not measured against
    the device. Off gives a flat grid."""

    apply_time_shift: bool = True
    """Displace each note by its stored time shift. Off gives a flat grid."""

    include_stale: bool = False
    """Export both note sets of a pattern holding both, not just the one 86 bit 6 plays."""

    include_disabled: bool = False
    """Export disabled notes, both kinds: step turned off, and past the last step."""

    markers: bool = True
    """Mark the start of every pattern with a marker meta event."""

    passes: int | None = None
    """How many of the four 16/32/48/64 repeats to render; ``None`` is auto.
    A single pass sounds every masked note at once, which is why auto is default."""

    flat_velocity: int | None = None
    """Render every note at this velocity instead of its own; ``None`` keeps the
    stored values. Written content, not audible: it sounds notes stored at 0."""

    repeat: int = 1
    """How many times to lay the whole export down end to end. Not ``passes``:
    export-only, and nothing writes it back to a project file."""

    def __post_init__(self) -> None:
        if self.ticks_per_beat < 1:
            raise ValueError("ticks_per_beat must be at least 1")
        if self.ticks_per_beat % TICKS_PER_BEAT_DIVISOR:
            raise ValueError(
                f"ticks_per_beat {self.ticks_per_beat} is not divisible by "
                f"{TICKS_PER_BEAT_DIVISOR}; the device's 1/4-1/32 step sizes and their "
                f"triplets would not land on exact ticks"
            )
        if not 0 <= self.drum_channel <= 15:
            raise ValueError("drum_channel must be 0-15")
        if self.default_gate <= 0:
            raise ValueError("default_gate must be greater than 0")
        if self.passes is not None and not 1 <= self.passes <= constants.SKIP_CYCLE_PASSES:
            raise ValueError(f"passes must be 1-{constants.SKIP_CYCLE_PASSES}, or None for auto")
        check_flat_velocity(self.flat_velocity)
        if not 1 <= self.repeat <= MAX_REPEAT:
            raise ValueError(f"repeat must be 1-{MAX_REPEAT}")


@dataclass(frozen=True)
class RenderedNote:
    """One note as a DAW will see it, in ticks. No MIDI library involved."""

    tick: int
    duration_ticks: int
    pitch: int
    velocity: int
    channel: int


@dataclass(frozen=True)
class Rendering:
    """One parameter set of one pattern, rendered from its own tick 0."""

    track_number: int
    kind: NoteKind
    pattern_number: int
    notes: tuple[RenderedNote, ...]
    length_ticks: int
    diagnostics: Report = EMPTY_REPORT

    @property
    def warnings(self) -> tuple[str, ...]:
        return self.diagnostics.messages

    @property
    def midi_track_name(self) -> str:
        if self.kind is NoteKind.DRUM:
            return f"Track {self.track_number} (drum)"
        return f"Track {self.track_number}"


@dataclass(frozen=True)
class ArrangedTrack:
    """One MIDI track's worth of notes, at absolute ticks."""

    name: str
    notes: tuple[RenderedNote, ...]


@dataclass(frozen=True)
class PatternBoundary:
    """Where one pattern starts on the timeline, and which pattern it is."""

    pattern_number: int
    tick: int

    @property
    def marker_text(self) -> str:
        return f"pattern {self.pattern_number}"


@dataclass(frozen=True)
class Arrangement:
    """Renderings placed on a timeline, ready to become a file."""

    tracks: tuple[ArrangedTrack, ...]
    length_ticks: int
    boundaries: tuple[PatternBoundary, ...]
    """Ascending by tick: the build layer walks them into MIDI deltas."""

    track_numbers: tuple[int, ...]
    diagnostics: Report = EMPTY_REPORT

    @property
    def pattern_numbers(self) -> tuple[int, ...]:
        # Which patterns are in this file, not how often each is played.
        return tuple(dict.fromkeys(b.pattern_number for b in self.boundaries))

    @property
    def warnings(self) -> tuple[str, ...]:
        return self.diagnostics.messages

    @property
    def note_count(self) -> int:
        return sum(len(t.notes) for t in self.tracks)


@dataclass(frozen=True)
class ExportResult:
    """A rendered file plus what the caller should be told about it."""

    midi: mido.MidiFile
    note_count: int
    pattern_numbers: tuple[int, ...]
    track_names: tuple[str, ...]
    diagnostics: Report
    track_numbers: tuple[int, ...] = ()
    """KeyStep Pro track numbers, which ``track_names`` is not: Track 1's drum
    set becomes a MIDI track of its own."""

    @property
    def warnings(self) -> tuple[str, ...]:
        return self.diagnostics.messages

    @property
    def is_empty(self) -> bool:
        return self.note_count == 0


def declared_step_count(pattern: Pattern, kind: NoteKind) -> int:
    """The step count the pattern declares for *kind*."""
    if kind is NoteKind.DRUM and pattern.drum_step_count is not None:
        return pattern.drum_step_count
    return pattern.seq_step_count


def ticks_per_step(pattern: Pattern, kind: NoteKind, ticks_per_beat: int) -> int:
    """How long one step of *pattern* is, from its own step size and triplet (spec 3.3)."""
    bits = pattern.bits(kind)
    ticks = ticks_per_beat * 4 // bits.step_denominator
    return ticks * 2 // 3 if bits.triplet else ticks


def auto_passes(notes: Sequence[Note]) -> int:
    """Four when any note sits out one of the four repeats, else one."""
    partial = any(len(n.skip) != constants.SKIP_CYCLE_PASSES for n in notes)
    return constants.SKIP_CYCLE_PASSES if partial else 1


def swing_percent(pattern: Pattern, kind: NoteKind) -> int:
    if kind is NoteKind.DRUM and pattern.drum_swing_percent is not None:
        return pattern.drum_swing_percent
    return pattern.seq_swing_percent


def step_count(pattern: Pattern, kind: NoteKind, notes: Sequence[Note] | None = None) -> int:
    """Declared length, widened to hold any note that sits past it.
    Pass the subset being exported so an omitted note does not stretch the pattern."""
    if notes is None:
        notes = pattern.notes_of(kind)
    return max(declared_step_count(pattern, kind), max((n.step for n in notes), default=0))


def render_pattern(
    pattern: Pattern, *, track_number: int, kind: NoteKind, options: ExportOptions | None = None
) -> Rendering:
    """Turn one parameter set of one pattern into plain tick data.
    Ticks count from the pattern's own start, so the caller decides where it sits."""
    options = options or ExportOptions()
    collector = Collector()
    site = Site(track=track_number, pattern=pattern.number, kind=kind.value)
    step_ticks = ticks_per_step(pattern, kind, options.ticks_per_beat)

    # Filter before measuring: a note the device does not play must not stretch
    # the pattern it sits in.
    last = declared_step_count(pattern, kind)
    playable = pattern.notes_of(kind)
    step_off = [n for n in playable if disablement(n, last) is Disablement.STEP_TURNED_OFF]
    past_last = [n for n in playable if disablement(n, last) is Disablement.PAST_LAST_STEP]
    said_step_off = False

    if options.include_disabled:
        if step_off or past_last:
            collector.add(
                Code.DISABLED_EXPORTED,
                f"{len(step_off) + len(past_last)} disabled note(s) were exported because "
                f"--include-disabled is set; the device does not play them",
                site=site,
                subjects=len(step_off) + len(past_last),
            )
    else:
        if step_off:
            collector.add(
                Code.DISABLED_NOT_EXPORTED,
                f"{len(step_off)} disabled note(s), step turned off, were not exported; "
                f"--include-disabled exports them",
                site=site,
                subjects=len(step_off),
            )
            said_step_off = True
        if past_last:
            collector.add(
                Code.DISABLED_PAST_LAST_STEP,
                f"{len(past_last)} disabled note(s), past the last step of {last}, were not "
                f"exported; --include-disabled exports them",
                site=site,
                subjects=len(past_last),
            )
        playable = tuple(n for n in playable if disablement(n, last) is None)

    steps = step_count(pattern, kind, playable)
    pass_ticks = steps * step_ticks
    passes = options.passes or auto_passes(playable)
    length_ticks = pass_ticks * passes
    swing = swing_percent(pattern, kind)
    channel = options.drum_channel if kind is NoteKind.DRUM else track_number - 1

    masked = [n for n in playable if len(n.skip) != constants.SKIP_CYCLE_PASSES]
    if masked and passes > 1:
        collector.add(
            Code.STEP_SKIP_EXPANDED,
            f"rendered as {passes} repeats so that {len(masked)} masked note(s) land on the "
            f"16/32/48/64 sequences they play in",
            site=site,
            subjects=len(masked),
        )
    elif masked:
        collector.add(
            Code.STEP_SKIP_SINGLE_PASS,
            f"{len(masked)} note(s) play on only some of the 16/32/48/64 sequences, which the "
            f"device runs as four repeats; one pass was rendered and all of them included",
            site=site,
            subjects=len(masked),
        )

    direction = pattern.bits(kind).direction
    if direction is not PlaybackDirection.FORWARD:
        collector.add(
            Code.DIRECTION_NOT_APPLIED,
            f"plays {direction.value}, which a MIDI file cannot express; the steps were "
            f"rendered in forward order",
            site=site,
        )

    if kind is NoteKind.DRUM:
        collector.add(
            Code.DRUM_MAP_ASSUMED,
            f"drum lanes resolved through the {options.drum_map.describe()} map on channel "
            f"{options.drum_channel + 1}; the KeyStep Pro drum map is a device global and is "
            f"not stored in the project file (spec 3.2.1)",
        )
        collector.extend(options.drum_map.diagnostics)
    if options.apply_swing and swing != constants.SWING_RANGE_PERCENT[0]:
        collector.add(
            Code.SWING_UNVERIFIED,
            f"uses {swing}% swing; the device delays the even steps, which is what was "
            f"exported, but how far one percent moves them is not measured",
            site=Site(pattern=pattern.number),
        )
    # The reader's own step-off finding is dropped where the export just said
    # the same thing and named the flag that brings the notes back.
    collector.extend(
        d.at(track=track_number)
        for d in pattern.diagnostics
        if not (said_step_off and d.code is Code.DISABLED_STEP_OFF)
    )

    # Rendered once per note, then replicated, so a per-note diagnostic is
    # collected once instead of four times.
    rendered_notes: list[tuple[Note, RenderedNote]] = []
    for note in playable:
        rendered = _render_note(note, kind, channel, swing, step_ticks, options, collector)
        if rendered is None:
            continue
        if rendered.tick + rendered.duration_ticks > pass_ticks:
            collector.add(
                Code.GATE_SHORTENED,
                "note(s) whose gate ran past the end of the pattern were shortened to it",
                site=Site(pattern=pattern.number),
            )
            rendered = replace(rendered, duration_ticks=max(1, pass_ticks - rendered.tick))
        rendered_notes.append((note, rendered))

    notes: list[RenderedNote] = []
    for index in range(passes):
        sequence = constants.SKIP_SEQUENCES[index]
        offset = index * pass_ticks
        for note, rendered in rendered_notes:
            # One pass renders everything: the mask has no meaning without the
            # repeats it selects between.
            if passes > 1 and sequence not in note.skip:
                continue
            notes.append(replace(rendered, tick=rendered.tick + offset) if offset else rendered)

    return Rendering(
        track_number=track_number,
        kind=kind,
        pattern_number=pattern.number,
        notes=tuple(notes),
        length_ticks=length_ticks,
        diagnostics=collector.report(),
    )


def _render_note(
    note: Note,
    kind: NoteKind,
    channel: int,
    swing: int,
    step_ticks: int,
    options: ExportOptions,
    collector: Collector,
) -> RenderedNote | None:
    pitch = note.pitch
    if kind is NoteKind.DRUM:
        if not options.drum_map.has_lane(note.pitch):
            collector.add(
                Code.DRUM_LANE_DROPPED,
                f"drum lane {note.pitch} is outside the device's "
                f"0-{constants.DRUM_LANE_COUNT - 1} lanes and was dropped",
            )
            return None
        pitch = options.drum_map.note_for_lane(note.pitch)

    tick = (note.step - 1) * step_ticks
    if options.apply_swing:
        tick += round(swing_delay(note.step - 1, swing, step_ticks))
    if options.apply_time_shift:
        # Independent of step size, so taken from the beat, not step_ticks.
        tick += constants.time_shift_ticks(note.time_shift, options.ticks_per_beat)

    gate = note.gate
    if gate is None:
        gate = options.default_gate
        collector.add(
            Code.GATE_OFF_LADDER,
            f"gate encoding {note.gate_raw} is off the 0-127 ladder and cannot be decoded; "
            f"exported at the {gate:g}-step default length",
        )
    return RenderedNote(
        tick=tick,
        duration_ticks=max(1, round(gate * step_ticks)),
        pitch=pitch,
        velocity=(
            options.flat_velocity
            if options.flat_velocity is not None
            else max(MIN_VELOCITY, note.velocity)
        ),
        channel=channel,
    )


def swing_delay(step: int, swing_percent: int, ticks_per_step: float) -> float:
    """Ticks the device delays *step* by. **0-based**: step 1 is the second of the
    pair, so a caller holding a 1-based note step must subtract one."""
    if not step % 2:
        return 0.0
    return float(round(ticks_per_step * (2 * swing_percent / 100 - 1)))


def _placed(note: RenderedNote, offset: int, collector: Collector) -> RenderedNote:
    """Move *note* onto the timeline, holding it at tick 0 if it lands before it."""
    tick = note.tick + offset
    if tick >= 0:
        return replace(note, tick=tick)
    collector.add(
        Code.TIME_SHIFT_CLIPPED,
        f"a note's time shift places it {-tick} tick(s) before the start of the export; "
        f"it was held at the start instead",
    )
    return replace(note, tick=0)


def arrange(renderings: Sequence[Rendering], *, repeat: int = 1) -> Arrangement:
    """Lay renderings end to end in pattern order, aligned across tracks.
    A pattern occupies the longest length any track gives it, so nothing drifts."""
    if not 1 <= repeat <= MAX_REPEAT:
        raise ValueError(f"repeat must be 1-{MAX_REPEAT}")

    collector = Collector()
    for rendering in renderings:
        collector.extend(rendering.diagnostics)

    lengths: dict[int, int] = {}
    for rendering in renderings:
        number = rendering.pattern_number
        lengths[number] = max(lengths.get(number, 0), rendering.length_ticks)

    offsets: dict[int, int] = {}
    cursor = 0
    for number in sorted(lengths):
        offsets[number] = cursor
        cursor += lengths[number]

    # A repeat is placed, not copied afterwards, so a note held past the end of
    # one round is resolved against the round that follows it.
    groups: dict[str, list[RenderedNote]] = {}
    for rendering in sorted(
        renderings, key=lambda r: (r.track_number, r.kind is NoteKind.DRUM, r.pattern_number)
    ):
        for repetition in range(repeat):
            offset = repetition * cursor + offsets[rendering.pattern_number]
            groups.setdefault(rendering.midi_track_name, []).extend(
                _placed(n, offset, collector) for n in rendering.notes
            )

    _warn_on_unequal_tracks(renderings, collector)
    tracks = tuple(
        ArrangedTrack(name=name, notes=_resolve_overlaps(notes, collector))
        for name, notes in groups.items()
        if notes
    )
    return Arrangement(
        tracks=tracks,
        length_ticks=cursor * repeat,
        boundaries=tuple(
            PatternBoundary(number, repetition * cursor + offsets[number])
            for repetition in range(repeat)
            for number in sorted(offsets)
        ),
        track_numbers=tuple(sorted({r.track_number for r in renderings})),
        diagnostics=collector.report(),
    )


def _warn_on_unequal_tracks(renderings: Sequence[Rendering], collector: Collector) -> None:
    """Say so when the tracks do not add up to the same length.
    This export restarts every track at each boundary; the device loops each on its own."""
    totals: dict[int, dict[int, int]] = {}
    for rendering in renderings:
        by_pattern = totals.setdefault(rendering.track_number, {})
        by_pattern[rendering.pattern_number] = max(
            by_pattern.get(rendering.pattern_number, 0), rendering.length_ticks
        )
    lengths = {track: sum(patterns.values()) for track, patterns in totals.items()}
    if len(set(lengths.values())) > 1:
        summary = ", ".join(f"track {t}: {n} ticks" for t, n in sorted(lengths.items()))
        collector.add(
            Code.TRACK_LENGTHS_DIFFER,
            f"tracks hold different total lengths ({summary}); this export aligns pattern N "
            f"across tracks, but the device loops each track on its own, so they drift apart",
        )


def _resolve_overlaps(notes: list[RenderedNote], collector: Collector) -> tuple[RenderedNote, ...]:
    """Stop a long gate from swallowing the next note of the same pitch.
    The device retriggers; most DAWs hang, so the earlier note is shortened."""
    ordered = sorted(notes, key=lambda n: (n.tick, n.pitch))
    resolved: list[RenderedNote] = []
    previous: dict[tuple[int, int], int] = {}  # (channel, pitch) -> index in resolved
    for note in ordered:
        key = (note.channel, note.pitch)
        index = previous.get(key)
        if index is not None:
            earlier = resolved[index]
            if earlier.tick + earlier.duration_ticks > note.tick:
                resolved[index] = replace(earlier, duration_ticks=max(1, note.tick - earlier.tick))
                collector.add(
                    Code.OVERLAPS_RESOLVED,
                    "overlapping note(s) of the same pitch were shortened so each has its "
                    "own note-off",
                )
        previous[key] = len(resolved)
        resolved.append(note)
    return tuple(resolved)


def build_midi_file(
    arrangement: Arrangement,
    *,
    name: str,
    tempo_bpm: float,
    ticks_per_beat: int,
    markers: bool = True,
) -> mido.MidiFile:
    """Turn an arrangement into a type-1 MIDI file. The only ``mido`` layer."""
    midi = mido.MidiFile(type=1, ticks_per_beat=ticks_per_beat)
    boundaries = arrangement.boundaries if markers else ()
    midi.tracks.append(
        _conductor_track(name, tempo_bpm, arrangement.length_ticks, boundaries=boundaries)
    )
    for track in arrangement.tracks:
        midi.tracks.append(_midi_track(track))
    return midi


def _conductor_track(
    name: str,
    tempo_bpm: float,
    total_ticks: int,
    *,
    boundaries: Sequence[PatternBoundary],
) -> mido.MidiTrack:
    """Track 0: name, tempo, time signature and the pattern markers, no notes."""
    # End-of-track sits at the end of the last pattern, not the last note, so a
    # DAW sees the arrangement's real length.
    track = mido.MidiTrack()
    track.append(mido.MetaMessage("track_name", name=name, time=0))
    track.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(tempo_bpm), time=0))
    track.append(mido.MetaMessage("time_signature", numerator=4, denominator=4, time=0))

    previous_tick = 0
    for boundary in boundaries:
        track.append(
            mido.MetaMessage(
                "marker", text=boundary.marker_text, time=boundary.tick - previous_tick
            )
        )
        previous_tick = boundary.tick
    track.append(mido.MetaMessage("end_of_track", time=total_ticks - previous_tick))
    return track


def _midi_track(arranged: ArrangedTrack) -> mido.MidiTrack:
    """Turn absolute-tick notes into a delta-time MIDI track."""
    track = mido.MidiTrack()
    track.append(mido.MetaMessage("track_name", name=arranged.name, time=0))

    # note_off sorts before note_on at the same tick so that a note retriggering
    # exactly where the previous one ends does not read as a hanging note.
    timed: list[tuple[int, int, mido.Message]] = []
    for note in arranged.notes:
        timed.append(
            (
                note.tick,
                1,
                mido.Message(
                    "note_on", note=note.pitch, velocity=note.velocity, channel=note.channel
                ),
            )
        )
        timed.append(
            (
                note.tick + note.duration_ticks,
                0,
                mido.Message("note_off", note=note.pitch, velocity=0, channel=note.channel),
            )
        )
    timed.sort(key=lambda item: (item[0], item[1], item[2].note))

    previous_tick = 0
    for tick, _, message in timed:
        track.append(message.copy(time=tick - previous_tick))
        previous_tick = tick
    track.append(mido.MetaMessage("end_of_track", time=0))
    return track


def export_project(project: Project, options: ExportOptions | None = None) -> ExportResult:
    """Render *project* as a single type-1 MIDI file.
    Only patterns holding notes are rendered; narrow with ``Project.select`` first."""
    options = options or ExportOptions()
    renderings = render_project(project, options)
    return _result(arrange(renderings, repeat=options.repeat), project, options)


def export_split(
    project: Project, options: ExportOptions | None = None
) -> tuple[ExportResult, ...]:
    """One file per non-empty (track, pattern), each starting at tick 0."""
    options = options or ExportOptions()
    parts: dict[tuple[int, int], list[Rendering]] = {}
    for rendering in render_project(project, options):
        # Track 1 can contribute a melodic *and* a drum rendering under
        # --include-stale; both belong to the same (track, pattern) file.
        parts.setdefault((rendering.track_number, rendering.pattern_number), []).append(rendering)

    results = []
    for _, group in sorted(parts.items()):
        result = _result(arrange(group, repeat=options.repeat), project, options)
        if not result.is_empty:
            results.append(result)
    return tuple(results)


def render_project(project: Project, options: ExportOptions | None = None) -> tuple[Rendering, ...]:
    """Render every (track, pattern, parameter set) that holds notes and plays.
    An auto pass count resolves per pattern *column*, so pattern N stays aligned."""
    options = options or ExportOptions()
    plans: list[tuple[Track, Pattern, NoteKind, Diagnostic | None]] = []
    for track in project.tracks:
        live = NoteKind.DRUM if track.drum_mode else NoteKind.SEQ
        for pattern in track.patterns:
            populated = [k for k in (NoteKind.SEQ, NoteKind.DRUM) if pattern.notes_of(k)]
            kinds = populated
            stale_diagnostic: Diagnostic | None = None
            if len(populated) > 1 and not options.include_stale:
                # Only when both sets hold notes does the flag have to decide; a
                # pattern holding one set is exported whatever the flag says.
                kinds = [live]
                stale = next(k for k in populated if k is not live)
                stale_diagnostic = Diagnostic(
                    Code.STALE_NOTE_SET,
                    f"holds both melodic ({len(pattern.notes_of(NoteKind.SEQ))}) and drum "
                    f"({len(pattern.notes_of(NoteKind.DRUM))}) notes; parameter 86 bit 6 says "
                    f"{live.value} plays, so the {stale.value} set was not exported "
                    f"(--include-stale exports both)",
                    site=Site(track=track.number, pattern=pattern.number),
                )
            for kind in kinds:
                plans.append((track, pattern, kind, stale_diagnostic))

    column_passes: dict[int, int] = {}
    for _, pattern, kind, _ in plans:
        number = pattern.number
        column_passes[number] = max(
            column_passes.get(number, 1), auto_passes(pattern.notes_of(kind))
        )

    renderings: list[Rendering] = []
    for track, pattern, kind, stale_diagnostic in plans:
        passes = options.passes or column_passes[pattern.number]
        rendering = render_pattern(
            pattern,
            track_number=track.number,
            kind=kind,
            options=replace(options, passes=passes),
        )
        if stale_diagnostic is not None:
            # This names the flag that brings the other set back, so the reader's
            # duplicate finding is dropped rather than printed alongside.
            kept = tuple(d for d in rendering.diagnostics if d.code is not Code.MIXED_NOTE_SETS)
            rendering = replace(rendering, diagnostics=Report((stale_diagnostic, *kept)))
        renderings.append(rendering)
    return tuple(renderings)


def _result(arrangement: Arrangement, project: Project, options: ExportOptions) -> ExportResult:
    diagnostics = arrangement.diagnostics
    # The per-pattern value takes precedence on the device, so the global is
    # reported rather than folded in.
    if options.apply_swing and project.global_swing_percent != constants.SWING_RANGE_PERCENT[0]:
        global_swing = Diagnostic(
            Code.GLOBAL_SWING_NOT_APPLIED,
            f"project sets a {project.global_swing_percent}% global swing (parameter 74); the "
            f"per-pattern value takes precedence on the device, so the global was not applied",
        )
        diagnostics = Report((global_swing, *diagnostics))
    return ExportResult(
        midi=build_midi_file(
            arrangement,
            name=project.source_name or project.device,
            tempo_bpm=project.tempo_bpm,
            ticks_per_beat=options.ticks_per_beat,
            markers=options.markers,
        ),
        note_count=arrangement.note_count,
        pattern_numbers=arrangement.pattern_numbers,
        track_names=tuple(t.name for t in arrangement.tracks),
        diagnostics=diagnostics,
        track_numbers=arrangement.track_numbers,
    )
