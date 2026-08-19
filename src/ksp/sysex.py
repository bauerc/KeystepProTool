"""The KeyStep Pro's SysEx read protocol, as frames.

Pure encode and decode: no I/O, no transport, no pyusb. The layout was decoded
from a 26,856-frame capture of MIDI Control Center performing Recall To -- see
docs/superpowers/specs/2026-08-05-usb-sysex-project-read-design.md and spec
section 7. Keeping this free of I/O is what lets the Swift port reuse it
against CoreMIDI.
"""

from dataclasses import dataclass
from typing import Final

HEADER: Final = bytes((0xF0, 0x00, 0x20, 0x6B, 0x7F, 0x42))
END: Final = 0xF7

CMD_SCALAR: Final = 0x01
CMD_SCALAR_REPLY: Final = 0x02
CMD_READ: Final = 0x0B
CMD_READ_REPLY: Final = 0x0C
CMD_ACK: Final = 0x1C

#: Byte 7, following every command byte: the project slot the transfer names
#: (spec 7.4). The ack is the only frame without one. Slot 1 is what every
#: capture but the project 2 recall and the project 3 import carries.
DEFAULT_SLOT: Final = 1

#: A SysEx data byte, so 0-127. Deliberately wider than the device's sixteen
#: slots: H4.1 asks what it does with 0 and with 17, and the codec is not the
#: place to refuse that question.
MAX_SLOT: Final = 0x7F

#: H1.6 measured the ceiling on a long read's count. Above it the device clamps
#: and echoes the count it honoured rather than the one asked for, so an
#: over-long request comes back looking like a reply to a different question --
#: refuse it here instead. MCC never sends above 16. See spec section 7.7.
MAX_READ_COUNT: Final = 100

#: The one frame with no slot in byte 7; its 0x00 is a constant (spec 7.4).
ACK: Final = HEADER + bytes((CMD_ACK, 0x00, END))

#: MCC sends this once before the first read and the device never answers it.
#: H1.4 read a cold device without it and got the same value, so it is MCC's
#: habit and not a handshake: a reader need not send it. Kept because it is
#: part of the recorded exchange and H1.4 is re-run against it.
CMD_PROLOGUE: Final = 0x05

#: Universal (non-Arturia) identity envelope. Not a handshake either -- H1.4
#: read fine without it -- but nothing in the read protocol carries the
#: firmware version, so a byte-identical file still needs this request.
IDENTITY_REQUEST: Final = bytes((0xF0, 0x7E, 0x7F, 0x06, 0x01, END))
_IDENTITY_PREFIX: Final = bytes((0xF0, 0x7E, 0x7F, 0x06, 0x02, 0x00, 0x20, 0x6B))

#: The device's "pattern default pitch unset" sentinel. It is a MIDI System
#: Reset byte, so no conformant host parser passes it through inside a SysEx:
#: MCC loses it and stores the terminator sitting at that offset instead, which
#: is why 247 is the only value above 127 in any project file.
UNSET: Final = 0xFF
UNSET_IN_FILE: Final = 247


@dataclass(frozen=True, slots=True)
class ReadRequest:
    item: int
    param: int
    indices: tuple[int, ...]
    count: int | None  # None is the index-less short form


def prologue(slot: int = DEFAULT_SLOT) -> bytes:
    """The ``05 <slot>`` frame MCC opens a transfer with."""
    _check_slot(slot)
    return HEADER + bytes((CMD_PROLOGUE, slot, END))


def epilogue(slot: int = DEFAULT_SLOT) -> bytes:
    """The ``06 <slot>`` frame MCC closes a write transfer with."""
    _check_slot(slot)
    return HEADER + bytes((0x06, slot, END))


def short_write(slot: int, param: int, item: int, value: int) -> bytes:
    """A short-form single scalar SysEx write message."""
    _check_slot(slot)
    return HEADER + bytes((CMD_SCALAR_REPLY, slot, param, item, value, END))


def long_write(
    slot: int,
    param: int,
    indices: tuple[int, ...],
    item: int,
    count_bytes: bytes,
) -> bytes:
    """A long-form multi-indexed SysEx write message."""
    _check_slot(slot)
    if not 1 <= len(indices) <= 3:
        raise ValueError(f"{len(indices)} indices, expected 1 to 3")
    return (
        HEADER
        + bytes((CMD_READ_REPLY, slot, param, len(indices), item, *indices, len(count_bytes)))
        + count_bytes
        + bytes((END,))
    )


def build_read_request(request: ReadRequest, slot: int = DEFAULT_SLOT) -> bytes:
    """One request frame, addressed at ``slot``.

    The slot rides beside the request rather than inside it: ``bulk_plan`` is
    generated from Arturia's descriptor, which names addresses and not projects,
    and keeping the two apart is what lets ``parse_reply`` compare what came back
    against what was asked for without the slot getting in the way.
    """
    _check_slot(slot)
    body: tuple[int, ...]
    if request.count is None:
        if request.indices:
            raise ValueError("the short form takes no indices")
        body = (CMD_SCALAR, slot, request.param, request.item)
    else:
        if not 1 <= len(request.indices) <= 3:
            raise ValueError(f"{len(request.indices)} indices, expected 1 to 3")
        if not 0 <= request.count <= MAX_READ_COUNT:
            raise ValueError(f"count {request.count}, expected 0 to {MAX_READ_COUNT}")
        body = (
            CMD_READ,
            slot,
            request.param,
            len(request.indices),
            request.item,
            *request.indices,
            request.count,
        )
    return HEADER + bytes(body) + bytes((END,))


def _check_slot(slot: int) -> None:
    if not 0 <= slot <= MAX_SLOT:
        raise ValueError(f"slot {slot}, expected 0 to {MAX_SLOT}")


def parse_slot(frame: bytes) -> int:
    """The project slot a frame names. Not valid for the ack."""
    if len(frame) < 8 or not frame.startswith(HEADER):
        raise ValueError("not a KeyStep Pro SysEx frame")
    return frame[7]


def parse_reply(frame: bytes) -> tuple[ReadRequest, tuple[int, ...]]:
    if not frame.startswith(HEADER) or frame[-1:] != bytes((END,)):
        raise ValueError("not a KeyStep Pro SysEx frame")

    command = frame[6]
    if command == CMD_SCALAR_REPLY:
        values = tuple(frame[10:-1])
        if len(values) != 1:
            raise ValueError(f"scalar reply carried {len(values)} values, expected 1")
        return ReadRequest(item=frame[9], param=frame[8], indices=(), count=None), values

    if command != CMD_READ_REPLY:
        raise ValueError(f"command {command:#04x} is not a read reply")

    n_indices = frame[9]
    count = frame[11 + n_indices]
    request = ReadRequest(
        item=frame[10],
        param=frame[8],
        indices=tuple(frame[11 : 11 + n_indices]),
        count=count,
    )
    values = tuple(frame[12 + n_indices : -1])
    if len(values) != count:
        raise ValueError(f"reply carried {len(values)} values, header promised {count}")
    return request, values


def parse_identity(frame: bytes) -> str:
    """The firmware version out of a universal identity reply.

    Arturia's version field is four bytes and runs backwards: the observed
    ``25 14 05 02`` is build 0x25 then 20.5.2 reversed, i.e. 2.5.20.
    """
    if not frame.startswith(_IDENTITY_PREFIX) or frame[-1:] != bytes((END,)):
        raise ValueError("not a KeyStep Pro identity reply")
    if len(frame) != 17:
        raise ValueError(f"identity reply is {len(frame)} bytes, expected 17")
    return f"{frame[-2]}.{frame[-3]}.{frame[-4]}"
