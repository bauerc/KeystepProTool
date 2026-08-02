"""Building a project from a Standard MIDI file.

The inverse of :mod:`ksp.midi_export`, and a much narrower operation than it
looks. The key set of a ``.KeyStepPro`` file is fixed at 153,495 numeric keys
(spec section 2), so nothing here *creates* a project: a template is loaded and
values are overwritten in it. Placement itself is
:func:`ksp.mutate.place_note`, whose 8-key recipe was measured from the device
rather than inferred.

Milestone M5, and deliberately the MVP of one: **one melodic track, one
pattern, monophonic**. Polyphony, drums and multi-pattern splitting are M6.

Two things the conversion does not carry, both warned about on every run
because the rule is that anything decided for the user is visible:

* **Note length.** Every note is written at the gate a freshly placed note has
  on the device. Gate *is* fully measured (spec 6.1) so carrying real durations
  is possible; the MVP does not, and M6 owns it.
* **Tempo.** ``70``-``72`` are decoded, but the project keeps its template's
  tempo.

A third is not a decision but a consequence: the pattern's step count is the
template's, so notes landing past its last step are **dropped**, not written.
The device disables notes past the last step rather than deleting them, so
writing them would put notes in the file that no hardware plays.

The work is in three layers, matching the export direction so the M8/M9 Swift
port translates arithmetic rather than a MIDI library:

1. :func:`read_clip` -- a ``mido.MidiFile`` becomes plain
   :class:`~ksp.midi_export.RenderedNote` data in ticks. The only part that
   knows what ``mido`` is.
2. :func:`quantise` -- ticks become steps, chords are reduced and everything
   out of bounds is dropped, still as plain data.
3. :func:`apply` -- placed notes go into a raw project dict.

Nothing here reads or writes a path, and nothing prints: the caller supplies a
parsed file and a template and decides where the result goes.
"""

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Final

import mido

from ksp import constants, mutate
from ksp.diagnostics import EMPTY_REPORT, Code, Collector, Report
from ksp.keys import key
from ksp.lenient_json import canonical
from ksp.midi_export import DEFAULT_STEPS_PER_BEAT, RenderedNote

#: MIDI's own default when a file carries no ``set_tempo``: 500,000
#: microseconds per beat, i.e. 120 BPM.
DEFAULT_TEMPO: Final = 500_000


@dataclass(frozen=True)
class ImportOptions:
    """Everything the MIDI file cannot tell us about the target pattern."""

    steps_per_beat: int = DEFAULT_STEPS_PER_BEAT
    """Step size. The device's own setting lives in the undecoded ``99``/``116``
    bitfield (spec 3.3), so it is supplied rather than read, exactly as in the
    export direction."""

    midi_track: int | None = None
    """Read only this track of the source file, counting from 1. ``None`` reads
    every track, which is what a type 0 file needs."""

    def __post_init__(self) -> None:
        if self.steps_per_beat < 1:
            raise ValueError("steps_per_beat must be at least 1")
        if self.midi_track is not None and self.midi_track < 1:
            raise ValueError("midi_track counts from 1")


@dataclass(frozen=True)
class Clip:
    """A MIDI file's note events, in ticks. No MIDI library involved."""

    notes: tuple[RenderedNote, ...]
    ticks_per_beat: int
    tempo_bpm: float
    source_tracks: tuple[int, ...]
    """Which tracks of the file the notes came from, counting from 1."""

    @property
    def channels(self) -> tuple[int, ...]:
        return tuple(sorted({note.channel for note in self.notes}))


@dataclass(frozen=True)
class PlacedNote:
    """One note addressed the way the device stores it: a 1-based step."""

    step: int
    pitch: int
    velocity: int


@dataclass(frozen=True)
class Placement:
    """A clip reduced to what one pattern can hold."""

    notes: tuple[PlacedNote, ...]
    step_count: int
    diagnostics: Report = EMPTY_REPORT


@dataclass(frozen=True)
class ImportResult:
    """A project with the clip written into it, ready to serialise."""

    raw: dict[str, int | str] = field(default_factory=dict)
    notes: tuple[PlacedNote, ...] = ()
    track: int = 1
    pattern: int = 1
    step_count: int = 0
    diagnostics: Report = EMPTY_REPORT

    @property
    def note_count(self) -> int:
        return len(self.notes)


