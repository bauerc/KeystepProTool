"""Structured diagnostics, and how they collapse for display."""

from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field, replace
from enum import StrEnum
from typing import Any, Final


class Severity(StrEnum):
    WARNING = "warning"
    ERROR = "error"


class Code(StrEnum):
    """What kind of problem this is. Grouping keys off these, not off text."""

    NO_VERSION_KEY = "no-version-key"
    MIXED_NOTE_SETS = "mixed-note-sets"
    DRUM_MODE_FLAG_DISAGREES = "drum-mode-flag-disagrees"
    HAS_DATA_FLAG_DISAGREES = "has-data-flag-disagrees"
    TRAILING_POOL_VALUES = "trailing-pool-values"
    DRUM_LANE_OUT_OF_RANGE = "drum-lane-out-of-range"
    FLAG_WITHOUT_NOTE = "flag-without-note"
    DISABLED_STEP_OFF = "disabled-step-off"
    PATTERN_BITS_UNKNOWN = "pattern-bits-unknown"
    SCALE_OFF_LIST = "scale-off-list"
    CHAIN_HAS_HOLE = "chain-has-hole"

    DRUM_MAP_ASSUMED = "drum-map-assumed"
    DRUM_MAP_DUPLICATE = "drum-map-duplicate"

    DISABLED_NOT_EXPORTED = "disabled-not-exported"
    DISABLED_EXPORTED = "disabled-exported"
    STALE_NOTE_SET = "stale-note-set"
    SWING_UNVERIFIED = "swing-unverified"
    GLOBAL_SWING_NOT_APPLIED = "global-swing-not-applied"
    DISABLED_PAST_LAST_STEP = "disabled-past-last-step"
    GATE_SHORTENED = "gate-shortened"
    GATE_OFF_LADDER = "gate-off-ladder"
    TIME_SHIFT_CLIPPED = "time-shift-clipped"
    STEP_SKIP_SINGLE_PASS = "step-skip-single-pass"
    STEP_SKIP_EXPANDED = "step-skip-expanded"
    DIRECTION_NOT_APPLIED = "direction-not-applied"
    DRUM_LANE_DROPPED = "drum-lane-dropped"
    TRACK_LENGTHS_DIFFER = "track-lengths-differ"
    OVERLAPS_RESOLVED = "overlaps-resolved"

    CLIP_ANCHORED = "clip-anchored"
    NOTES_QUANTISED = "notes-quantised"
    PAST_PATTERN_END = "past-pattern-end"
    MULTIPLE_SOURCES = "multiple-sources"
    PATTERN_SPLIT = "pattern-split"
    PATTERN_SEGMENTED = "pattern-segmented"
    POOL_OVERFLOW = "pool-overflow"
    TRACKS_DROPPED = "tracks-dropped"
    GATE_APPROXIMATED = "gate-approximated"
    GATE_PAST_END = "gate-past-end"
    TEMPO_CARRIED = "tempo-carried"
    TEMPO_CHANGES_IGNORED = "tempo-changes-ignored"
    SWING_FITTED = "swing-fitted"
    TIMING_RESIDUAL = "timing-residual"
    DRUM_MAP_FITTED = "drum-map-fitted"
    DRUM_PITCH_UNMAPPED = "drum-pitch-unmapped"
    TRACK_SPLIT_BY_CHANNEL = "track-split-by-channel"
    CONTROLLERS_DROPPED = "controllers-dropped"
    TEMPO_OUT_OF_RANGE = "tempo-out-of-range"
    SOURCE_TEMPO_DIFFERS = "source-tempo-differs"
    SOURCE_RESOLUTION_DIFFERS = "source-resolution-differs"
    SOURCE_METER_DIFFERS = "source-meter-differs"


@dataclass(frozen=True)
class Summary:
    """How one code's instances read once collapsed."""

    # ``template`` is formatted with {sites} and {subjects}, each already a
    # counted noun phrase; a template using neither is fine.

    template: str
    subject: str = "note"
    site: str = "pattern"


