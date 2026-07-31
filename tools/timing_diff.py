"""Summarise and diff the timing parameters of ``.KeyStepPro`` projects.

Dev instrument for tiers 7 and 8 of ``analysis/Hardware_Test_Protocol.md``.
Reports only what displaces a note in time: swing (74, 97, 114), time shift
(112, 120) and the pattern bitfields (99, 116) that set step duration.

    uv run python tools/timing_diff.py project_files/*.KeyStepPro
    uv run python tools/timing_diff.py --diff BEFORE.KeyStepPro AFTER.KeyStepPro

In ``tools/`` rather than ``src/``: a dev instrument, not a shipped command.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

# Allow running from a source checkout without installing the package.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from ksp import constants, keys, lenient_json, model, reader

# Timing parameter -> index depth of its keys.
# 0 = project-level, 1 = per pattern, 3 = per pattern/slot/note.
TIMING_PARAMS: dict[int, int] = {
    constants.P_GLOBAL_SWING: 0,
    constants.P_SEQ_SWING: 1,
    constants.P_DRUM_SWING: 1,
    constants.P_SEQ_PATTERN_BITS: 1,
    constants.P_DRUM_PATTERN_BITS: 1,
    constants.P_SEQ_TIME_SHIFT: 3,
    constants.P_DRUM_TIME_SHIFT: 3,
}

NEUTRAL_GLOBAL_SWING = 50
NEUTRAL_PATTERN_SWING = constants.SWING_OFFSET  # 25, i.e. no offset


def timing_keys(raw: dict[str, Any]) -> Iterator[str]:
    """Yield every key in *raw* holding a timing parameter."""
    for item in (constants.ITEM_PROJECT, *constants.TRACK_ITEM_IDS):
        for param, depth in TIMING_PARAMS.items():
            if depth == 0:
                candidate = keys.key(item, param)
                if candidate in raw:
                    yield candidate
                continue
            for pattern in range(1, constants.PATTERNS_PER_TRACK + 1):
                if depth == 1:
                    candidate = keys.key(item, param, pattern)
                    if candidate in raw:
                        yield candidate
                    continue
                for slot in range(1, constants.SLOTS_BY_ITEM.get(item, 3) + 1):
                    for note in range(1, constants.MAX_STEPS + 1):
                        candidate = keys.key(item, param, pattern, slot, note)
                        if candidate in raw:
                            yield candidate


def _sort_key(name: str) -> list[int | str]:
    """Sort per segment numerically, so ``_2_`` precedes ``_10_``."""
    return [int(part) if part.isdigit() else part for part in name.split("_")]


def summarise(path: Path) -> Iterator[str]:
    """Yield a timing summary of one project."""
    raw = lenient_json.load_path(path)
    project = reader.load(path)
    yield f"{path.name}"

    global_swing = keys.get_int(raw, constants.ITEM_PROJECT, constants.P_GLOBAL_SWING)
    flag = "" if global_swing == NEUTRAL_GLOBAL_SWING else "   <-- non-default"
    yield f"  global swing (74) = {global_swing}%{flag}"

    for item in constants.TRACK_ITEM_IDS:
        rows = list(_track_rows(raw, item))
        if rows:
            yield f"  item {item}"
            yield from rows

    shifts = _shift_summary(project)
    if shifts:
        yield "  time shift, notes away from centre:"
        yield from shifts
    else:
        yield f"  time shift: every note at centre ({constants.TIME_SHIFT_CENTRE})"


def _track_rows(raw: dict[str, Any], item: int) -> Iterator[str]:
    """One row per pattern whose swing or bitfield is worth showing."""
    for pattern in range(1, constants.PATTERNS_PER_TRACK + 1):
        seq_swing = keys.get_int(raw, item, constants.P_SEQ_SWING, pattern)
        drum_swing = keys.get_int(raw, item, constants.P_DRUM_SWING, pattern)
        seq_bits = keys.get_int(raw, item, constants.P_SEQ_PATTERN_BITS, pattern)
        drum_bits = keys.get_int(raw, item, constants.P_DRUM_PATTERN_BITS, pattern)

        interesting = (seq_swing is not None and seq_swing != NEUTRAL_PATTERN_SWING) or (
            drum_swing is not None and drum_swing != NEUTRAL_PATTERN_SWING
        )
        # Pattern 1 always prints, as the reference row for the bitfields.
        if not interesting and pattern != 1:
            continue

        parts = [f"    pattern {pattern:<2}"]
        if seq_swing is not None:
            offset = seq_swing - constants.SWING_OFFSET
            parts.append(f"seq swing {seq_swing:>3} (offset {offset:+d})")
        if drum_swing is not None:
            parts.append(f"drum swing {drum_swing:>3}")
        if seq_bits is not None:
            parts.append(f"99 = {seq_bits:>3} {seq_bits:08b}")
        if drum_bits is not None:
            parts.append(f"116 = {drum_bits:>3} {drum_bits:08b}")
        yield "  ".join(parts)


def _shift_summary(project: model.Project) -> list[str]:
    """One row per real note whose time shift is off centre.

    Walks the decoded model, not the raw arrays: reading 112/120 directly
    reports Track 1's zero-filled fourth slot as 64 notes at -49 (spec §4).
    """
    rows: list[str] = []
    for track in project.tracks:
        for pattern in track.patterns:
            for note in pattern.notes:
                if not note.time_shift:
                    continue
                stored = note.time_shift + constants.TIME_SHIFT_CENTRE
                rows.append(
                    f"    track {track.number} {note.kind.value:<4} "
                    f"pattern {pattern.number:<2} slot {note.slot} note {note.index:<2}  "
                    f"stored {stored:>3}  = {note.time_shift:+d}  (step {note.step})"
                )
    return rows


def diff(before: Path, after: Path, *, show_all: bool = False) -> Iterator[str]:
    """Yield every timing key whose value differs between two projects.

    Changes where one side is the 127 sentinel are suppressed by default:
    they mean the note list changed length, not that a timing value moved.
    A baseline-vs-capture diff should have none.
    """
    a = lenient_json.load_path(before)
    b = lenient_json.load_path(after)

    changed: list[str] = []
    sentinel_churn = 0
    for name in sorted(set(timing_keys(a)) | set(timing_keys(b)), key=_sort_key):
        old, new = a.get(name), b.get(name)
        if old == new:
            continue
        if not show_all and constants.SENTINEL in (old, new):
            sentinel_churn += 1
            continue
        changed.append(name)

    yield f"{before.name} -> {after.name}"
    for name in changed:
        yield f"  {name:<28} {a.get(name)!r:>6} -> {b.get(name)!r}"
    yield f"  ({len(changed)} timing keys changed)" if changed else "  no timing parameter changed"
    if sentinel_churn:
        yield (
            f"  ({sentinel_churn} further keys differ only by the {constants.SENTINEL} "
            f"sentinel, i.e. note-list length; --all shows them)"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Summarise or diff the timing parameters of .KeyStepPro projects.",
    )
    parser.add_argument("files", nargs="+", type=Path, help="project files")
    parser.add_argument(
        "--diff", action="store_true", help="diff exactly two files instead of summarising each"
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="with --diff, also show keys differing only by the 127 sentinel",
    )
    args = parser.parse_args(argv)

    if args.diff:
        if len(args.files) != 2:
            parser.error("--diff takes exactly two files")
        for line in diff(args.files[0], args.files[1], show_all=args.all):
            print(line)
        return 0

    for index, path in enumerate(args.files):
        if index:
            print()
        for line in summarise(path):
            print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