def read_clip(midi: mido.MidiFile, options: ImportOptions | None = None) -> Clip:
    """Pair note-ons with their note-offs and return them in absolute ticks."""
    options = options or ImportOptions()

    tempo = DEFAULT_TEMPO
    notes: list[RenderedNote] = []
    sources: list[int] = []

    for number, track in enumerate(midi.tracks, start=1):
        if options.midi_track is not None and number != options.midi_track:
            continue

        tick = 0
        # (channel, pitch) -> (onset tick, velocity). A second note-on for a
        # pitch already sounding retriggers it, so the earlier one ends here.
        open_notes: dict[tuple[int, int], tuple[int, int]] = {}
        started = len(notes)

        for message in track:
            tick += message.time
            if message.type == "set_tempo":
                tempo = message.tempo
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

        # A note-on the file never closes still sounded; end it at the track's
        # last event rather than discarding it.
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

        if len(notes) > started:
            sources.append(number)

    notes.sort(key=lambda note: (note.tick, note.pitch))
    return Clip(
        notes=tuple(notes),
        ticks_per_beat=midi.ticks_per_beat,
        tempo_bpm=float(mido.tempo2bpm(tempo)),
        source_tracks=tuple(sources),
    )


def quantise(clip: Clip, *, step_count: int, options: ImportOptions | None = None) -> Placement:
    """Snap *clip* to a *step_count*-step grid, one note per step.

    Raises:
        ValueError: if *step_count* is outside the device's 1-64.
    """
    options = options or ImportOptions()
    if not 1 <= step_count <= constants.MAX_STEPS:
        raise ValueError(f"step count {step_count} out of range 1-{constants.MAX_STEPS}")

    collector = Collector()
    ticks_per_step = clip.ticks_per_beat / options.steps_per_beat

    if len(clip.source_tracks) > 1 or len(clip.channels) > 1:
        collector.add(
            Code.MULTIPLE_SOURCES,
            f"notes came from track(s) {_listed(clip.source_tracks)} and channel(s) "
            f"{_listed(tuple(c + 1 for c in clip.channels))} and were merged into one "
            "pattern; --midi-track picks just one",
        )

    # A pattern is a loop with no room for a lead-in, so the clip is anchored:
    # its first note becomes step 1. DAWs routinely export a clip from bar 5
    # with its ticks intact, and without this every note lands past the end.
    first = min((note.tick for note in clip.notes), default=0)
    origin = round(first / ticks_per_step) * ticks_per_step
    if origin:
        collector.add(
            Code.CLIP_ANCHORED,
            f"the clip starts {origin:g} tick(s) into the file; its first note was placed on "
            "step 1 and the rest moved with it, because a pattern is a loop with nowhere to "
            "keep a lead-in",
        )

    # Highest pitch wins the step. Sorting descending means the first note
    # reaching a step is the one kept, and every later one is a drop.
    by_step: dict[int, PlacedNote] = {}
    moved = 0
    dropped_chord = 0
    dropped_past_end = 0

    for note in sorted(clip.notes, key=lambda n: (n.tick, -n.pitch)):
        step = round((note.tick - origin) / ticks_per_step) + 1
        if (step - 1) * ticks_per_step != note.tick - origin:
            moved += 1
        if step > step_count:
            dropped_past_end += 1
            continue
        if step in by_step:
            dropped_chord += 1
            continue
        by_step[step] = PlacedNote(step=step, pitch=note.pitch, velocity=note.velocity)

    if moved:
        collector.add(
            Code.NOTES_QUANTISED,
            f"{moved} note(s) did not land on a 1/{options.steps_per_beat * 4} step "
            "and were moved to the nearest one",
            subjects=moved,
        )
    if dropped_chord:
        collector.add(
            Code.CHORD_REDUCED,
            f"{dropped_chord} note(s) shared a step with a higher one and were dropped; "
            "this conversion is monophonic",
            subjects=dropped_chord,
        )
    if dropped_past_end:
        collector.add(
            Code.PAST_PATTERN_END,
            f"{dropped_past_end} note(s) fall past step {step_count} and were dropped; "
            "the device disables notes past the last step rather than playing them",
            subjects=dropped_past_end,
        )
    if by_step:
        collector.add(
            Code.GATE_NOT_CARRIED,
            "note lengths are not carried; every note is written at gate "
            f"{constants.DEFAULT_GATE_LENGTH:g} steps, what a freshly placed note has "
            "on the device",
        )
        collector.add(
            Code.TEMPO_NOT_CARRIED,
            f"the source plays at {clip.tempo_bpm:g} BPM; tempo is not carried, so the "
            "project keeps the one its template holds",
        )

    return Placement(
        notes=tuple(by_step[step] for step in sorted(by_step)),
        step_count=step_count,
        diagnostics=collector.report(),
    )