#: One entry per Code, kept as data so adding one needs no new branch.
SUMMARIES: Mapping[Code, Summary] = {
    Code.NO_VERSION_KEY: Summary("no 'version' key (factory template rather than a saved project)"),
    Code.MIXED_NOTE_SETS: Summary(
        "{sites} hold both melodic and drum notes; parameter 86 bit 6 decides which set plays "
        "and the other is stale. Both are reported",
    ),
    Code.DRUM_MODE_FLAG_DISAGREES: Summary(
        "{sites} disagree with parameter 86 bit 6 about which note set is live",
    ),
    Code.HAS_DATA_FLAG_DISAGREES: Summary(
        "{sites} hold notes but parameter 40 says they have no data",
    ),
    Code.TRAILING_POOL_VALUES: Summary(
        "{subjects} in {sites} sit after the end of a melodic note list and were ignored",
        subject="value",
    ),
    Code.DRUM_LANE_OUT_OF_RANGE: Summary(
        "{sites} hold drum lanes outside the device's 24",
    ),
    Code.PATTERN_BITS_UNKNOWN: Summary(
        "{sites} set a bit of parameter 99 / 116 that no capture accounted for (spec 3.3)",
    ),
    Code.SCALE_OFF_LIST: Summary(
        "{sites} hold a scale index the device's list does not reach",
    ),
    Code.CHAIN_HAS_HOLE: Summary(
        "{sites} hold a pattern chain with a gap in it; everything after the gap was ignored",
        site="scene",
    ),
    Code.FLAG_WITHOUT_NOTE: Summary(
        "{subjects} across {sites} are flagged active but hold no note. Every flagged step "
        "should have a pooled note, so this means the note pool was decoded wrongly rather "
        "than that the file is damaged",
        subject="step",
    ),
    Code.DISABLED_STEP_OFF: Summary(
        "{sites} hold disabled notes ({subjects}, step turned off); they do not play on the device",
    ),
    Code.DRUM_MAP_ASSUMED: Summary(
        "drum lanes were resolved through an assumed map; the KeyStep Pro drum map is a device "
        "global and is not stored in the project file (spec 3.2.1)",
    ),
    Code.DRUM_MAP_DUPLICATE: Summary(
        "{subjects} are mapped from more than one drum lane; reverse lookup will use the lowest",
    ),
    Code.DISABLED_NOT_EXPORTED: Summary(
        "{subjects} across {sites} are disabled (step turned off) and were not exported; "
        "--include-disabled exports them",
    ),
    Code.STALE_NOTE_SET: Summary(
        "{sites} hold notes in both parameter sets; only the set parameter 86 bit 6 calls live "
        "was exported (--include-stale exports both)",
    ),
    Code.SWING_UNVERIFIED: Summary(
        "{sites} carry swing; which steps move is measured (the even ones) but how far is not, "
        "so the standard shuffle formula was used",
    ),
    Code.GLOBAL_SWING_NOT_APPLIED: Summary(
        "the project sets a global swing (parameter 74); the per-pattern value takes precedence "
        "on the device, so only the per-pattern value was applied",
    ),
    Code.DISABLED_PAST_LAST_STEP: Summary(
        "{subjects} across {sites} are disabled (past the last step) and were not exported; "
        "--include-disabled exports them",
    ),
    Code.DISABLED_EXPORTED: Summary(
        "{subjects} across {sites} are disabled but were exported because --include-disabled "
        "is set; the device does not play them",
    ),
    Code.GATE_SHORTENED: Summary(
        "{sites} hold notes whose gate ran past the end of the pattern; they were shortened to it",
    ),
    Code.GATE_OFF_LADDER: Summary(
        "{subjects} are off the 0-127 gate ladder and cannot be decoded; "
        "exported at the default length",
        subject="encoding",
    ),
    Code.TIME_SHIFT_CLIPPED: Summary(
        "{subjects} are shifted to before the start of the export and were held at it",
        subject="note",
    ),
    Code.STEP_SKIP_SINGLE_PASS: Summary(
        "notes are set to play on only some of the 16/32/48/64 sequences, which the device "
        "plays as four repeats; --passes 1 renders one and includes them all",
    ),
    Code.STEP_SKIP_EXPANDED: Summary(
        "{sites} were rendered as repeats so each note lands on the 16/32/48/64 "
        "sequences its mask selects",
    ),
    Code.DIRECTION_NOT_APPLIED: Summary(
        "{sites} play in a non-forward direction, which no MIDI file can express; the "
        "export renders them forward",
    ),
    Code.DRUM_LANE_DROPPED: Summary(
        "{subjects} lie outside the device's 24 drum lanes and were dropped",
        subject="lane",
    ),
    Code.TRACK_LENGTHS_DIFFER: Summary(
        "tracks hold different total lengths; this export aligns pattern N across tracks, "
        "but the device loops each track on its own, so they drift apart",
    ),
    Code.OVERLAPS_RESOLVED: Summary(
        "{sites} hold overlapping notes of the same pitch; they were shortened so each has "
        "its own note-off",
    ),
    Code.CLIP_ANCHORED: Summary(
        "the clip does not start at the beginning of the file; its first note was placed on "
        "step 1 and the rest moved with it. A pattern is a loop, so it has nowhere to keep "
        "the lead-in",
    ),
    Code.NOTES_QUANTISED: Summary(
        "{subjects} did not land on a step and were moved to the nearest one",
    ),
    Code.PAST_PATTERN_END: Summary(
        "{subjects} fall past the pattern's last step and were dropped; the device disables "
        "notes beyond it, so writing them would put silent notes in the file",
    ),
    Code.MULTIPLE_SOURCES: Summary(
        "notes were taken from more than one source track or channel and merged into one "
        "pattern; --midi-track picks just one",
    ),
    Code.PATTERN_SPLIT: Summary(
        "{sites} run longer than the device's 64-step maximum and were split across consecutive "
        "patterns, chained in the current scene so they play as one sequence",
        site="track",
    ),
    Code.PATTERN_SEGMENTED: Summary(
        "{sites} were cut at the bars asked for and laid across consecutive patterns, chained "
        "in the current scene so they play as one sequence",
        site="track",
    ),
    Code.POOL_OVERFLOW: Summary(
        "{subjects} did not fit; a pattern holds 192 events and the firmware refuses the rest",
    ),
    Code.TRACKS_DROPPED: Summary(
        "{subjects} had nowhere to go; the device has four tracks",
        subject="source track",
    ),
    Code.GATE_APPROXIMATED: Summary(
        "{subjects} have a length the gate ladder cannot express exactly and took the nearest "
        "rung; the ladder is coarse above 3 steps",
    ),
    Code.GATE_PAST_END: Summary(
        "{subjects} are held past the pattern's last step; the device wraps the loop rather than "
        "sustaining them",
    ),
    Code.TEMPO_CARRIED: Summary("the project tempo was set from the source file"),
    Code.TEMPO_CHANGES_IGNORED: Summary(
        "the source changes tempo partway through; the device stores one tempo per project, so "
        "only the first was taken",
    ),
    Code.SWING_FITTED: Summary(
        "{sites} carry a groove that was fitted to the device's per-pattern swing",
        site="pattern",
    ),
    Code.TIMING_RESIDUAL: Summary(
        "{subjects} sit further off the grid than swing and time shift together can express, and "
        "were left at the nearest representable position",
    ),
    Code.DRUM_MAP_FITTED: Summary(
        "no drum map was given, so one was fitted to the source pitches. The real map lives in "
        "device settings and is not in the project file",
    ),
    Code.DRUM_PITCH_UNMAPPED: Summary(
        "{subjects} fall outside the 24 lanes the drum map covers and were dropped",
    ),
    Code.TRACK_SPLIT_BY_CHANNEL: Summary(
        "{subjects} shared one source track and each became a device track of its own, except "
        "where a flag merged them; a type 0 file tells its instruments apart by channel and "
        "nothing else",
        subject="channel",
    ),
    Code.CONTROLLERS_DROPPED: Summary(
        "{subjects} are not notes and were dropped; the device's patterns store notes only",
        subject="event",
    ),
    Code.TEMPO_OUT_OF_RANGE: Summary(
        "the source's tempo is outside the 30-240 BPM the device runs at, and was held to the "
        "nearest end of it",
    ),
    Code.SOURCE_TEMPO_DIFFERS: Summary(
        "the source files do not all run at the same tempo; the device stores one tempo per "
        "project, so the first file's was taken",
    ),
    Code.SOURCE_RESOLUTION_DIFFERS: Summary(
        "the source files are not all written at the same resolution; their notes were rescaled "
        "to the first file's",
    ),
    Code.SOURCE_METER_DIFFERS: Summary(
        "the source files are not all in the same time signature; bar length was taken from the "
        "first file's",
    ),
}


