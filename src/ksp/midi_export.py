"""Rendering a decoded project as one or more Standard MIDI files.

The device does not store an arrangement -- it stores 4 tracks x 16 independent
patterns, each a loop. Turning that into a linear MIDI file means choosing a
layout, and there are two:

* **Merged** (the default) -- patterns that hold notes are laid end to end in
  pattern order, and pattern N starts at the same tick on every track, in a
  single file. Tracks therefore keep the relationship the hardware gives them
  (pattern N plays against pattern N), and patterns nobody uses take up no time.
* **Split** -- one file per non-empty (track, pattern), each starting at tick 0.
  No layout is invented at all; the caller reassembles them.

Two quantities the file does not tell us have to be supplied from outside, and
each is an :class:`ExportOptions` field rather than a buried literal:

* **Step size.** Held in the undecoded bitfield ``99``/``116`` (spec 3.3).
  Defaults to 1/16.
* **The drum map.** Lane -> MIDI note is a *device global*, explicitly not in
  the project file (spec 3.2.1), so a :class:`ksp.drum_map.DrumMap` is supplied
  and named in the output. MIDI has no way to express an unresolved lane, so
  unlike ``ksp-dump`` this cannot fall back to printing the lane number.

Gate length used to be a third; the ladder is now measured in full (spec 6.1),
so ``default_gate`` only covers a value off the 0-127 ladder -- corrupt input,
which is still warned about rather than rounded to the nearest rung.

The work is in three layers, so the M8/M9 Swift port translates arithmetic
rather than a MIDI library:

1. :func:`render_pattern` -- one pattern's notes become plain
   :class:`RenderedNote` data, ticks relative to the pattern's own start.
2. :func:`arrange` -- renderings are placed on a timeline and grouped into MIDI
   tracks, still as plain data.
3. :func:`build_midi_file` -- the only part that knows what ``mido`` is.

Nothing here reads or writes a path: the caller gets a ``mido.MidiFile`` and
decides where it goes.
"""

from collections.abc import Sequence
from dataclasses import dataclass, field, replace
from typing import Final

import mido

from ksp import constants
from ksp.diagnostics import EMPTY_REPORT, Code, Collector, Diagnostic, Report, Site
from ksp.drum_map import DEFAULT_DRUM_CHANNEL, DrumMap
from ksp.model import Note, NoteKind, Pattern, Project

#: 480 divides evenly by 3 and 4, so triplet step sizes stay exact if M6 ever
#: decodes the triplet bit.
DEFAULT_TICKS_PER_BEAT: Final = 480

#: 1/16 steps. The real value lives in the undecoded ``99``/``116`` bitfield;
#: 1/16 is the device's default and the only setting our sample projects use.
DEFAULT_STEPS_PER_BEAT: Final = 4

#: The device's Drum output default (``globalParamId 79``) is channel 10,
#: counting from 1; MIDI messages count channels from 0.
DRUM_CHANNEL: Final = DEFAULT_DRUM_CHANNEL - 1

#: A note stored with velocity 0 is silent on the device and would read as a
#: note-off in MIDI, which is a different thing. Exported at 1 instead.
MIN_VELOCITY: Final = 1


@dataclass(frozen=True)
class ExportOptions:
    """Everything the project file cannot tell us about timing and mapping."""

    ticks_per_beat: int = DEFAULT_TICKS_PER_BEAT
    steps_per_beat: int = DEFAULT_STEPS_PER_BEAT
    drum_map: DrumMap = field(default_factory=DrumMap.chromatic)
    drum_channel: int = DRUM_CHANNEL
    default_gate: float = constants.DEFAULT_GATE_LENGTH
    """Length in steps for a gate value off the 0-127 ladder. Every legal value
    decodes (spec 6.1), so this only fires on a corrupt file; it defaults to the
    length a freshly placed note has on the device."""

    apply_swing: bool = True
    """Swing percent is decoded, but its *timing* meaning is the standard
    one (the first of each step pair takes that share of the pair), which has
    not been measured against the device. Turn it off to get a flat grid."""

    include_stale: bool = False
    """Export both note sets of a pattern that holds both, rather than the one
    parameter 86 bit 6 says the device plays. Off by default: the point of a
    MIDI export is to hear what the hardware does."""

    include_disabled: bool = False
    """Export notes whose step is turned off. Off by default for the same
    reason as *include_stale*: the device does not play them (capture D1), so
    exporting them invents audio. Turn it on to see everything the file holds,
    e.g. to recover an edit that was disabled rather than deleted.

    Only this kind of disabled note is affected. Notes past the last step are
    also disabled, but they are exported either way -- see
    :func:`step_count`."""

    def __post_init__(self) -> None:
        if self.steps_per_beat < 1:
            raise ValueError("steps_per_beat must be at least 1")
        if self.ticks_per_beat < 1:
            raise ValueError("ticks_per_beat must be at least 1")
        if self.ticks_per_beat % self.steps_per_beat:
            raise ValueError(
                f"ticks_per_beat {self.ticks_per_beat} is not divisible by "
                f"steps_per_beat {self.steps_per_beat}; steps would not land on exact ticks"
            )
        if not 0 <= self.drum_channel <= 15:
            raise ValueError("drum_channel must be 0-15")
        if self.default_gate <= 0:
            raise ValueError("default_gate must be greater than 0")

    @property
    def ticks_per_step(self) -> int:
        return self.ticks_per_beat // self.steps_per_beat


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
class Arrangement:
    """Renderings placed on a timeline, ready to become a file."""

    tracks: tuple[ArrangedTrack, ...]
    length_ticks: int
    pattern_numbers: tuple[int, ...]
    track_numbers: tuple[int, ...]
    diagnostics: Report = EMPTY_REPORT

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
    """KeyStep Pro track numbers in this file -- what a split export names its
    files after. ``track_names`` holds the MIDI track names, which are not the
    same thing once Track 1's drum set becomes a track of its own."""

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


