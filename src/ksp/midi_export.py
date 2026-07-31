"""Rendering a decoded project as a Standard MIDI file.

The device does not store an arrangement -- it stores 4 tracks x 16 independent
patterns, each a loop. Turning that into a linear MIDI file means choosing a
layout, and the one here is: **patterns that hold notes are laid end to end in
pattern order, and pattern N starts at the same tick on every track.** Tracks
therefore keep the relationship the hardware gives them (pattern N plays
against pattern N), and patterns nobody uses take up no time.

Three quantities the file does not tell us have to be supplied from outside,
and each is an :class:`ExportOptions` field rather than a buried literal:

* **Step size.** Held in the undecoded bitfield ``99``/``116`` (spec 3.3).
  Defaults to 1/16.
* **The drum map.** Lane -> MIDI note is a *device global*, explicitly not in
  the project file (spec 3.4), so lane 0 is mapped to MIDI 36 by the General
  MIDI convention and the export says so.
* **Gate length.** Only six encodings are hardware-confirmed (spec 6).
  Anything else is exported at the device's own default note length and
  warned about, never interpolated -- see :mod:`ksp.constants`.

Nothing here reads or writes a path: the caller gets a ``mido.MidiFile`` and
decides where it goes.
"""

from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from typing import Final

import mido

from ksp import constants
from ksp.model import Note, NoteKind, Pattern, Project

#: 480 divides evenly by 3 and 4, so triplet step sizes stay exact if M6 ever
#: decodes the triplet bit.
DEFAULT_TICKS_PER_BEAT: Final = 480

#: 1/16 steps. The real value lives in the undecoded ``99``/``116`` bitfield;
#: 1/16 is the device's default and the only setting our sample projects use.
DEFAULT_STEPS_PER_BEAT: Final = 4

#: MIDI channel 10, where every DAW expects percussion.
DRUM_CHANNEL: Final = 9

#: General MIDI bass drum. Drum lanes are exported as consecutive notes from
#: here, which is a *convention*, not something decoded from the file.
DRUM_LANE_BASE: Final = 36

#: A note stored with velocity 0 is silent on the device and would read as a
#: note-off in MIDI, which is a different thing. Exported at 1 instead.
MIN_VELOCITY: Final = 1


@dataclass(frozen=True)
class ExportOptions:
    """Everything the project file cannot tell us about timing and mapping."""

    ticks_per_beat: int = DEFAULT_TICKS_PER_BEAT
    steps_per_beat: int = DEFAULT_STEPS_PER_BEAT
    drum_lane_base: int = DRUM_LANE_BASE
    drum_channel: int = DRUM_CHANNEL
    apply_swing: bool = True
    """Swing percent is decoded, but its *timing* meaning is the standard
    one (the first of each step pair takes that share of the pair), which has
    not been measured against the device. Turn it off to get a flat grid."""

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
        if not 0 <= self.drum_lane_base <= 127:
            raise ValueError("drum_lane_base must be a MIDI note, 0-127")

    @property
    def ticks_per_step(self) -> int:
        return self.ticks_per_beat // self.steps_per_beat


@dataclass(frozen=True)
class ExportResult:
    """A rendered file plus what the caller should be told about it."""

    midi: mido.MidiFile
    note_count: int
    pattern_numbers: tuple[int, ...]
    track_names: tuple[str, ...]
    warnings: tuple[str, ...]

    @property
    def is_empty(self) -> bool:
        return self.note_count == 0


@dataclass
class _Event:
    """A note being placed. Mutable because overlap resolution shortens it."""

    start: int
    end: int
    pitch: int
    velocity: int
    channel: int


@dataclass
class _Warnings:
    """Deduplicating, order-preserving warning collector.

    One misread gate encoding usually affects dozens of notes; repeating the
    same line dozens of times would bury the ones that only happened once.
    """

    _lines: list[str] = field(default_factory=list)
    _seen: set[str] = field(default_factory=set)

    def add(self, line: str) -> None:
        if line not in self._seen:
            self._seen.add(line)
            self._lines.append(line)

    def extend(self, lines: Iterable[str]) -> None:
        for line in lines:
            self.add(line)

    def tuple(self) -> tuple[str, ...]:
        return tuple(self._lines)


@dataclass(frozen=True)
class _Region:
    """One parameter set of one pattern, ready to be placed on the timeline."""

    track_number: int
    kind: NoteKind
    pattern: Pattern
    notes: tuple[Note, ...]

    @property
    def step_count(self) -> int:
        """Declared length, widened to hold any note that sits past it.

        A note beyond the declared step count does not play on the device, but
        dropping it silently would hide a real disagreement in the file, so it
        is exported and warned about instead.
        """
        declared = self.pattern.seq_step_count
        if self.kind is NoteKind.DRUM and self.pattern.drum_step_count is not None:
            declared = self.pattern.drum_step_count
        return max(declared, max(n.step for n in self.notes))

    @property
    def declared_step_count(self) -> int:
        if self.kind is NoteKind.DRUM and self.pattern.drum_step_count is not None:
            return self.pattern.drum_step_count
        return self.pattern.seq_step_count

    @property
    def swing_percent(self) -> int:
        if self.kind is NoteKind.DRUM and self.pattern.drum_swing_percent is not None:
            return self.pattern.drum_swing_percent
        return self.pattern.seq_swing_percent

    @property
    def midi_track_name(self) -> str:
        if self.kind is NoteKind.DRUM:
            return f"Track {self.track_number} (drum)"
        return f"Track {self.track_number}"


