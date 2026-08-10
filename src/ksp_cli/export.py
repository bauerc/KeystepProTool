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

import enum
from collections.abc import Sequence
from pathlib import Path
from typing import Annotated

import typer

from ksp.constants import DEFAULT_GATE_LENGTH
from ksp.diagnostics import Report
from ksp.midi_export import (
    DEFAULT_TICKS_PER_BEAT,
    DRUM_CHANNEL,
    ExportOptions,
    ExportResult,
    export_project,
    export_split,
)
from ksp.model import Project
from ksp_cli.drum_map_option import CONFIG_PATH, DRUM_MAP_HELP, resolve_drum_map_or_fail
from ksp_cli.loading import load_project
from ksp_cli.reporting import OUTPUT_PANEL, VerboseInPanel, fail, print_report
from ksp_cli.runner import standalone

PROG = "ksp2midi"

HELP = "Convert an Arturia KeyStep Pro project into Standard MIDI file(s)."
EPILOG = (
    "By default patterns that hold notes are laid end to end in pattern order in one "
    "file, and pattern N starts at the same point on every track. --split writes each "
    "(track, pattern) to its own file instead."
)

_SELECTION_PANEL = "Selection"
_TIMING_PANEL = "Timing"
_DRUM_PANEL = "Drum mapping"


class Passes(enum.StrEnum):
    """How many of the four repeats to render. ``auto`` decides per pattern."""

    AUTO = "auto"
    ONE = "1"
    TWO = "2"
    THREE = "3"
    FOUR = "4"


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
    project: Project,
    options: ExportOptions,
    *,
    path: Path,
    output: Path | None,
    split: bool,
    track: int | None,
    pattern: int | None,
) -> list[tuple[ExportResult, Path]]:
    """Pair each rendered file with where it goes. Nothing is written yet."""
    narrowed = project.select(track=track, pattern=pattern)
    if split:
        directory = output or path.parent
        return [
            (result, directory / _split_name(path, result))
            for result in export_split(narrowed, options)
        ]
    result = export_project(narrowed, options)
    if result.is_empty:
        return []
    return [(result, output or path.with_suffix(".mid"))]


