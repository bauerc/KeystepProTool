"""``midi2ksp`` -- write a MIDI clip into a ``.KeyStepPro`` project.

The conversion lives in :mod:`ksp.midi_import`; this module handles arguments,
paths and what gets printed.

A project file is never synthesised. Its key set is fixed at 153,495 numeric
keys, so a template is loaded and values are overwritten in it -- MIDI Control
Center's factory default by default, or any project you point ``--template``
at, which is how a clip goes into a pattern of a project you already have.

Warnings go to stderr and the summary to stdout, the same contract as
``ksp2midi``: the file is still written, because a note length we chose not to
carry is a caveat rather than a failure. ``--quiet`` suppresses the stdout
summary only.
"""

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

import mido

from ksp import constants
from ksp.constants import DEFAULT_STEPS_PER_BEAT
from ksp.lenient_json import dump_path, load_path
from ksp.midi_import import ImportOptions, ImportResult, convert, saveable
from ksp_cli.reporting import add_verbose_option, print_report

PROG = "midi2ksp"

#: Shipped inside the package so the installed command is self-contained. Path
#: resolution stays in the CLI: ``ksp`` must not decide where files are.
TEMPLATE_NAME = "Default.KeyStepPro"


def default_template() -> Path:
    """MCC's factory default, as shipped with this package."""
    return Path(__file__).parent / "templates" / TEMPLATE_NAME


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=PROG,
        description="Convert a Standard MIDI file into an Arturia KeyStep Pro project.",
        epilog=(
            "One track, one pattern, monophonic. The clip is anchored so its first note lands "
            "on step 1, quantised to the step grid, and any note past the pattern's last step "
            "is dropped -- the device does not play those. Note lengths and tempo are not "
            "carried."
        ),
    )
    parser.add_argument("path", type=Path, help="a Standard MIDI file")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="destination .KeyStepPro file (default: the input file with a .KeyStepPro suffix)",
    )
    parser.add_argument(
        "--track",
        type=int,
        default=1,
        choices=range(1, len(constants.TRACK_ITEM_IDS) + 1),
        metavar="{1..4}",
        help="KeyStep Pro track to write to (default: %(default)s)",
    )
    parser.add_argument(
        "--pattern",
        type=int,
        default=1,
        choices=range(1, constants.PATTERNS_PER_TRACK + 1),
        metavar="{1..16}",
        help="pattern to write to (default: %(default)s). It must be empty",
    )
    parser.add_argument(
        "--template",
        type=Path,
        help=(
            "project to write into (default: MIDI Control Center's factory default). "
            "Point this at one of your own projects to keep everything else in it"
        ),
    )
    parser.add_argument(
        "--midi-track",
        type=int,
        metavar="N",
        help="read only track N of the source file, counting from 1 (default: all of them)",
    )
    parser.add_argument(
        "--steps-per-beat",
        type=int,
        default=DEFAULT_STEPS_PER_BEAT,
        metavar="N",
        help=(
            "step size to quantise to (default: %(default)s, i.e. 1/16 steps). Written into "
            "the pattern, so the device plays back on the grid the clip was snapped to"
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would be written, and write nothing",
    )
    parser.add_argument("--force", action="store_true", help="overwrite an existing output file")
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="suppress the stdout summary. Warnings still go to stderr",
    )
    add_verbose_option(parser)
    return parser


def _summary(result: ImportResult, destination: Path, dry_run: bool) -> str:
    verb = "would write" if dry_run else "wrote"
    return (
        f"{verb} {destination}\n"
        f"  {result.note_count} note(s) onto track {result.track}, pattern {result.pattern} "
        f"({result.step_count} steps)"
    )


def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)

    try:
        options = ImportOptions(
            steps_per_beat=args.steps_per_beat,
            midi_track=args.midi_track,
        )
    except ValueError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 2

    # Cheapest checks first: the destination depends only on the arguments, and
    # a bad clip is the likelier mistake. Reading the 3.5 MB template before
    # either would spend a file read and a parse to reject the command anyway.
    destination = args.output or args.path.with_suffix(".KeyStepPro")
    if destination.exists() and not args.force:
        print(
            f"{PROG}: {destination} already exists (use --force to overwrite)",
            file=sys.stderr,
        )
        return 1

    try:
        midi = mido.MidiFile(args.path)
    except FileNotFoundError as exc:  # its message already names the file
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 1
    except (OSError, EOFError, ValueError, IndexError) as exc:
        # mido raises OSError for a file that is not MIDI at all, so this is
        # the same class of failure as a truncated one rather than an IO error.
        print(f"{PROG}: {args.path}: not a readable MIDI file: {exc}", file=sys.stderr)
        return 1

    template_path = args.template or default_template()
    try:
        template = load_path(template_path)
    except OSError as exc:
        print(f"{PROG}: template: {exc}", file=sys.stderr)
        return 1
    except ValueError as exc:
        print(f"{PROG}: template: {template_path}: {exc}", file=sys.stderr)
        return 1

    try:
        result = convert(midi, template, track=args.track, pattern=args.pattern, options=options)
    except ValueError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 1

    if not result.note_count:
        # A project with nothing in it looks like success and plays silence.
        print(f"{PROG}: {args.path}: no notes to convert", file=sys.stderr)
        return 1

    if not args.dry_run:
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            dump_path(saveable(result.raw), destination)
        except OSError as exc:
            print(f"{PROG}: {exc}", file=sys.stderr)
            return 1

    print_report(result.diagnostics, prog=PROG, verbose=args.verbose)
    if not args.quiet:
        print(_summary(result, destination, args.dry_run))
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
