"""USB-MIDI packet framing, against the frames the device actually sent.

No device is needed: framing is pure arithmetic over the tape fixture. What a
green run here does not prove is that the device answers at all -- that is
H1.1 and H1.2, at the hardware.
"""

import pytest

from ksp import sysex
from ksp_cli.usb_transport import deframe, frame_sysex


def test_every_captured_frame_survives_the_round_trip(
    recall_tape: list[tuple[bytes, bytes]],
) -> None:
    """8,951 requests and their replies, including the 64-byte ones."""
    for request, reply in recall_tape:
        assert deframe(frame_sysex(request)) == [request]
        assert deframe(frame_sysex(reply)) == [reply]


@pytest.mark.parametrize("cable", [0, 1, 15])
def test_the_cable_number_rides_in_the_high_nibble(cable: int) -> None:
    frame = bytes.fromhex("f000206b7f4201012578f7")
    packets = frame_sysex(frame, cable=cable)
    assert all(packet >> 4 == cable for packet in packets[::4])
    assert deframe(packets) == [frame]


@pytest.mark.parametrize(
    ("payload", "packets"),
    [
        # 6 bytes: two whole packets, the terminator third in the second.
        (sysex.IDENTITY_REQUEST, "04f07e7f070601f7"),
        # 9 bytes: three whole packets, CIN 0x07 again on the last.
        (sysex.prologue(), "04f00020046b7f42070501f7"),
        # 4 bytes: the terminator lands alone, so the last packet is CIN 0x05.
        (bytes.fromhex("f0000df7"), "04f0000d05f70000"),
    ],
)
def test_the_terminator_picks_the_code_index_number(payload: bytes, packets: str) -> None:
    assert frame_sysex(payload).hex() == packets
    assert deframe(bytes.fromhex(packets)) == [payload]


def test_padding_bytes_never_reach_the_message() -> None:
    """A reply of 9 bytes pads its last packet with two zeros. Reading all three
    regardless is what put a stray 00 between a reply and its ack in the
    investigation log."""
    reply = bytes.fromhex("f000206b7f420201257803f7")
    assert deframe(frame_sysex(reply)) == [reply]
    assert 0x00 not in deframe(frame_sysex(reply))[0][6:]


def test_a_reply_and_its_ack_come_back_as_two_frames() -> None:
    """The device sends the reply then the ack, back to back on the endpoint."""
    reply = bytes.fromhex("f000206b7f420201257803f7")
    assert deframe(frame_sysex(reply) + frame_sysex(sysex.ACK)) == [reply, sysex.ACK]


def test_packets_that_are_not_sysex_are_ignored() -> None:
    """Interface 2 can carry live playing alongside a read. A note-on must not
    be spliced into the middle of a reply."""
    reply = bytes.fromhex("f000206b7f420201257803f7")
    note_on = bytes((0x09, 0x90, 0x3C, 0x64))
    packets = frame_sysex(reply)
    assert deframe(packets[:4] + note_on + packets[4:] + bytes(4)) == [reply]


def test_a_truncated_packet_is_dropped_rather_than_guessed() -> None:
    reply = bytes.fromhex("f000206b7f420201257803f7")
    assert deframe(frame_sysex(reply)[:-1]) == []
