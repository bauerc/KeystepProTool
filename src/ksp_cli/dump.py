"""``ksp-dump`` -- print the contents of a ``.KeyStepPro`` project.

Inspect a project file without opening MIDI Control Center. Everything
printed here is decoded by :mod:`ksp.reader`; this module only formats.
"""

import json
import sys
from collections.abc import Iterator, Sequence
from pathlib import Path
from typing import Annotated

import typer

from ksp.constants import SKIP_SEQUENCES, root_note_name
from ksp.diagnostics import Collector, Report
from ksp.drum_map import DEFAULT_CHROMATIC_LOW, DrumMap
from ksp.model import Note, NoteKind, Pattern, Project, Track
from ksp.reader import load

# The --drum-map grammar is shared with ksp2midi so both commands accept the
# same syntax and the same config file. CONFIG_PATH stays a name in this
# module so tests can point it somewhere harmless.
from ksp_cli.drum_map_option import CONFIG_PATH, parse_drum_map, resolve_drum_map
from ksp_cli.reporting import Verbose
from ksp_cli.runner import run

PROG = "ksp-dump"

__all__ = ["CONFIG_PATH", "format_project", "main", "parse_drum_map", "resolve_drum_map"]


#: Widest gate the ladder prints, ``0.0625``. Fixed so the columns after gate
#: stay aligned across a pattern.
_GATE_WIDTH = 6


def _format_gate(gate: float | None, raw: int) -> str:
    """Show the gate length in steps, or the raw value when it does not decode.

    The ladder covers every legal value, so ``?`` now means the file holds a
    gate outside 0-127. Printing the raw number beats printing the nearest
    rung, which would look authoritative and be wrong.
    """
    if gate is None:
        return f"?({raw})"
    return f"{gate:g}".rjust(_GATE_WIDTH)


def _format_skip(skip: Sequence[int]) -> str:
    if len(skip) == len(SKIP_SEQUENCES):
        return "always"
    if not skip:
        return "never"
    return ",".join(str(s) for s in skip)


def _disabled_marker(note: Note, last_step: int | None) -> str:
    """Why this note will not play, or "" when it will.

    Two mechanisms, both toggled the same way on the device, so both read as
    "disabled" and name their reason rather than inventing separate words.
    """
    if not note.active:
        return "  [DISABLED: step turned off]"
    if last_step is not None and note.step > last_step:
        return "  [DISABLED: past last step]"
    return ""


def _scale_line(pattern: Pattern) -> str:
    """Root note and scale, both decoded by protocol T5.6."""
    scale = pattern.scale_name or f"scale {pattern.scale} (off the device's list)"
    return f"      root {root_note_name(pattern.root_note)}   scale {scale}"


def _pattern_lines(pattern: Pattern, drum_map: DrumMap | None, *, verbose: bool) -> Iterator[str]:
    yield f"    Pattern {pattern.number:<2} [{pattern.mode.value}]"
    if pattern.root_note or pattern.scale:
        # Only when set: every sample project reads C chromatic, and a line
        # printed on all 16 patterns of all 4 tracks would be noise.
        yield _scale_line(pattern)

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
        bits = pattern.bits(kind)
        rhythm = "poly" if bits.polyrhythm else "mono"
        yield (
            f"      {kind.value}: {steps} steps, {bits.label}, swing {swing}%, "
            f"{bits.direction.value}, {rhythm}"
        )
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
                    # Only ever marked when the note will not play: that is
                    # the surprise, an audible note is the norm.
                    f"{_disabled_marker(note, steps)}"
                )
    if verbose:
        # Inline, next to the notes they are about. Collapsed they would lose
        # the one thing a tree dump is for: where the problem is.
        for warning in pattern.warnings:
            yield f"      ! {warning}"


def _track_lines(
    track: Track, *, show_all: bool, drum_map: DrumMap | None, verbose: bool
) -> Iterator[str]:
    patterns = [p for p in track.patterns if show_all or not p.is_empty]
    if not patterns:
        return
    mode = "  [drum mode]" if track.drum_mode else ""
    yield f"  Track {track.number} (item {track.item_id}){mode}"
    for pattern in patterns:
        yield from _pattern_lines(pattern, drum_map, verbose=verbose)


