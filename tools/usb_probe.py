"""The Phase 1 hardware probes, H1.1 to H1.5 -- one subcommand each.

Run these with the device attached and MIDI Control Center closed, then write
what they print into the ledger in analysis/Hardware_Test_Protocol.md. Each is
a few seconds; none of them writes to the device.

Nothing in the read protocol's address tuple identifies a project slot, so
every read here targets whichever project is loaded on the panel. H4.1 settles
whether a select command exists at all.
"""

import argparse
import json
import statistics
import sys
import time
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from ksp import sysex
from ksp_cli.usb_transport import TransportError, UsbMidiTransport

PROG = "usb_probe"

CAVEAT = "note: this reads whichever project is loaded on the panel (H4.1 is unsettled)"

#: H1.2. The first read of MCC's own plan, and one byte wide.
SCALAR = sysex.ReadRequest(item=120, param=37, indices=(), count=None)

#: H1.3. Pitches for track 2, pattern 1, note-pool chunk 1, from step 1.
THROUGHPUT = sysex.ReadRequest(item=124, param=109, indices=(1, 1, 1), count=16)

#: H1.5. Pattern default pitch, one request per pattern.
SENTINEL_ITEM = 123
SENTINEL_PARAM = 117
PATTERNS = range(1, 17)


class Recorder:
    """Every frame a probe sent or received, for --save."""

    def __init__(self) -> None:
        self.entries: list[dict[str, str]] = []

    def note(self, direction: str, frame: bytes) -> None:
        self.entries.append({"direction": direction, "sysex_hex": frame.hex()})

    def write(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w") as handle:
            for entry in self.entries:
                handle.write(json.dumps(entry) + "\n")
        print(f"saved {len(self.entries)} frames to {path}")


@contextmanager
def device(args: argparse.Namespace, recorder: Recorder) -> Iterator[UsbMidiTransport]:
    """An open transport that has been through the handshake args ask for."""
    with UsbMidiTransport(timeout_ms=args.timeout) as transport:
        if not args.no_identity:
            exchange(transport, recorder, sysex.IDENTITY_REQUEST)
        if not args.no_prologue:
            recorder.note("out", sysex.PROLOGUE)
            transport.send(sysex.PROLOGUE)
        yield transport


def exchange(transport: UsbMidiTransport, recorder: Recorder, request: bytes) -> bytes:
    recorder.note("out", request)
    reply = transport.exchange(request)
    recorder.note("in", reply)
    return reply


def read(
    transport: UsbMidiTransport, recorder: Recorder, request: sysex.ReadRequest
) -> tuple[int, ...]:
    frame = exchange(transport, recorder, sysex.build_read_request(request))
    answered, values = sysex.parse_reply(frame)
    if answered != request:
        raise TransportError(f"asked for {request}, device answered {answered}")
    return values


def probe_identity(args: argparse.Namespace, recorder: Recorder) -> int:
    """H1.1. The version the read protocol cannot supply."""
    with UsbMidiTransport(timeout_ms=args.timeout) as transport:
        reply = exchange(transport, recorder, sysex.IDENTITY_REQUEST)
    print(f"reply   {reply.hex()}")
    print(f"version {sysex.parse_identity(reply)}")
    print("H1.1 confirms if that reads 2.5.20")
    return 0


def probe_scalar(args: argparse.Namespace, recorder: Recorder) -> int:
    """H1.2. The whole stack, end to end, on one byte."""
    with device(args, recorder) as transport:
        values = read(transport, recorder, SCALAR)
    print(f"120_37 = {values[0]}")
    print("H1.2 confirms if a value came back at all; 3 is what the capture holds")
    print(CAVEAT)
    return 0


def probe_throughput(args: argparse.Namespace, recorder: Recorder) -> int:
    """H1.3. Whether count may exceed the 16 MCC never goes above.

    keysteppro_usb_investigation.md already records a live count=0x40 answered
    in full, but that note predates the protocol decode. This re-confirms it and
    puts a number on what it buys.
    """
    print(f"{'count':>6}  {'ok':>3}  {'median ms':>9}  {'full dump':>10}")
    for count in (16, 64):
        request = sysex.ReadRequest(
            item=THROUGHPUT.item,
            param=THROUGHPUT.param,
            indices=THROUGHPUT.indices,
            count=count,
        )
        periods: list[float] = []
        delivered = 0
        try:
            with device(args, recorder) as transport:
                for _ in range(args.repeat):
                    start = time.perf_counter()
                    values = read(transport, recorder, request)
                    periods.append((time.perf_counter() - start) * 1000)
                    delivered = len(values)
        except (TransportError, ValueError) as error:
            print(f"{count:>6}  {'no':>3}  {error}")
            continue
        median = statistics.median(periods)
        # 153,495 values at this many per request, at this period.
        projected = 153_495 / count * median / 1000
        print(f"{count:>6}  {'yes':>3}  {median:>9.3f}  {projected:>9.1f}s  ({delivered} values)")
    print("H1.3 confirms if count=64 returns 64 values; expected, from the earlier live run")
    print(CAVEAT)
    return 0


def probe_prologue(args: argparse.Namespace, recorder: Recorder) -> int:
    """H1.4. Which of the two handshake frames a read actually needs."""
    print(f"{'identity':>9}  {'prologue':>9}  result")
    for no_identity in (False, True):
        for no_prologue in (False, True):
            variant = argparse.Namespace(
                timeout=args.timeout, no_identity=no_identity, no_prologue=no_prologue
            )
            try:
                with device(variant, recorder) as transport:
                    values = read(transport, recorder, SCALAR)
                outcome = f"120_37 = {values[0]}"
            except (TransportError, ValueError) as error:
                outcome = f"failed: {error}"
            sent = ("sent", "skipped")
            print(f"{sent[no_identity]:>9}  {sent[no_prologue]:>9}  {outcome}")
    print("H1.4 settles which rows succeed; the last row is the minimal prologue if it does")
    print(CAVEAT)
    return 0


def probe_sentinel(args: argparse.Namespace, recorder: Recorder) -> int:
    """H1.5. The 0xFF the wire carries and MCC turns into 247."""
    print(f"{'pattern':>7}  {'raw':>4}  meaning")
    unset = 0
    with device(args, recorder) as transport:
        for pattern in PATTERNS:
            request = sysex.ReadRequest(
                item=SENTINEL_ITEM, param=SENTINEL_PARAM, indices=(pattern,), count=1
            )
            value = read(transport, recorder, request)[0]
            if value == sysex.UNSET:
                unset += 1
                meaning = f"unset (MCC would store {sysex.UNSET_IN_FILE})"
            else:
                meaning = "initialised"
            print(f"{pattern:>7}  {value:>4}  {meaning}")
    print(f"{unset} of {len(PATTERNS)} patterns unset")
    print(f"H1.5 confirms if any pattern reads {sysex.UNSET} raw rather than {sysex.UNSET_IN_FILE}")
    print(CAVEAT)
    return 0


PROBES = {
    "identity": probe_identity,
    "scalar": probe_scalar,
    "throughput": probe_throughput,
    "prologue": probe_prologue,
    "sentinel": probe_sentinel,
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=PROG, description=__doc__)
    parser.add_argument("--timeout", type=int, default=1000, help="reply timeout, ms")
    parser.add_argument(
        "--save",
        type=Path,
        metavar="PATH",
        help="write every frame sent and received to PATH as jsonl",
    )
    parser.add_argument(
        "--no-identity", action="store_true", help="skip the identity request (H1.4)"
    )
    parser.add_argument(
        "--no-prologue", action="store_true", help="skip the 0x05 prologue frame (H1.4)"
    )
    # Only throughput reads it, but keeping every option on the parent parser
    # means they all sit before the subcommand rather than some either side.
    parser.add_argument(
        "--repeat", type=int, default=32, help="reads per count in the throughput probe"
    )

    sub = parser.add_subparsers(dest="probe", required=True, metavar="PROBE")
    for name, probe in PROBES.items():
        summary = (probe.__doc__ or "").splitlines()[0]
        sub.add_parser(name, help=summary, description=probe.__doc__)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    recorder = Recorder()
    probe: Any = PROBES[args.probe]
    try:
        code = int(probe(args, recorder))
    except TransportError as error:
        print(f"{PROG}: {error}", file=sys.stderr)
        code = 1
    except ValueError as error:
        print(f"{PROG}: the device answered something unreadable: {error}", file=sys.stderr)
        code = 1
    if args.save is not None:
        recorder.write(args.save)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