@dataclass(frozen=True)
class Site:
    """Where a diagnostic came from. Every part is optional."""

    track: int | None = None
    pattern: int | None = None
    kind: str | None = None
    slot: int | None = None
    scene: int | None = None

    def describe(self) -> str:
        parts = []
        if self.scene is not None:
            parts.append(f"scene {self.scene}")
        if self.track is not None:
            parts.append(f"track {self.track}")
        if self.pattern is not None:
            parts.append(f"pattern {self.pattern}")
        if self.slot is not None:
            parts.append(f"slot {self.slot}")
        text = " ".join(parts)
        if self.kind is not None:
            text = f"{text} ({self.kind})" if text else f"({self.kind})"
        return text

    def to_dict(self) -> dict[str, Any]:
        return {"track": self.track, "pattern": self.pattern, "kind": self.kind, "slot": self.slot}


#: Shared "nowhere in particular". Site is frozen, so one instance is enough.
NO_SITE: Final = Site()


@dataclass(frozen=True)
class Diagnostic:
    """One occurrence of one problem."""

    code: Code
    detail: str
    """The full sentence ``--verbose`` shows. No site or "warning:" prefix;
    both are added when rendering."""

    site: Site = NO_SITE
    severity: Severity = Severity.WARNING
    subjects: int = 1
    """How many notes, steps or lanes this occurrence covers; summed when collapsed."""

    @property
    def message(self) -> str:
        where = self.site.describe()
        return f"{where}: {self.detail}" if where else self.detail

    def at(
        self,
        *,
        track: int | None = None,
        pattern: int | None = None,
        kind: str | None = None,
        slot: int | None = None,
    ) -> "Diagnostic":
        """Copy with the given site parts filled in, leaving the rest alone."""
        site = replace(
            self.site,
            track=self.site.track if track is None else track,
            pattern=self.site.pattern if pattern is None else pattern,
            kind=self.site.kind if kind is None else kind,
            slot=self.site.slot if slot is None else slot,
        )
        return replace(self, site=site)

    def to_dict(self) -> dict[str, Any]:
        return {
            "code": str(self.code),
            "severity": str(self.severity),
            "site": self.site.to_dict(),
            "detail": self.detail,
            "subjects": self.subjects,
        }