def project_report(project: Project) -> Report:
    """Every diagnostic in the project, stamped with the track it came from."""
    collector = Collector()
    collector.extend(project.diagnostics)
    for track in project.tracks:
        for pattern in track.patterns:
            collector.extend(d.at(track=track.number) for d in pattern.diagnostics)
    return collector.report()


def format_project(
    project: Project,
    *,
    show_all: bool = False,
    drum_map: DrumMap | None = None,
    verbose: bool = False,
) -> str:
    """Render a project as an indented tree: tracks -> patterns -> notes."""
    lines = [
        project.source_name or project.device,
        f"  device {project.device}   version {project.version or '(none)'}",
        f"  tempo {project.tempo_bpm:g} BPM   swing {project.global_swing_percent}%   "
        f"scene {project.current_scene}",
    ]
    # Only scenes that chain something: a project nobody has chained holds the
    # sentinel in all 16 slots of all 5 tracks of all 16 scenes.
    for scene in project.chained_scenes:
        for chain in scene.chains:
            patterns = " -> ".join(str(p) for p in chain.patterns)
            lines.append(f"  scene {scene.number} track {chain.track} chain: {patterns}")
    if verbose:
        lines.extend(f"  ! {w}" for w in project.warnings)
    lines.append("")

    body = [
        line
        for track in project.tracks
        for line in _track_lines(track, show_all=show_all, drum_map=drum_map, verbose=verbose)
    ]
    if not body:
        body = ["  (no patterns hold notes)"]
    lines.extend(body)

    if not verbose:
        # One block at the end rather than a line beside every pattern: the
        # notes are what the dump is for, and the same finding recurs in a
        # dozen patterns.
        report = project_report(project)
        if report:
            lines.append("")
            lines.extend(f"  ! {line}" for line in report.render())
            note = report.note()
            if note is not None:
                lines.append(f"  ({note})")
    return "\n".join(lines)


HELP = "Print the contents of an Arturia KeyStep Pro project file."


def dump(
    path: Annotated[Path, typer.Argument(help="a .KeyStepPro project file")],
    show_all: Annotated[
        bool,
        typer.Option(
            "--all", help="include patterns that hold no notes (all 16 are always present)"
        ),
    ] = False,
    track: Annotated[
        int | None, typer.Option(min=1, max=4, metavar="{1..4}", help="show only this track")
    ] = None,
    pattern: Annotated[
        int | None, typer.Option(min=1, max=16, metavar="{1..16}", help="show only this pattern")
    ] = None,
    as_json: Annotated[
        bool, typer.Option("--json", help="emit the decoded model as JSON instead of a tree")
    ] = False,
    drum_map_spec: Annotated[
        str | None,
        typer.Option(
            "--drum-map",
            metavar="SPEC",
            help=(
                "how drum lanes map to MIDI notes: chromatic:N, custom:a,b,c,... or none. "
                "The device stores this globally and it is not in the project file, so it is "
                f"always an assumption (default: chromatic:{DEFAULT_CHROMATIC_LOW})"
            ),
        ),
    ] = None,
    verbose: Verbose = False,
) -> None:
    try:
        drum_map = resolve_drum_map(drum_map_spec, CONFIG_PATH)
    except json.JSONDecodeError as exc:  # a ValueError, so it must come first
        print(f"{PROG}: drum map: {CONFIG_PATH}: {exc}", file=sys.stderr)
        raise typer.Exit(2) from None
    except (OSError, ValueError) as exc:
        print(f"{PROG}: drum map: {exc}", file=sys.stderr)
        raise typer.Exit(2) from None

    try:
        project = load(path)
    except OSError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        raise typer.Exit(1) from None
    except ValueError as exc:
        print(f"{PROG}: {path}: {exc}", file=sys.stderr)
        raise typer.Exit(1) from None

    project = project.select(track=track, pattern=pattern)

    if as_json:
        print(json.dumps(project.to_dict(drum_map), indent=2))
    else:
        print(format_project(project, show_all=show_all, drum_map=drum_map, verbose=verbose))


def register(app: typer.Typer) -> None:
    """Mount this command on *app* -- its own, or the kspplus group."""
    app.command(name=PROG, help=HELP)(dump)


app = typer.Typer(add_completion=False, rich_markup_mode="rich")
register(app)


def main(argv: Sequence[str] | None = None) -> int:
    return run(app, argv, prog_name=PROG)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
