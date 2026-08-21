"""Building a project from a Standard MIDI file.

The inverse of :mod:`ksp.midi_export`, and a much narrower operation than it
looks. The key set of a ``.KeyStepPro`` file is fixed (spec section 2), so
nothing here *creates* a project: a template is loaded and values are
overwritten in it. Placement itself is :func:`ksp.mutate.place_note` and
:func:`ksp.mutate.place_drum_note`.

Three layers, mirroring the export direction inverted: :func:`read_song` (the
only part that knows what ``mido`` is) -> :func:`plan_song` (plain arithmetic)
-> :func:`apply` (a raw project dict).

What the conversion decides for the user -- anchoring, track length, the
channel split and the fitted drum map -- is documented in ``README.md`` and
reported on every run.
"""

import math
from collections import Counter
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from typing import Final, NamedTuple

import mido

from ksp import constants, mutate
from ksp import drum_map as drum_map_module
from ksp.constants import DEFAULT_STEPS_PER_BEAT, check_steps_per_beat
from ksp.diagnostics import EMPTY_REPORT, Code, Collector, Report, Site
from ksp.drum_map import DrumMap
from ksp.keys import get_int, item_for_track
from ksp.lenient_json import canonical
from ksp.midi_export import RenderedNote, swing_delay

#: MIDI's own default when a file carries no ``set_tempo``: 500,000
#: microseconds per beat, i.e. 120 BPM.
DEFAULT_TEMPO: Final = 500_000

#: MIDI's default when a file carries no ``time_signature``.
DEFAULT_TIME_SIGNATURE: Final = (4, 4)

#: The MIDI channel GM reserves for percussion, counting from 0.
DRUM_CHANNEL: Final = 9

#: Message types a pattern has nowhere to put. Counted rather than ignored, so
#: a source whose expression lives in its controllers is not silently flattened.
UNSTORABLE_TYPES: Final = frozenset(
    {
        "control_change",
        "pitchwheel",
        "program_change",
        "aftertouch",
        "polytouch",
        "sysex",
    }
)

#: No swing. Both the bottom of the device's range and its default.
_STRAIGHT: Final = constants.SWING_RANGE_PERCENT[0]

#: Notes that must land on delayed steps before a groove is believed rather
#: than left to per-note time shift.
_MIN_SWUNG_NOTES: Final = 3


class TrackRoute(NamedTuple):
    """One source track of the file onto one device track, both counting from 1."""

    source: int
    device: int


@dataclass(frozen=True)
class ImportOptions:
    """Everything the MIDI file cannot tell us about the target project."""

    steps_per_beat: int = DEFAULT_STEPS_PER_BEAT
    """Step size to quantise to. Unlike the export direction, which now reads
    the pattern's own setting out of ``99``, this is a real choice: it decides
    what grid the incoming clip is snapped to. ``apply`` writes it into the
    pattern's ``99`` so the device plays back at the size it was written for."""

    midi_track: int | None = None
    """Read only this track of the source file, counting from 1. ``None`` reads
    every track, which is what a type 0 file needs."""

    drum_track: int | None = None
    """Which source track to write as drums, counting from 1. ``None`` looks
    for a track on the GM percussion channel instead, and finds nothing in the
    many files that put drums on an ordinary channel."""

    drum_map: DrumMap | None = None
    """The lane-to-note map to invert. ``None`` fits a chromatic one to the
    source's own pitches, because the real map is device state the file does
    not carry (spec 3.2.1)."""

    carry_tempo: bool = True
    fit_swing: bool = True
    fit_time_shift: bool = True

    routes: tuple[TrackRoute, ...] = ()
    """Where named source tracks go, overriding the fill-upwards rule. Empty
    assigns exactly as before. A drum track still lands on device track 1."""

    def __post_init__(self) -> None:
        check_steps_per_beat(self.steps_per_beat)
        for name in ("midi_track", "drum_track"):
            value = getattr(self, name)
            if value is not None and value < 1:
                raise ValueError(f"{name} counts from 1")
        self._check_routes()

    def _check_routes(self) -> None:
        """The faults a route has without knowing the song: range and clashes."""
        if self.routes and self.midi_track is not None:
            # Reading one track goes straight to quantise and never reaches
            # _assign, so a route here would be silently ignored.
            raise ValueError(
                "routes and midi_track contradict each other; midi_track converts a single "
                "source track into the one pattern the target names, leaving a route nothing "
                "to place"
            )
        tracks = len(constants.TRACK_ITEM_IDS)
        sources: set[int] = set()
        devices: dict[int, TrackRoute] = {}
        for route in self.routes:
            if route.source < 1:
                raise ValueError(
                    f"route counts source tracks from 1, so {route.source}:{route.device} "
                    "is not one"
                )
            if not 1 <= route.device <= tracks:
                raise ValueError(
                    f"route {route.source}:{route.device} names device track {route.device}; "
                    f"the device has {tracks} tracks"
                )
            if route.source in sources:
                raise ValueError(f"route names source track {route.source} twice")
            if route.device in devices:
                first = devices[route.device]
                raise ValueError(
                    f"routes {first.source}:{first.device} and {route.source}:{route.device} "
                    f"both name device track {route.device}; one device track holds one "
                    "source track"
                )
            if self.drum_track == route.source and route.device != 1:
                raise ValueError(
                    f"route {route.source}:{route.device} sends the drum track to device "
                    f"track {route.device}; only device track 1 carries a drum set"
                )
            if (
                self.drum_track is not None
                and self.drum_track != route.source
                and route.device == 1
            ):
                raise ValueError(
                    f"route {route.source}:1 collides with the drum track; only device track 1 "
                    "carries a drum set"
                )
            sources.add(route.source)
            devices[route.device] = route


