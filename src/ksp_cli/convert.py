"""``midi2ksp`` -- write a MIDI clip into a ``.KeyStepPro`` project.

The conversion lives in :mod:`ksp.midi_import`; this module handles arguments,
paths and what gets printed.

A project file is never synthesised. Its key set is fixed at 153,495 numeric
keys, so a template is loaded and values are overwritten in it -- MIDI Control
Center's factory default by default, or any project you point ``--template``
at, which is how a clip goes into a pattern of a project you already have.

Warnings go to stderr and the summary to stdout, the same contract as
``ksp2midi``: the file is still written, because a drum map we had to assume is
a caveat rather than a failure. ``--quiet`` suppresses the stdout summary only.
"""

import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Annotated

import mido
import typer

from ksp import constants
from ksp.constants import DEFAULT_STEPS_PER_BEAT
from ksp.lenient_json import dump_path, load_path
from ksp.midi_import import ImportOptions, ImportResult, convert, convert_song, saveable
from ksp_cli.drum_map_option import DRUM_MAP_HELP, resolve_import_drum_map
from ksp_cli.reporting import OUTPUT_PANEL, VerboseInPanel, print_report
from ksp_cli.runner import run

PROG = "midi2ksp"

HELP = "Convert a Standard MIDI file into an Arturia KeyStep Pro project."
EPILOG = (
    "Every note-bearing track of the file is converted, onto the device's four. Each is "
    "anchored so its first note lands on step 1, quantised to the step grid, and cut "
    "into 64-step patterns if it runs longer -- chained, never truncated. Note lengths, "
    "velocity and tempo are carried. --midi-track converts a single track instead, into "
    "the one pattern --track and --pattern name."
)

_SOURCE_PANEL = "Source"
_DESTINATION_PANEL = "Destination"
_TIMING_PANEL = "Timing"

#: Shipped inside the package so the installed command is self-contained. Path
#: resolution stays in the CLI: ``ksp`` must not decide where files are.
TEMPLATE_NAME = "Default.KeyStepPro"


def default_template() -> Path:
    """MCC's factory default, as shipped with this package."""
    return Path(__file__).parent / "templates" / TEMPLATE_NAME


def _summary(result: ImportResult, destination: Path, dry_run: bool) -> str:
    verb = "would write" if dry_run else "wrote"
    lines = [f"{verb} {destination}"]

    tracks = result.plan.tracks
    if len(tracks) == 1 and len(tracks[0].placements) == 1:
        # The single-target shape, said the way it has always been said.
        lines.append(
            f"  {result.note_count} note(s) onto track {result.track}, "
            f"pattern {result.pattern} ({result.step_count} steps)"
        )
        return "\n".join(lines)

    for plan in tracks:
        patterns = plan.patterns
        where = (
            f"pattern {patterns[0]}"
            if len(patterns) == 1
            else f"patterns {patterns[0]}-{patterns[-1]}"
        )
        steps = ", ".join(str(p.step_count) for p in plan.placements)
        kind = " [drum]" if plan.is_drum else ""
        lines.append(
            f"  track {plan.track}{kind}: {len(plan.notes)} note(s), {where} ({steps} steps)"
        )
    return "\n".join(lines)