def swing_percent(pattern: Pattern, kind: NoteKind) -> int:
    if kind is NoteKind.DRUM and pattern.drum_swing_percent is not None:
        return pattern.drum_swing_percent
    return pattern.seq_swing_percent


def step_count(pattern: Pattern, kind: NoteKind, notes: Sequence[Note] | None = None) -> int:
    """Declared length, widened to hold any note that sits past it.

    *notes* defaults to every note of *kind*; pass the subset actually being
    exported so a note that is omitted does not stretch the pattern.
    """
    # A note past the declared count does not play on the device, but dropping
    # it silently would hide a real disagreement in the file.
    if notes is None:
        notes = pattern.notes_of(kind)
    return max(declared_step_count(pattern, kind), max((n.step for n in notes), default=0))


def render_pattern(
    pattern: Pattern, *, track_number: int, kind: NoteKind, options: ExportOptions | None = None
) -> Rendering:
    """Turn one parameter set of one pattern into plain tick data.

    Ticks count from the pattern's own start, so the caller decides where the
    pattern sits. This is where every timing decision is made and what the
    tests assert against.
    """
    options = options or ExportOptions()
    collector = Collector()
    site = Site(track=track_number, pattern=pattern.number, kind=kind.value)
    ticks_per_step = options.ticks_per_step

    # Filter before measuring: a note the device does not play must not
    # stretch the pattern it sits in.
    playable = pattern.notes_of(kind)
    said_step_off = False
    if not options.include_disabled:
        disabled = [n for n in playable if not n.active]
        if disabled:
            collector.add(
                Code.DISABLED_NOT_EXPORTED,
                f"{len(disabled)} disabled note(s), step turned off, were not exported; "
                f"--include-disabled exports them",
                site=site,
                subjects=len(disabled),
            )
            said_step_off = True
            playable = tuple(n for n in playable if n.active)

    steps = step_count(pattern, kind, playable)
    length_ticks = steps * ticks_per_step
    swing = swing_percent(pattern, kind)
    channel = options.drum_channel if kind is NoteKind.DRUM else track_number - 1

    if kind is NoteKind.DRUM:
        collector.add(
            Code.DRUM_MAP_ASSUMED,
            f"drum lanes resolved through the {options.drum_map.describe()} map on channel "
            f"{options.drum_channel + 1}; the KeyStep Pro drum map is a device global and is "
            f"not stored in the project file (spec 3.2.1)",
        )
        collector.extend(options.drum_map.diagnostics)
    if options.apply_swing and swing != 50:
        collector.add(
            Code.SWING_UNVERIFIED,
            f"uses {swing}% swing; exported with the standard swing interpretation, "
            f"which is not measured against the device",
            site=Site(pattern=pattern.number),
        )
    if steps > declared_step_count(pattern, kind):
        past = [n for n in playable if n.step > declared_step_count(pattern, kind)]
        collector.add(
            Code.DISABLED_PAST_LAST_STEP,
            f"{len(past)} disabled note(s), past the last step of "
            f"{declared_step_count(pattern, kind)}, so they do not play on the device; "
            f"exported anyway",
            site=site,
            subjects=len(past),
        )
    # A pattern the reader could not fully resolve produces MIDI that is
    # confidently wrong in a way the file itself will not reveal. The reader's
    # own step-off finding is dropped when the export has just said the same
    # thing more usefully -- it names the flag that brings the notes back.
    collector.extend(
        d.at(track=track_number)
        for d in pattern.diagnostics
        if not (said_step_off and d.code is Code.DISABLED_STEP_OFF)
    )

    notes: list[RenderedNote] = []
    for note in playable:
        rendered = _render_note(note, kind, channel, swing, options, collector)
        if rendered is None:
            continue
        if rendered.tick + rendered.duration_ticks > length_ticks:
            collector.add(
                Code.GATE_SHORTENED,
                "note(s) whose gate ran past the end of the pattern were shortened to it",
                site=Site(pattern=pattern.number),
            )
            rendered = replace(rendered, duration_ticks=max(1, length_ticks - rendered.tick))
        notes.append(rendered)

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
    options: ExportOptions,
    collector: Collector,
) -> RenderedNote | None:
    ticks_per_step = options.ticks_per_step
    pitch = note.pitch
    if kind is NoteKind.DRUM:
        # A lane the device does not have means parameter 117 is not the
        # 0-based lane index we think it is. The reader already warns; here
        # there is simply no note to emit, so the note is dropped loudly.
        if not options.drum_map.has_lane(note.pitch):
            collector.add(
                Code.DRUM_LANE_DROPPED,
                f"drum lane {note.pitch} is outside the device's "
                f"0-{constants.DRUM_LANE_COUNT - 1} lanes and was dropped",
            )
            return None
        pitch = options.drum_map.note_for_lane(note.pitch)

    if note.time_shift:
        collector.add(
            Code.TIME_SHIFT_NOT_APPLIED,
            "note(s) carry a non-zero time shift; its timing encoding is not measured, "
            "so the shift was not applied",
        )
    if len(note.skip) != len(constants.SKIP_SEQUENCES):
        collector.add(
            Code.STEP_SKIP_SINGLE_PASS,
            "note(s) are set to play on only some of the 16/32/48/64 sequences; the export "
            "renders one pass of each pattern and includes them all",
        )

    tick = (note.step - 1) * ticks_per_step
    if options.apply_swing:
        tick += _swing_delay(note.step, swing, ticks_per_step)

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
        duration_ticks=max(1, round(gate * ticks_per_step)),
        pitch=pitch,
        velocity=max(MIN_VELOCITY, note.velocity),
        channel=channel,
    )