@dataclass(frozen=True)
class Clip:
    """One source track's note events, in ticks. No MIDI library involved."""

    notes: tuple[RenderedNote, ...]
    ticks_per_beat: int
    tempo_bpm: float
    source_tracks: tuple[int, ...]
    """Which tracks of the file the notes came from, counting from 1."""

    @property
    def channels(self) -> tuple[int, ...]:
        return tuple(sorted({note.channel for note in self.notes}))

    @property
    def is_percussion(self) -> bool:
        """Whether every note sits on the GM percussion channel."""
        return bool(self.notes) and self.channels == (DRUM_CHANNEL,)


@dataclass(frozen=True)
class Song:
    """A whole source file: one clip per note-bearing track, plus its timing."""

    clips: tuple[Clip, ...]
    ticks_per_beat: int
    tempo_bpm: float
    beats_per_bar: float
    tempo_changes: int = 0
    controllers_dropped: int = 0
    """Events the device cannot store, counted across every track read."""

    def steps_per_bar(self, steps_per_beat: int) -> int:
        return max(1, round(self.beats_per_bar * steps_per_beat))


@dataclass(frozen=True)
class PlacedNote:
    """One note addressed the way the device stores it: a 1-based step."""

    step: int
    pitch: int
    velocity: int
    gate: int = constants.DEFAULT_GATE_STORED
    time_shift: int = constants.TIME_SHIFT_CENTRE
    lane: int | None = None
    """The drum lane this hit plays, or ``None`` on a melodic note. A drum note
    stores a lane index in ``117`` where a melodic one stores a pitch."""


@dataclass(frozen=True)
class Placement:
    """What one pattern holds."""

    notes: tuple[PlacedNote, ...]
    step_count: int
    steps_per_beat: int = DEFAULT_STEPS_PER_BEAT
    """The grid the notes were snapped to. Carried so ``apply`` can write it
    into the pattern's own step size rather than leaving the device to play a
    1/32 clip at 1/16."""

    pattern: int = 1
    swing_percent: int = constants.SWING_RANGE_PERCENT[0]
    diagnostics: Report = EMPTY_REPORT


@dataclass(frozen=True)
class TrackPlan:
    """One source track's worth of patterns, and where they go."""

    track: int
    """The device track, 1-4."""

    placements: tuple[Placement, ...]
    is_drum: bool = False
    source_track: int | None = None

    @property
    def notes(self) -> tuple[PlacedNote, ...]:
        return tuple(note for placement in self.placements for note in placement.notes)

    @property
    def patterns(self) -> tuple[int, ...]:
        return tuple(placement.pattern for placement in self.placements)


@dataclass(frozen=True)
class SongPlan:
    """Everything the conversion decided, before any of it is written."""

    tracks: tuple[TrackPlan, ...]
    tempo_bpm: float | None = None
    """The tempo to write, or ``None`` to keep the template's."""

    drum_map: DrumMap | None = None
    scene: int = 1
    diagnostics: Report = EMPTY_REPORT

    @property
    def notes(self) -> tuple[PlacedNote, ...]:
        return tuple(note for track in self.tracks for note in track.notes)


@dataclass(frozen=True)
class ImportResult:
    """A project with the source written into it, ready to serialise."""

    raw: dict[str, int | str]
    plan: SongPlan
    diagnostics: Report

    @property
    def notes(self) -> tuple[PlacedNote, ...]:
        return self.plan.notes

    @property
    def note_count(self) -> int:
        return len(self.plan.notes)

    @property
    def track(self) -> int:
        """The first device track written. The single-target path has one."""
        return self.plan.tracks[0].track if self.plan.tracks else 1

    @property
    def pattern(self) -> int:
        return self.plan.tracks[0].placements[0].pattern if self.plan.tracks else 1

    @property
    def step_count(self) -> int:
        return self.plan.tracks[0].placements[0].step_count if self.plan.tracks else 0


# --- Layer 1: reading MIDI -------------------------------------------------


@dataclass(frozen=True)
class _TrackRead:
    """One source track's notes, and what else went past while pairing them."""

    notes: list[RenderedNote]
    dropped: int
    """Events the device cannot store: controllers, bend, program, pressure."""


def _track_notes(track: Iterable[mido.Message]) -> _TrackRead:
    """Pair one track's note-ons with their note-offs, in absolute ticks."""
    tick = 0
    dropped = 0
    notes: list[RenderedNote] = []
    # (channel, pitch) -> (onset tick, velocity). A second note-on for a pitch
    # already sounding retriggers it, so the earlier one ends here.
    open_notes: dict[tuple[int, int], tuple[int, int]] = {}

    for message in track:
        tick += message.time
        if message.type in UNSTORABLE_TYPES:
            dropped += 1
            continue
        if message.type not in ("note_on", "note_off"):
            continue

        held = (message.channel, message.note)
        ending = message.type == "note_off" or message.velocity == 0
        if held in open_notes:
            onset, velocity = open_notes.pop(held)
            notes.append(
                RenderedNote(
                    tick=onset,
                    duration_ticks=tick - onset,
                    pitch=message.note,
                    velocity=velocity,
                    channel=message.channel,
                )
            )
        if not ending:
            open_notes[held] = (tick, message.velocity)

    # A note-on the file never closes still sounded; end it at the track's last
    # event rather than discarding it.
    for (channel, pitch), (onset, velocity) in open_notes.items():
        notes.append(
            RenderedNote(
                tick=onset,
                duration_ticks=max(0, tick - onset),
                pitch=pitch,
                velocity=velocity,
                channel=channel,
            )
        )

    return _TrackRead(notes=notes, dropped=dropped)


