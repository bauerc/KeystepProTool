"""The decoded object model: project -> tracks -> patterns -> notes.

This is what the flat key/value file becomes once both index spaces have been
resolved. Everything here is plain data with no reference back to the raw
dict, so consumers -- the dump CLI now, MIDI export at M2 -- never need to
know the key grammar.

The model is intentionally read-only. Mutation belongs to M3+, once there is a
byte-identical round-trip proving that what we write back is what MCC expects.
"""

from dataclasses import dataclass, replace
from enum import StrEnum
from typing import Any

from ksp import constants
from ksp.constants import note_name
from ksp.diagnostics import EMPTY_REPORT, Report
from ksp.drum_map import DrumMap


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


class PlaybackDirection(StrEnum):
    """How a pattern walks its steps (99 / 116 bits 5-6).

    ``UNKNOWN`` is the honest reading of the fourth value: two bits allow it
    but the device never produced it during T5.5, so nothing knows its name.
    """

    FORWARD = "forward"
    RANDOM = "random"
    WALK = "walk"
    UNKNOWN = "unknown"


_DIRECTIONS = {
    constants.DIRECTION_FORWARD: PlaybackDirection.FORWARD,
    constants.DIRECTION_RANDOM: PlaybackDirection.RANDOM,
    constants.DIRECTION_WALK: PlaybackDirection.WALK,
}


@dataclass(frozen=True)
class PatternBits:
    """One decoded 99 / 116 field.

    The sequencer and drum fields share this layout; only their defaults
    differ (spec 3.3). ``raw`` is kept so a caller can see the value the
    decode came from without going back to the file.
    """

    raw: int
    step_denominator: int
    """4, 8, 16 or 32 -- the step size as the device displays it."""

    triplet: bool
    polyrhythm: bool
    direction: PlaybackDirection
    unallocated: int
    """Bits set that tier 5 never accounted for. Always 0 in every known file."""

    @classmethod
    def decode(cls, raw: int) -> "PatternBits":
        return cls(
            raw=raw,
            step_denominator=constants.step_denominator(raw),
            triplet=constants.is_triplet(raw),
            polyrhythm=constants.is_polyrhythm(raw),
            direction=_DIRECTIONS.get(constants.direction_index(raw), PlaybackDirection.UNKNOWN),
            unallocated=constants.unallocated_bits(raw),
        )

    @property
    def steps_per_beat(self) -> int:
        return self.step_denominator // 4

    @property
    def label(self) -> str:
        """How the device writes it: ``1/16``, or ``1/16T`` for a triplet."""
        return f"1/{self.step_denominator}{'T' if self.triplet else ''}"

    def to_dict(self) -> dict[str, Any]:
        return {
            "raw": self.raw,
            "step_size": self.label,
            "step_denominator": self.step_denominator,
            "triplet": self.triplet,
            "polyrhythm": self.polyrhythm,
            "direction": self.direction.value,
            "unallocated": self.unallocated,
        }


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
    """Gate length in steps. The ladder covers all of 0-127, so this is
    ``None`` only for a ``gate_raw`` outside that range, i.e. a corrupt file.
    See ``constants.GATE_TABLE``."""

    time_shift: int
    """Signed, already offset from the stored centre of 49."""

    randomness: int
    skip: tuple[int, ...]
    """Which of the 16/32/48/64 sequences this note plays in."""

    active: bool = True
    """Whether the step-active flag says the device plays this note.

    Existence and audibility are different tests: a note is in the pool
    because ``50``/``54`` is not the sentinel, but it only sounds if its bit
    in ``48``/``52`` is set. Capture D1 toggled a drum step off without
    deleting the note -- the pool entry survived unchanged and the step did
    not sound. Defaults to True so a caller constructing a Note by hand gets
    an audible one.
    """

    @property
    def label(self) -> str:
        """Human-readable pitch: a note name, or a bare drum lane number."""
        return self.labelled(None)

    def labelled(self, drum_map: DrumMap | None) -> str:
        """Like :attr:`label`, but resolving a drum lane through *drum_map*.

        Without a map a drum note can only be reported as ``lane 0``, because
        which MIDI note that lane transmits is a device setting the file does
        not contain.
        """
        if self.kind is NoteKind.DRUM:
            if drum_map is None:
                return f"lane {self.pitch}"
            return drum_map.label_for_lane(self.pitch)
        return f"{note_name(self.pitch)} ({self.pitch})"

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
            "active": self.active,
        }
        if drum_map is not None and self.kind is NoteKind.DRUM and drum_map.has_lane(self.pitch):
            note = drum_map.note_for_lane(self.pitch)
            data["drum_note"] = note
            data["drum_note_name"] = note_name(note)
        return data


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
    seq_bits: PatternBits
    drum_step_count: int | None
    drum_swing_percent: int | None
    drum_bits: PatternBits | None
    root_note: int
    """Pitch class 0-11 (parameter 107). The octave the display shows is not
    stored anywhere in the file."""

    scale: int
    """Index into ``constants.SCALE_NAMES`` (parameter 108). One list serves
    both parameter sets -- there is no drum twin."""

    notes: tuple[Note, ...]
    diagnostics: Report = EMPTY_REPORT
    """Inconsistencies found while decoding. Reported, never silently fixed --
    a reader that quietly repairs its input hides exactly the surprises this
    milestone exists to find."""

    @property
    def warnings(self) -> tuple[str, ...]:
        """Every diagnostic in full, for callers that just want the text."""
        return self.diagnostics.messages

    @property
    def is_empty(self) -> bool:
        return not self.notes

    @property
    def scale_name(self) -> str | None:
        return constants.scale_name(self.scale)

    def notes_of(self, kind: NoteKind) -> tuple[Note, ...]:
        return tuple(n for n in self.notes if n.kind is kind)

    def bits(self, kind: NoteKind) -> PatternBits:
        """The 99 / 116 field governing *kind*, falling back to the melodic one
        on the tracks that have no drum set."""
        if kind is NoteKind.DRUM and self.drum_bits is not None:
            return self.drum_bits
        return self.seq_bits

    def to_dict(self, drum_map: DrumMap | None = None) -> dict[str, Any]:
        return {
            "pattern": self.number,
            "mode": self.mode.value,
            "has_data": self.has_data,
            "seq_step_count": self.seq_step_count,
            "seq_swing_percent": self.seq_swing_percent,
            "seq_bits": self.seq_bits.to_dict(),
            "drum_step_count": self.drum_step_count,
            "drum_swing_percent": self.drum_swing_percent,
            "drum_bits": self.drum_bits.to_dict() if self.drum_bits else None,
            "root_note": self.root_note,
            "scale": self.scale,
            "scale_name": self.scale_name,
            "notes": [n.to_dict(drum_map) for n in self.notes],
            "warnings": list(self.warnings),
            "diagnostics": self.diagnostics.to_list(),
        }


