"""The read protocol's frame codec, against bytes the device actually sent."""

import pytest

from ksp import sysex


def test_a_scalar_request_is_the_short_form() -> None:
    """Frame 13 of the capture: paramId 37, itemId 120, no indices."""
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
    """Build a request, dress it as the reply the device would send, parse it back to the request we
    started from.
    """
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
    """The count byte is a promise."""
    frame = bytes.fromhex("f000206b7f420c0130037b0101111001020304f7")
    with pytest.raises(ValueError, match="16"):
        sysex.parse_reply(frame)


def test_the_short_form_refuses_indices() -> None:
    with pytest.raises(ValueError, match="short form"):
        sysex.build_read_request(sysex.ReadRequest(item=120, param=37, indices=(1,), count=None))


def test_byte_7_carries_the_slot_in_the_short_form() -> None:
    """The same frame as the capture's 13, addressed at slot 2 instead."""
    request = sysex.ReadRequest(item=120, param=37, indices=(), count=None)
    assert sysex.build_read_request(request, slot=2).hex() == "f000206b7f4201022578f7"


def test_byte_7_carries_the_slot_in_the_long_form() -> None:
    request = sysex.ReadRequest(item=123, param=48, indices=(1, 1, 17), count=16)
    assert sysex.build_read_request(request, slot=2).hex() == "f000206b7f420b0230037b01011110f7"


def test_the_slot_defaults_to_one() -> None:
    """Every capture but the project 2 recall and the project 3 import sends 1."""
    request = sysex.ReadRequest(item=120, param=37, indices=(), count=None)
    assert sysex.build_read_request(request) == sysex.build_read_request(request, slot=1)
    assert sysex.DEFAULT_SLOT == 1


@pytest.mark.parametrize("slot", [0, 17, 127])
def test_a_slot_outside_the_sixteen_still_builds(slot: int) -> None:
    """H4.1 asks the device what it does with 0 and with 17, so the codec must not be the thing that
    refuses them.
    """
    request = sysex.ReadRequest(item=120, param=37, indices=(), count=None)
    assert sysex.build_read_request(request, slot=slot)[7] == slot


@pytest.mark.parametrize("slot", [-1, 128])
def test_a_slot_outside_seven_bits_is_refused(slot: int) -> None:
    request = sysex.ReadRequest(item=120, param=37, indices=(), count=None)
    with pytest.raises(ValueError, match="slot"):
        sysex.build_read_request(request, slot=slot)


def test_the_slot_comes_back_off_a_reply() -> None:
    assert sysex.parse_slot(bytes.fromhex("f000206b7f420201257803f7")) == 1
    assert sysex.parse_slot(bytes.fromhex("f000206b7f420202257803f7")) == 2


def test_a_frame_that_is_too_short_has_no_slot() -> None:
    with pytest.raises(ValueError):
        sysex.parse_slot(bytes.fromhex("f000206b7f42"))


def test_the_prologue_names_its_slot() -> None:
    """Spec 7.5: ``05 <slot>`` is the first frame of a read."""
    assert sysex.prologue().hex() == "f000206b7f420501f7"
    assert sysex.prologue(2).hex() == "f000206b7f420502f7"


def test_the_identity_reply_gives_the_firmware_version(identity_reply: bytes) -> None:
    """Frame 9 of the capture."""
    assert sysex.parse_identity(identity_reply) == "2.5.20"


@pytest.mark.parametrize(
    "frame",
    [
        "f000206b7f420201257803f7",  # a read reply, not an identity one
        "f07e7f060200206b0200090025140502",  # no terminator
        "f07e7f06020001610200090025140502f7",  # a different manufacturer
        "f07e7f060200206b02000900251405f7",  # a byte short
    ],
)
def test_a_frame_that_is_not_an_identity_reply_is_refused(frame: str) -> None:
    with pytest.raises(ValueError):
        sysex.parse_identity(bytes.fromhex(frame))