def apply(
    raw: Mapping[str, int | str],
    placement: Placement,
    *,
    track: int,
    pattern: int,
) -> dict[str, int | str]:
    """Write *placement* into a copy of *raw*, one ``place_note`` per note."""
    result = dict(raw)
    for note in placement.notes:
        result = mutate.place_note(
            result,
            track=track,
            pattern=pattern,
            step=note.step,
            pitch=note.pitch,
            velocity=note.velocity,
        )
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
    item = _item_for_track(track)
    stored = _get(raw, item, constants.P_SEQ_STEP_COUNT, pattern)
    if stored is None:
        raise ValueError(f"track {track} pattern {pattern} declares no step count")
    return stored + constants.STEP_COUNT_OFFSET


def pattern_is_empty(raw: Mapping[str, int | str], *, track: int, pattern: int) -> bool:
    """Whether a melodic pattern's note pool holds nothing.

    Existence is ``50 != 127`` and nothing else -- never velocity (spec 4).
    """
    item = _item_for_track(track)
    slots = constants.POOL_CAPACITY // constants.MAX_STEPS
    return all(
        _get(raw, item, constants.P_SEQ_NOTE_STEP, pattern, slot, ordinal)
        in (constants.SENTINEL, None)
        for slot in range(1, slots + 1)
        for ordinal in range(1, constants.MAX_STEPS + 1)
    )


def track_is_melodic(raw: Mapping[str, int | str], *, track: int) -> bool:
    """Whether a track's mode flag says the melodic parameter set is live.

    ``86`` bit 6 is DRUM on Track 1 and ARP on Tracks 2-4 (spec 5). Either way
    the melodic pool is not what the device is playing from.
    """
    item = _item_for_track(track)
    bits = _get(raw, item, constants.P_TRACK_MODE_BITS)
    return not (bits or 0) & (1 << constants.DRUM_MODE_BIT)


def convert(
    midi: mido.MidiFile,
    raw: Mapping[str, int | str],
    *,
    track: int = 1,
    pattern: int = 1,
    options: ImportOptions | None = None,
) -> ImportResult:
    """Convert *midi* into a copy of the template *raw*.

    Raises:
        ValueError: if the target track is not in a melodic mode, or its
            pattern already holds notes. Appending to an occupied pool would
            interleave two takes, and emptying one means writing sentinels,
            which no hardware capture covers.
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
    return ImportResult(
        raw=apply(raw, placement, track=track, pattern=pattern),
        notes=placement.notes,
        track=track,
        pattern=pattern,
        step_count=placement.step_count,
        diagnostics=placement.diagnostics,
    )


def _get(raw: Mapping[str, int | str], item: int, param: int, *indices: int) -> int | None:
    """One integer out of a raw project, without copying it to use ``keys``."""
    value = raw.get(key(item, param, *indices))
    return value if isinstance(value, int) else None


def _item_for_track(track: int) -> int:
    if not 1 <= track <= len(constants.TRACK_ITEM_IDS):
        raise ValueError(f"track {track} out of range 1-{len(constants.TRACK_ITEM_IDS)}")
    return constants.TRACK_ITEM_IDS[track - 1]


def _listed(values: Sequence[int]) -> str:
    return ", ".join(str(value) for value in values) or "none"
