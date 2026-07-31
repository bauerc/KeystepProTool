"""Build the gate length table from a T2.1 sweep capture.

Dev instrument for tier 2 of ``analysis/Hardware_Test_Protocol.md``. The sweep
puts detent *k* on step *k*, so one capture holds the whole table; this pairs
the stored values against the displayed ones transcribed in T2.0 and runs the
checks that say whether the pairing can be trusted.

    uv run python tools/gate_table.py project_files/captures/T2-gate-sweep.KeyStepPro
    uv run python tools/gate_table.py CAPTURE.KeyStepPro --display analysis/gate_display_sweep.txt

Runs without --display, reporting the stored axis alone, so a capture can be
checked at the device before anything is transcribed. Exits non-zero when a
check fails, so it is usable as a desk gate.

In ``tools/`` rather than ``src/``: a dev instrument, not a shipped command.
"""

from __future__ import annotations

import argparse
import itertools
import sys
from dataclasses import dataclass
from pathlib import Path

# Allow running from a source checkout without installing the package.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from ksp import encoding, model, reader
from ksp.model import NoteKind

# Where the protocol stages each sweep, used when no location is given.
MELODIC_TRACK, MELODIC_PATTERN = 2, 1
DRUM_TRACK, DRUM_PATTERN = 1, 1

# The unexplained gate in initial_project, below the lowest documented point.
UNEXPLAINED_STORED = 2

FAIL, WARN = "FAIL", "warn"


@dataclass(frozen=True)
class Row:
    """One detent: what the device showed, and what the file stored."""

    detent: int
    step: int
    ordinal: int
    stored: int
    displayed: str | None

    @property
    def as_number(self) -> float | None:
        """The displayed value as a number, or None if it is a label."""
        return _as_number(self.displayed)


@dataclass(frozen=True)
class Sweep:
    label: str
    track: int
    pattern: int
    rows: tuple[Row, ...]


@dataclass(frozen=True)
class Finding:
    level: str
    message: str


def _as_number(label: str | None) -> float | None:
    if label is None:
        return None
    try:
        return float(label)
    except ValueError:
        # A non-numeric extreme (TIE, HOLD, inf). Kept as a label, and left out
        # of the numeric checks rather than coerced into one.
        return None


