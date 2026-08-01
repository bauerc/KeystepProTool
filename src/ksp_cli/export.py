"""``ksp2midi`` -- write a ``.KeyStepPro`` project out as MIDI.

MIDI Control Center can put patterns onto the device but has no way of getting
them off as a ``.mid``, so this is the direction that is useful on its own.
All the rendering lives in :mod:`ksp.midi_export`; this module handles
arguments, paths and what gets printed.

Warnings go to stderr and the summary to stdout, so a shell pipeline can take
the summary while a human still sees everything the export was unsure about --
and the file is written either way, because a gate length we cannot decode is
a caveat, not a failure.

Warnings are collapsed to one line per kind by default and listed in full
under ``--verbose``; ``--quiet`` suppresses the stdout summary only, never the
caveats.
"""

import argparse
import json
import sys
from collections.abc import Sequence
from pathlib import Path

from ksp.constants import DEFAULT_GATE_LENGTH
from ksp.diagnostics import Report
from ksp.midi_export import (
    DEFAULT_STEPS_PER_BEAT,
    DEFAULT_TICKS_PER_BEAT,
    DRUM_CHANNEL,
    ExportOptions,
    ExportResult,
    export_project,
    export_split,
)
from ksp.model import Project
from ksp.reader import load
from ksp_cli.drum_map_option import CONFIG_PATH, DRUM_MAP_HELP, resolve_drum_map
from ksp_cli.reporting import add_verbose_option, print_report

PROG = "ksp2midi"


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=PROG,
        description="Convert an Arturia KeyStep Pro project into Standard MIDI file(s).",
        epilog=(
            "By default patterns that hold notes are laid end to end in pattern order in one "
            "file, and pattern N starts at the same point on every track. --split writes each "
            "(track, pattern) to its own file instead."
        ),
    )
    parser.add_argument("path", type=Path, help="a .KeyStepPro project file")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help=(
            "destination .mid file (default: the input file with a .mid suffix); "
            "with --split, a directory (default: the input file's own directory)"
        ),
    )
    parser.add_argument(
        "--split",
        action="store_true",
        help=(
            "write one file per non-empty (track, pattern), named "
            "<stem>_track{N}_pattern{P}.mid, each starting at its own tick 0"
        ),
    )
    parser.add_argument("--track", type=int, choices=range(1, 5), help="export only this track")
    parser.add_argument(
        "--pattern",
        type=int,
        choices=range(1, 17),
        metavar="{1..16}",
        help="export only this pattern",
    )
    parser.add_argument(
        "--steps-per-beat",
        type=int,
        default=DEFAULT_STEPS_PER_BEAT,
        help=(
            "step size as a division of the beat (default: %(default)s, i.e. 1/16 steps). "
            "The project file does store this, in a bitfield we have not decoded"
        ),
    )
    parser.add_argument(
        "--ticks-per-beat",
        type=int,
        default=DEFAULT_TICKS_PER_BEAT,
        help="MIDI resolution (default: %(default)s)",
    )
    parser.add_argument("--drum-map", metavar="SPEC", help=DRUM_MAP_HELP)
    parser.add_argument(
        "--drum-channel",
        type=int,
        default=DRUM_CHANNEL + 1,
        metavar="{1..16}",
        help="MIDI channel for drum lanes (default: %(default)s)",
    )
    parser.add_argument(
        "--default-gate",
        type=float,
        default=DEFAULT_GATE_LENGTH,
        metavar="STEPS",
        help=(
            "note length in steps for a gate encoding that is not measured "
            "(default: %(default)s, the length a freshly placed note has on the device)"
        ),
    )
    parser.add_argument(
        "--include-stale",
        action="store_true",
        help=(
            "where a pattern holds both a melodic and a drum note set, export both instead of "
            "only the one parameter 86 bit 6 says the device plays"
        ),
    )
    parser.add_argument(
        "--include-inactive",
        action="store_true",
        help=(
            "export pooled notes whose step-active flag is clear; the device does not play "
            "them, so they are omitted by default"
        ),
    )
    parser.add_argument(
        "--no-swing",
        action="store_false",
        dest="apply_swing",
        help="ignore per-pattern swing and place every step on a flat grid",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would be written, and write nothing",
    )
    parser.add_argument(
        "--force", action="store_true", help="overwrite the output file if it already exists"
    )
    parser.add_argument("--quiet", action="store_true", help="suppress the summary on stdout")
    add_verbose_option(parser)
    return parser