def export_project(project: Project, options: ExportOptions | None = None) -> ExportResult:
    """Render *project* as a type-1 MIDI file.

    Only patterns holding notes are rendered; the caller narrows the project
    first (see :meth:`ksp.model.Project.select`) if it wants a single track or
    pattern.
    """
    options = options or ExportOptions()
    warnings = _Warnings()

    regions = _regions(project)
    offsets = _pattern_offsets(regions, options)

    midi = mido.MidiFile(type=1, ticks_per_beat=options.ticks_per_beat)
    midi.tracks.append(_conductor_track(project, _total_ticks(regions, offsets, options)))

    note_count = 0
    track_names: list[str] = []
    for name, group in _group_by_midi_track(regions):
        events: list[_Event] = []
        for region in group:
            events.extend(_events_for(region, offsets[region.pattern.number], options, warnings))
        if not events:
            continue
        _resolve_overlaps(events, warnings)
        midi.tracks.append(_midi_track(name, events))
        track_names.append(name)
        note_count += len(events)

    _collect_reader_warnings(regions, warnings)
    return ExportResult(
        midi=midi,
        note_count=note_count,
        pattern_numbers=tuple(sorted(offsets)),
        track_names=tuple(track_names),
        warnings=warnings.tuple(),
    )


def _regions(project: Project) -> tuple[_Region, ...]:
    """Every (track, pattern, parameter set) combination that holds notes.

    Track 1 can hold a melodic *and* a drum set in the same pattern (spec 5).
    Each becomes its own region, and later its own MIDI track, because they
    need different channels and different pitch meanings.
    """
    return tuple(
        _Region(track_number=track.number, kind=kind, pattern=pattern, notes=notes)
        for track in project.tracks
        for pattern in track.patterns
        for kind in (NoteKind.SEQ, NoteKind.DRUM)
        if (notes := pattern.notes_of(kind))
    )


def _pattern_offsets(regions: Sequence[_Region], options: ExportOptions) -> dict[int, int]:
    """Place each used pattern on the timeline, in pattern order.

    A pattern occupies the longest step count any track gives it, so tracks
    of unequal length stay aligned at every pattern boundary instead of
    drifting apart.
    """
    lengths: dict[int, int] = {}
    for region in regions:
        number = region.pattern.number
        lengths[number] = max(lengths.get(number, 0), region.step_count)

    offsets: dict[int, int] = {}
    cursor = 0
    for number in sorted(lengths):
        offsets[number] = cursor
        cursor += lengths[number] * options.ticks_per_step
    return offsets


def _group_by_midi_track(regions: Sequence[_Region]) -> list[tuple[str, list[_Region]]]:
    """Gather regions into one MIDI track per (KeyStep Pro track, note kind)."""
    groups: dict[str, list[_Region]] = {}
    for region in sorted(regions, key=lambda r: (r.track_number, r.kind is NoteKind.DRUM)):
        groups.setdefault(region.midi_track_name, []).append(region)
    return list(groups.items())


def _total_ticks(
    regions: Sequence[_Region], offsets: dict[int, int], options: ExportOptions
) -> int:
    """Length of the whole arrangement, patterns included."""
    return max(
        (
            offsets[region.pattern.number] + region.step_count * options.ticks_per_step
            for region in regions
        ),
        default=0,
    )


def _conductor_track(project: Project, total_ticks: int) -> mido.MidiTrack:
    """Track 0: name, tempo and time signature, no notes.

    Its end-of-track sits at the end of the last pattern rather than at the
    last note, so a DAW importing the file sees the arrangement's real length
    instead of stopping wherever the music happens to stop.
    """
    track = mido.MidiTrack()
    track.append(mido.MetaMessage("track_name", name=project.source_name or project.device, time=0))
    track.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(project.tempo_bpm), time=0))
    track.append(mido.MetaMessage("time_signature", numerator=4, denominator=4, time=0))
    track.append(mido.MetaMessage("end_of_track", time=total_ticks))
    return track


