"""Reading a whole project off the device, one address at a time.

The transport is injected: this module never imports pyusb and never opens a
port, so the read path is testable against a captured exchange and the M8-M9
Swift port can hand it CoreMIDI instead. What comes out is the same flat dict
lenient_json produces from a file, so ksp.reader and the whole export path are
unchanged -- the hardware is simply a second producer of it.

A full read is 8,951 requests at a median 4.047 ms each, about 36 seconds.
"""

from collections.abc import Iterable, Iterator
from typing import Final, Protocol

from ksp.bulk_plan import iter_requests
from ksp.keys import key
from ksp.lenient_json import LEADING_KEYS
from ksp.sysex import UNSET, UNSET_IN_FILE, ReadRequest, build_read_request, parse_reply

DEVICE_NAME: Final = "KeyStepPro"

#: From the universal identity reply's trailing bytes. Nothing in the read
#: protocol supplies it, and a user-saved project always has it.
DEFAULT_VERSION: Final = "2.5.20"

#: Read 0 from hardware but 127 in all six corpus files, including the factory
#: default, which never came off a device. Host-side, so hard-coded.
MCC_CONSTANTS: Final = {"120_55_5": 127, "120_56_4": 127, "120_56_5": 127}


class Transport(Protocol):
    def exchange(self, request: bytes) -> bytes: ...


def keys_for(request: ReadRequest) -> list[str]:
    """The flat keys one reply fills, in payload order.

    A long read walks its last index forward by ``count``; the others are fixed.
    """
    if request.count is None:
        return [key(request.item, request.param)]
    head, last = request.indices[:-1], request.indices[-1]
    return [
        key(request.item, request.param, *head, last + offset) for offset in range(request.count)
    ]


def _walk(transport: Transport) -> Iterator[tuple[str, int]]:
    for request in iter_requests():
        answered, values = parse_reply(transport.exchange(build_read_request(request)))
        if answered != request:
            raise ValueError(f"asked for {request}, device answered {answered}")
        for name, value in zip(keys_for(request), values, strict=True):
            yield name, UNSET_IN_FILE if value == UNSET else value


def read_raw(
    transport: Transport,
    template_keys: Iterable[str],
    version: str = DEFAULT_VERSION,
) -> dict[str, int | str]:
    """Read the loaded project into the dict ``ksp.reader.read_project`` takes.

    ``template_keys`` supplies the file's full key set -- the plan addresses the
    logical extent only, and the 35,712 keys it never asks for hold 0 in every
    corpus file.

    The address tuple carries no project slot, so this reads whichever project
    is currently loaded. Every caller must say so.
    """
    values: dict[str, int] = dict(_walk(transport))
    values.update(MCC_CONSTANTS)
    for name in template_keys:
        if name not in LEADING_KEYS:
            values.setdefault(name, 0)

    result: dict[str, int | str] = {"device": DEVICE_NAME, "version": version}
    result.update(values)
    return result
