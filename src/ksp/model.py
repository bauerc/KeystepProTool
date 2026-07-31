"""The decoded object model: project -> tracks -> patterns -> notes.

What the flat key/value file becomes once both index spaces are resolved
(spec 4). Plain data with no reference back to the raw dict, so consumers never
need the key grammar.

Read-only by design: mutation belongs to M3+, once a byte-identical round-trip
proves what we write back is what MCC expects.
"""

from collections.abc import Mapping
from dataclasses import dataclass, field, replace
from typing import Any

from ksp.drum_map import DrumMap
from ksp.encoding import note_name
from ksp.types import ItemId, Lane, NoteIndex, NoteKind, PatternMode, Pitch, Step

__all__ = [
    "Note",
    "NoteKind",
    "Pattern",
    "PatternMode",
    "PatternTiming",
    "Project",
    "Track",
]


@dataclass(frozen=True)
class Note:
    """One entry from a slot's note list."""

    kind: NoteKind
    slot: int

    #: Ordinal in the note list. The file's own note index, distinct from
    #: ``step`` -- the two index spaces of spec 4.
    index: NoteIndex

    #: Physical step, 1-based here; the file stores it 0-based.
    step: Step

    #: MIDI pitch for a SEQ note, drum lane for a DRUM note. Reach it through
    #: :attr:`as_pitch` / :attr:`as_lane`, which check the kind.
    pitch: Pitch | Lane

    velocity: int
    gate_raw: int

    #: Displayed gate length, or ``None`` where the encoding is unmeasured (M7).
    gate: float | None

    #: Signed, already offset from the stored centre.
    time_shift: int

    randomness: int

    #: Which of the 16/32/48/64 sequences this note plays in.
    skip: tuple[int, ...]

    @property
    def as_pitch(self) -> Pitch:
        """The MIDI pitch, refusing a drum note whose value is a lane."""
        if self.kind is NoteKind.DRUM:
            raise TypeError("a drum note carries a lane, not a pitch")
        return Pitch(self.pitch)

    @property
    def as_lane(self) -> Lane:
        """The drum lane, refusing a melodic note whose value is a pitch."""
        if self.kind is NoteKind.SEQ:
            raise TypeError("a melodic note carries a pitch, not a lane")
        return Lane(self.pitch)

    def labelled(self, drum_map: DrumMap | None) -> str:
        """Human-readable pitch, resolving a drum lane through *drum_map*."""
        # Without a map a drum note can only be reported as its lane: which
        # MIDI note that lane sends is a device setting the file lacks.
        if self.kind is NoteKind.DRUM:
            if drum_map is None:
                return f"lane {self.pitch}"
            return drum_map.label_for_lane(self.as_lane)
        return f"{note_name(self.as_pitch)} ({self.pitch})"

    def to_dict(self, drum_map: DrumMap | None = None) -> dict[str, Any]:
        data: dict[str, Any] = {
            "kind": self.kind.value,
            "slot": self.slot,
            "index": self.index,
            "step": self.step,
            "pitch": self.pitch,
            "velocity": self.velocity,
            "gate_raw": self.gate_raw,
            "gate": self.gate,
            "time_shift": self.time_shift,
            "randomness": self.randomness,
            "skip": list(self.skip),
        }
        if drum_map is not None and self.kind is NoteKind.DRUM and drum_map.has_lane(self.as_lane):
            note = drum_map.note_for_lane(self.as_lane)
            data["drum_note"] = note
            data["drum_note_name"] = note_name(note)
        return data


@dataclass(frozen=True)
class PatternTiming:
    """The step count and swing of one of a pattern's parameter sets."""

    step_count: int
    swing_percent: int