def _swing_delay(step: int, swing_percent: int, ticks_per_step: int) -> int:
    """Delay applied to the second step of each pair."""
    # Standard swing: at p percent the first step of a pair takes p of the
    # pair, so the second starts 2*p/100 - 1 steps late. 50% is no swing.
    if step % 2:
        return 0
    return round(ticks_per_step * (2 * swing_percent / 100 - 1))


def arrange(renderings: Sequence[Rendering]) -> Arrangement:
    """Lay renderings end to end in pattern order, aligned across tracks.

    A pattern occupies the longest length any track gives it, so tracks of
    unequal length stay aligned at every pattern boundary instead of drifting.
    """
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

    groups: dict[str, list[RenderedNote]] = {}
    for rendering in sorted(
        renderings, key=lambda r: (r.track_number, r.kind is NoteKind.DRUM, r.pattern_number)
    ):
        offset = offsets[rendering.pattern_number]
        groups.setdefault(rendering.midi_track_name, []).extend(
            replace(n, tick=n.tick + offset) for n in rendering.notes
        )

    _warn_on_unequal_tracks(renderings, collector)
    tracks = tuple(
        ArrangedTrack(name=name, notes=_resolve_overlaps(notes, collector))
        for name, notes in groups.items()
        if notes
    )
    return Arrangement(
        tracks=tracks,
        length_ticks=cursor,
        pattern_numbers=tuple(sorted(offsets)),
        track_numbers=tuple(sorted({r.track_number for r in renderings})),
        diagnostics=collector.report(),
    )


def _warn_on_unequal_tracks(renderings: Sequence[Rendering], collector: Collector) -> None:
    """Say so when the tracks do not add up to the same length.

    This export restarts every track at each pattern boundary; the device
    loops each track independently, so from the first mismatch onwards the
    hardware and the file no longer agree about what plays together.
    """
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
    """Stop a long gate from swallowing the next note of the same pitch."""
    # Two note-ons for one pitch with one note-off between them hangs in most
    # DAWs. The device retriggers, so the earlier note is shortened instead.
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
    arrangement: Arrangement, *, name: str, tempo_bpm: float, ticks_per_beat: int
) -> mido.MidiFile:
    """Turn an arrangement into a type-1 MIDI file. The only ``mido`` layer."""
    midi = mido.MidiFile(type=1, ticks_per_beat=ticks_per_beat)
    midi.tracks.append(_conductor_track(name, tempo_bpm, arrangement.length_ticks))
    for track in arrangement.tracks:
        midi.tracks.append(_midi_track(track))
    return midi


