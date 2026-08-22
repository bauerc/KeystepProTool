"""Distil a gitignored USB capture into a tracked replay fixture.

``--write`` reads a write capture, whose directions are the same frames with the
roles swapped: the reply opcodes are what the host sends (spec section 7).
"""

import json
import sys
from pathlib import Path

CAPTURE = Path("usb_midi_investigation/recall_sysex.jsonl")
TAPE = Path("tests/fixtures/recall_tape.txt")

ARTURIA = bytes((0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42))
REQUESTS = (0x0B, 0x01)
REPLIES = (0x0C, 0x02)
ACKS = (0x1C,)

#: The capture's ``direction`` field is unreliable; the USB endpoint distinguishes them.
HOST_TO_DEVICE = "0x01"
DEVICE_TO_HOST = "0x81"

#: Reply column for a frame the device never answered (spec section 7.6).
NO_REPLY = "-"


def distil(capture: Path, *, write: bool = False) -> list[str]:
    """Pair each sent frame with the reply that followed it. Traffic is strictly
    serialised -- send, reply, ack -- so a single pending slot is enough."""
    sent, received = (REPLIES, ACKS) if write else (REQUESTS, REPLIES)
    lines: list[str] = []
    pending: bytes | None = None
    for raw in capture.read_text().splitlines():
        if not raw.strip():
            continue
        record = json.loads(raw)
        frame = bytes.fromhex(record["sysex_hex"])
        if not frame.startswith(ARTURIA):
            continue
        if record["endpoint"] == HOST_TO_DEVICE and frame[6] in sent:
            if pending is not None:
                lines.append(f"{pending.hex()} {NO_REPLY}")
            pending = frame
        elif record["endpoint"] == DEVICE_TO_HOST and frame[6] in received and pending is not None:
            lines.append(f"{pending.hex()} {frame.hex()}")
            pending = None
    if pending is not None:
        lines.append(f"{pending.hex()} {NO_REPLY}")
    return lines


def main(argv: list[str]) -> int:
    write = bool(argv) and argv[0] == "--write"
    if write:
        argv = argv[1:]
    capture = Path(argv[0]) if argv else CAPTURE
    tape = Path(argv[1]) if len(argv) > 1 else TAPE
    if not capture.is_file():
        print(f"{capture} not found -- pass the path to the capture", file=sys.stderr)
        return 2
    lines = distil(capture, write=write)
    tape.write_text("\n".join(lines) + "\n")
    print(f"wrote {len(lines)} transactions to {tape}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
