"""``midi2ksp`` -- write MIDI clips into a ``.KeyStepPro`` project."""

from pathlib import Path
from typing import Annotated

import mido
import typer

from ksp import constants
from ksp.constants import DEFAULT_STEPS_PER_BEAT
from ksp.lenient_json import dump_path
from ksp.midi_export import DEFAULT_FLAT_VELOCITY
from ksp.midi_import import (
    ImportOptions,
    ImportResult,
    Source,
    TrackPlan,
    check_selections,
    convert,
    convert_songs,
    saveable,
)
from ksp_cli.drum_map_option import DRUM_MAP_HELP, resolve_import_drum_map
from ksp_cli.flat_velocity import parse_flat_velocity
from ksp_cli.loading import load_template
from ksp_cli.midi_tracks_option import MIDI_TRACKS_HELP, resolve_midi_tracks
from ksp_cli.reporting import OUTPUT_PANEL, VerboseInPanel, fail, print_report
from ksp_cli.route_option import ROUTE_HELP, resolve_routes
from ksp_cli.runner import standalone

PROG = "midi2ksp"

HELP = "Convert Standard MIDI files into an Arturia KeyStep Pro project."
EPILOG = (
    "Every note-bearing track of every file is converted, onto the device's four. Each is "
    "anchored so its first note lands on step 1, quantised to the step grid, and cut "
    "into 64-step patterns if it runs longer -- chained, never truncated. Note lengths, "
    "velocity and tempo are carried. Several files merge in argument order, their tracks "
    "numbered on through one another. --midi-track converts a single track of a single "
    "file instead, into the one pattern --track and --pattern name."
)

_SOURCE_PANEL = "Source"
_DESTINATION_PANEL = "Destination"
_TIMING_PANEL = "Timing"


def _source(plan: TrackPlan, show_sources: bool, show_files: bool) -> str:
    """Where a track came from: its source track, then the file it was read from.
    A clip merged from several source tracks has no one source track, so it gets no number."""
    marks = []
    if show_sources and plan.source_track is not None:
        marks.append(f"source {plan.source_track}")
    if show_files and plan.source_file:
        marks.append(plan.source_file)
    return ", ".join(marks)


def _marks(plan: TrackPlan, show_sources: bool, show_files: bool) -> str:
    """The bracket after a track number in the per-track shape: kind, then source."""
    marks = ["drum"] if plan.is_drum else []
    source = _source(plan, show_sources, show_files)
    if source:
        marks.append(source)
    return f" [{', '.join(marks)}]" if marks else ""