def export(
    path: Annotated[Path, typer.Argument(help="a .KeyStepPro project file")],
    output: Annotated[
        Path | None,
        typer.Option(
            "-o",
            "--output",
            rich_help_panel=OUTPUT_PANEL,
            help=(
                "destination .mid file (default: the input file with a .mid suffix); "
                "with --split, a directory (default: the input file's own directory)"
            ),
        ),
    ] = None,
    split: Annotated[
        bool,
        typer.Option(
            "--split",
            rich_help_panel=_SELECTION_PANEL,
            help=(
                "write one file per non-empty (track, pattern), named "
                "<stem>_track{N}_pattern{P}.mid, each starting at its own tick 0"
            ),
        ),
    ] = False,
    track: Annotated[
        int | None,
        typer.Option(
            min=1,
            max=4,
            rich_help_panel=_SELECTION_PANEL,
            help="export only this track",
        ),
    ] = None,
    pattern: Annotated[
        int | None,
        typer.Option(
            min=1,
            max=16,
            rich_help_panel=_SELECTION_PANEL,
            help="export only this pattern",
        ),
    ] = None,
    passes: Annotated[
        Passes,
        typer.Option(
            rich_help_panel=_SELECTION_PANEL,
            help=(
                "how many of the four 16/32/48/64 repeats to render (auto: four when a "
                "pattern holds a note that does not play on all four, one otherwise)"
            ),
        ),
    ] = Passes.AUTO,
    ticks_per_beat: Annotated[
        int, typer.Option(rich_help_panel=_TIMING_PANEL, help="MIDI resolution")
    ] = DEFAULT_TICKS_PER_BEAT,
    drum_map_spec: Annotated[
        str | None,
        typer.Option("--drum-map", metavar="SPEC", rich_help_panel=_DRUM_PANEL, help=DRUM_MAP_HELP),
    ] = None,
    drum_channel: Annotated[
        int,
        typer.Option(
            min=1,
            max=16,
            rich_help_panel=_DRUM_PANEL,
            help="MIDI channel for drum lanes",
        ),
    ] = DRUM_CHANNEL + 1,
    default_gate: Annotated[
        float,
        typer.Option(
            metavar="STEPS",
            rich_help_panel=_TIMING_PANEL,
            help=(
                "note length in steps for a gate value outside the measured 0-127 ladder "
                "(the default is the length a freshly placed note has on the device)"
            ),
        ),
    ] = DEFAULT_GATE_LENGTH,
    include_stale: Annotated[
        bool,
        typer.Option(
            "--include-stale",
            rich_help_panel=_SELECTION_PANEL,
            help=(
                "where a pattern holds both a melodic and a drum note set, export both instead "
                "of only the one parameter 86 bit 6 says the device plays"
            ),
        ),
    ] = False,
    include_disabled: Annotated[
        bool,
        typer.Option(
            "--include-disabled",
            rich_help_panel=_SELECTION_PANEL,
            help=(
                "export notes whose step is turned off; the device does not play them, so they "
                "are omitted by default"
            ),
        ),
    ] = False,
    no_swing: Annotated[
        bool,
        typer.Option(
            "--no-swing",
            rich_help_panel=_TIMING_PANEL,
            help="ignore per-pattern swing and place every step on a flat grid",
        ),
    ] = False,
    no_time_shift: Annotated[
        bool,
        typer.Option(
            "--no-time-shift",
            rich_help_panel=_TIMING_PANEL,
            help="ignore each note's time shift and place every step on a flat grid",
        ),
    ] = False,
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
            "--force",
            rich_help_panel=OUTPUT_PANEL,
            help="overwrite the output file if it already exists",
        ),
    ] = False,
    quiet: Annotated[
        bool,
        typer.Option(
            "--quiet", rich_help_panel=OUTPUT_PANEL, help="suppress the summary on stdout"
        ),
    ] = False,
    verbose: VerboseInPanel = False,
) -> None:
    drum_map = resolve_drum_map_or_fail(drum_map_spec, CONFIG_PATH, prog=PROG)
    if drum_map is None:
        # ksp-dump can print "lane 0" and leave it unresolved; a MIDI file has
        # no way to say that, so there is nothing sensible to write.
        fail(
            "--drum-map none cannot be exported: a MIDI file has to name a note "
            "for every drum lane",
            prog=PROG,
            code=2,
        )

    try:
        options = ExportOptions(
            ticks_per_beat=ticks_per_beat,
            passes=None if passes is Passes.AUTO else int(passes.value),
            drum_map=drum_map,
            drum_channel=drum_channel - 1,
            default_gate=default_gate,
            apply_swing=not no_swing,
            apply_time_shift=not no_time_shift,
            include_stale=include_stale,
            include_disabled=include_disabled,
        )
    except ValueError as exc:
        fail(str(exc), prog=PROG, code=2)

    project = load_project(path, prog=PROG)
    planned = _plan(
        project, options, path=path, output=output, split=split, track=track, pattern=pattern
    )
    if not planned:
        # Writing a MIDI file with no notes in it would look like success.
        fail(f"{path}: nothing to export (no selected pattern holds notes)", prog=PROG, code=1)

    existing = [str(destination) for _, destination in planned if destination.exists()]
    if existing and not force:
        fail(f"{', '.join(existing)} already exists (use --force to overwrite)", prog=PROG, code=1)

    if not dry_run:
        try:
            for _, destination in planned:
                destination.parent.mkdir(parents=True, exist_ok=True)
            for result, destination in planned:
                result.midi.save(destination)
        except OSError as exc:
            fail(str(exc), prog=PROG, code=1)

    print_report(_report(planned), prog=PROG, verbose=verbose)
    if not quiet:
        print("\n".join(_summary(result, destination, dry_run) for result, destination in planned))


def register(app: typer.Typer) -> None:
    """Mount this command on *app* -- its own, or the kspplus group."""
    app.command(name=PROG, help=HELP, epilog=EPILOG)(export)


main = standalone(register, PROG)


def _report(planned: Sequence[tuple[ExportResult, Path]]) -> Report:
    """Every file's diagnostics, each said once however many files repeat it."""
    merged = Report()
    for result, _ in planned:
        merged = merged.merge(result.diagnostics)
    return merged


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
