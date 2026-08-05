"""Distil the gitignored Recall capture into a tracked replay fixture.

``usb_midi_investigation/recall_sysex.jsonl`` is 5.3 MB and gitignored, so it is
absent from every worktree and every fresh clone. This pairs each request with
its reply and writes only the pair, which is all the replay tests need, at a
size the repository can hold.

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


def distil(capture: Path) -> list[str]:
    """Pair each request with the reply that followed it. Traffic is strictly
    serialised -- request, reply, ack -- so a single pending slot is enough."""
    lines: list[str] = []
    pending: bytes | None = None
    for raw in capture.read_text().splitlines():
        if not raw.strip():
            continue
        record = json.loads(raw)
        frame = bytes.fromhex(record["sysex_hex"])
        if not frame.startswith(ARTURIA):
            continue
        if record["direction"] == "outbound" and frame[6] in REQUESTS:
            pending = frame
        elif record["direction"] == "inbound" and frame[6] in REPLIES and pending is not None:
            lines.append(f"{pending.hex()} {frame.hex()}")
            pending = None
    return lines


def main(argv: list[str]) -> int:
    capture = Path(argv[0]) if argv else CAPTURE
    if not capture.is_file():
        print(f"{capture} not found -- pass the path to the capture", file=sys.stderr)
        return 2
    lines = distil(capture)
    TAPE.write_text("\n".join(lines) + "\n")
    print(f"wrote {len(lines)} transactions to {TAPE}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