def _check_readable(midi: mido.MidiFile) -> None:
    """Refuse the two file shapes whose ticks mean something else entirely.

    Both convert to nonsense rather than to nothing, which is the reason to
    stop here: mido reads the division field signed, so a timecode file arrives
    with a negative ``ticks_per_beat`` and every step calculation inverts.
    """
    if midi.ticks_per_beat < 1:
        raise ValueError(
            "the file is timed in SMPTE timecode rather than ticks per beat, which has no "
            "beat to quantise against; re-export it with a PPQ division"
        )
    if midi.type == 2:
        raise ValueError(
            "a type 2 file holds independent sequences rather than one arrangement, so its "
            "tracks cannot be played together; pick one with --midi-track"
        )


def _timing(midi: mido.MidiFile) -> tuple[int, tuple[int, int], int]:
    """The file's first tempo, its first time signature and how many tempi."""
    tempo = DEFAULT_TEMPO
    signature = DEFAULT_TIME_SIGNATURE
    changes = 0
    found_tempo = False
    found_signature = False

    for track in midi.tracks:
        for message in track:
            if message.type == "set_tempo":
                changes += 1
                if not found_tempo:
                    tempo, found_tempo = message.tempo, True
            elif message.type == "time_signature" and not found_signature:
                signature = (message.numerator, message.denominator)
                found_signature = True

    return tempo, signature, changes


def read_clip(midi: mido.MidiFile, options: ImportOptions | None = None) -> Clip:
    """Every selected track's notes, merged into one clip in absolute ticks."""
    options = options or ImportOptions()
    _check_readable(midi)
    tempo, _, _ = _timing(midi)

    notes: list[RenderedNote] = []
    sources: list[int] = []
    for number, track in enumerate(midi.tracks, start=1):
        if options.midi_track is not None and number != options.midi_track:
            continue
        found = _track_notes(track).notes
        if found:
            sources.append(number)
            notes.extend(found)

    notes.sort(key=lambda note: (note.tick, note.pitch))
    return Clip(
        notes=tuple(notes),
        ticks_per_beat=midi.ticks_per_beat,
        tempo_bpm=float(mido.tempo2bpm(tempo)),
        source_tracks=tuple(sources),
    )


def read_song(midi: mido.MidiFile, options: ImportOptions | None = None) -> Song:
    """One clip per note-bearing source track and channel, in file order.

    Type 1 files -- what a DAW exports -- give one track per instrument, which
    is the shape M6 is for. A type 0 file puts everything on one track and
    tells its instruments apart by channel alone, so a track carrying several
    is split into one clip each: merged, its percussion would arrive as melodic
    pitches on whichever device track the rest of it landed on.
    """
    options = options or ImportOptions()
    _check_readable(midi)
    tempo, (numerator, denominator), changes = _timing(midi)
    tempo_bpm = float(mido.tempo2bpm(tempo))

    clips = []
    dropped = 0
    for number, track in enumerate(midi.tracks, start=1):
        if options.midi_track is not None and number != options.midi_track:
            continue
        read = _track_notes(track)
        dropped += read.dropped
        by_channel: dict[int, list[RenderedNote]] = {}
        for note in read.notes:
            by_channel.setdefault(note.channel, []).append(note)
        for channel in sorted(by_channel):
            notes = sorted(by_channel[channel], key=lambda note: (note.tick, note.pitch))
            clips.append(
                Clip(
                    notes=tuple(notes),
                    ticks_per_beat=midi.ticks_per_beat,
                    tempo_bpm=tempo_bpm,
                    source_tracks=(number,),
                )
            )

    return Song(
        clips=tuple(clips),
        ticks_per_beat=midi.ticks_per_beat,
        tempo_bpm=tempo_bpm,
        # A bar in quarter notes, which is what a beat is here.
        beats_per_bar=numerator * 4 / denominator,
        tempo_changes=changes,
        controllers_dropped=dropped,
    )


# --- Layer 2: planning -----------------------------------------------------


@dataclass(frozen=True)
class _Snapped:
    """One source note against the grid, before it belongs to a pattern."""

    step: int
    """0-based, counted from the anchored origin, and unbounded by a pattern."""

    residual: float
    """Ticks between where the note actually is and where its step is."""

    note: RenderedNote


def _anchor(clips: Sequence[Clip], ticks_per_step: float) -> float:
    """The tick the first note of *clips* is snapped back from.

    Taken across every clip at once on the whole-file path. Anchoring each
    track on its own first note would slide a part that enters at bar 3 back
    onto bar 1, which is not a lead-in the pattern cannot hold -- it is the
    arrangement.
    """
    first = min((note.tick for clip in clips for note in clip.notes), default=0)
    return round(first / ticks_per_step) * ticks_per_step


def _assign_step(offset: float, ticks_per_step: float, percent: int) -> tuple[int, float]:
    """The step *offset* belongs to under *percent* swing, and what is left.

    Nearest-step arithmetic alone cannot do this. At 75% -- the device's
    maximum -- a delayed step sits exactly half a step late, so snapping to the
    nearest lands it on the *next* step and collapses each pair onto one. So
    the neighbours are tried against the swung grid and the closest wins.
    """
    base = round(offset / ticks_per_step)
    best: tuple[int, float] | None = None
    for step in (base - 1, base, base + 1):
        if step < 0:
            continue
        residual = offset - (step * ticks_per_step + swing_delay(step, percent, ticks_per_step))
        if best is None or abs(residual) < abs(best[1]):
            best = (step, residual)
    return best if best is not None else (0, offset)


def _snap(clip: Clip, ticks_per_step: float, origin: float, percent: int) -> list[_Snapped]:
    snapped = []
    for note in sorted(clip.notes, key=lambda n: (n.tick, n.pitch)):
        step, residual = _assign_step(note.tick - origin, ticks_per_step, percent)
        snapped.append(_Snapped(step=step, residual=residual, note=note))
    return snapped


