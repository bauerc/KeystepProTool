"""``ksp2midi`` -- write a ``.KeyStepPro`` project out as a MIDI file.

MIDI Control Center can put patterns onto the device but has no way of getting
them off as a ``.mid``, so this is the direction that is useful on its own.
All the rendering lives in :mod:`ksp.midi_export`; this module handles
arguments, paths and what gets printed.

Warnings go to stderr and the summary to stdout, so a shell pipeline can take
the summary while a human still sees everything the export was unsure about --
and the file is written either way, because a gate length we cannot decode is
a caveat, not a failure.
"""

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from ksp.midi_export import (
    DEFAULT_STEPS_PER_BEAT,
    DEFAULT_TICKS_PER_BEAT,
    DRUM_CHANNEL,
    DRUM_LANE_BASE,
    ExportOptions,
    ExportResult,
    export_project,
)
from ksp.reader import load

PROG = "ksp2midi"


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=PROG,
        description="Convert an Arturia KeyStep Pro project into a Standard MIDI file.",
        epilog=(
            "Patterns that hold notes are laid end to end in pattern order, and pattern N "
            "starts at the same point on every track."
        ),
    )
    parser.add_argument("path", type=Path, help="a .KeyStepPro project file")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="destination .mid file (default: the input file with a .mid suffix)",
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
    parser.add_argument(
        "--drum-lane-base",
        type=int,
        default=DRUM_LANE_BASE,
        help=(
            "MIDI note that drum lane 0 maps to (default: %(default)s, the General MIDI bass "
            "drum). The device's drum map is a global setting and is not in the project file"
        ),
    )
    parser.add_argument(
        "--drum-channel",
        type=int,
        default=DRUM_CHANNEL + 1,
        metavar="{1..16}",
        help="MIDI channel for drum lanes (default: %(default)s)",
    )
    parser.add_argument(
        "--no-swing",
        action="store_false",
        dest="apply_swing",
        help="ignore per-pattern swing and place every step on a flat grid",
    )
    parser.add_argument(
        "--force", action="store_true", help="overwrite the output file if it already exists"
    )
    parser.add_argument("--quiet", action="store_true", help="suppress the summary on stdout")
    return parser


def _summary(result: ExportResult, destination: Path) -> str:
    patterns = ", ".join(str(n) for n in result.pattern_numbers)
    tracks = ", ".join(result.track_names)
    return (
        f"wrote {destination}\n"
        f"  {result.note_count} note(s) from pattern(s) {patterns}\n"
        f"  tracks: {tracks}"
    )


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    try:
        options = ExportOptions(
            ticks_per_beat=args.ticks_per_beat,
            steps_per_beat=args.steps_per_beat,
            drum_lane_base=args.drum_lane_base,
            drum_channel=args.drum_channel - 1,
            apply_swing=args.apply_swing,
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

    result = export_project(project.select(track=args.track, pattern=args.pattern), options)
    if result.is_empty:
        # Writing a MIDI file with no notes in it would look like success.
        print(
            f"{PROG}: {args.path}: nothing to export (no selected pattern holds notes)",
            file=sys.stderr,
        )
        return 1

    destination = args.output or args.path.with_suffix(".mid")
    if destination.exists() and not args.force:
        print(f"{PROG}: {destination} already exists (use --force to overwrite)", file=sys.stderr)
        return 1

    try:
        result.midi.save(destination)
    except OSError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 1

    for warning in result.warnings:
        print(f"{PROG}: warning: {warning}", file=sys.stderr)
    if not args.quiet:
        print(_summary(result, destination))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