def load_display(path: Path) -> dict[str, list[str]]:
    """Read the T2.0 census into ``{"melodic": [...], "drum": [...]}``."""
    sections: dict[str, list[str]] = {}
    current: list[str] | None = None
    for number, raw_line in enumerate(path.read_text().splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.lower() in ("melodic", "drum"):
            current = sections.setdefault(line.lower(), [])
            continue
        if current is None:
            raise ValueError(f"{path}:{number}: value before any 'melodic' or 'drum' header")
        current.append(line)
    return sections


def build_sweep(
    project: model.Project,
    *,
    label: str,
    track: int,
    pattern: int,
    kind: NoteKind,
    displayed: list[str] | None,
) -> Sweep:
    """Pair a pattern's notes, in step order, against the displayed values.

    Ordered by step rather than by note ordinal: the two are different index
    spaces (spec section 4) and nothing guarantees the device pools notes in
    step order. Detent *k* was placed on step *k*, so step is the pairing key.
    """
    notes = sorted(project.track(track).pattern(pattern).notes_of(kind), key=lambda n: n.step)
    rows = tuple(
        Row(
            detent=index,
            step=note.step,
            ordinal=note.index,
            stored=note.gate_raw,
            displayed=displayed[index - 1] if displayed and index <= len(displayed) else None,
        )
        for index, note in enumerate(notes, start=1)
    )
    return Sweep(label=label, track=track, pattern=pattern, rows=rows)


def check(sweep: Sweep, displayed: list[str] | None) -> list[Finding]:
    """Every reason to distrust this sweep, worst first."""
    findings: list[Finding] = []
    rows = sweep.rows
    if not rows:
        return [
            Finding(FAIL, f"no {sweep.label} notes in track {sweep.track} pattern {sweep.pattern}")
        ]

    findings += _check_anchors(rows)
    findings += _check_monotonic(rows)
    findings += _check_duplicates(rows)
    findings += _check_steps(rows)
    findings += _check_ordinals(rows)
    if displayed is not None and len(displayed) != len(rows):
        findings.append(
            Finding(
                FAIL,
                f"{len(rows)} notes but {len(displayed)} displayed values: the pairing is off, "
                f"so every row below may be mislabelled",
            )
        )
    return findings


def _check_anchors(rows: tuple[Row, ...]) -> list[Finding]:
    """The six hardware-confirmed points, checked both ways.

    These are the built-in proof that the procedure was followed. A
    disagreement means the pairing slipped, not that the table is surprising.
    """
    by_display = {value: stored for stored, value in encoding.GATE_TABLE.items()}
    findings: list[Finding] = []
    for row in rows:
        shown = row.as_number
        if shown is None:
            continue
        known_display = encoding.GATE_TABLE.get(row.stored)
        if known_display is not None and known_display != shown:
            findings.append(
                Finding(
                    FAIL,
                    f"detent {row.detent}: stored {row.stored} is a known point displaying "
                    f"{known_display:g}, but the census says {shown:g}",
                )
            )
        expected_stored = by_display.get(shown)
        if expected_stored is not None and expected_stored != row.stored:
            findings.append(
                Finding(
                    FAIL,
                    f"detent {row.detent}: display {shown:g} is a known point stored as "
                    f"{expected_stored}, but this capture stores {row.stored}",
                )
            )
    return findings


def _check_monotonic(rows: tuple[Row, ...]) -> list[Finding]:
    """Stored gate must rise with the detent index.

    Non-monotonic means a hysteretic encoder reading, which is a different
    problem from a non-linear table and is fixed by re-reading, not re-staging.
    """
    findings: list[Finding] = []
    previous: Row | None = None
    for row in rows:
        if previous is not None and row.stored <= previous.stored:
            findings.append(
                Finding(
                    FAIL,
                    f"not monotonic: detent {previous.detent} stores {previous.stored}, "
                    f"detent {row.detent} stores {row.stored}",
                )
            )
        previous = row
    return findings


def _check_duplicates(rows: tuple[Row, ...]) -> list[Finding]:
    """Two detents sharing a stored value is a finding, not just an error."""
    # Grouped, so one repeated value is one finding rather than one per pair.
    seen: dict[int, list[int]] = {}
    for row in rows:
        seen.setdefault(row.stored, []).append(row.detent)
    return [
        Finding(
            FAIL,
            f"detents {', '.join(str(d) for d in detents)} all store {stored}: the display has "
            f"finer resolution than the storage, so display -> stored is many-to-one",
        )
        for stored, detents in seen.items()
        if len(detents) > 1
    ]


def _check_steps(rows: tuple[Row, ...]) -> list[Finding]:
    """One note per step, or the detent numbering means nothing."""
    seen: set[int] = set()
    findings: list[Finding] = []
    for row in rows:
        if row.step in seen:
            findings.append(
                Finding(
                    FAIL, f"step {row.step} carries more than one note; detent numbering is lost"
                )
            )
        seen.add(row.step)
    return findings


def _check_ordinals(rows: tuple[Row, ...]) -> list[Finding]:
    """Ordinals ascending with step: a warning, since pairing uses step."""
    out_of_order = [r for a, r in itertools.pairwise(rows) if r.ordinal <= a.ordinal]
    if out_of_order:
        return [
            Finding(
                WARN,
                f"{len(out_of_order)} note(s) are not pooled in step order, so ordinal != detent. "
                f"Paired through step instead. Record this: it tells a writer what note ordering "
                f"the device produces.",
            )
        ]
    return []


def render(sweep: Sweep) -> list[str]:
    count = len(sweep.rows)
    lines = [
        f"{sweep.label} sweep - track {sweep.track} pattern {sweep.pattern}, "
        f"{count} detent{'' if count == 1 else 's'}",
        "  detent  step  ordinal  stored  displayed",
    ]
    for row in sweep.rows:
        shown = row.displayed if row.displayed is not None else "-"
        lines.append(
            f"  {row.detent:>6}  {row.step:>4}  {row.ordinal:>7}  {row.stored:>6}  {shown}"
        )
    return lines


def render_table(sweep: Sweep) -> list[str]:
    """The measured table as a paste-ready GATE_TABLE literal."""
    pairs = [(r.stored, r.as_number) for r in sweep.rows if r.as_number is not None]
    if not pairs:
        return [
            f"  no displayed values for the {sweep.label} sweep, so no table can be built "
            f"(pass --display once T2.0 is transcribed)"
        ]
    body = ", ".join(f"{stored}: {shown:g}" for stored, shown in pairs)
    labels = [(r.detent, r.displayed) for r in sweep.rows if r.displayed and r.as_number is None]
    lines = [f"  GATE_TABLE = {{{body}}}"]
    for detent, label in labels:
        lines.append(f"  (detent {detent} displayed {label!r}: a label, left out of the table)")
    return lines


def render_unexplained(sweeps: list[Sweep], *, complete: bool) -> list[str]:
    """Whether the sweep reached the stored 2 that initial_project holds."""
    hits = [
        f"{s.label} detent {r.detent} (displayed {r.displayed or '?'})"
        for s in sweeps
        for r in s.rows
        if r.stored == UNEXPLAINED_STORED
    ]
    if hits:
        return [f"  stored {UNEXPLAINED_STORED} reached at " + "; ".join(hits)]
    absent = f"  stored {UNEXPLAINED_STORED} (the unexplained gate in initial_project) is absent"
    if not complete:
        # Only part of the project was read, so nothing follows about the encoder.
        return [f"{absent} from what was read here"]
    return [
        f"{absent} from both full sweeps, so it is not reachable from the Gate encoder and is "
        f"set some other way (a tie, a trigger). Say so in the ledger."
    ]


def compare(melodic: Sweep, drum: Sweep) -> list[str]:
    """Does 118 share 110's table? Spec section 6 assumes so without evidence."""
    left = {r.displayed: r.stored for r in melodic.rows if r.displayed}
    right = {r.displayed: r.stored for r in drum.rows if r.displayed}
    shared = sorted(set(left) & set(right), key=lambda d: left[d])
    if not shared:
        # No display axis, so compare the stored sequences positionally instead.
        a = [r.stored for r in melodic.rows]
        b = [r.stored for r in drum.rows]
        if a == b:
            return [
                "  melodic and drum stored sequences are identical (no display axis to pair on)"
            ]
        return [f"  melodic and drum stored sequences DIFFER: {a} vs {b}"]

    differing = [(d, left[d], right[d]) for d in shared if left[d] != right[d]]
    if not differing:
        return [
            f"  118 matches 110 at all {len(shared)} shared displayed values: one table serves both"
        ]
    lines = [f"  118 DIFFERS from 110 at {len(differing)} of {len(shared)} shared values:"]
    lines += [f"    displayed {d}: melodic {a}, drum {b}" for d, a, b in differing]
    lines.append("    the drum table is its own; do not reuse the melodic one")
    return lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build the gate length table from a tier 2 sweep capture.",
    )
    parser.add_argument("capture", type=Path, help="the T2.1 capture")
    parser.add_argument(
        "--display", type=Path, help="the T2.0 census (analysis/gate_display_sweep.txt)"
    )
    parser.add_argument("--track", type=int, help="read one sweep from this track instead of both")
    parser.add_argument("--pattern", type=int, default=1, help="pattern to read (default 1)")
    parser.add_argument("--drum", action="store_true", help="read the DRUM parameter set")
    args = parser.parse_args(argv)

    census = load_display(args.display) if args.display else {}
    project = reader.load(args.capture)

    wanted: list[tuple[str, int, int, NoteKind]]
    if args.track is not None:
        label = "drum" if args.drum else "melodic"
        wanted = [(label, args.track, args.pattern, NoteKind.DRUM if args.drum else NoteKind.SEQ)]
    else:
        wanted = [
            ("melodic", MELODIC_TRACK, MELODIC_PATTERN, NoteKind.SEQ),
            ("drum", DRUM_TRACK, DRUM_PATTERN, NoteKind.DRUM),
        ]

    print(f"{args.capture.name}")
    sweeps: list[Sweep] = []
    failed = False
    for label, track, pattern, kind in wanted:
        displayed = census.get(label)
        sweep = build_sweep(
            project, label=label, track=track, pattern=pattern, kind=kind, displayed=displayed
        )
        if not sweep.rows and args.track is None:
            # Only one of the two sweeps was staged. Not an error by itself.
            print(f"\n{label} sweep - none in track {track} pattern {pattern}, skipped")
            continue
        sweeps.append(sweep)

        print()
        for line in render(sweep):
            print(line)
        findings = check(sweep, displayed)
        for finding in findings:
            print(f"  {finding.level}: {finding.message}")
        if any(f.level == FAIL for f in findings):
            # No paste-ready table from a sweep that failed a check. A
            # plausible-but-wrong gate table is the one bug this whole tier
            # exists to prevent, and it would load and play without erroring.
            failed = True
            print("  no table emitted: fix the failures above first")
        else:
            for line in render_table(sweep):
                print(line)

    if len(sweeps) == 2:
        print()
        for line in compare(sweeps[0], sweeps[1]):
            print(line)

    if sweeps:
        print()
        for line in render_unexplained(sweeps, complete=args.track is None and len(sweeps) == 2):
            print(line)

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