def _fit_swing(clip: Clip, ticks_per_step: float, origin: float) -> int:
    """The swing percentage that best explains a clip's timing.

    Fitted before any time shift is spent, because one pattern-level value
    expresses a systematic groove for free and the per-note field is scarce
    (Timing_Calibration 3.2). A search over the 26 storable percentages, not an
    inverted median -- see ROADMAP M6 for why the median breaks at 75 %. Ties
    keep the lowest, so a straight clip stays straight.
    """
    low, high = constants.SWING_RANGE_PERCENT
    if not clip.notes:
        return low

    offsets = [note.tick - origin for note in clip.notes]
    best_percent, best_cost = low, math.inf
    for percent in range(low, high + 1):
        cost = sum(abs(_assign_step(o, ticks_per_step, percent)[1]) for o in offsets)
        if cost < best_cost - 1e-9:
            best_percent, best_cost = percent, cost

    if best_percent == low:
        return low

    # A groove is a thing a pattern does repeatedly. Without that guard the
    # search will gladly explain one late note as swing, which would displace
    # every other note on a delayed step to explain a single one.
    swung = sum(1 for o in offsets if _assign_step(o, ticks_per_step, best_percent)[0] % 2)
    return best_percent if swung >= _MIN_SWUNG_NOTES else low


def _fit_shift(residual: float, ticks_per_beat: int) -> tuple[int, float]:
    """A residual as a stored time shift, and what it could not express.

    The unit is a fixed 1/400 of a beat (spec 6.4), so the reachable range is
    60 ticks either way at 480 PPQN whatever the step size. At a 1/4 grid that
    is an eighth of a step and most residuals will not fit; at 1/32 it is a
    whole one.
    """
    unit = ticks_per_beat / constants.TIME_SHIFT_UNITS_PER_BEAT
    low, high = constants.TIME_SHIFT_RANGE
    wanted = residual / unit
    units = max(low, min(high, round(wanted)))
    return constants.TIME_SHIFT_CENTRE + units, residual - units * unit


def _gate_for(note: RenderedNote, ticks_per_step: float) -> tuple[int, bool]:
    """The ladder rung nearest this note's length, and whether it is exact."""
    length = note.duration_ticks / ticks_per_step
    stored = constants.encode_gate(length)
    return stored, constants.GATE_TABLE[stored] == length


def _place(
    snapped: Sequence[_Snapped],
    *,
    step_count: int,
    pattern: int,
    ticks_per_step: float,
    ticks_per_beat: int,
    options: ImportOptions,
    drum_map: DrumMap | None,
    site: Site,
    collector: Collector,
    swing: int,
    offset: int = 0,
) -> Placement:
    """Turn snapped notes into one pattern's worth of placed ones.

    *offset* is the 0-based step this pattern starts at within the track, so a
    split track's later patterns count their steps from 1 again. *swing* is
    already fitted and already removed from each residual, so what is left here
    is only what time shift has to carry.
    """
    notes: list[PlacedNote] = []
    approximated = 0
    held_past_end = 0
    unrepresentable = 0
    unmapped: list[int] = []

    for entry in snapped:
        local = entry.step - offset
        gate, exact = _gate_for(entry.note, ticks_per_step)
        if not exact:
            approximated += 1
        if local + entry.note.duration_ticks / ticks_per_step > step_count:
            held_past_end += 1

        shift = constants.TIME_SHIFT_CENTRE
        if options.fit_time_shift:
            shift, remainder = _fit_shift(entry.residual, ticks_per_beat)
            if abs(remainder) > ticks_per_beat / constants.TIME_SHIFT_UNITS_PER_BEAT / 2:
                unrepresentable += 1

        lane: int | None = None
        if drum_map is not None:
            lane = drum_map.lane_for_note(entry.note.pitch)
            if lane is None:
                unmapped.append(entry.note.pitch)
                continue

        notes.append(
            PlacedNote(
                step=local + 1,
                pitch=entry.note.pitch,
                velocity=entry.note.velocity,
                gate=gate,
                time_shift=shift,
                lane=lane,
            )
        )

    if swing != constants.SWING_RANGE_PERCENT[0]:
        collector.add(
            Code.SWING_FITTED,
            f"the source swings; pattern {pattern} was written at {swing}% swing and each "
            "note's leftover given to its time shift",
            site=site,
        )
    if approximated:
        collector.add(
            Code.GATE_APPROXIMATED,
            f"{approximated} note length(s) are not on the gate ladder and took the nearest "
            "rung; the ladder is coarse above 3 steps",
            site=site,
            subjects=approximated,
        )
    if held_past_end:
        collector.add(
            Code.GATE_PAST_END,
            f"{held_past_end} note(s) are held past step {step_count}; the device loops the "
            "pattern rather than sustaining them",
            site=site,
            subjects=held_past_end,
        )
    if unrepresentable:
        collector.add(
            Code.TIMING_RESIDUAL,
            f"{unrepresentable} note(s) sit further off the grid than swing and time shift "
            "together reach, and were left at the nearest position the device can store",
            site=site,
            subjects=unrepresentable,
        )
    if unmapped:
        collector.add(
            Code.DRUM_PITCH_UNMAPPED,
            f"{len(unmapped)} note(s) at pitch(es) {_listed(sorted(set(unmapped)))} are outside "
            "the drum map's 24 lanes and were dropped",
            site=site,
            subjects=len(unmapped),
        )

    # Refused here rather than by ``mutate`` from underneath, so the message
    # can name the step to thin and nothing has been written yet.
    crowded = Counter(note.step for note in notes)
    over = [step for step, held in crowded.items() if held > constants.MAX_NOTES_PER_STEP]
    if over:
        # The worst step, and the earliest of those when several tie.
        step = max(over, key=lambda s: (crowded[s], -s))
        held = crowded[step]
        where = f"track {site.track} " if site.track is not None else ""
        raise ValueError(
            f"step {step} of {where}pattern {pattern} holds {held} notes; the firmware's limit "
            f"is {constants.MAX_NOTES_PER_STEP} per step. Thin the chord, or quantise finer with "
            "--steps-per-beat so its notes fall on steps of their own"
        )

    if len(notes) > constants.POOL_CAPACITY:
        collector.add(
            Code.POOL_OVERFLOW,
            f"pattern {pattern} holds {len(notes)} events; the firmware's limit is "
            f"{constants.POOL_CAPACITY}, so the last {len(notes) - constants.POOL_CAPACITY} "
            "were dropped",
            site=site,
            subjects=len(notes) - constants.POOL_CAPACITY,
        )
        notes = notes[: constants.POOL_CAPACITY]

    return Placement(
        notes=tuple(notes),
        step_count=step_count,
        steps_per_beat=options.steps_per_beat,
        pattern=pattern,
        swing_percent=swing,
        diagnostics=EMPTY_REPORT,
    )


