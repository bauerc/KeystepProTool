"""Reading a whole project off the device, one address at a time.

The transport is injected: this module never imports pyusb and never opens a
port, so the read path is testable against a captured exchange and the Swift port
Swift port can hand it CoreMIDI instead. What comes out is the same flat dict
lenient_json produces from a file, so ksp.reader and the whole export path are
unchanged -- the hardware is simply a second producer of it.

Walking MCC's plan is 8,951 requests at a median 4.047 ms each, about 36
seconds. ``fast=True`` walks ``ksp.bulk_fast`` instead and skips what the
existence array has already answered, which is about 1,000 requests and four
seconds for the same keys. See ``read_raw``.
"""

from collections.abc import Iterable, Iterator
from typing import Final, Protocol

from ksp import bulk_fast
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


def _fetch(transport: Transport, request: ReadRequest) -> tuple[int, ...]:
    answered, values = parse_reply(transport.exchange(build_read_request(request)))
    if answered != request:
        raise ValueError(f"asked for {request}, device answered {answered}")
    return tuple(UNSET_IN_FILE if value == UNSET else value for value in values)


def _walk(transport: Transport) -> Iterator[tuple[str, int]]:
    for request in iter_requests():
        yield from zip(keys_for(request), _fetch(transport, request), strict=True)


def _pool_gate(request: ReadRequest, slot: int) -> list[str]:
    """The existence entries covering ``request``'s note ordinals in ``slot``."""
    assert request.count is not None
    pattern, _, first = request.indices
    return [
        key(request.item, bulk_fast.MELODIC_GATE, pattern, slot, first + offset)
        for offset in range(request.count)
    ]


def _already_answered(request: ReadRequest, seen: dict[str, int]) -> int | None:
    """The value a request would return, when an earlier reply already settles it.

    Two rules, both about the melodic pool and both spec section 3. A per-note
    parameter of an entry whose ``50`` is 127 is itself 127. And notes reach a
    chunk only once the chunk before it is full, so a sentinel in the previous
    chunk proves this one empty -- which is what lets the existence array skip
    its own later chunks.
    """
    if request.count is None or len(request.indices) != 3:
        return None
    if request.param in bulk_fast.MELODIC_GATED:
        gate = _pool_gate(request, request.indices[1])
        return bulk_fast.EMPTY if all(seen.get(n) == bulk_fast.EMPTY for n in gate) else None
    if request.param == bulk_fast.MELODIC_GATE and request.indices[1] > 1:
        previous = _pool_gate(request, request.indices[1] - 1)
        if any(seen.get(n) == bulk_fast.EMPTY for n in previous):
            return bulk_fast.EMPTY
    return None


def _walk_fast(transport: Transport) -> Iterator[tuple[str, int]]:
    seen: dict[str, int] = {}
    for request in bulk_fast.iter_requests():
        names = keys_for(request)
        settled = _already_answered(request, seen)
        values = (settled,) * len(names) if settled is not None else _fetch(transport, request)
        for name, value in zip(names, values, strict=True):
            seen[name] = value
            yield name, value


def read_raw(
    transport: Transport,
    template_keys: Iterable[str],
    version: str = DEFAULT_VERSION,
    fast: bool = False,
) -> dict[str, int | str]:
    """Read the loaded project into the dict ``ksp.reader.read_project`` takes.

    ``template_keys`` supplies the file's full key set -- the plan addresses the
    logical extent only, and the 35,712 keys it never asks for hold 0 in every
    corpus file.

    ``fast`` fills the identical keys off ``ksp.bulk_fast`` in a ninth of the
    requests. It is off by default because MCC's stream is the one the captured
    tapes pin down; the replay tests hold both walks to the same result.

    The address tuple carries no project slot, so this reads whichever project
    is currently loaded. Every caller must say so.
    """
    values: dict[str, int] = dict(_walk_fast(transport) if fast else _walk(transport))
    values.update(MCC_CONSTANTS)
    for name in template_keys:
        if name not in LEADING_KEYS:
            values.setdefault(name, 0)

    result: dict[str, int | str] = {"device": DEVICE_NAME, "version": version}
    result.update(values)
    return result