@dataclass(frozen=True)
class Pattern:
    """One of a track's 16 patterns."""

    number: int
    mode: PatternMode

    #: From parameter 40, the firmware's own "this pattern holds data" flag.
    has_data: bool

    #: Per parameter set. The melodic and drum sets each carry their own step
    #: count and swing, so neither is collapsed into a single pair whose owner
    #: would be ambiguous. DRUM is absent on tracks 2-4.
    timing: Mapping[NoteKind, PatternTiming]

    notes: tuple[Note, ...]

    #: Inconsistencies found while decoding. Reported, never silently fixed --
    #: a reader that quietly repairs its input hides the surprises we want.
    warnings: tuple[str, ...] = ()

    @property
    def is_empty(self) -> bool:
        return not self.notes

    def notes_of(self, kind: NoteKind) -> tuple[Note, ...]:
        return tuple(n for n in self.notes if n.kind is kind)

    def timing_for(self, kind: NoteKind) -> PatternTiming:
        """The timing of *kind*, falling back to the melodic set."""
        timing = self.timing.get(kind)
        return self.timing[NoteKind.SEQ] if timing is None else timing

    @property
    def seq_step_count(self) -> int:
        return self.timing[NoteKind.SEQ].step_count

    @property
    def seq_swing_percent(self) -> int:
        return self.timing[NoteKind.SEQ].swing_percent

    @property
    def drum_step_count(self) -> int | None:
        drum = self.timing.get(NoteKind.DRUM)
        return None if drum is None else drum.step_count

    @property
    def drum_swing_percent(self) -> int | None:
        drum = self.timing.get(NoteKind.DRUM)
        return None if drum is None else drum.swing_percent

    def to_dict(self, drum_map: DrumMap | None = None) -> dict[str, Any]:
        return {
            "pattern": self.number,
            "mode": self.mode.value,
            "has_data": self.has_data,
            "seq_step_count": self.seq_step_count,
            "seq_swing_percent": self.seq_swing_percent,
            "drum_step_count": self.drum_step_count,
            "drum_swing_percent": self.drum_swing_percent,
            "notes": [n.to_dict(drum_map) for n in self.notes],
            "warnings": list(self.warnings),
        }


@dataclass(frozen=True)
class Track:
    """One of the four sequencer tracks."""

    number: int
    item_id: ItemId
    patterns: tuple[Pattern, ...]

    #: Whether the track's Arp/Drum mode bit (86 bit 6) is set. Only Track 1
    #: has a drum parameter set, and this says whether it is the live one.
    drum_mode: bool = False

    @property
    def is_empty(self) -> bool:
        return all(p.is_empty for p in self.patterns)

    def pattern(self, number: int) -> Pattern:
        """Pattern *number*, counting from 1."""
        return self.patterns[number - 1]

    def to_dict(self, drum_map: DrumMap | None = None) -> dict[str, Any]:
        return {
            "track": self.number,
            "item_id": self.item_id,
            "drum_mode": self.drum_mode,
            "patterns": [p.to_dict(drum_map) for p in self.patterns],
        }


@dataclass(frozen=True)
class Project:
    """A decoded ``.KeyStepPro`` project."""

    device: str

    #: Absent in the factory Default.KeyStepPro, present in user saves.
    version: str | None

    tempo_bpm: float
    global_swing_percent: int
    current_scene: int
    tracks: tuple[Track, ...]
    source_name: str = ""
    warnings: tuple[str, ...] = field(default=())

    def track(self, number: int) -> Track:
        """Track *number*, counting from 1."""
        return self.tracks[number - 1]

    def select(self, *, track: int | None = None, pattern: int | None = None) -> "Project":
        """A copy narrowed to one track and/or one pattern."""
        # replace() so fields added later survive narrowing untouched.
        tracks = tuple(t for t in self.tracks if track is None or t.number == track)
        if pattern is not None:
            tracks = tuple(
                replace(t, patterns=tuple(p for p in t.patterns if p.number == pattern))
                for t in tracks
            )
        return replace(self, tracks=tracks)

    def to_dict(self, drum_map: DrumMap | None = None) -> dict[str, Any]:
        data: dict[str, Any] = {
            "source": self.source_name,
            "device": self.device,
            "version": self.version,
            "tempo_bpm": self.tempo_bpm,
            "global_swing_percent": self.global_swing_percent,
            "current_scene": self.current_scene,
            "warnings": list(self.warnings),
        }
        if drum_map is not None:
            # Named at the top level because every resolved drum note depends
            # on it, and it is an assumption about the user's device.
            data["drum_map"] = drum_map.to_dict()
        data["tracks"] = [t.to_dict(drum_map) for t in self.tracks]
        return data