def _conductor_track(name: str, tempo_bpm: float, total_ticks: int) -> mido.MidiTrack:
    """Track 0: name, tempo and time signature, no notes."""
    # End-of-track sits at the end of the last pattern rather than the last
    # note, so a DAW sees the arrangement's real length.
    track = mido.MidiTrack()
    track.append(mido.MetaMessage("track_name", name=name, time=0))
    track.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(tempo_bpm), time=0))
    track.append(mido.MetaMessage("time_signature", numerator=4, denominator=4, time=0))
    track.append(mido.MetaMessage("end_of_track", time=total_ticks))
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

    Only patterns holding notes are rendered; narrow with
    :meth:`ksp.model.Project.select` first to pick one track or pattern.
    """
    options = options or ExportOptions()
    renderings = render_project(project, options)
    return _result(arrange(renderings), project, options)


def export_split(
    project: Project, options: ExportOptions | None = None
) -> tuple[ExportResult, ...]:
    """One file per non-empty (track, pattern), each starting at tick 0.

    Nothing is laid out across patterns, so this is the layout that invents
    least; the caller names the files from each result's ``track_numbers`` and
    ``pattern_numbers``.
    """
    options = options or ExportOptions()
    parts: dict[tuple[int, int], list[Rendering]] = {}
    for rendering in render_project(project, options):
        # Track 1 can contribute a melodic *and* a drum rendering under
        # --include-stale; both belong to the same (track, pattern) file.
        parts.setdefault((rendering.track_number, rendering.pattern_number), []).append(rendering)

    results = []
    for _, group in sorted(parts.items()):
        result = _result(arrange(group), project, options)
        if not result.is_empty:
            results.append(result)
    return tuple(results)


def render_project(project: Project, options: ExportOptions | None = None) -> tuple[Rendering, ...]:
    """Render every (track, pattern, parameter set) that holds notes and plays.

    Track 1 can hold a melodic *and* a drum set in the same pattern -- leftovers
    from before the track was switched over. Parameter 86 bit 6 says which one
    the device plays, so only that one is exported; the other would be notes no
    hardware ever produces.
    """
    options = options or ExportOptions()
    renderings: list[Rendering] = []
    for track in project.tracks:
        live = NoteKind.DRUM if track.drum_mode else NoteKind.SEQ
        for pattern in track.patterns:
            populated = [k for k in (NoteKind.SEQ, NoteKind.DRUM) if pattern.notes_of(k)]
            kinds = populated
            stale_diagnostic: Diagnostic | None = None
            if len(populated) > 1 and not options.include_stale:
                # Only when both sets hold notes does the flag have to decide.
                # A pattern holding just one set is exported whatever the flag
                # says -- the reader already warns about that disagreement, and
                # dropping real user data over it would be worse.
                kinds = [live]
                stale = next(k for k in populated if k is not live)
                # Carries the counts the reader's own line has, so that line
                # can be dropped below without losing anything.
                stale_diagnostic = Diagnostic(
                    Code.STALE_NOTE_SET,
                    f"holds both melodic ({len(pattern.notes_of(NoteKind.SEQ))}) and drum "
                    f"({len(pattern.notes_of(NoteKind.DRUM))}) notes; parameter 86 bit 6 says "
                    f"{live.value} plays, so the {stale.value} set was not exported "
                    f"(--include-stale exports both)",
                    site=Site(track=track.number, pattern=pattern.number),
                )
            for kind in kinds:
                rendering = render_pattern(
                    pattern, track_number=track.number, kind=kind, options=options
                )
                if stale_diagnostic is not None:
                    # The reader says the same pattern holds both sets. This
                    # says that *and* which flag brings the other one back, so
                    # its duplicate is dropped rather than printed alongside.
                    kept = tuple(
                        d for d in rendering.diagnostics if d.code is not Code.MIXED_NOTE_SETS
                    )
                    rendering = replace(
                        rendering,
                        diagnostics=Report((stale_diagnostic, *kept)),
                    )
                renderings.append(rendering)
    return tuple(renderings)


def _result(arrangement: Arrangement, project: Project, options: ExportOptions) -> ExportResult:
    return ExportResult(
        midi=build_midi_file(
            arrangement,
            name=project.source_name or project.device,
            tempo_bpm=project.tempo_bpm,
            ticks_per_beat=options.ticks_per_beat,
        ),
        note_count=arrangement.note_count,
        pattern_numbers=arrangement.pattern_numbers,
        track_names=tuple(t.name for t in arrangement.tracks),
        diagnostics=arrangement.diagnostics,
        track_numbers=arrangement.track_numbers,
    )