def quantise(clip: Clip, *, step_count: int, options: ImportOptions | None = None) -> Placement:
    """Snap *clip* to a *step_count*-step grid, as one pattern.

    The single-target path: notes past the last step are dropped, because the
    device disables them rather than playing them. :func:`plan_track` is the
    one that splits instead.

    Raises:
        ValueError: if *step_count* is outside the device's 1-64.
    """
    options = options or ImportOptions()
    if not 1 <= step_count <= constants.MAX_STEPS:
        raise ValueError(f"step count {step_count} out of range 1-{constants.MAX_STEPS}")

    collector = Collector()
    ticks_per_step = clip.ticks_per_beat / options.steps_per_beat
    origin = _anchor((clip,), ticks_per_step)

    if len(clip.source_tracks) > 1 or len(clip.channels) > 1:
        collector.add(
            Code.MULTIPLE_SOURCES,
            f"notes came from track(s) {_listed(clip.source_tracks)} and channel(s) "
            f"{_listed(tuple(c + 1 for c in clip.channels))} and were merged into one "
            "pattern; --midi-track picks just one",
        )
    if origin:
        collector.add(
            Code.CLIP_ANCHORED,
            f"the clip starts {origin:g} tick(s) into the file; its first note was placed on "
            "step 1 and the rest moved with it, because a pattern is a loop with nowhere to "
            "keep a lead-in",
        )

    swing = _fit_swing(clip, ticks_per_step, origin) if options.fit_swing else _STRAIGHT
    snapped = _snap(clip, ticks_per_step, origin, swing)
    moved = sum(1 for entry in snapped if entry.residual)
    if moved:
        collector.add(
            Code.NOTES_QUANTISED,
            f"{moved} note(s) did not land on a 1/{options.steps_per_beat * 4} step "
            "and were moved to the nearest one",
            subjects=moved,
        )

    within = [entry for entry in snapped if 0 <= entry.step < step_count]
    dropped = len(snapped) - len(within)
    if dropped:
        collector.add(
            Code.PAST_PATTERN_END,
            f"{dropped} note(s) fall past step {step_count} and were dropped; "
            "the device disables notes past the last step rather than playing them",
            subjects=dropped,
        )

    placement = _place(
        within,
        step_count=step_count,
        pattern=1,
        ticks_per_step=ticks_per_step,
        ticks_per_beat=clip.ticks_per_beat,
        options=options,
        drum_map=None,
        site=Site(),
        collector=collector,
        swing=swing,
    )
    return Placement(
        notes=placement.notes,
        step_count=placement.step_count,
        steps_per_beat=placement.steps_per_beat,
        pattern=placement.pattern,
        swing_percent=placement.swing_percent,
        diagnostics=collector.report(),
    )


