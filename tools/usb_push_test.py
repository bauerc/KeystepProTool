"""USB MIDI write probe -- minimal single-note push experiment targeting Project 8.

Tests pushing a single note change (Track 2, Pattern 1, Step 1 = C3) over USB SysEx
using Arturia's bulk direct-transfer protocol.

Two test modes:
  --mode ack     Synchronous mode: waits for an ACK frame after each write frame.
  --mode no-ack  Fire-and-forget mode: pushes all write frames continuously and reads ACKs at the end.
"""  # noqa: E501

import argparse
import sys
import time
from pathlib import Path

from ksp import sysex
from ksp_cli.usb_transport import DEFAULT_TIMEOUT_MS, TransportError, UsbMidiTransport

PROG = "usb_push_test"
TARGET_SLOT = 8  # Project 8
ACK_FRAME = b"\xf0\x00\x20\x6b\x7f\x42\x1c\x00\xf7"


def build_payload_frames(slot: int) -> list[tuple[str, bytes]]:
    """Build the clean minimal set of 8 write frames to place C3 (MIDI 60) on Track 2 Pattern 1 Step 1."""  # noqa: E501
    return [
        (
            "Global Project Scalar (Item 120 Param 37 = 3)",
            sysex.short_write(slot=slot, param=37, item=120, value=3),
        ),
        (
            "Pattern 1 Data State (Latch param 40 = 3)",
            sysex.short_write(slot=slot, param=40, item=124, value=3),
        ),
        (
            "Step 1 Active Flag (Param 48 = 1)",
            sysex.long_write(slot=slot, param=48, indices=(1, 1), item=124, count_bytes=b"\x01"),
        ),
        (
            "Note 1 Step Assignment (Param 50 = 0 / Step 1)",
            sysex.long_write(slot=slot, param=50, indices=(1, 1, 1), item=124, count_bytes=b"\x00"),
        ),
        (
            "Note 1 Pitch (Param 109 = 60 / C3 on KeyStep Pro)",
            sysex.long_write(
                slot=slot, param=109, indices=(1, 1, 1), item=124, count_bytes=b"\x3c"
            ),
        ),
        (
            "Note 1 Gate Length (Param 110 = 7)",
            sysex.long_write(
                slot=slot, param=110, indices=(1, 1, 1), item=124, count_bytes=b"\x07"
            ),
        ),
        (
            "Note 1 Velocity (Param 111 = 100)",
            sysex.long_write(
                slot=slot, param=111, indices=(1, 1, 1), item=124, count_bytes=b"\x64"
            ),
        ),
        (
            "Note 1 Time Shift (Param 112 = 49 / Centered)",
            sysex.long_write(
                slot=slot, param=112, indices=(1, 1, 1), item=124, count_bytes=b"\x31"
            ),
        ),
        (
            "Note 1 Randomness (Param 113 = 100 / Fresh Default)",
            sysex.long_write(
                slot=slot, param=113, indices=(1, 1, 1), item=124, count_bytes=b"\x64"
            ),
        ),
    ]


def run_ack_test(
    transport: UsbMidiTransport, slot: int, recorder: list[dict[str, str]] | None
) -> None:
    """Run test with synchronous ACK handling per write frame."""
    print("Sending Identity Request handshake...")
    t0 = time.perf_counter()
    id_reply = transport.exchange(sysex.IDENTITY_REQUEST)
    t_id = (time.perf_counter() - t0) * 1000
    print(
        f"<- Identity Reply: {id_reply.hex()} (Version: {sysex.parse_identity(id_reply)}) [{t_id:.2f} ms]"  # noqa: E501
    )
    if recorder is not None:
        recorder.append(
            {
                "direction": "out",
                "sysex_hex": sysex.IDENTITY_REQUEST.hex(),
                "label": "identity_request",
            }
        )
        recorder.append({"direction": "in", "sysex_hex": id_reply.hex(), "label": "identity_reply"})

    print(f"\nTargeting Project Slot {slot} with direct write frames...")
    frames = build_payload_frames(slot)
    t_write_start = time.perf_counter()
    for label, frame in frames:
        if recorder is not None:
            recorder.append({"direction": "out", "sysex_hex": frame.hex(), "label": label})

        reply = transport.exchange(frame)
        print(f"-> Sent [{label}] <- ACK: {reply.hex()}")
        if recorder is not None:
            recorder.append({"direction": "in", "sysex_hex": reply.hex()})

    epilogue = sysex.epilogue(slot)
    if recorder is not None:
        recorder.append({"direction": "out", "sysex_hex": epilogue.hex(), "label": "epilogue"})
    transport.send(epilogue)
    t_write_total = (time.perf_counter() - t_write_start) * 1000
    print(f"-> Epilogue sent. Total write transfer time: {t_write_total:.2f} ms")


