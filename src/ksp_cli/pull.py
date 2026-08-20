"""``ksp-pull`` -- read a project off an attached KeyStep Pro over USB.

The read lives in :mod:`ksp.bulk_read` and the protocol in :mod:`ksp.sysex`;
this module handles arguments, the transport, paths and what gets printed. What
comes back off the wire is the same flat dict ``lenient_json`` parses out of a
file, so writing it is a canonical key order and a ``dump_path``, nothing more.

MIDI Control Center is the only other way to get this file, and it wants a
Recall To and an export for each one. This asks the device directly.

The default walk is ``ksp.bulk_fast``'s: the same addresses MCC reads, coalesced
into requests of up to 64 values and skipping what the existence array has
already settled. H1.3 measured a request period that does not move with the
payload, so that is about a thousand requests rather than 8,951 -- ten seconds
against thirty-eight. ``--mcc-plan`` walks MCC's own stream instead.
"""

from pathlib import Path
from time import monotonic
from typing import Annotated

import typer

from ksp import constants, sysex
from ksp.bulk_read import DEFAULT_VERSION, Transport, read_raw
from ksp.lenient_json import canonical, dump_path
from ksp.reader import read_project
from ksp_cli.loading import load_template
from ksp_cli.reporting import OUTPUT_PANEL, VerboseInPanel, fail, print_report
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
    """The transport, with its requests counted for the summary.

    Counting belongs here rather than in ``bulk_read``: how many frames a walk
    costs is something to print, and ``ksp`` does not print.
    """

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

    A project MCC exported holds one, so a byte-identical file needs the
    identity request even though nothing in the read plan supplies it.
    """
    reply = transport.exchange(sysex.IDENTITY_REQUEST)
    try:
        return sysex.parse_identity(reply)
    except ValueError as exc:
        raise ValueError(f"{exc}: {reply.hex()}") from exc


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
    # write of the same size are most of a run that is not at the device, and a
    # total that quietly left them out would be the wrong number to plan around.
    began = monotonic()

    # Before the device is touched: a read costs ten seconds and the operator's
    # attention, and refusing it afterwards wastes both.
    if output.exists() and not force:
        fail(f"{output} already exists (use --force to overwrite)", prog=PROG, code=1)

    template_keys = load_template(template, prog=PROG).keys()

    opened = monotonic()
    try:
        with UsbMidiTransport(timeout_ms=timeout) as device:
            # The identity request is asked outside the count: what the summary
            # reports is the size of the walk, which is the figure spec 7.8
            # states and the one worth comparing a run against.
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

    # What was read has to parse as a project before it is worth writing: the
    # point of the dump is that the rest of this tool can take it from here.
    try:
        project = read_project(raw, source_name=str(output))
    except ValueError as exc:
        fail(f"the device's answer is not a readable project: {exc}", prog=PROG, code=1)

    try:
        output.parent.mkdir(parents=True, exist_ok=True)
        dump_path(canonical(raw), output)
    except OSError as exc:
        fail(str(exc), prog=PROG, code=1)

    print_report(project.diagnostics, prog=PROG, verbose=verbose)
    if not quiet:
        notes = sum(len(pattern.notes) for track in project.tracks for pattern in track.patterns)
        total = monotonic() - began
        print(f"read slot {slot} in {reading:.1f} s, {transport.requests} requests")
        print(f"wrote {output}")
        print(f"  {notes} note(s), {project.tempo_bpm:g} BPM")
        print(f"  {total:.1f} s total, {reading:.1f} s of it at the device")


def register(app: typer.Typer) -> None:
    """Mount this command on *app* -- its own, or the kspplus group."""
    app.command(name=PROG, help=HELP, epilog=EPILOG)(pull_command)


main = standalone(register, PROG)


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