def _events_for(
    region: _Region, offset: int, options: ExportOptions, warnings: _Warnings
) -> list[_Event]:
    ticks_per_step = options.ticks_per_step
    region_end = offset + region.step_count * ticks_per_step
    channel = options.drum_channel if region.kind is NoteKind.DRUM else region.track_number - 1

    if region.kind is NoteKind.DRUM:
        warnings.add(
            f"drum lanes exported as MIDI notes {options.drum_lane_base}+lane on channel "
            f"{options.drum_channel + 1}; the KeyStep Pro drum map is a device global and is "
            f"not stored in the project file (spec 3.4)"
        )
    if options.apply_swing and region.swing_percent != 50:
        warnings.add(
            f"pattern {region.pattern.number} uses {region.swing_percent}% swing; exported "
            f"with the standard swing interpretation, which is not measured against the device"
        )
    if region.step_count > region.declared_step_count:
        warnings.add(
            f"track {region.track_number} pattern {region.pattern.number} ({region.kind.value}): "
            f"note(s) sit past the declared {region.declared_step_count}-step length and would "
            f"not play on the device; exported anyway"
        )

    events: list[_Event] = []
    for note in region.notes:
        pitch = note.pitch
        if region.kind is NoteKind.DRUM:
            pitch += options.drum_lane_base
            if pitch > 127:
                warnings.add(
                    f"drum lane {note.pitch} maps above MIDI note 127 and was dropped; "
                    f"lower --drum-lane-base to export it"
                )
                continue

        if note.time_shift:
            warnings.add(
                "note(s) carry a non-zero time shift; its timing encoding is not measured, "
                "so the shift was not applied"
            )
        if len(note.skip) != len(constants.SKIP_SEQUENCES):
            warnings.add(
                "note(s) are set to play on only some of the 16/32/48/64 sequences; the "
                "export renders one pass of each pattern and includes them all"
            )

        start = offset + (note.step - 1) * ticks_per_step
        if options.apply_swing:
            start += _swing_delay(note.step, region.swing_percent, ticks_per_step)

        gate = note.gate
        if gate is None:
            gate = constants.DEFAULT_GATE_LENGTH
            warnings.add(
                f"gate encoding {note.gate_raw} is not measured (roadmap M7); exported at the "
                f"device's default {gate:g}-step length"
            )
        end = start + max(1, round(gate * ticks_per_step))
        if end > region_end:
            warnings.add(
                f"pattern {region.pattern.number}: note(s) whose gate ran past the end of the "
                f"pattern were shortened to it"
            )
            end = max(start + 1, region_end)

        events.append(
            _Event(
                start=start,
                end=end,
                pitch=pitch,
                velocity=max(MIN_VELOCITY, note.velocity),
                channel=channel,
            )
        )
    return events


def _swing_delay(step: int, swing_percent: int, ticks_per_step: int) -> int:
    """Delay applied to the second step of each pair.

    Standard swing: at *p* percent the first step of a pair takes *p* of the
    pair's duration, so the second starts ``2 * p / 100 - 1`` steps late. 50%
    is no swing.
    """
    if step % 2:
        return 0
    return round(ticks_per_step * (2 * swing_percent / 100 - 1))


def _resolve_overlaps(events: list[_Event], warnings: _Warnings) -> None:
    """Stop a long gate from swallowing the next note of the same pitch.

    Two note-ons for one pitch with only one note-off between them leaves a
    hanging note in most DAWs. The device retriggers instead, so the earlier
    note is shortened to where the later one begins.
    """
    events.sort(key=lambda e: (e.start, e.pitch))
    previous: dict[tuple[int, int], _Event] = {}
    for event in events:
        key = (event.channel, event.pitch)
        earlier = previous.get(key)
        if earlier is not None and earlier.end > event.start:
            earlier.end = max(earlier.start + 1, event.start)
            warnings.add(
                "overlapping note(s) of the same pitch were shortened so each has its own note-off"
            )
        previous[key] = event


def _midi_track(name: str, events: Sequence[_Event]) -> mido.MidiTrack:
    """Turn absolute-tick events into a delta-time MIDI track."""
    track = mido.MidiTrack()
    track.append(mido.MetaMessage("track_name", name=name, time=0))

    # note_off sorts before note_on at the same tick so that a note retriggering
    # exactly where the previous one ends does not read as a hanging note.
    timed: list[tuple[int, int, mido.Message]] = []
    for event in events:
        timed.append(
            (
                event.start,
                1,
                mido.Message(
                    "note_on", note=event.pitch, velocity=event.velocity, channel=event.channel
                ),
            )
        )
        timed.append(
            (
                event.end,
                0,
                mido.Message("note_off", note=event.pitch, velocity=0, channel=event.channel),
            )
        )
    timed.sort(key=lambda item: (item[0], item[1], item[2].note))

    previous_tick = 0
    for tick, _, message in timed:
        track.append(message.copy(time=tick - previous_tick))
        previous_tick = tick
    track.append(mido.MetaMessage("end_of_track", time=0))
    return track


def _collect_reader_warnings(regions: Sequence[_Region], warnings: _Warnings) -> None:
    """Carry the reader's own complaints about exported patterns through.

    A pattern the reader could not fully make sense of -- Track 1 holding both
    parameter sets, say -- produces a MIDI file that is confidently wrong in a
    way the file itself will not reveal.
    """
    for region in regions:
        warnings.extend(f"track {region.track_number}: {line}" for line in region.pattern.warnings)
