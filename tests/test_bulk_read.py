"""Reading a project off the wire, replayed from a captured exchange.

The tape distils MCC's Recall To against the device, so these tests run against
the hardware's own bytes without the hardware. Green here is still not verified
on hardware -- see ROADMAP.md.
"""

from pathlib import Path

TRANSACTIONS = 8951

FIRST_REQUEST = "f000206b7f4201012578f7"
FIRST_REPLY = "f000206b7f420201257803f7"


def test_the_tape_holds_every_captured_transaction(fixtures_dir: Path) -> None:
    """A short tape means a truncated capture, and every downstream count is
    then wrong in a way the reconstruction test would report as a diff."""
    lines = (fixtures_dir / "recall_tape.txt").read_text().splitlines()
    assert len(lines) == TRANSACTIONS
    assert all(len(line.split()) == 2 for line in lines)
    assert lines[0].split() == [FIRST_REQUEST, FIRST_REPLY]