@dataclass(frozen=True)
class Group:
    """Every occurrence of one code, and what they add up to."""

    code: Code
    severity: Severity
    entries: tuple[Diagnostic, ...]

    @property
    def sites(self) -> int:
        return len({e.site for e in self.entries})

    @property
    def subjects(self) -> int:
        return sum(e.subjects for e in self.entries)

    @property
    def headline(self) -> str:
        """The collapsed line."""
        # A group of one keeps its own message, which still carries its site.
        if len(self.entries) == 1:
            return self.entries[0].message
        summary = SUMMARIES[self.code]
        return summary.template.format(
            sites=_counted(self.sites, summary.site),
            subjects=_counted(self.subjects, summary.subject),
        )


@dataclass(frozen=True)
class Report:
    """An immutable set of diagnostics, in the order they were raised."""

    entries: tuple[Diagnostic, ...] = ()

    def __bool__(self) -> bool:
        return bool(self.entries)

    def __len__(self) -> int:
        return len(self.entries)

    def __iter__(self):  # type: ignore[no-untyped-def]
        return iter(self.entries)

    @property
    def messages(self) -> tuple[str, ...]:
        return tuple(e.message for e in self.entries)

    def grouped(self) -> tuple[Group, ...]:
        """One group per code, in the order each code first appeared."""
        order: list[Code] = []
        by_code: dict[Code, list[Diagnostic]] = {}
        for entry in self.entries:
            if entry.code not in by_code:
                order.append(entry.code)
                by_code[entry.code] = []
            by_code[entry.code].append(entry)
        return tuple(
            Group(code=code, severity=by_code[code][0].severity, entries=tuple(by_code[code]))
            for code in order
        )

    def render(self, *, verbose: bool = False) -> tuple[str, ...]:
        if verbose:
            return self.messages
        return tuple(group.headline for group in self.grouped())

    def note(self, *, verbose: bool = False) -> str | None:
        """The "there is more to see" line, or None when there is not."""
        if verbose:
            return None
        kinds = len(self.grouped())
        if len(self.entries) <= kinds:
            return None
        return (
            f"{_counted(len(self.entries), 'warning')} collapsed into "
            f"{_counted(kinds, 'kind')}; --verbose for detail"
        )

    def merge(self, other: "Report") -> "Report":
        """Concatenate, dropping anything the result already says."""
        collector = Collector()
        collector.extend(self.entries)
        collector.extend(other.entries)
        return collector.report()

    def to_list(self) -> list[dict[str, Any]]:
        return [e.to_dict() for e in self.entries]


#: Shared "nothing to report". Report is frozen, so one instance is enough.
EMPTY_REPORT: Final = Report()


@dataclass
class Collector:
    """Builds a :class:`Report`, dropping exact repeats."""

    # Keyed on (code, site, detail), not the rendered string, so two alike
    # diagnostics from different patterns both survive.

    _entries: list[Diagnostic] = field(default_factory=list)
    _seen: set[tuple[Code, Site, str]] = field(default_factory=set)

    def add(
        self,
        code: Code,
        detail: str,
        *,
        site: Site = NO_SITE,
        severity: Severity = Severity.WARNING,
        subjects: int = 1,
    ) -> None:
        self.push(
            Diagnostic(code=code, detail=detail, site=site, severity=severity, subjects=subjects)
        )

    def push(self, diagnostic: Diagnostic) -> None:
        key = (diagnostic.code, diagnostic.site, diagnostic.detail)
        if key in self._seen:
            return
        self._seen.add(key)
        self._entries.append(diagnostic)

    def extend(self, diagnostics: Iterable[Diagnostic]) -> None:
        for diagnostic in diagnostics:
            self.push(diagnostic)

    def report(self) -> Report:
        return Report(tuple(self._entries))


def _counted(count: int, noun: str) -> str:
    """Render a count with its noun: 3 -> '3 notes', 1 -> '1 note'."""
    return f"{count} {noun}" if count == 1 else f"{count} {noun}s"