@dataclass(frozen=True)
class Track:
    """One of the four sequencer tracks."""

    number: int
    item_id: int
    patterns: tuple[Pattern, ...]
    drum_mode: bool = False
    """Whether the track's Arp/Drum mode bit (parameter 86, bit 6) is set.

    Only Track 1 has a drum parameter set, and this is what says whether it is
    the live one. It is track-level rather than per-pattern, matching the
    device's Drum button. Parameter 100 was expected to carry this and does
    not -- it reads 26 everywhere."""

    @property
    def is_empty(self) -> bool:
        return all(p.is_empty for p in self.patterns)

    def pattern(self, number: int) -> Pattern:
        """Return pattern *number*, counting from 1."""
        return self.patterns[number - 1]

    def to_dict(self, drum_map: DrumMap | None = None) -> dict[str, Any]:
        return {
            "track": self.number,
            "item_id": self.item_id,
            "drum_mode": self.drum_mode,
            "patterns": [p.to_dict(drum_map) for p in self.patterns],
        }


@dataclass(frozen=True)
class Chain:
    """One track's pattern chain within a scene (parameter 84).

    ``patterns`` is in chain order and 1-based, matching how the device
    numbers patterns; the file stores them 0-based.
    """

    track: int
    patterns: tuple[int, ...]

    def to_dict(self) -> dict[str, Any]:
        return {"track": self.track, "patterns": list(self.patterns)}


@dataclass(frozen=True)
class Scene:
    """One of the 16 scenes, holding a chain per track.

    Only tracks that actually chain appear: an unused slot reads the sentinel
    across all 16 entries, which is every scene of every sample project.
    """

    number: int
    chains: tuple[Chain, ...] = ()

    @property
    def is_empty(self) -> bool:
        return not self.chains

    def to_dict(self) -> dict[str, Any]:
        return {"scene": self.number, "chains": [c.to_dict() for c in self.chains]}


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
    scenes: tuple[Scene, ...] = ()
    source_name: str = ""
    diagnostics: Report = EMPTY_REPORT

    @property
    def warnings(self) -> tuple[str, ...]:
        return self.diagnostics.messages

    @property
    def chained_scenes(self) -> tuple[Scene, ...]:
        return tuple(s for s in self.scenes if not s.is_empty)

    def track(self, number: int) -> Track:
        """Return track *number*, counting from 1."""
        return self.tracks[number - 1]

    def select(self, *, track: int | None = None, pattern: int | None = None) -> "Project":
        """Return a copy narrowed to one track and/or one pattern.

        Uses ``replace`` so fields added later (``drum_mode``) survive
        narrowing without every caller being updated.
        """
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
            "scenes": [s.to_dict() for s in self.chained_scenes],
            "warnings": list(self.warnings),
            "diagnostics": self.diagnostics.to_list(),
        }
        if drum_map is not None:
            # Named at the top level because every resolved drum note below
            # depends on it, and it is an assumption about the user's device
            # rather than anything read from the file.
            data["drum_map"] = drum_map.to_dict()
        data["tracks"] = [t.to_dict(drum_map) for t in self.tracks]
        return data
