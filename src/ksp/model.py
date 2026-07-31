"""The decoded object model: project -> tracks -> patterns -> notes.

This is what the flat key/value file becomes once both index spaces have been
resolved. Everything here is plain data with no reference back to the raw
dict, so consumers -- the dump CLI now, MIDI export at M2 -- never need to
know the key grammar.

The model is intentionally read-only. Mutation belongs to M3+, once there is a
byte-identical round-trip proving that what we write back is what MCC expects.
"""

from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any

from ksp.constants import note_name


class NoteKind(StrEnum):
    """Which parameter set a note was decoded from.

    Track 1 carries a melodic and a drum set side by side, and they mean
    different things: a melodic note's value is a MIDI pitch, a drum note's is
    a lane index. Tagging each note is what lets a pattern hold both without
    the two becoming indistinguishable.
    """

    SEQ = "seq"
    DRUM = "drum"


class PatternMode(StrEnum):
    """Which parameter set(s) of a pattern hold notes.

    ``BOTH`` is not a hardware mode -- the device plays one or the other. It
    means the file has notes in both sets and we cannot yet tell which is
    live, so the reader reports everything rather than guessing.
    """

    SEQ = "seq"
    DRUM = "drum"
    BOTH = "both"
    EMPTY = "empty"


@dataclass(frozen=True)
class Note:
    """One entry from a slot's note list.

    ``step`` is 1-based here, matching how the hardware and the project
    descriptions count beats, though the file stores it 0-based.
    """

    kind: NoteKind
    slot: int
    index: int
    """Ordinal position in the note list, 1-based. This is the file's own note
    index -- distinct from ``step``, which is where it plays."""

    step: int
    pitch: int
    """MIDI pitch for a ``SEQ`` note; 0-based drum lane for a ``DRUM`` note
    (lane 0 is the kick, confirmed against project_5)."""

    velocity: int
    gate_raw: int
    gate: float | None
    """Displayed gate length, or ``None`` where the encoding is not yet
    measured. See ``constants.GATE_TABLE`` and roadmap M7."""

    time_shift: int
    """Signed, already offset from the stored centre of 49."""

    randomness: int
    skip: tuple[int, ...]
    """Which of the 16/32/48/64 sequences this note plays in."""

    @property
    def label(self) -> str:
        """Human-readable pitch: a note name, or a drum lane number."""
        if self.kind is NoteKind.DRUM:
            return f"lane {self.pitch}"
        return f"{note_name(self.pitch)} ({self.pitch})"

    def to_dict(self) -> dict[str, Any]:
        return {
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


@dataclass(frozen=True)
class Pattern:
    """One of a track's 16 patterns.

    The melodic and drum parameter sets each carry their own step count and
    swing, so both are reported rather than collapsing them into one pair of
    numbers that would silently belong to whichever set happened to win.
    ``drum_*`` is ``None`` on tracks 2-4, which have no drum set at all.
    """

    number: int
    mode: PatternMode
    has_data: bool
    """From parameter 40, the firmware's own "this pattern holds data" flag."""

    seq_step_count: int
    seq_swing_percent: int
    drum_step_count: int | None
    drum_swing_percent: int | None
    notes: tuple[Note, ...]
    warnings: tuple[str, ...] = ()
    """Inconsistencies found while decoding. Reported, never silently fixed --
    a reader that quietly repairs its input hides exactly the surprises this
    milestone exists to find."""

    @property
    def is_empty(self) -> bool:
        return not self.notes

    def notes_of(self, kind: NoteKind) -> tuple[Note, ...]:
        return tuple(n for n in self.notes if n.kind is kind)

    def to_dict(self) -> dict[str, Any]:
        return {
            "pattern": self.number,
            "mode": self.mode.value,
            "has_data": self.has_data,
            "seq_step_count": self.seq_step_count,
            "seq_swing_percent": self.seq_swing_percent,
            "drum_step_count": self.drum_step_count,
            "drum_swing_percent": self.drum_swing_percent,
            "notes": [n.to_dict() for n in self.notes],
            "warnings": list(self.warnings),
        }


@dataclass(frozen=True)
class Track:
    """One of the four sequencer tracks."""

    number: int
    item_id: int
    patterns: tuple[Pattern, ...]

    @property
    def is_empty(self) -> bool:
        return all(p.is_empty for p in self.patterns)

    def pattern(self, number: int) -> Pattern:
        """Return pattern *number*, counting from 1."""
        return self.patterns[number - 1]

    def to_dict(self) -> dict[str, Any]:
        return {
            "track": self.number,
            "item_id": self.item_id,
            "patterns": [p.to_dict() for p in self.patterns],
        }


@dataclass(frozen=True)
class Project:
    """A decoded ``.KeyStepPro`` project."""

    device: str
    version: str | None
    """Absent in the factory ``Default.KeyStepPro``, present in user saves."""

    tempo_bpm: float
    global_swing_percent: int
    current_scene: int
    tracks: tuple[Track, ...]
    source_name: str = ""
    warnings: tuple[str, ...] = field(default=())

    def track(self, number: int) -> Track:
        """Return track *number*, counting from 1."""
        return self.tracks[number - 1]

    def to_dict(self) -> dict[str, Any]:
        return {
            "source": self.source_name,
            "device": self.device,
            "version": self.version,
            "tempo_bpm": self.tempo_bpm,
            "global_swing_percent": self.global_swing_percent,
            "current_scene": self.current_scene,
            "warnings": list(self.warnings),
            "tracks": [t.to_dict() for t in self.tracks],
        }
