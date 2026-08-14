"""The hardware probes -- Phase 1's H1.1 to H1.5, and Phase 2's H2.2 to H2.4.

Run these with the device attached and MIDI Control Center closed, then write
what they print into the ledger in analysis/Hardware_Test_Protocol.md. Each is
a few seconds; none of them writes to the device.

Byte 7 of every frame is the project slot (spec 7.4), so ``--slot`` says which
project to read. What comes back is that slot as stored: unsaved panel edits do
not travel. ``phase2`` also carries H4.1, the probe that shows the device
honouring the byte rather than the captures merely varying it.
"""

import argparse
import json
import statistics
import sys
import time
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ksp import bulk_fast, bulk_read, midi_export, reader, sysex
from ksp.keys import item_for_track
from ksp_cli.usb_transport import TransportError, UsbMidiTransport

PROG = "usb_probe"

#: H1.2. The first read of MCC's own plan, and one byte wide.
SCALAR = sysex.ReadRequest(item=120, param=37, indices=(), count=None)

#: H1.3. Pitches for track 2, pattern 1, note-pool chunk 1, from step 1.
THROUGHPUT = sysex.ReadRequest(item=124, param=109, indices=(1, 1, 1), count=16)

#: H1.5. Pattern default pitch, one request per pattern.
SENTINEL_ITEM = 123
SENTINEL_PARAM = 117
PATTERNS = range(1, 17)

#: H2.1's recipe, from the design doc: four ascending notes on every fourth step.
DEFAULT_STEPS = "1,5,9,13"
DEFAULT_PITCHES = "60,64,67,72"

#: The melodic trio H2.2 and H2.3 read, all note-indexed but 48.
P_STEP_ACTIVE = 48
P_NOTE_STEP = bulk_fast.MELODIC_GATE
P_PITCH = 109
P_GATE = 110
EMPTY = bulk_fast.EMPTY

#: Rows of a table or faults to print before summarising. A pattern the probe
#: was not pointed at can hold all 64 notes, and that is not worth 64 lines.
ROWS = 16


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


def slot_note(slot: int) -> str:
    return (
        f"note: read from project slot {slot} (byte 7), as stored -- "
        "edits made on the panel and not saved do not travel"
    )


@contextmanager
def device(args: argparse.Namespace, recorder: Recorder) -> Iterator[UsbMidiTransport]:
    """An open transport that has been through the handshake args ask for."""
    with UsbMidiTransport(timeout_ms=args.timeout) as transport:
        if not args.no_identity:
            exchange(transport, recorder, sysex.IDENTITY_REQUEST)
        if not args.no_prologue:
            # Names args.slot, not 1: H1.4 measured "no prologue needed" while
            # reading slot 1, so it rules one out only for slot 1.
            frame = sysex.prologue(args.slot)
            recorder.note("out", frame)
            transport.send(frame)
        yield transport


def exchange(transport: UsbMidiTransport, recorder: Recorder, request: bytes) -> bytes:
    recorder.note("out", request)
    reply = transport.exchange(request)
    recorder.note("in", reply)
    return reply


def read(
    transport: UsbMidiTransport,
    recorder: Recorder,
    request: sysex.ReadRequest,
    slot: int = sysex.DEFAULT_SLOT,
) -> tuple[int, ...]:
    frame = exchange(transport, recorder, sysex.build_read_request(request, slot))
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
        values = read(transport, recorder, SCALAR, args.slot)
    print(f"120_37 = {values[0]}")
    print("H1.2 confirms if a value came back at all; 3 is what the capture holds")
    print(slot_note(args.slot))
    return 0


