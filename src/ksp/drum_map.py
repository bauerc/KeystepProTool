"""Mapping the KeyStep Pro's 24 drum lanes to MIDI note numbers.

Parameter 117 stores a **lane index**, not a pitch. Which note a lane transmits
is a global device setting that no project file contains and none can be
written into -- spec 3.2.1 has the MCC field definitions and the evidence.

So this module holds an *assumption about the user's device*, never a decoded
fact, and every consumer is expected to say which map it used.

Chromatic mode is implemented as lane *i* -> ``low + i``, matching Arturia's
"which note the lowest key will trigger". That reading and the factory default
of 36 are both unconfirmed on hardware (roadmap Test D1).
"""

from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any, Final, Self

from ksp.constants import DRUM_LANE_COUNT
from ksp.encoding import note_name
from ksp.types import Lane, Pitch

#: Arturia's documented default; the Custom defaults in KeyStepPro.json are
#: 36..59, i.e. a chromatic run from here.
DEFAULT_CHROMATIC_LOW: Final = 36

#: globalParamId 79 (Drum output) defaults to 10, unlike tracks 1-4 (0-3).
DEFAULT_DRUM_CHANNEL: Final = 10

#: Highest Low note MCC will accept in chromatic mode.
MAX_CHROMATIC_LOW: Final = 103

MIN_NOTE: Final = 0
MAX_NOTE: Final = 127

#: General MIDI percussion names, keyed by **MIDI note rather than by lane**,
#: so they stay correct under any drum map -- including a custom one where
#: lane order says nothing about which instrument is where.
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
    """Lane index -> MIDI note, for all 24 lanes.

    Construct through :meth:`chromatic` or :meth:`custom`, which set a
    descriptive ``name`` callers are expected to print alongside any resolved
    note -- the mapping is an assumption about the user's hardware.
    """

    notes: tuple[Pitch, ...]
    name: str = "chromatic-36"

    #: Non-fatal oddities, e.g. a custom map sending two lanes to one note.
    #: Reported, never silently repaired.
    warnings: tuple[str, ...] = field(default=())

    def __post_init__(self) -> None:
        if len(self.notes) != DRUM_LANE_COUNT:
            raise ValueError(
                f"a drum map needs exactly {DRUM_LANE_COUNT} notes, got {len(self.notes)}"
            )
        for lane, note in enumerate(self.notes):
            if not MIN_NOTE <= note <= MAX_NOTE:
                raise ValueError(f"lane {lane} maps to note {note}, outside {MIN_NOTE}-{MAX_NOTE}")

        duplicates = sorted({n for n in self.notes if self.notes.count(n) > 1})
        if duplicates and not self.warnings:
            # Permitted by the hardware, so not an error -- but it makes
            # note -> lane lossy, and silently picking one lane is exactly the
            # kind of quiet wrong answer this project avoids.
            object.__setattr__(
                self,
                "warnings",
                tuple(
                    f"note {n} is mapped from lanes "
                    f"{[i for i, v in enumerate(self.notes) if v == n]}; "
                    f"reverse lookup will use the lowest"
                    for n in duplicates
                ),
            )

    @classmethod
    def chromatic(cls, low: int = DEFAULT_CHROMATIC_LOW) -> Self:
        """Lane *i* plays ``low + i``, the device's Chromatic mode."""
        # MCC's own cap of 103 is enforced rather than a wider limit derived
        # from it: that puts the top lane at 126, and whether the missing 127
        # is an off-by-one in Arturia's range or in our low+i reading is
        # unconfirmed (Test D1). 103 + 23 cannot overflow, so no second check.
        if not MIN_NOTE <= low <= MAX_CHROMATIC_LOW:
            raise ValueError(f"chromatic low note {low} is outside {MIN_NOTE}-{MAX_CHROMATIC_LOW}")
        return cls(
            notes=tuple(Pitch(n) for n in range(low, low + DRUM_LANE_COUNT)),
            name=f"chromatic-{low}",
        )

    @classmethod
    def custom(cls, notes: Sequence[int]) -> Self:
        """An explicit 24-entry map, the device's Custom Notes mode."""
        return cls(notes=tuple(Pitch(n) for n in notes), name="custom")

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Self:
        """Build from an already-parsed config mapping.

        Takes a dict, not a path: this module must not decide where files live.
        """
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

    def has_lane(self, lane: Lane) -> bool:
        """Whether *lane* is one the device actually has."""
        return 0 <= lane < DRUM_LANE_COUNT

    def note_for_lane(self, lane: Lane) -> Pitch:
        """The MIDI note lane *lane* transmits."""
        if not self.has_lane(lane):
            raise ValueError(f"lane {lane} is outside 0-{DRUM_LANE_COUNT - 1}")
        return self.notes[lane]

    def lane_for_note(self, note: Pitch) -> Lane | None:
        """The lane that plays *note*, or ``None`` if the map does not reach it."""
        # None is a real answer: snapping an unmapped hit to the nearest lane
        # would play the wrong instrument with nothing to signal it -- the same
        # failure mode as a guessed gate table.
        for lane, mapped in enumerate(self.notes):
            if mapped == note:
                return Lane(lane)
        return None

    def describe(self) -> str:
        """One line naming the map and flagging that it is an assumption."""
        chromatic = self.name.startswith("chromatic-")
        what = f"chromatic from {self.notes[0]}" if chromatic else "custom"
        return f"{what} (assumed - not in file)"

    def label_for_lane(self, lane: Lane) -> str:
        """Render a lane as ``lane 0 -> C1 (36) Bass Drum 1``."""
        # A lane the device lacks is shown as-is rather than resolved: the
        # reader warns about those, and inventing a note would hide it.
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