def run_no_ack_test(
    transport: UsbMidiTransport, slot: int, recorder: list[dict[str, str]] | None
) -> None:
    """Run test asynchronously by streaming all frames without waiting for intermediate ACKs."""
    print("Sending Identity Request handshake...")
    t0 = time.perf_counter()
    id_reply = transport.exchange(sysex.IDENTITY_REQUEST)
    t_id = (time.perf_counter() - t0) * 1000
    print(
        f"<- Identity Reply: {id_reply.hex()} (Version: {sysex.parse_identity(id_reply)}) [{t_id:.2f} ms]"  # noqa: E501
    )
    if recorder is not None:
        recorder.append(
            {
                "direction": "out",
                "sysex_hex": sysex.IDENTITY_REQUEST.hex(),
                "label": "identity_request",
            }
        )
        recorder.append({"direction": "in", "sysex_hex": id_reply.hex(), "label": "identity_reply"})

    print(f"\nTargeting Project Slot {slot} with streaming write frames...")
    frames = build_payload_frames(slot)

    t_write_start = time.perf_counter()
    # Batch write all frames together for maximum USB throughput
    batch_bytes = bytearray()
    for label, frame in frames:
        if recorder is not None:
            recorder.append({"direction": "out", "sysex_hex": frame.hex(), "label": label})
        batch_bytes.extend(frame)

    epilogue = sysex.epilogue(slot)
    if recorder is not None:
        recorder.append({"direction": "out", "sysex_hex": epilogue.hex(), "label": "epilogue"})
    batch_bytes.extend(epilogue)

    # Send entire batch in one single USB call
    transport.send(bytes(batch_bytes))
    t_write_total = (time.perf_counter() - t_write_start) * 1000
    print(
        f"-> Pushed {len(frames)} frames + Epilogue in a single USB burst: {t_write_total:.2f} ms"
    )

    try:
        t_drain_start = time.perf_counter()
        queued = transport._read_frames()
        t_drain = (time.perf_counter() - t_drain_start) * 1000
        for _idx, reply in enumerate(queued, start=1):
            if recorder is not None:
                recorder.append({"direction": "in", "sysex_hex": reply.hex()})
        print(f"<- Received {len(queued)} ACKs from device in {t_drain:.2f} ms")
    except TransportError:
        print("<- No ACKs/replies received (device executed unbuffered burst)")


def save_recording(path: Path, entries: list[dict[str, str]]) -> None:
    import json

    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        for entry in entries:
            handle.write(json.dumps(entry) + "\n")
    print(f"Saved {len(entries)} log entries to {path}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog=PROG,
        description="Push a  C3 note on Track 2 Pattern 1 Step 1 to Project 8 over USB SysEx.",
    )
    parser.add_argument(
        "--mode",
        choices=["ack", "no-ack"],
        default="ack",
        help="Test mode: 'ack' (synchronous wait for ACKs) or 'no-ack' (fire-and-forget stream)",
    )
    parser.add_argument(
        "--slot",
        type=int,
        default=TARGET_SLOT,
        help=f"Target project slot (default: {TARGET_SLOT})",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT_MS,
        help=f"USB read timeout in milliseconds (default: {DEFAULT_TIMEOUT_MS})",
    )
    parser.add_argument(
        "--save",
        type=Path,
        metavar="PATH",
        help="Save SysEx frame trace to JSONL file",
    )

    args = parser.parse_args(argv)
    recorder: list[dict[str, str]] | None = [] if args.save else None

    print(f"Targeting Project Slot {args.slot} in [{args.mode.upper()}] mode")
    print("Ensure KeyStep Pro is connected via USB and MIDI Control Center is CLOSED.\n")

    try:
        with UsbMidiTransport(timeout_ms=args.timeout) as transport:
            if args.mode == "ack":
                run_ack_test(transport, args.slot, recorder)
            else:
                run_no_ack_test(transport, args.slot, recorder)
    except TransportError as error:
        print(f"Transport Error: {error}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"Unexpected Error: {error}", file=sys.stderr)
        return 1

    if args.save and recorder:
        save_recording(args.save, recorder)

    print("\nTest completed successfully.")
    print(f"Please inspect Project {args.slot} on the hardware panel (Track 2, Pattern 1, Step 1).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
