"""Regenerate tests/fixtures/bulk_read_walk.txt, the gated walk both cores are held to.

The plan fixture pins what may be asked; this one pins what the gate leaves unasked over
the recall tape, which no count agreement can establish. Run it after either changes, then
the tests: test_bulk_fast holds the Python walk to this file and BulkReadTests the Swift.
"""

import sys
from pathlib import Path

from ksp import bulk_read
from ksp.sysex import ReadRequest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))

from gen_bulk_fast_fixture import line  # noqa: E402

from conftest import DeviceModel, tape_values  # noqa: E402

TAPE = ROOT / "tests/fixtures/recall_tape.txt"
TARGET = ROOT / "tests/fixtures/bulk_read_walk.txt"


def asked() -> list[ReadRequest]:
    """The requests the gated walk puts on the wire, replaying the tape."""
    device = DeviceModel(tape_values(TAPE))
    bulk_read.read_raw(device, [], fast=True)
    return device.asked


def render() -> str:
    return "".join(line(request) + "\n" for request in asked())


if __name__ == "__main__":
    TARGET.write_text(render())
    print(f"wrote {TARGET}")
