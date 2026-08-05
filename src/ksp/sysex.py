"""The KeyStep Pro's SysEx read protocol, as frames.

Pure encode and decode: no I/O, no transport, no pyusb. The layout was decoded
from a 26,856-frame capture of MIDI Control Center performing Recall To -- see
docs/superpowers/specs/2026-08-05-usb-sysex-project-read-design.md and spec
section 7. Keeping this free of I/O is what lets the M8-M9 Swift port reuse it
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

#: Follows every command byte in a request. Its meaning is untested.
SUBCOMMAND: Final = 0x01

ACK: Final = HEADER + bytes((CMD_ACK, 0x00, END))

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


def build_read_request(request: ReadRequest) -> bytes:
    body: tuple[int, ...]
    if request.count is None:
        if request.indices:
            raise ValueError("the short form takes no indices")
        body = (CMD_SCALAR, SUBCOMMAND, request.param, request.item)
    else:
        if not 1 <= len(request.indices) <= 3:
            raise ValueError(f"{len(request.indices)} indices, expected 1 to 3")
        body = (
            CMD_READ,
            SUBCOMMAND,
            request.param,
            len(request.indices),
            request.item,
            *request.indices,
            request.count,
        )
    return HEADER + bytes(body) + bytes((END,))


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