def _summary(result: ExportResult, destination: Path, dry_run: bool) -> str:
    patterns = ", ".join(str(n) for n in result.pattern_numbers)
    tracks = ", ".join(result.track_names)
    verb = "would write" if dry_run else "wrote"
    return (
        f"{verb} {destination}\n"
        f"  {result.note_count} note(s) from pattern(s) {patterns}\n"
        f"  tracks: {tracks}"
    )


def _split_name(source: Path, result: ExportResult) -> str:
    """``<stem>_track{N}_pattern{P}.mid`` -- one file holds exactly one of each."""
    track = result.track_numbers[0]
    pattern = result.pattern_numbers[0]
    return f"{source.stem}_track{track}_pattern{pattern}.mid"


def _plan(
    args: argparse.Namespace, project: Project, options: ExportOptions
) -> list[tuple[ExportResult, Path]]:
    """Pair each rendered file with where it goes. Nothing is written yet."""
    narrowed = project.select(track=args.track, pattern=args.pattern)
    if args.split:
        directory = args.output or args.path.parent
        return [
            (result, directory / _split_name(args.path, result))
            for result in export_split(narrowed, options)
        ]
    result = export_project(narrowed, options)
    if result.is_empty:
        return []
    return [(result, args.output or args.path.with_suffix(".mid"))]


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    try:
        drum_map = resolve_drum_map(args.drum_map, CONFIG_PATH)
    except json.JSONDecodeError as exc:  # a ValueError, so it must come first
        print(f"{PROG}: drum map: {CONFIG_PATH}: {exc}", file=sys.stderr)
        return 2
    except (OSError, ValueError) as exc:
        print(f"{PROG}: drum map: {exc}", file=sys.stderr)
        return 2

    if drum_map is None:
        # ksp-dump can print "lane 0" and leave it unresolved; a MIDI file has
        # no way to say that, so there is nothing sensible to write.
        print(
            f"{PROG}: --drum-map none cannot be exported: a MIDI file has to name a note "
            f"for every drum lane",
            file=sys.stderr,
        )
        return 2

    try:
        options = ExportOptions(
            ticks_per_beat=args.ticks_per_beat,
            steps_per_beat=args.steps_per_beat,
            drum_map=drum_map,
            drum_channel=args.drum_channel - 1,
            default_gate=args.default_gate,
            apply_swing=args.apply_swing,
            include_stale=args.include_stale,
            include_inactive=args.include_inactive,
        )
    except ValueError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 2

    try:
        project = load(args.path)
    except OSError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 1
    except ValueError as exc:
        print(f"{PROG}: {args.path}: {exc}", file=sys.stderr)
        return 1

    planned = _plan(args, project, options)
    if not planned:
        # Writing a MIDI file with no notes in it would look like success.
        print(
            f"{PROG}: {args.path}: nothing to export (no selected pattern holds notes)",
            file=sys.stderr,
        )
        return 1

    existing = [str(path) for _, path in planned if path.exists()]
    if existing and not args.force:
        print(
            f"{PROG}: {', '.join(existing)} already exists (use --force to overwrite)",
            file=sys.stderr,
        )
        return 1

    if not args.dry_run:
        try:
            for _, path in planned:
                path.parent.mkdir(parents=True, exist_ok=True)
            for result, path in planned:
                result.midi.save(path)
        except OSError as exc:
            print(f"{PROG}: {exc}", file=sys.stderr)
            return 1

    print_report(_report(planned), prog=PROG, verbose=args.verbose)
    if not args.quiet:
        print("\n".join(_summary(result, path, args.dry_run) for result, path in planned))
    return 0


def _report(planned: Sequence[tuple[ExportResult, Path]]) -> Report:
    """Every file's diagnostics, each said once however many files repeat it."""
    merged = Report()
    for result, _ in planned:
        merged = merged.merge(result.diagnostics)
    return merged


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