def probe_throughput(args: argparse.Namespace, recorder: Recorder) -> int:
    """H1.3. Whether count may exceed the 16 MCC never goes above.

    An early investigation note had already seen a live count=0x40 answered in
    full, but it predated the protocol decode. This re-confirms it and puts a
    number on what it buys.
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
                    values = read(transport, recorder, request, args.slot)
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
    print(slot_note(args.slot))
    return 0


def probe_prologue(args: argparse.Namespace, recorder: Recorder) -> int:
    """H1.4. Which of the two handshake frames a read actually needs."""
    print(f"{'identity':>9}  {'prologue':>9}  result")
    for no_identity in (False, True):
        for no_prologue in (False, True):
            variant = argparse.Namespace(
                timeout=args.timeout,
                slot=args.slot,
                no_identity=no_identity,
                no_prologue=no_prologue,
            )
            try:
                with device(variant, recorder) as transport:
                    values = read(transport, recorder, SCALAR, args.slot)
                outcome = f"120_37 = {values[0]}"
            except (TransportError, ValueError) as error:
                outcome = f"failed: {error}"
            sent = ("sent", "skipped")
            print(f"{sent[no_identity]:>9}  {sent[no_prologue]:>9}  {outcome}")
    print("H1.4 settles which rows succeed; the last row is the minimal prologue if it does")
    print(slot_note(args.slot))
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
            value = read(transport, recorder, request, args.slot)[0]
            if value == sysex.UNSET:
                unset += 1
                meaning = f"unset (MCC would store {sysex.UNSET_IN_FILE})"
            else:
                meaning = "initialised"
            print(f"{pattern:>7}  {value:>4}  {meaning}")
    print(f"{unset} of {len(PATTERNS)} patterns unset")
    print(f"H1.5 confirms if any pattern reads {sysex.UNSET} raw rather than {sysex.UNSET_IN_FILE}")
    print(slot_note(args.slot))
    return 0


@dataclass(frozen=True)
class Verdict:
    passed: bool
    faults: tuple[str, ...]


def int_list(text: str) -> list[int]:
    """``"1,5,9,13"`` as integers, refusing anything else."""
    parts = [part.strip() for part in text.split(",")]
    if not all(part.isdigit() for part in parts):
        raise ValueError(f"{text!r} is not a comma-separated list of numbers")
    return [int(part) for part in parts]


def chunk(item: int, param: int, pattern: int, pool_slot: int = 1) -> sysex.ReadRequest:
    """A whole 64-entry array in one request.

    ``pool_slot`` is the note pool's own middle index, not the project slot: 48
    only ever uses 1 (spec section 4) and chunk 1 is where the first 64 notes
    live.
    """
    return sysex.ReadRequest(item=item, param=param, indices=(pattern, pool_slot, 1), count=64)


def live_notes(
    steps: Sequence[int], pitches: Sequence[int], gates: Sequence[int]
) -> list[tuple[int, int, int, int]]:
    """``(ordinal, step, pitch, gate)`` per occupied entry, both counters 1-based.

    50 holds the step 0-based while the panel counts from 1, so this is where
    that is undone -- printing it raw would send the operator hunting for a note
    on step 0.
    """
    return [
        (ordinal + 1, step + 1, pitches[ordinal], gates[ordinal])
        for ordinal, step in enumerate(steps)
        if step != EMPTY
    ]


def check_pool(
    steps: Sequence[int],
    pitches: Sequence[int],
    expected_steps: Sequence[int],
    expected_pitches: Sequence[int],
) -> Verdict:
    """H2.2. Do the ordinals and pitches say what the panel shows?

    ``steps`` is chunk 1 only, so it sees the first 64 notes of a 192-note pool.
    A full chunk therefore means "at least this many", not "this many" -- said
    out loud below rather than left to be misread.
    """
    live = [(ordinal + 1, step + 1) for ordinal, step in enumerate(steps) if step != EMPTY]
    faults = []
    if len(live) == len(steps):
        faults.append(f"chunk 1 is full ({len(live)} notes); the pattern may continue into chunk 2")
    elif len(live) != len(expected_steps):
        faults.append(f"{len(live)} notes in the pool, panel has {len(expected_steps)}")
    for (ordinal, step), want in zip(live, expected_steps, strict=False):
        if step != want:
            faults.append(f"ordinal {ordinal} sits on step {step}, panel has {want}")
    for (ordinal, _), want in zip(live, expected_pitches, strict=False):
        if pitches[ordinal - 1] != want:
            faults.append(f"ordinal {ordinal} has pitch {pitches[ordinal - 1]}, panel has {want}")
    return Verdict(not faults, tuple(faults))


def check_step_active(active: Sequence[int], expected_steps: Sequence[int]) -> Verdict:
    """H2.3. 48 is step-indexed, so a note-indexed writer lights the wrong steps."""
    wanted = set(expected_steps)
    faults = [
        f"step {step} is {'active' if value else 'inactive'} and should not be"
        for step, value in enumerate(active, start=1)
        if bool(value) != (step in wanted)
    ]
    return Verdict(not faults, tuple(faults))


class RecordingTransport:
    """``bulk_read.Transport`` that logs every frame into the recorder."""

    def __init__(self, transport: UsbMidiTransport, recorder: Recorder) -> None:
        self._transport = transport
        self._recorder = recorder

    def exchange(self, request: bytes) -> bytes:
        return exchange(self._transport, self._recorder, request)


def _report(label: str, verdict: Verdict) -> bool:
    print(f"{label}  {'PASS' if verdict.passed else 'FAIL'}")
    for fault in verdict.faults[:ROWS]:
        print(f"        {fault}")
    if len(verdict.faults) > ROWS:
        print(f"        ... and {len(verdict.faults) - ROWS} more")
    return verdict.passed


def probe_phase2(args: argparse.Namespace, recorder: Recorder) -> int:
    """H2.2-H2.4 and H4.1. One pass over a scratch pattern, checked against the panel.

    Build the pattern by hand first -- the recipe is in the Phase 2 section of
    analysis/Hardware_Test_Protocol.md -- and save it, because the read returns
    the slot as stored. Every section prints whatever the ones before it did, so
    one run yields all four results.
    """
    item = item_for_track(args.track)
    steps, pitches = int_list(args.steps), int_list(args.pitches)
    passed = True
    print(f"track {args.track} (item {item}), pattern {args.pattern}, project slot {args.slot}")
    print(f"panel: steps {steps} at pitches {pitches}\n")

    with device(args, recorder) as transport:

        def array(param: int, slot: int) -> tuple[int, ...]:
            return read(transport, recorder, chunk(item, param, args.pattern), slot)

        print("== H2.2  the note pool ==")
        pool = array(P_NOTE_STEP, args.slot)
        pitch = array(P_PITCH, args.slot)
        gate = array(P_GATE, args.slot)
        notes = live_notes(pool, pitch, gate)
        print(f"{'ordinal':>7}  {'step':>4}  {'pitch':>5}  {'gate':>4}")
        for ordinal, step, value, length in notes[:ROWS]:
            print(f"{ordinal:>7}  {step:>4}  {value:>5}  {length:>4}")
        if len(notes) > ROWS:
            print(f"{'...':>7}  and {len(notes) - ROWS} more notes in the pool")
        passed &= _report("H2.2", check_pool(pool, pitch, steps, pitches))

        print("\n== H2.3  the step-active array ==")
        active = array(P_STEP_ACTIVE, args.slot)
        lit = [step for step, value in enumerate(active, start=1) if value]
        print(f"active on {len(lit)} steps: {lit[:ROWS]}{' ...' if len(lit) > ROWS else ''}")
        passed &= _report("H2.3", check_step_active(active, steps))

        print("\n== H2.4  one pattern through the whole read path ==")
        plan = list(bulk_fast.iter_pattern_requests(item, args.pattern))
        template = _template_keys()
        start = time.perf_counter()
        raw = bulk_read.read_raw(
            RecordingTransport(transport, recorder),
            template,
            slot=args.slot,
            requests=plan,
        )
        elapsed = (time.perf_counter() - start) * 1000
        print(f"{len(plan)} requests in {elapsed:.0f} ms")
        try:
            _export(raw, args)
        except (OSError, ValueError, IndexError) as error:
            # The operator gets one run: a bad export must not cost them H4.1.
            print(f"        export failed: {error!r}")
            passed = False

        print("\n== H4.1  does the device honour byte 7? ==")
        passed &= _byte_seven(transport, recorder, args, item, pool, pitch)

    print(f"\nphase 2 {'PASSES' if passed else 'FAILS'}")
    print(slot_note(args.slot))
    return 0


def _template_keys() -> list[str]:
    """The full key set a project file has; the plan addresses less than that."""
    from ksp import lenient_json

    template = Path(__file__).resolve().parent.parent / "src/ksp_cli/templates/Default.KeyStepPro"
    return list(lenient_json.load_path(template))


def _export(raw: dict[str, int | str], args: argparse.Namespace) -> None:
    project = reader.read_project(raw, source_name=f"slot {args.slot}")
    result = midi_export.export_project(project)
    pattern = project.tracks[args.track - 1].patterns[args.pattern - 1]
    print(
        f"tempo {project.tempo_bpm} bpm, {pattern.seq_step_count} steps, {result.note_count} notes"
    )
    for warning in result.warnings:
        print(f"        {warning}")
    if args.midi_out is not None:
        args.midi_out.parent.mkdir(parents=True, exist_ok=True)
        result.midi.save(args.midi_out)
        print(f"wrote {args.midi_out} -- listen to it")
    print("H2.4 confirms if that file sounds like the panel")


def _byte_seven(
    transport: UsbMidiTransport,
    recorder: Recorder,
    args: argparse.Namespace,
    item: int,
    pool: tuple[int, ...],
    pitch: tuple[int, ...],
) -> bool:
    """H4.1, folded in because the byte is settable and the reads cost nothing.

    The panel is on ``--slot`` throughout. If naming ``--other-slot`` returns
    that slot's contents instead, byte 7 selects the project; if it returns the
    loaded one again, byte 7 is inert and the panel decides.
    """
    other = args.other_slot
    if other is None or other == args.slot:
        print("skipped: pass --other-slot with a slot whose pattern differs")
        return True

    here = read(transport, recorder, SCALAR, args.slot)[0]
    there = read(transport, recorder, SCALAR, other)[0]
    other_pool = read(transport, recorder, chunk(item, P_NOTE_STEP, args.pattern), other)
    other_pitch = read(transport, recorder, chunk(item, P_PITCH, args.pattern), other)
    print(f"{'':>10}  {'120_37':>6}  notes  first pitches")
    for label, scalar, entries, pitches in (
        (f"slot {args.slot}", here, pool, pitch),
        (f"slot {other}", there, other_pool, other_pitch),
    ):
        live = live_notes(entries, pitches, (0,) * len(entries))
        heads = [note[2] for note in live[:4]]
        print(f"{label:>10}  {scalar:>6}  {len(live):>5}  {heads}")

    differs = (here, pool, pitch) != (there, other_pool, other_pitch)
    outcome = "confirms: byte 7 SELECTS the project" if differs else "FALSIFIED: byte 7 is inert"
    print(f"H4.1 {outcome}")
    if not differs:
        print("        (or the two slots hold the same thing -- check the panel and re-run)")

    for edge in (0, 17):
        try:
            print(
                f"        byte 7 = {edge:>2}: 120_37 = {read(transport, recorder, SCALAR, edge)[0]}"
            )
        except (TransportError, ValueError) as error:
            print(f"        byte 7 = {edge:>2}: {error}")
    return True


PROBES = {
    "identity": probe_identity,
    "scalar": probe_scalar,
    "throughput": probe_throughput,
    "prologue": probe_prologue,
    "sentinel": probe_sentinel,
    "phase2": probe_phase2,
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog=PROG, description=__doc__)
    parser.add_argument("--timeout", type=int, default=1000, help="reply timeout, ms")
    parser.add_argument(
        "--slot",
        type=int,
        default=sysex.DEFAULT_SLOT,
        help="project slot to read, byte 7 of every frame (spec 7.4)",
    )
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
    parsers = {}
    for name, probe in PROBES.items():
        summary = (probe.__doc__ or "").splitlines()[0]
        parsers[name] = sub.add_parser(name, help=summary, description=probe.__doc__)

    # phase2 is the one probe that has to be told what the panel was built to
    # show, so its options do not fit on the parent parser the way the rest do.
    phase2 = parsers["phase2"]
    phase2.add_argument("--track", type=int, default=1, help="sequencer track, 1-4")
    phase2.add_argument("--pattern", type=int, default=1, help="pattern within that track, 1-16")
    phase2.add_argument("--steps", default=DEFAULT_STEPS, help="steps the panel has notes on")
    phase2.add_argument("--pitches", default=DEFAULT_PITCHES, help="their pitches, in step order")
    phase2.add_argument(
        "--other-slot", type=int, help="a second slot whose pattern differs, for H4.1"
    )
    phase2.add_argument("--midi-out", type=Path, metavar="PATH", help="write H2.4's export here")
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
