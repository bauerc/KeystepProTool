"""Mapping the KeyStep Pro's 24 drum lanes to MIDI note numbers."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any, Final

from ksp.constants import DRUM_LANE_COUNT, note_name
from ksp.diagnostics import EMPTY_REPORT, Code, Collector, Report

#: The Low note the device's Drum Map menu defaults to.
DEFAULT_CHROMATIC_LOW: Final = 36

#: ``globalParamId 79`` (Drum output), which defaults apart from tracks 1-4.
DEFAULT_DRUM_CHANNEL: Final = 10

#: Highest Low note the device's encoder reaches in chromatic mode.
MAX_CHROMATIC_LOW: Final = 103

MIN_NOTE: Final = 0
MAX_NOTE: Final = 127

#: General MIDI percussion names, keyed by **MIDI note, never by lane**, so
#: they stay correct under a custom map whose lane order means nothing.
GM_DRUM_NAMES: Final[dict[int, str]] = {
    35: "Acoustic Bass Drum",
    36: "Bass Drum 1",
    37: "Side Stick",
    38: "Acoustic Snare",
    39: "Hand Clap",
    40: "Electric Snare",
    41: "Low Floor Tom",
    42: "Closed Hi-Hat",
    43: "High Floor Tom",
    44: "Pedal Hi-Hat",
    45: "Low Tom",
    46: "Open Hi-Hat",
    47: "Low-Mid Tom",
    48: "Hi-Mid Tom",
    49: "Crash Cymbal 1",
    50: "High Tom",
    51: "Ride Cymbal 1",
    52: "Chinese Cymbal",
    53: "Ride Bell",
    54: "Tambourine",
    55: "Splash Cymbal",
    56: "Cowbell",
    57: "Crash Cymbal 2",
    58: "Vibraslap",
    59: "Ride Cymbal 2",
    60: "Hi Bongo",
    61: "Low Bongo",
    62: "Mute Hi Conga",
    63: "Open Hi Conga",
    64: "Low Conga",
    65: "High Timbale",
    66: "Low Timbale",
    67: "High Agogo",
    68: "Low Agogo",
    69: "Cabasa",
    70: "Maracas",
    71: "Short Whistle",
    72: "Long Whistle",
    73: "Short Guiro",
    74: "Long Guiro",
    75: "Claves",
    76: "Hi Wood Block",
    77: "Low Wood Block",
    78: "Mute Cuica",
    79: "Open Cuica",
    80: "Mute Triangle",
    81: "Open Triangle",
}


@dataclass(frozen=True)
class DrumMap:
    """Lane index -> MIDI note, for all 24 lanes. Construct through :meth:`chromatic`
    or :meth:`custom`: the ``name`` they set is what callers print beside a resolved note."""

    notes: tuple[int, ...]
    name: str = "chromatic-36"
    diagnostics: Report = EMPTY_REPORT
    """Non-fatal oddities, e.g. two lanes on one note. Reported, never repaired."""

    @property
    def warnings(self) -> tuple[str, ...]:
        return self.diagnostics.messages

    def __post_init__(self) -> None:
        if len(self.notes) != DRUM_LANE_COUNT:
            raise ValueError(
                f"a drum map needs exactly {DRUM_LANE_COUNT} notes, got {len(self.notes)}"
            )
        for lane, note in enumerate(self.notes):
            if not MIN_NOTE <= note <= MAX_NOTE:
                raise ValueError(f"lane {lane} maps to note {note}, outside {MIN_NOTE}-{MAX_NOTE}")

        duplicates = sorted({n for n in self.notes if self.notes.count(n) > 1})
        if duplicates and not self.diagnostics:
            # The hardware permits this, so it is not an error, but it makes
            # note -> lane lossy.
            collector = Collector()
            for note in duplicates:
                collector.add(
                    Code.DRUM_MAP_DUPLICATE,
                    f"note {note} is mapped from lanes "
                    f"{[i for i, v in enumerate(self.notes) if v == note]}; "
                    f"reverse lookup will use the lowest",
                )
            object.__setattr__(self, "diagnostics", collector.report())

    @classmethod
    def chromatic(cls, low: int = DEFAULT_CHROMATIC_LOW) -> DrumMap:
        """Lane *i* plays ``low + i``, the device's Chromatic mode."""
        # The 103 cap is Arturia's, not an off-by-one, and it is also why no
        # separate overflow check is needed: 103 + 23 cannot exceed 127.
        if not MIN_NOTE <= low <= MAX_CHROMATIC_LOW:
            raise ValueError(f"chromatic low note {low} is outside {MIN_NOTE}-{MAX_CHROMATIC_LOW}")
        return cls(
            notes=tuple(range(low, low + DRUM_LANE_COUNT)),
            name=f"chromatic-{low}",
        )

    @classmethod
    def custom(cls, notes: Sequence[int]) -> DrumMap:
        """An explicit 24-entry map, the device's Custom Notes mode."""
        return cls(notes=tuple(notes), name="custom")

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> DrumMap:
        """Build from an already-parsed config mapping."""
        mode = data.get("mode", "chromatic")
        if mode == "chromatic":
            low = data.get("low", DEFAULT_CHROMATIC_LOW)
            if not isinstance(low, int):
                raise ValueError(f"'low' holds {type(low).__name__}, expected int")
            return cls.chromatic(low)
        if mode == "custom":
            notes = data.get("notes")
            if not isinstance(notes, list) or not all(isinstance(n, int) for n in notes):
                raise ValueError("'notes' must be a list of integers")
            return cls.custom(notes)
        raise ValueError(f"unknown drum map mode {mode!r}, expected 'chromatic' or 'custom'")

    def has_lane(self, lane: int) -> bool:
        """Whether *lane* is one the device actually has."""
        return 0 <= lane < DRUM_LANE_COUNT

    def note_for_lane(self, lane: int) -> int:
        """The MIDI note lane *lane* transmits."""
        if not self.has_lane(lane):
            raise ValueError(f"lane {lane} is outside 0-{DRUM_LANE_COUNT - 1}")
        return self.notes[lane]

    def lane_for_note(self, note: int) -> int | None:
        """The lane that plays *note*, or ``None`` if the map does not reach it.
        ``None`` is a real answer: snapping to the nearest lane plays the wrong drum."""
        for lane, mapped in enumerate(self.notes):
            if mapped == note:
                return lane
        return None

    def describe(self) -> str:
        """One line naming the map and flagging that it is an assumption."""
        chromatic = self.name.startswith("chromatic-")
        what = f"chromatic from {self.notes[0]}" if chromatic else "custom"
        return f"{what} (assumed - not in file)"

    def label_for_lane(self, lane: int) -> str:
        """Render a lane as ``lane 0 -> C1 (36) Bass Drum 1``.
        A lane the device does not have is shown as-is rather than resolved."""
        if not self.has_lane(lane):
            return f"lane {lane} (out of range)"
        note = self.note_for_lane(lane)
        name = GM_DRUM_NAMES.get(note)
        rendered = f"lane {lane} -> {note_name(note)} ({note})"
        return f"{rendered} {name}" if name else rendered

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "notes": list(self.notes),
            "warnings": list(self.warnings),
        }
