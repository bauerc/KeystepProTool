"""What the captured tapes prove about the slot byte and the write direction."""

from pathlib import Path

import pytest

from ksp import sysex

SLOT = 7

#: The one address in the corpus whose value is the 0xFF unset sentinel.
SENTINEL_ADDRESS = (123, 117, (1,))


def load_pairs(path: Path) -> list[tuple[bytes, bytes | None]]:
    pairs = []
    for line in path.read_text().splitlines():
        sent, received = line.split()
        pairs.append((bytes.fromhex(sent), None if received == "-" else bytes.fromhex(received)))
    return pairs


@pytest.fixture(scope="session")
def slot_2(fixtures_dir: Path) -> list[tuple[bytes, bytes | None]]:
    return load_pairs(fixtures_dir / "recall_project_2_tape.txt")


@pytest.fixture(scope="session")
def slot_3(fixtures_dir: Path) -> list[tuple[bytes, bytes | None]]:
    return load_pairs(fixtures_dir / "import_project_3_tape.txt")


@pytest.mark.parametrize(
    ("tape", "slot"), [("recall_tape.txt", 1), ("recall_project_2_tape.txt", 2)]
)
def test_a_read_tape_carries_its_slot_in_every_frame(
    fixtures_dir: Path, tape: str, slot: int
) -> None:
    pairs = load_pairs(fixtures_dir / tape)
    assert pairs, tape
    assert {frame[SLOT] for frame, _ in pairs} == {slot}
    assert {reply[SLOT] for _, reply in pairs if reply is not None} == {slot}


def test_the_write_tape_carries_slot_3_and_its_acks_carry_none(
    slot_3: list[tuple[bytes, bytes | None]],
) -> None:
    assert {frame[SLOT] for frame, _ in slot_3} == {3}
    # The ack is not slot-scoped; it is the same four bytes whatever was written.
    assert {ack for _, ack in slot_3 if ack is not None} == {sysex.ACK}
    assert sysex.ACK[SLOT] == 0


def test_the_write_replays_the_read_with_only_the_slot_changed(
    slot_2: list[tuple[bytes, bytes | None]],
    slot_3: list[tuple[bytes, bytes | None]],
) -> None:
    """The two captures are the same project moved from slot 2 to slot 3, so every write is the
    reply it came from with byte 7 rewritten -- which leaves byte 7 as the destination.
    """
    assert len(slot_2) == len(slot_3) == 8951

    def masked(frame: bytes) -> bytes:
        return frame[:SLOT] + b"\x00" + frame[SLOT + 1 :]

    differing = [
        i
        for i, ((_, reply), (write, _)) in enumerate(zip(slot_2, slot_3, strict=True))
        if reply is None or masked(reply) != masked(write)
    ]
    assert differing == [955]


def test_the_sentinel_is_read_but_cannot_be_written(
    slot_2: list[tuple[bytes, bytes | None]],
    slot_3: list[tuple[bytes, bytes | None]],
) -> None:
    """0xFF survives the read (H1.5) and does not survive the write: MCC emits the frame with its
    count intact and the payload byte gone, and the device answers nothing at all.
    """
    _, reply = slot_2[955]
    assert reply is not None
    request, values = sysex.parse_reply(reply)
    assert (request.item, request.param, request.indices) == SENTINEL_ADDRESS
    assert values == (sysex.UNSET,)

    write, ack = slot_3[955]
    assert ack is None, "the device acked every other write in the capture"
    # Same header down to the count of 1, restamped for slot 3, value byte gone.
    restamped = reply[:SLOT] + bytes((3,)) + reply[SLOT + 1 : -1 - len(values)]
    assert write == restamped + bytes((sysex.END,))
    with pytest.raises(ValueError, match="header promised"):
        sysex.parse_reply(write)


def test_the_two_slots_hold_different_projects(
    fixtures_dir: Path, slot_2: list[tuple[bytes, bytes | None]]
) -> None:
    """An identical request stream answered differently -- 971 of 8,951 addresses -- so the reads
    are not both returning one loaded project.
    """
    slot_1 = load_pairs(fixtures_dir / "recall_tape.txt")
    requests = [(a.hex(), b.hex()) for (a, _), (b, _) in zip(slot_1, slot_2, strict=True)]
    assert all(a[:14] + a[16:] == b[:14] + b[16:] for a, b in requests)

    differing = sum(
        1
        for (_, one), (_, two) in zip(slot_1, slot_2, strict=True)
        if one is not None and two is not None and one[8:] != two[8:]
    )
    assert differing == 971
