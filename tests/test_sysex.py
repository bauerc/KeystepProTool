"""The read protocol's frame codec, against bytes the device actually sent.

Every frame quoted here appears in usb_midi_investigation/recall_sysex.jsonl and
in the tape fixture. See spec section 7.
"""

import pytest

from ksp import sysex


def test_a_scalar_request_is_the_short_form() -> None:
    """Frame 13 of the capture: paramId 37, itemId 120, no indices. The earlier
    investigation note filed it under setup calls; it is the first real read in
    the plan."""
    request = sysex.ReadRequest(item=120, param=37, indices=(), count=None)
    assert sysex.build_read_request(request).hex() == "f000206b7f4201012578f7"


def test_a_three_index_request_carries_its_count() -> None:
    """48 for track 1, pattern 1, slot 1, steps 17-32."""
    request = sysex.ReadRequest(item=123, param=48, indices=(1, 1, 17), count=16)
    assert sysex.build_read_request(request).hex() == "f000206b7f420b0130037b01011110f7"


def test_a_scalar_reply_yields_one_value() -> None:
    request, values = sysex.parse_reply(bytes.fromhex("f000206b7f420201257803f7"))
    assert request == sysex.ReadRequest(item=120, param=37, indices=(), count=None)
    assert values == (3,)


def test_a_long_reply_yields_exactly_count_values() -> None:
    frame = bytes.fromhex("f000206b7f420c01540379010501107f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7ff7")
    request, values = sysex.parse_reply(frame)
    assert request == sysex.ReadRequest(item=121, param=84, indices=(1, 5, 1), count=16)
    assert values == (127,) * 16


def test_the_round_trip_is_exact() -> None:
    """Build a request, dress it as the reply the device would send, parse it
    back to the request we started from."""
    request = sysex.ReadRequest(item=126, param=50, indices=(16, 3, 49), count=16)
    frame = sysex.build_read_request(request)
    reply = frame[:6] + bytes((sysex.CMD_READ_REPLY,)) + frame[7:-1] + bytes(16) + b"\xf7"
    assert sysex.parse_reply(reply)[0] == request


@pytest.mark.parametrize(
    "frame",
    [
        "f07e7f0601f7",  # universal identity, not our envelope
        "f000206b7f421c00f7",  # the ack, not a reply
        "f000206b7f420c01540379010501107f",  # truncated, no terminator
    ],
)
def test_a_frame_that_is_not_a_reply_is_refused(frame: str) -> None:
    with pytest.raises(ValueError):
        sysex.parse_reply(bytes.fromhex(frame))


def test_a_reply_that_underdelivers_is_refused() -> None:
    """The count byte is a promise. Silently accepting four values where the
    header said sixteen would shift every later key by twelve."""
    frame = bytes.fromhex("f000206b7f420c0130037b0101111001020304f7")
    with pytest.raises(ValueError, match="16"):
        sysex.parse_reply(frame)


def test_the_short_form_refuses_indices() -> None:
    with pytest.raises(ValueError, match="short form"):
        sysex.build_read_request(sysex.ReadRequest(item=120, param=37, indices=(1,), count=None))