def _summary(
    result: ImportResult,
    destination: Path,
    dry_run: bool,
    show_sources: bool = False,
    show_files: bool = False,
) -> str:
    verb = "would write" if dry_run else "wrote"
    lines = [f"{verb} {destination}"]

    tracks = result.plan.tracks
    if len(tracks) == 1 and len(tracks[0].placements) == 1:
        # The single-target shape carries no [drum] mark, so only a route adds one.
        source = _source(tracks[0], show_sources, show_files)
        lines.append(
            f"  {result.note_count} note(s) onto track {result.track}"
            f"{f' [{source}]' if source else ''}, "
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
        lines.append(
            f"  track {plan.track}{_marks(plan, show_sources, show_files)}: "
            f"{len(plan.notes)} note(s), {where} ({steps} steps)"
        )
    return "\n".join(lines)


def convert_command(
    paths: Annotated[
        list[Path],
        typer.Argument(
            metavar="PATHS...",
            help="one or more Standard MIDI files, merged in argument order",
        ),
    ],
    output: Annotated[
        Path | None,
        typer.Option(
            "-o",
            "--output",
            rich_help_panel=OUTPUT_PANEL,
            help=(
                "destination .KeyStepPro file (default: the first input file with a "
                ".KeyStepPro suffix)"
            ),
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
    route: Annotated[
        str | None,
        typer.Option("--route", metavar="SPEC", rich_help_panel=_SOURCE_PANEL, help=ROUTE_HELP),
    ] = None,
    drum_map_spec: Annotated[
        str | None,
        typer.Option(
            "--drum-map", metavar="SPEC", rich_help_panel=_SOURCE_PANEL, help=DRUM_MAP_HELP
        ),
    ] = None,
    flat_velocity: Annotated[
        str | None,
        typer.Option(
            "--flat-velocity",
            metavar="VALUE",
            rich_help_panel=_SOURCE_PANEL,
            help=(
                "write every note and trigger at this velocity instead of the source's: "
                f"'fresh' for the measured fresh-note velocity ({DEFAULT_FLAT_VELOCITY}), "
                "or 1-127"
            ),
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
    midi_tracks: Annotated[
        str | None,
        typer.Option(
            "--midi-tracks",
            metavar="LIST",
            rich_help_panel=_SOURCE_PANEL,
            help=MIDI_TRACKS_HELP,
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
            midi_tracks=resolve_midi_tracks(midi_track, midi_tracks),
            drum_track=drum_track,
            drum_map=resolve_import_drum_map(drum_map_spec),
            carry_tempo=not no_tempo,
            fit_swing=not no_swing_fit,
            fit_time_shift=not no_time_shift,
            routes=resolve_routes(midi_track, route),
            flat_velocity=parse_flat_velocity(flat_velocity),
        )
    except ValueError as exc:
        fail(str(exc), prog=PROG, code=2)

    if midi_track is not None and len(paths) > 1:
        fail("--midi-track reads one file, and several were given", prog=PROG, code=2)

    # Cheapest checks first: reading the 3.5 MB template before either would
    # spend a file read and a parse to reject the command anyway.
    destination = output or paths[0].with_suffix(".KeyStepPro")
    if destination.exists() and not force:
        fail(f"{destination} already exists (use --force to overwrite)", prog=PROG, code=1)

    # Every file is read before any of them is converted, so one unreadable late in the
    # list fails the run rather than half-filling a project.
    sources: list[Source] = []
    for source_path in paths:
        try:
            sources.append(Source(name=source_path.name, midi=mido.MidiFile(source_path)))
        except FileNotFoundError as exc:  # its message already names the file
            fail(str(exc), prog=PROG, code=1)
        except (OSError, EOFError, ValueError, IndexError) as exc:
            # mido raises OSError for a file that is not MIDI at all, so this is the
            # same class of failure as a truncated one rather than an IO error.
            fail(f"{source_path}: not a readable MIDI file: {exc}", prog=PROG, code=1)

    try:
        check_selections(sources, options)
    except ValueError as exc:
        fail(str(exc), prog=PROG, code=2)

    loaded_template = load_template(template, prog=PROG)

    # --midi-track is the single-target path; --midi-tracks is a selection, and
    # the song path is the only one that can place several tracks.
    try:
        if midi_track is not None:
            result = convert(
                sources[0].midi, loaded_template, track=track, pattern=pattern, options=options
            )
        else:
            result = convert_songs(
                sources,
                loaded_template,
                options=options,
                first_pattern=pattern,
                first_track=track,
            )
    except ValueError as exc:
        fail(str(exc), prog=PROG, code=1)

    if not result.note_count:
        # A project with nothing in it looks like success and plays silence.
        fail(f"{', '.join(str(p) for p in paths)}: no notes to convert", prog=PROG, code=1)

    if not dry_run:
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            dump_path(saveable(result.raw), destination)
        except OSError as exc:
            fail(str(exc), prog=PROG, code=1)

    print_report(result.diagnostics, prog=PROG, verbose=verbose)
    if not quiet:
        print(
            _summary(
                result,
                destination,
                dry_run,
                show_sources=route is not None or len(paths) > 1,
                show_files=len(paths) > 1,
            )
        )


def register(app: typer.Typer) -> None:
    """Mount this command on *app* -- its own, or the kspplus group."""
    app.command(name=PROG, help=HELP, epilog=EPILOG)(convert_command)


main = standalone(register, PROG)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
