"""Structured diagnostics, and how they collapse for display.

The format has more unknowns than a converter can hide, so this package says
what it assumed rather than deciding quietly (see CLAUDE.md). The problem is
volume: one misread encoding affects dozens of notes across a dozen patterns,
and as free text that buries the one-off findings that matter most.

So a diagnostic is a record, not a sentence. It carries a stable ``Code``, the
``Site`` it came from, and how many notes or steps it is about. Reporting can
then collapse a code's instances into a single counted line, and expand them
again on request, without pattern-matching on English.

Adding one means: a ``Code`` member, a ``SUMMARIES`` entry, and the call site.
There is no class per diagnostic -- the variation is data.

This module is pure. It builds strings but never prints them; ``ksp_cli``
decides where they go.
"""

from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field, replace
from enum import StrEnum
from typing import Any, Final


class Severity(StrEnum):
    WARNING = "warning"
    ERROR = "error"


class Code(StrEnum):
    """What kind of problem this is. Grouping keys off these, not off text."""

    # --- reader ---
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

    # --- drum map ---
    DRUM_MAP_ASSUMED = "drum-map-assumed"
    DRUM_MAP_DUPLICATE = "drum-map-duplicate"

    # --- export ---
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

    # --- import ---
    CLIP_ANCHORED = "clip-anchored"
    CHORD_REDUCED = "chord-reduced"
    NOTES_QUANTISED = "notes-quantised"
    PAST_PATTERN_END = "past-pattern-end"
    GATE_NOT_CARRIED = "gate-not-carried"
    TEMPO_NOT_CARRIED = "tempo-not-carried"
    MULTIPLE_SOURCES = "multiple-sources"


@dataclass(frozen=True)
class Summary:
    """How one code's instances read once collapsed."""

    # ``template`` is formatted with {sites} and {subjects}, each already a
    # counted noun phrase -- "3 patterns", "41 notes". A template using
    # neither is fine: some diagnostics are said once however often they arise.

    template: str
    subject: str = "note"
    site: str = "pattern"


#: One entry per Code. Kept as data so that adding a diagnostic does not mean
#: adding a branch, and so the Swift port (M8-M9) can carry the same table.
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
        "the project sets a global swing (parameter 74); how it combines with the per-pattern "
        "value is not measured, so only the per-pattern value was applied",
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
    Code.CHORD_REDUCED: Summary(
        "{subjects} share a step with a higher one and were dropped; this conversion is monophonic",
    ),
    Code.NOTES_QUANTISED: Summary(
        "{subjects} did not land on a step and were moved to the nearest one",
    ),
    Code.PAST_PATTERN_END: Summary(
        "{subjects} fall past the pattern's last step and were dropped; the device disables "
        "notes beyond it, so writing them would put silent notes in the file",
    ),
    Code.GATE_NOT_CARRIED: Summary(
        "note lengths are not carried; every note is written at the gate a freshly placed one "
        "has on the device",
    ),
    Code.TEMPO_NOT_CARRIED: Summary(
        "the source tempo is not carried; the project keeps the tempo its template holds",
    ),
    Code.MULTIPLE_SOURCES: Summary(
        "notes were taken from more than one source track or channel and merged into one "
        "pattern; --midi-track picks just one",
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
    """The specific, full sentence -- what ``--verbose`` shows. No site prefix
    and no "warning:" prefix; both are added when rendering."""

    site: Site = NO_SITE
    severity: Severity = Severity.WARNING
    subjects: int = 1
    """How many notes, steps or lanes this one occurrence covers. Summed when
    the code is collapsed, which is why a single line can honestly say "41
    notes across 3 patterns"."""

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
        # For diagnostics crossing a boundary that knows more than the code
        # that raised them: the reader knows the pattern, the export the track.
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
        # A group of one keeps its own message: there is nothing to collapse,
        # so summarising would lose its site for no gain.
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
        """Every diagnostic in full, as plain strings."""
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

    # Deduplication keys on (code, site, detail) rather than the rendered
    # string, so two diagnostics that read alike but come from different
    # patterns both survive and the counts stay honest.

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
