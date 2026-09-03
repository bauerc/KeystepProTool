"""``ksp-pull`` -- read a project off an attached KeyStep Pro over USB."""

from pathlib import Path
from time import monotonic
from typing import Annotated, NamedTuple

import typer

from ksp import constants, sysex
from ksp.bulk_read import DEFAULT_VERSION, Transport, read_raw
from ksp.lenient_json import canonical, dump_path
from ksp.midi_export import ExportOptions, export_project
from ksp.reader import read_project
from ksp_cli.drum_map_option import CONFIG_PATH, default_drum_map
from ksp_cli.export import summary
from ksp_cli.loading import load_template
from ksp_cli.reporting import (
    OUTPUT_PANEL,
    VerboseInPanel,
    fail,
    print_report,
    refuse_existing,
)
from ksp_cli.runner import standalone
from ksp_cli.usb_transport import DEFAULT_TIMEOUT_MS, TransportError, UsbMidiTransport

PROG = "ksp-pull"

HELP = "Read a project off an attached KeyStep Pro into a .KeyStepPro file."
EPILOG = (
    "The device must be connected over USB and powered on, and MIDI Control Center must be "
    "closed -- it holds the same interface. On macOS the read needs root, because the system "
    "binds its own USB-MIDI driver to that interface and will not release it: run this under "
    "sudo. --slot chooses which of the sixteen projects is read and needs no help from the "
    "panel, but it is read as saved, so save any panel edits first."
)

_DEVICE_PANEL = "Device"


class _Counted:
    """The transport, with its requests counted for the summary."""

    def __init__(self, inner: Transport) -> None:
        self._inner = inner
        self.requests = 0

    def send(self, frame: bytes) -> None:
        self._inner.send(frame)

    def exchange(self, request: bytes) -> bytes:
        self.requests += 1
        return self._inner.exchange(request)


def _version(transport: Transport) -> str:
    """The firmware version, which no read address carries.
    A project MCC exported holds one, so a byte-identical file needs this request."""
    reply = transport.exchange(sysex.IDENTITY_REQUEST)
    try:
        return sysex.parse_identity(reply)
    except ValueError as exc:
        raise ValueError(f"{exc}: {reply.hex()}") from exc


class _MidiPlan(NamedTuple):
    """Where --also-midi's export goes, and how it is rendered."""

    path: Path
    options: ExportOptions


def _midi_plan(output: Path, *, prog: str) -> _MidiPlan:
    """The sidecar for *output*, refusing a name whose .mid is *output* itself."""
    path = output.with_suffix(".mid")
    if path == output:
        fail(
            f"--also-midi cannot write {output}: the project and its MIDI would be the "
            "same file; name the project .KeyStepPro",
            prog=prog,
            code=2,
        )
    # The map is a usage error, so the config file is read before the walk, not after.
    return _MidiPlan(path, ExportOptions(drum_map=default_drum_map(CONFIG_PATH, prog=prog)))


def pull_command(
    output: Annotated[
        Path, typer.Argument(help="destination .KeyStepPro file", show_default=False)
    ],
    slot: Annotated[
        int,
        typer.Option(
            min=1,
            max=constants.PROJECT_SLOTS,
            rich_help_panel=_DEVICE_PANEL,
            help="project slot to read, as numbered on the device",
        ),
    ] = sysex.DEFAULT_SLOT,
    mcc_plan: Annotated[
        bool,
        typer.Option(
            "--mcc-plan",
            rich_help_panel=_DEVICE_PANEL,
            help=(
                "walk MIDI Control Center's own 8,951-request stream instead of the coalesced "
                "one. Reads the identical addresses, and takes about four times as long"
            ),
        ),
    ] = False,
    no_identity: Annotated[
        bool,
        typer.Option(
            "--no-identity",
            rich_help_panel=_DEVICE_PANEL,
            help=(
                f"skip the identity request and write version {DEFAULT_VERSION} instead of "
                "asking the device for it"
            ),
        ),
    ] = False,
    timeout: Annotated[
        int,
        typer.Option(
            metavar="MS",
            min=1,
            rich_help_panel=_DEVICE_PANEL,
            help="how long to wait for each reply",
        ),
    ] = DEFAULT_TIMEOUT_MS,
    template: Annotated[
        Path | None,
        typer.Option(
            rich_help_panel=_DEVICE_PANEL,
            help=(
                "project supplying the file's full key set (default: the shipped factory "
                "default). The read plan addresses the logical extent only; the rest is zero"
            ),
        ),
    ] = None,
    also_midi: Annotated[
        bool,
        typer.Option(
            "--also-midi",
            rich_help_panel=OUTPUT_PANEL,
            help=(
                "also write the .mid beside it, the file ksp2midi with no options would "
                "make from what was read"
            ),
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
    # From the top, not from the first frame: the 3.5 MB template parse and the
    # write of the same size are most of a run that is not at the device.
    began = monotonic()

    # Everything that can refuse the run happens here: a read costs ten seconds
    # of the operator's attention, and refusing it afterwards wastes them.
    plan = _midi_plan(output, prog=PROG) if also_midi else None
    refuse_existing([output] if plan is None else [output, plan.path], force=force, prog=PROG)

    template_keys = load_template(template, prog=PROG).keys()

    opened = monotonic()
    try:
        with UsbMidiTransport(timeout_ms=timeout) as device:
            # Outside the count: the summary reports the size of the walk.
            version = DEFAULT_VERSION if no_identity else _version(device)
            transport = _Counted(device)
            raw = read_raw(transport, template_keys, version=version, fast=not mcc_plan, slot=slot)
    except TransportError as exc:
        fail(str(exc), prog=PROG, code=1)
    except ValueError as exc:
        # A well-formed frame that answered the wrong question, or a slot with
        # nothing saved in it. bulk_read's messages already say which.
        fail(f"slot {slot}: {exc}", prog=PROG, code=1)
    reading = monotonic() - opened

    # What was read has to parse as a project before it is worth writing.
    try:
        # The bare name, as reader.load gives it: it becomes the MIDI track name.
        project = read_project(raw, source_name=output.name)
    except ValueError as exc:
        fail(f"the device's answer is not a readable project: {exc}", prog=PROG, code=1)

    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        dump_path(canonical(raw), output)
    except OSError as exc:
        fail(str(exc), prog=PROG, code=1)

    report = project.diagnostics
    midi_summary = None
    if plan is not None:
        exported = export_project(project, plan.options)
        report = report.merge(exported.diagnostics)
        if exported.is_empty:
            print_report(report, prog=PROG, verbose=verbose)
            fail(f"{output} was written, but no pattern holds notes to export", prog=PROG, code=1)
        try:
            exported.midi.save(plan.path)
        except OSError as exc:
            fail(str(exc), prog=PROG, code=1)
        midi_summary = summary(exported, plan.path)

    print_report(report, prog=PROG, verbose=verbose)
    if not quiet:
        notes = sum(len(pattern.notes) for track in project.tracks for pattern in track.patterns)
        total = monotonic() - began
        print(f"read slot {slot} in {reading:.1f} s, {transport.requests} requests")
        print(f"wrote {output}")
        print(f"  {notes} note(s), {project.tempo_bpm:g} BPM")
        if midi_summary is not None:
            print(midi_summary)
        print(f"  {total:.1f} s total, {reading:.1f} s of it at the device")


def register(app: typer.Typer) -> None:
    """Mount this command on *app* -- its own, or the kspplus group."""
    app.command(name=PROG, help=HELP, epilog=EPILOG)(pull_command)


main = standalone(register, PROG)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
