"""Distil a gitignored USB capture into a tracked replay fixture.

The captures under ``usb_midi_investigation/`` are 3.5-5.3 MB and gitignored, so
they are absent from every worktree and every fresh clone. This pairs each frame
the host sent with the frame the device sent back and writes only the pair,
which is all the replay tests need, at a size the repository can hold.

Reads a *read* capture by default and a *write* capture under ``--write``, whose
directions are the same frames with the roles swapped: the reply opcodes are
what the host sends, and the device answers with an ack. See spec section 7.

Takes the capture path as an optional argument, defaulting to the main
checkout's copy, so it runs from a worktree without the capture being carried
across.
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

#: The capture's ``direction`` field is unreliable -- the extractor that made
#: the project 2 and 3 captures wrote "inbound" for every row. The USB endpoint
#: is what actually distinguishes them.
HOST_TO_DEVICE = "0x01"
DEVICE_TO_HOST = "0x81"

#: Reply column for a frame the device never answered. The project 3 capture
#: holds one: the truncated 0xFF write that stalled the link (spec section 7.6).
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