def convert_command(
    path: Annotated[Path, typer.Argument(help="a Standard MIDI file")],
    output: Annotated[
        Path | None,
        typer.Option(
            "-o",
            "--output",
            rich_help_panel=OUTPUT_PANEL,
            help="destination .KeyStepPro file (default: the input file with a .KeyStepPro suffix)",
        ),
    ] = None,
    track: Annotated[
        int,
        typer.Option(
            min=1,
            max=len(constants.TRACK_ITEM_IDS),
            rich_help_panel=_DESTINATION_PANEL,
            help="KeyStep Pro track to write to",
        ),
    ] = 1,
    pattern: Annotated[
        int,
        typer.Option(
            min=1,
            max=constants.PATTERNS_PER_TRACK,
            rich_help_panel=_DESTINATION_PANEL,
            help=(
                "first pattern to write to. Every target pattern must be empty; a track "
                "needing more than one continues into the slots after it"
            ),
        ),
    ] = 1,
    drum_track: Annotated[
        int | None,
        typer.Option(
            metavar="N",
            rich_help_panel=_SOURCE_PANEL,
            help=(
                "write track N of the source as drums, onto KeyStep Pro track 1 (the only one "
                "with a drum set). Counting from 1 over every track of the file. Without this, "
                "a track on the GM percussion channel is used, and many files have none"
            ),
        ),
    ] = None,
    drum_map_spec: Annotated[
        str | None,
        typer.Option(
            "--drum-map", metavar="SPEC", rich_help_panel=_SOURCE_PANEL, help=DRUM_MAP_HELP
        ),
    ] = None,
    no_tempo: Annotated[
        bool,
        typer.Option(
            "--no-tempo",
            rich_help_panel=_TIMING_PANEL,
            help="keep the template's tempo instead of taking the source's",
        ),
    ] = False,
    no_swing_fit: Annotated[
        bool,
        typer.Option(
            "--no-swing-fit",
            rich_help_panel=_TIMING_PANEL,
            help="leave every pattern straight instead of fitting the source's groove to swing",
        ),
    ] = False,
    no_time_shift: Annotated[
        bool,
        typer.Option(
            "--no-time-shift",
            rich_help_panel=_TIMING_PANEL,
            help="quantise hard, instead of giving each note's leftover to its time shift",
        ),
    ] = False,
    template: Annotated[
        Path | None,
        typer.Option(
            rich_help_panel=_DESTINATION_PANEL,
            help=(
                "project to write into (default: MIDI Control Center's factory default). "
                "Point this at one of your own projects to keep everything else in it"
            ),
        ),
    ] = None,
    midi_track: Annotated[
        int | None,
        typer.Option(
            metavar="N",
            rich_help_panel=_SOURCE_PANEL,
            help="read only track N of the source file, counting from 1 (default: all of them)",
        ),
    ] = None,
    steps_per_beat: Annotated[
        int,
        typer.Option(
            metavar="N",
            rich_help_panel=_TIMING_PANEL,
            help=(
                "step size to quantise to (the default is 1/16 steps). Written into the "
                "pattern, so the device plays back on the grid the clip was snapped to"
            ),
        ),
    ] = DEFAULT_STEPS_PER_BEAT,
    dry_run: Annotated[
        bool,
        typer.Option(
            "--dry-run",
            rich_help_panel=OUTPUT_PANEL,
            help="report what would be written, and write nothing",
        ),
    ] = False,
    force: Annotated[
        bool,
        typer.Option(
            "--force", rich_help_panel=OUTPUT_PANEL, help="overwrite an existing output file"
        ),
    ] = False,
    quiet: Annotated[
        bool,
        typer.Option(
            "--quiet",
            rich_help_panel=OUTPUT_PANEL,
            help="suppress the stdout summary. Warnings still go to stderr",
        ),
    ] = False,
    verbose: VerboseInPanel = False,
) -> None:
    try:
        options = ImportOptions(
            steps_per_beat=steps_per_beat,
            midi_track=midi_track,
            drum_track=drum_track,
            drum_map=resolve_import_drum_map(drum_map_spec),
            carry_tempo=not no_tempo,
            fit_swing=not no_swing_fit,
            fit_time_shift=not no_time_shift,
        )
    except ValueError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        raise typer.Exit(2) from None

    # Cheapest checks first: the destination depends only on the arguments, and
    # a bad clip is the likelier mistake. Reading the 3.5 MB template before
    # either would spend a file read and a parse to reject the command anyway.
    destination = output or path.with_suffix(".KeyStepPro")
    if destination.exists() and not force:
        print(
            f"{PROG}: {destination} already exists (use --force to overwrite)",
            file=sys.stderr,
        )
        raise typer.Exit(1)

    try:
        midi = mido.MidiFile(path)
    except FileNotFoundError as exc:  # its message already names the file
        print(f"{PROG}: {exc}", file=sys.stderr)
        raise typer.Exit(1) from None
    except (OSError, EOFError, ValueError, IndexError) as exc:
        # mido raises OSError for a file that is not MIDI at all, so this is
        # the same class of failure as a truncated one rather than an IO error.
        print(f"{PROG}: {path}: not a readable MIDI file: {exc}", file=sys.stderr)
        raise typer.Exit(1) from None

    template_path = template or default_template()
    try:
        loaded_template = load_path(template_path)
    except OSError as exc:
        print(f"{PROG}: template: {exc}", file=sys.stderr)
        raise typer.Exit(1) from None
    except ValueError as exc:
        print(f"{PROG}: template: {template_path}: {exc}", file=sys.stderr)
        raise typer.Exit(1) from None

    # --midi-track narrows the source to one track, which is the whole of the
    # single-target path: that one track, into the one pattern --track and
    # --pattern name, at the length that pattern already declares.
    try:
        if midi_track is not None:
            result = convert(midi, loaded_template, track=track, pattern=pattern, options=options)
        else:
            result = convert_song(
                midi,
                loaded_template,
                options=options,
                first_pattern=pattern,
                first_track=track,
            )
    except ValueError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        raise typer.Exit(1) from None

    if not result.note_count:
        # A project with nothing in it looks like success and plays silence.
        print(f"{PROG}: {path}: no notes to convert", file=sys.stderr)
        raise typer.Exit(1)

    if not dry_run:
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            dump_path(saveable(result.raw), destination)
        except OSError as exc:
            print(f"{PROG}: {exc}", file=sys.stderr)
            raise typer.Exit(1) from None

    print_report(result.diagnostics, prog=PROG, verbose=verbose)
    if not quiet:
        print(_summary(result, destination, dry_run))


def register(app: typer.Typer) -> None:
    """Mount this command on *app* -- its own, or the kspplus group."""
    app.command(name=PROG, help=HELP, epilog=EPILOG)(convert_command)


app = typer.Typer(add_completion=False, rich_markup_mode="rich")
register(app)


def main(argv: Sequence[str] | None = None) -> int:
    return run(app, argv, prog_name=PROG)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
