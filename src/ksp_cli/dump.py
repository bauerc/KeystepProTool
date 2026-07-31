"""``ksp-dump`` -- print the contents of a ``.KeyStepPro`` project.

Inspect a project file without opening MIDI Control Center. Everything
printed here is decoded by :mod:`ksp.reader`; this module only formats.
"""

import argparse
import json
import sys
from collections.abc import Iterator, Sequence
from pathlib import Path

from ksp.constants import SKIP_SEQUENCES
from ksp.drum_map import DEFAULT_CHROMATIC_LOW, DrumMap
from ksp.model import NoteKind, Pattern, Project, Track
from ksp.reader import load

# The --drum-map grammar is shared with ksp2midi so both commands accept the
# same syntax and the same config file. CONFIG_PATH stays a name in this
# module so tests can point it somewhere harmless.
from ksp_cli.drum_map_option import CONFIG_PATH, parse_drum_map, resolve_drum_map

__all__ = ["CONFIG_PATH", "format_project", "main", "parse_drum_map", "resolve_drum_map"]


def _format_gate(gate: float | None, raw: int) -> str:
    """Show the displayed gate length, or the raw value when it is unknown.

    Only six gate encodings are hardware-confirmed. Printing an interpolated
    guess would be worse than printing the raw number, because it would look
    authoritative. ``?`` marks the ones still to be measured (roadmap M7).
    """
    if gate is None:
        return f"?({raw})"
    return f"{gate:g}".rjust(4)


def _format_skip(skip: Sequence[int]) -> str:
    if len(skip) == len(SKIP_SEQUENCES):
        return "always"
    if not skip:
        return "never"
    return ",".join(str(s) for s in skip)


def _pattern_lines(pattern: Pattern, drum_map: DrumMap | None) -> Iterator[str]:
    yield f"    Pattern {pattern.number:<2} [{pattern.mode.value}]"

    # A pattern's melodic and drum sets each have their own step count and
    # swing, so each is printed against the notes it governs rather than as a
    # single pair of numbers whose owner would be ambiguous.
    for kind in (NoteKind.SEQ, NoteKind.DRUM):
        notes = pattern.notes_of(kind)
        if not notes:
            continue
        if kind is NoteKind.DRUM:
            steps, swing = pattern.drum_step_count, pattern.drum_swing_percent
            if drum_map is not None:
                # Said next to the notes it governs, and said every time,
                # because a resolved drum note is an assumption about the
                # user's device rather than anything read from their file.
                yield f"      drum map: {drum_map.describe()}"
        else:
            steps, swing = pattern.seq_step_count, pattern.seq_swing_percent
        yield f"      {kind.value}: {steps} steps, swing {swing}%"
        width = 30 if kind is NoteKind.DRUM and drum_map is not None else 10
        for slot in sorted({n.slot for n in notes}):
            yield f"        slot {slot}"
            for note in (n for n in notes if n.slot == slot):
                shift = f"{note.time_shift:+d}" if note.time_shift else " 0"
                yield (
                    f"          note {note.index:>2}  step {note.step:>2}  "
                    f"{note.labelled(drum_map):<{width}} "
                    f"vel {note.velocity:>3}  gate {_format_gate(note.gate, note.gate_raw)}  "
                    f"shift {shift}  rand {note.randomness:>3}  "
                    f"seq {_format_skip(note.skip)}"
                    # Only ever flagged when clear: a silent note is the
                    # surprise, an audible one is the norm.
                    f"{'' if note.active else '  [SILENT: no step-active flag]'}"
                )
    for warning in pattern.warnings:
        yield f"      ! {warning}"


def _track_lines(track: Track, *, show_all: bool, drum_map: DrumMap | None) -> Iterator[str]:
    patterns = [p for p in track.patterns if show_all or not p.is_empty]
    if not patterns:
        return
    mode = "  [drum mode]" if track.drum_mode else ""
    yield f"  Track {track.number} (item {track.item_id}){mode}"
    for pattern in patterns:
        yield from _pattern_lines(pattern, drum_map)


def format_project(
    project: Project, *, show_all: bool = False, drum_map: DrumMap | None = None
) -> str:
    """Render a project as an indented tree: tracks -> patterns -> notes."""
    lines = [
        project.source_name or project.device,
        f"  device {project.device}   version {project.version or '(none)'}",
        f"  tempo {project.tempo_bpm:g} BPM   swing {project.global_swing_percent}%   "
        f"scene {project.current_scene}",
    ]
    lines.extend(f"  ! {w}" for w in project.warnings)
    lines.append("")

    body = [
        line
        for track in project.tracks
        for line in _track_lines(track, show_all=show_all, drum_map=drum_map)
    ]
    if not body:
        body = ["  (no patterns hold notes)"]
    lines.extend(body)
    return "\n".join(lines)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ksp-dump",
        description="Print the contents of an Arturia KeyStep Pro project file.",
    )
    parser.add_argument("path", type=Path, help="a .KeyStepPro project file")
    parser.add_argument(
        "--all",
        action="store_true",
        help="include patterns that hold no notes (all 16 are always present)",
    )
    parser.add_argument("--track", type=int, choices=range(1, 5), help="show only this track")
    parser.add_argument(
        "--pattern",
        type=int,
        choices=range(1, 17),
        metavar="{1..16}",
        help="show only this pattern",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="as_json",
        help="emit the decoded model as JSON instead of a tree",
    )
    parser.add_argument(
        "--drum-map",
        metavar="SPEC",
        help=(
            "how drum lanes map to MIDI notes: chromatic:N, custom:a,b,c,... or none. "
            "The device stores this globally and it is not in the project file, so it is "
            f"always an assumption (default: chromatic:{DEFAULT_CHROMATIC_LOW})"
        ),
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    try:
        drum_map = resolve_drum_map(args.drum_map, CONFIG_PATH)
    except json.JSONDecodeError as exc:  # a ValueError, so it must come first
        print(f"ksp-dump: drum map: {CONFIG_PATH}: {exc}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        print(f"ksp-dump: drum map: {exc}", file=sys.stderr)
        return 1

    try:
        project = load(args.path)
    except OSError as exc:
        print(f"ksp-dump: {exc}", file=sys.stderr)
        return 1
    except ValueError as exc:
        print(f"ksp-dump: {args.path}: {exc}", file=sys.stderr)
        return 1

    project = project.select(track=args.track, pattern=args.pattern)

    if args.as_json:
        print(json.dumps(project.to_dict(drum_map), indent=2))
    else:
        print(format_project(project, show_all=args.all, drum_map=drum_map))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
