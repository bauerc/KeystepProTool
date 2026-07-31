"""``ksp-dump`` -- print the contents of a ``.KeyStepPro`` project.

Inspect a project without opening MIDI Control Center. Everything printed is
decoded by :mod:`ksp.reader`; this module only formats.
"""

import argparse
import json
from collections.abc import Iterator, Sequence

from ksp.drum_map import DrumMap
from ksp.encoding import SKIP_SEQUENCES
from ksp.model import NoteKind, Pattern, Project, Track
from ksp_cli.common import (
    CONFIG_PATH,
    add_drum_map_arg,
    add_path_arg,
    add_selection_args,
    load_project,
    resolve_drum_map_arg,
    run,
    select,
)

PROG = "ksp-dump"


def _format_gate(gate: float | None, raw: int) -> str:
    """The displayed gate length, or the raw value where it is unknown."""
    # Only six encodings are hardware-confirmed. An interpolated guess would
    # look authoritative; `?` marks the ones still to be measured (M7).
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

    # Each parameter set is printed against the notes it governs: they carry
    # their own step count and swing, and one pair of numbers would leave the
    # owner ambiguous.
    for kind in (NoteKind.SEQ, NoteKind.DRUM):
        notes = pattern.notes_of(kind)
        if not notes:
            continue
        timing = pattern.timing_for(kind)
        if kind is NoteKind.DRUM and drum_map is not None:
            # Said next to the notes it governs, and said every time, because a
            # resolved drum note is an assumption about the user's device.
            yield f"      drum map: {drum_map.describe()}"
        yield f"      {kind.value}: {timing.step_count} steps, swing {timing.swing_percent}%"
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
        prog=PROG,
        description="Print the contents of an Arturia KeyStep Pro project file.",
    )
    add_path_arg(parser)
    parser.add_argument(
        "--all",
        action="store_true",
        help="include patterns that hold no notes (all 16 are always present)",
    )
    add_selection_args(parser, "show")
    parser.add_argument(
        "--json",
        action="store_true",
        dest="as_json",
        help="emit the decoded model as JSON instead of a tree",
    )
    add_drum_map_arg(parser)
    return parser


def _run(args: argparse.Namespace) -> int:
    drum_map = resolve_drum_map_arg(args.drum_map, CONFIG_PATH)
    project = select(load_project(args.path), args)
    if args.as_json:
        print(json.dumps(project.to_dict(drum_map), indent=2))
    else:
        print(format_project(project, show_all=args.all, drum_map=drum_map))
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    return run(PROG, lambda: _run(args))


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