def plan_track(
    clip: Clip,
    *,
    track: int,
    collector: Collector,
    options: ImportOptions | None = None,
    is_drum: bool = False,
    drum_map: DrumMap | None = None,
    first_pattern: int = 1,
    steps_per_bar: int = 16,
    origin: float,
) -> TrackPlan:
    """Lay one source track out across as many patterns as it needs.

    The track's length is its content rounded up to a whole bar, then cut into
    64-step patterns -- the device's ceiling. Nothing is truncated: a sequence
    too long for one pattern becomes several, chained. Lengths are per track,
    not padded to a common one: the device loops each track's chain on its own,
    so a one-bar part under an eight-bar one repeats against it.

    *origin* is the tick the grid is counted from, taken by :func:`plan_song`
    across the whole file so a part that enters at bar 3 stays there.
    """
    options = options or ImportOptions()
    ticks_per_step = clip.ticks_per_beat / options.steps_per_beat
    site = Site(track=track, kind="drum" if is_drum else "seq")

    # Fitted once for the track rather than once per pattern: a groove belongs
    # to the performance, not to which 64-step window of it a pattern holds,
    # and the steps a pattern is cut on cannot be known until it is fitted.
    swing = _fit_swing(clip, ticks_per_step, origin) if options.fit_swing else _STRAIGHT
    snapped = _snap(clip, ticks_per_step, origin, swing)

    # The last step any note reaches, rounded up to the bar so a loop stays
    # musical: a track that stops mid-bar drifts against every other one.
    ends = [entry.step + entry.note.duration_ticks / ticks_per_step for entry in snapped]
    total = max(1, -(-round(max(ends, default=1)) // steps_per_bar) * steps_per_bar)

    moved = sum(1 for entry in snapped if entry.residual)
    if moved:
        collector.add(
            Code.NOTES_QUANTISED,
            f"{moved} note(s) on track {track} did not land on a 1/"
            f"{options.steps_per_beat * 4} step and were moved to the nearest one",
            site=site,
            subjects=moved,
        )

    count = -(-total // constants.MAX_STEPS)
    available = constants.PATTERNS_PER_TRACK - first_pattern + 1
    if count > available:
        collector.add(
            Code.PAST_PATTERN_END,
            f"track {track} needs {count} patterns but only {available} are free from pattern "
            f"{first_pattern}; the tail was dropped",
            site=site,
            subjects=count - available,
        )
        count = available

    placements = []
    for index in range(count):
        offset = index * constants.MAX_STEPS
        steps = min(constants.MAX_STEPS, total - offset)
        inside = [entry for entry in snapped if offset <= entry.step < offset + steps]
        placements.append(
            _place(
                inside,
                step_count=steps,
                pattern=first_pattern + index,
                ticks_per_step=ticks_per_step,
                ticks_per_beat=clip.ticks_per_beat,
                options=options,
                drum_map=drum_map if is_drum else None,
                site=Site(track=track, pattern=first_pattern + index, kind=site.kind),
                collector=collector,
                swing=swing,
                offset=offset,
            )
        )

    if count > 1:
        collector.add(
            Code.PATTERN_SPLIT,
            f"track {track} runs {total} steps, past the device's {constants.MAX_STEPS}; it was "
            f"split across patterns {first_pattern}-{first_pattern + count - 1} and chained",
            site=site,
        )

    return TrackPlan(
        track=track,
        placements=tuple(placements),
        is_drum=is_drum,
        source_track=clip.source_tracks[0] if clip.source_tracks else None,
    )


def fit_drum_map(clip: Clip) -> DrumMap:
    """A chromatic map covering *clip*'s pitches, low note first.

    The device's real map is a global setting the project file does not carry
    (spec 3.2.1), so importing drums means assuming one. Assuming the factory
    default would silently drop every source that does not start at MIDI 36,
    which is most of them; fitting to what is actually there converts the file
    and says which map it used.
    """
    pitches = [note.pitch for note in clip.notes]
    low = min(pitches, default=drum_map_module.DEFAULT_CHROMATIC_LOW)
    return DrumMap.chromatic(
        max(drum_map_module.MIN_NOTE, min(low, drum_map_module.MAX_CHROMATIC_LOW))
    )


def _merged(clips: Sequence[Clip]) -> Clip:
    """Several clips of one source track back into the one the file wrote."""
    if len(clips) == 1:
        return clips[0]
    notes = sorted(
        (note for clip in clips for note in clip.notes), key=lambda note: (note.tick, note.pitch)
    )
    return Clip(
        notes=tuple(notes),
        ticks_per_beat=clips[0].ticks_per_beat,
        tempo_bpm=clips[0].tempo_bpm,
        source_tracks=clips[0].source_tracks,
    )


def _assign(
    song: Song, options: ImportOptions, collector: Collector, first_track: int = 1
) -> list[tuple[Clip, int, bool]]:
    """Which device track each source clip goes to, and which one is drums.

    A route puts a named source track where it says. Whatever is left fills the
    tracks a route did not claim, from *first_track* upwards in source order. A
    drum clip goes to Track 1 whatever that is, because item 123 is the only
    one carrying a drum parameter set.
    """
    drum: Clip | None = None
    if options.drum_track is not None:
        # --drum-track names a track of the file, so a track split across
        # channels is put back together rather than leaving half a kit behind.
        named = [clip for clip in song.clips if clip.source_tracks == (options.drum_track,)]
        if not named:
            raise ValueError(
                f"track {options.drum_track} of the source holds no notes; --drum-track counts "
                "every track of the file from 1, including ones that carry only tempo or a name"
            )
        drum = _merged(named)
        melodic = [clip for clip in song.clips if clip.source_tracks != (options.drum_track,)]
    else:
        drum = next((clip for clip in song.clips if clip.is_percussion), None)
        melodic = [clip for clip in song.clips if clip is not drum]

    drum_source = drum.source_tracks[0] if drum is not None and drum.source_tracks else None
    routed: list[tuple[Clip, int]] = []
    claimed: set[int] = set()
    for route in options.routes:
        named = [clip for clip in song.clips if clip.source_tracks == (route.source,)]
        if not named:
            raise ValueError(
                f"track {route.source} of the source holds no notes; route counts every track "
                "of the file from 1, including ones that carry only tempo or a name"
            )
        if route.source == drum_source:
            if route.device != 1:
                raise ValueError(
                    f"route {route.source}:{route.device} sends the drum track to device "
                    f"track {route.device}; only device track 1 carries a drum set"
                )
            # The map agrees with the drum designation; the drum clip is
            # already on 1, and whatever else the track holds still fills.
            continue
        if route.device == 1 and drum is not None:
            raise ValueError(
                f"route {route.source}:1 collides with the drum track; only device track 1 "
                "carries a drum set"
            )
        # A route names a track of the file, so it is put back together the way
        # --drum-track is rather than routing only one of its channels.
        routed.append((_merged(named), route.device))
        claimed.add(route.device)
        melodic = [clip for clip in melodic if clip.source_tracks != (route.source,)]

    assigned: list[tuple[Clip, int, bool]] = []
    if drum is not None:
        assigned.append((drum, 1, True))
    assigned.extend((clip, device, False) for clip, device in routed)

    # Only Track 1 carries a drum set, so it is spoken for when there is one.
    free = [
        n
        for n in range(first_track, len(constants.TRACK_ITEM_IDS) + 1)
        if (drum is None or n != 1) and n not in claimed
    ]
    for clip, track in zip(melodic, free, strict=False):
        assigned.append((clip, track, False))

    dropped = len(melodic) - len(free)
    if dropped > 0:
        collector.add(
            Code.TRACKS_DROPPED,
            f"{dropped} source track(s) had nowhere to go; the device has "
            f"{len(constants.TRACK_ITEM_IDS)} tracks",
            subjects=dropped,
        )
    assigned.sort(key=lambda placed: placed[1])
    return assigned


def plan_song(
    song: Song,
    options: ImportOptions | None = None,
    *,
    first_pattern: int = 1,
    first_track: int = 1,
    scene: int = 1,
) -> SongPlan:
    """Decide everything the conversion will write, without writing any of it."""
    options = options or ImportOptions()
    collector = Collector()

    split = Counter(clip.source_tracks[0] for clip in song.clips if clip.source_tracks)
    multi = {track: count for track, count in split.items() if count > 1}
    if multi:
        collector.add(
            Code.TRACK_SPLIT_BY_CHANNEL,
            f"source track(s) {_listed(sorted(multi))} carry more than one channel; each channel "
            "became a device track of its own, unless --drum-track or --route named the track, "
            "which puts it back together as one part",
            subjects=sum(multi.values()),
        )
    if song.controllers_dropped:
        collector.add(
            Code.CONTROLLERS_DROPPED,
            f"{song.controllers_dropped} event(s) are control change, pitch bend, program "
            "change or pressure; a pattern stores notes only, so they were dropped",
            subjects=song.controllers_dropped,
        )

    assigned = _assign(song, options, collector, first_track)

    drum_map = options.drum_map
    drum_clip = next((clip for clip, _, is_drum in assigned if is_drum), None)
    if drum_clip is not None and drum_map is None:
        drum_map = fit_drum_map(drum_clip)
        collector.add(
            Code.DRUM_MAP_FITTED,
            f"no drum map was given, so one was fitted to the source: {drum_map.describe()}. "
            "The real map is a device setting the project file does not carry",
        )

    steps_per_bar = song.steps_per_bar(options.steps_per_beat)
    ticks_per_step = song.ticks_per_beat / options.steps_per_beat
    origin = _anchor([clip for clip, _, _ in assigned], ticks_per_step)
    if origin:
        collector.add(
            Code.CLIP_ANCHORED,
            f"the song starts {origin:g} tick(s) into the file; every track was moved back "
            "together so its first note lands on step 1, because a pattern is a loop with "
            "nowhere to keep a lead-in",
        )

    tracks = [
        plan_track(
            clip,
            track=track,
            collector=collector,
            options=options,
            is_drum=is_drum,
            drum_map=drum_map,
            first_pattern=first_pattern,
            steps_per_bar=steps_per_bar,
            origin=origin,
        )
        for clip, track, is_drum in assigned
    ]

    tempo = None
    if options.carry_tempo and song.clips:
        low, high = constants.TEMPO_RANGE_BPM
        tempo = max(low, min(high, song.tempo_bpm))
        if tempo != song.tempo_bpm:
            collector.add(
                Code.TEMPO_OUT_OF_RANGE,
                f"the source runs at {song.tempo_bpm:g} BPM, outside the {low:g}-{high:g} the "
                f"device plays; the project was written at {tempo:g} BPM instead",
            )
        else:
            collector.add(
                Code.TEMPO_CARRIED,
                f"the project tempo was set to the source's {song.tempo_bpm:g} BPM",
            )
        if song.tempo_changes > 1:
            collector.add(
                Code.TEMPO_CHANGES_IGNORED,
                f"the source changes tempo {song.tempo_changes} time(s); the device stores one "
                f"tempo per project, so {song.tempo_bpm:g} BPM was taken and the rest ignored",
            )

    return SongPlan(
        tracks=tuple(tracks),
        tempo_bpm=tempo,
        drum_map=drum_map,
        scene=scene,
        diagnostics=collector.report(),
    )


# --- Layer 3: writing ------------------------------------------------------


def apply(raw: Mapping[str, int | str], plan: SongPlan) -> dict[str, int | str]:
    """Write *plan* into a copy of *raw*.

    One copy for the whole conversion rather than one per note: the scalars go
    through the ordinary ``mutate`` functions, and the notes -- of which there
    may be hundreds -- through the delta form onto this dict.
    """
    result = dict(raw)

    for track_plan in plan.tracks:
        track = track_plan.track
        drum = track_plan.is_drum
        result = mutate.set_drum_mode(result, track=track, on=drum)

        for placement in track_plan.placements:
            pattern = placement.pattern
            result = mutate.set_step_size(
                result,
                track=track,
                pattern=pattern,
                steps_per_beat=placement.steps_per_beat,
                drum=drum,
            )
            result = mutate.set_step_count(
                result, track=track, pattern=pattern, steps=placement.step_count, drum=drum
            )
            result = mutate.set_swing(
                result, track=track, pattern=pattern, percent=placement.swing_percent, drum=drum
            )

            for note in placement.notes:
                if drum:
                    if note.lane is None:
                        continue
                    updates = mutate.drum_note_updates(
                        result,
                        pattern=pattern,
                        lane=note.lane,
                        step=note.step,
                        velocity=note.velocity,
                        gate=note.gate,
                        time_shift=note.time_shift,
                    )
                else:
                    updates = mutate.note_updates(
                        result,
                        track=track,
                        pattern=pattern,
                        step=note.step,
                        pitch=note.pitch,
                        velocity=note.velocity,
                        gate=note.gate,
                        time_shift=note.time_shift,
                    )
                mutate.merge_updates(result, updates)

        # Only a split track needs a chain. Every sample project leaves all 16
        # slots at the sentinel and still plays, so a chain is what makes
        # several patterns one sequence -- not what makes one pattern play.
        # Writing one anyway would rewrite the scene of a project that was
        # only ever asked to take a clip.
        if len(track_plan.placements) > 1:
            result = mutate.set_chain(
                result, scene=plan.scene, track=track, patterns=track_plan.patterns
            )

    if plan.tempo_bpm is not None:
        result = mutate.set_tempo(result, bpm=plan.tempo_bpm)
    return result


def saveable(raw: Mapping[str, int | str]) -> dict[str, int | str]:
    """Put a converted project in MCC's key order, with a ``version`` key.

    The factory template has no ``version`` and every saved project does, so
    starting from it means injecting one. Assigning it to a loaded dict appends
    it at the end, which is a key order no file MCC wrote has ever had, so
    ``canonical`` places it (spec section 2).
    """
    if "version" not in raw:
        raw = dict(raw) | {"version": constants.PROJECT_VERSION}
    return canonical(raw)


def pattern_step_count(raw: Mapping[str, int | str], *, track: int, pattern: int) -> int:
    """The declared length of one melodic pattern, in steps.

    ``98`` is 0-based, so a stored 15 is a 16-step pattern.
    """
    item = item_for_track(track)
    stored = get_int(raw, item, constants.P_SEQ_STEP_COUNT, pattern)
    if stored is None:
        raise ValueError(f"track {track} pattern {pattern} declares no step count")
    return stored + constants.STEP_COUNT_OFFSET


def pattern_is_empty(
    raw: Mapping[str, int | str], *, track: int, pattern: int, drum: bool = False
) -> bool:
    """Whether a pattern's note pool holds nothing.

    Existence is ``50 != 127`` -- ``54`` on the drum side -- and nothing else,
    never velocity (spec 4).
    """
    item = item_for_track(track)
    param = constants.P_DRUM_NOTE_STEP if drum else constants.P_SEQ_NOTE_STEP
    return all(
        get_int(raw, item, param, pattern, slot, ordinal) in (constants.SENTINEL, None)
        for slot in range(1, constants.POOL_SLOTS + 1)
        for ordinal in range(1, constants.MAX_STEPS + 1)
    )


def track_is_melodic(raw: Mapping[str, int | str], *, track: int) -> bool:
    """Whether a track's mode flag says the melodic parameter set is live.

    ``86`` bit 6 is DRUM on Track 1 and ARP on Tracks 2-4 (spec 5). Either way
    the melodic pool is not what the device is playing from.
    """
    item = item_for_track(track)
    bits = get_int(raw, item, constants.P_TRACK_MODE_BITS)
    return not (bits or 0) & (1 << constants.DRUM_MODE_BIT)


def _check_targets(raw: Mapping[str, int | str], plan: SongPlan) -> None:
    """Refuse the whole conversion if any target pattern already holds notes.

    Checked before anything is written, so a file is never left half converted.
    Appending to an occupied pool would interleave two takes, and emptying one
    means writing sentinels, which no hardware capture covers.
    """
    for track_plan in plan.tracks:
        for placement in track_plan.placements:
            if not pattern_is_empty(
                raw,
                track=track_plan.track,
                pattern=placement.pattern,
                drum=track_plan.is_drum,
            ):
                kind = "drum" if track_plan.is_drum else "melodic"
                raise ValueError(
                    f"track {track_plan.track} pattern {placement.pattern} already holds notes "
                    f"in its {kind} pool; pick an empty pattern"
                )


def convert(
    midi: mido.MidiFile,
    raw: Mapping[str, int | str],
    *,
    track: int = 1,
    pattern: int = 1,
    options: ImportOptions | None = None,
) -> ImportResult:
    """Convert one clip of *midi* into one pattern of the template *raw*.

    The single-target path: everything lands on *track* and *pattern*, at the
    length that pattern already declares. :func:`convert_song` is the one that
    reads a whole file.

    Raises:
        ValueError: if the target track is not in a melodic mode, or its
            pattern already holds notes.
    """
    options = options or ImportOptions()
    if not track_is_melodic(raw, track=track):
        raise ValueError(
            f"track {track} has parameter 86 bit 6 set, so the device is not playing its "
            "melodic notes; pick another track or clear the mode on the device"
        )
    if not pattern_is_empty(raw, track=track, pattern=pattern):
        raise ValueError(
            f"track {track} pattern {pattern} already holds notes; pick an empty pattern"
        )

    clip = read_clip(midi, options)
    placement = quantise(
        clip,
        step_count=pattern_step_count(raw, track=track, pattern=pattern),
        options=options,
    )
    plan = SongPlan(
        tracks=(TrackPlan(track=track, placements=(placement,)),),
        diagnostics=placement.diagnostics,
    )
    return ImportResult(
        raw=apply(raw, plan),
        plan=plan,
        diagnostics=placement.diagnostics,
    )


def convert_song(
    midi: mido.MidiFile,
    raw: Mapping[str, int | str],
    *,
    options: ImportOptions | None = None,
    first_pattern: int = 1,
    first_track: int = 1,
) -> ImportResult:
    """Convert every note-bearing track of *midi* into the template *raw*.

    Raises:
        ValueError: if any target pattern already holds notes, or the source
            names a drum track that carries none.
    """
    options = options or ImportOptions()
    song = read_song(midi, options)
    scene = get_int(raw, constants.ITEM_PROJECT, constants.P_CURRENT_SCENE) or 0
    plan = plan_song(
        song,
        options,
        first_pattern=first_pattern,
        first_track=first_track,
        scene=scene + 1,
    )
    _check_targets(raw, plan)
    return ImportResult(raw=apply(raw, plan), plan=plan, diagnostics=plan.diagnostics)


def _listed(values: Sequence[int]) -> str:
    return ", ".join(str(value) for value in values) or "none"
