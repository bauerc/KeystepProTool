"""Reading a whole project off the device into the flat dict a file parses to."""

from collections.abc import Iterable, Iterator
from typing import Final, Protocol

from ksp import bulk_fast
from ksp.bulk_plan import iter_requests
from ksp.keys import key
from ksp.lenient_json import LEADING_KEYS
from ksp.sysex import (
    DEFAULT_SLOT,
    UNSET,
    UNSET_IN_FILE,
    ReadRequest,
    build_read_request,
    parse_reply,
    parse_slot,
    prologue,
)

DEVICE_NAME: Final = "KeyStepPro"

#: From the identity reply; nothing in the read protocol itself supplies it.
DEFAULT_VERSION: Final = "2.5.20"

#: Read 0 from hardware but 127 in every corpus file: host-side, so hard-coded.
MCC_CONSTANTS: Final = {"120_55_5": 127, "120_56_4": 127, "120_56_5": 127}

#: What a read returns when the device has no project to give. Well-formed, so
#: nothing in the codec catches it.
FILLER: Final = 0x7F

#: The first address both plans ask for, and the one that tells a filler read
#: from a real one: it never holds the filler byte in any corpus file.
SLOT_PROBE: Final = "120_37"


class Transport(Protocol):
    def exchange(self, request: bytes) -> bytes: ...

    def send(self, frame: bytes) -> None:
        """Write a frame the device does not answer. Only the prologue is one."""


def keys_for(request: ReadRequest) -> list[str]:
    """The flat keys one reply fills, in payload order.
    A long read walks its last index forward by ``count``; the others are fixed."""
    if request.count is None:
        return [key(request.item, request.param)]
    head, last = request.indices[:-1], request.indices[-1]
    return [
        key(request.item, request.param, *head, last + offset) for offset in range(request.count)
    ]


def _fetch(transport: Transport, request: ReadRequest, slot: int) -> tuple[int, ...]:
    frame = transport.exchange(build_read_request(request, slot))
    answered, values = parse_reply(frame)
    if answered != request:
        raise ValueError(f"asked for {request}, device answered {answered}")
    # A reply about another project would merge two of them into one file.
    if parse_slot(frame) != slot:
        raise ValueError(f"asked slot {slot}, device answered slot {parse_slot(frame)}")
    return tuple(UNSET_IN_FILE if value == UNSET else value for value in values)


def _walk(transport: Transport, slot: int) -> Iterator[tuple[str, int]]:
    for request in iter_requests():
        yield from zip(keys_for(request), _fetch(transport, request, slot), strict=True)


def _pool_gate(request: ReadRequest, pool_slot: int) -> list[str]:
    """The existence entries covering ``request``'s note ordinals in that chunk.
    ``pool_slot`` is the note pool's own middle index, not the project slot."""
    assert request.count is not None
    pattern, _, first = request.indices
    return [
        key(request.item, bulk_fast.MELODIC_GATE, pattern, pool_slot, first + offset)
        for offset in range(request.count)
    ]


def _already_answered(request: ReadRequest, seen: dict[str, int]) -> int | None:
    """The value a request would return, when an earlier reply already settles it.
    Two rules, both about the melodic pool and both spec 3."""
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


def _walk_fast(
    transport: Transport, requests: Iterable[ReadRequest], slot: int
) -> Iterator[tuple[str, int]]:
    seen: dict[str, int] = {}
    for request in requests:
        names = keys_for(request)
        settled = _already_answered(request, seen)
        values = (
            (settled,) * len(names) if settled is not None else _fetch(transport, request, slot)
        )
        for name, value in zip(names, values, strict=True):
            seen[name] = value
            yield name, value


def _refuse_filler(pairs: Iterator[tuple[str, int]], slot: int) -> Iterator[tuple[str, int]]:
    """Stop the moment a read comes back as filler rather than a project.
    A whole dump of filler parses as a valid, empty project, so nothing below notices."""
    for name, value in pairs:
        if name == SLOT_PROBE and value == FILLER:
            raise ValueError(
                f"the device answered {SLOT_PROBE} with {FILLER:#04x}, the filler byte, rather "
                f"than a value any project holds: it is not returning slot {slot}'s contents. "
                f"The usual cause is slot {slot} never having been saved on the device."
            )
        yield name, value


def read_raw(
    transport: Transport,
    template_keys: Iterable[str],
    version: str = DEFAULT_VERSION,
    fast: bool = False,
    slot: int = DEFAULT_SLOT,
    requests: Iterable[ReadRequest] | None = None,
) -> dict[str, int | str]:
    """Read one project slot into the dict ``ksp.reader.read_project`` takes.
    ``template_keys`` supplies the full key set; the plan addresses the logical extent only."""
    # The prologue is what selects the slot: a read naming one in byte 7 without
    # it returns whichever project the last prologue named, silently and in full.
    transport.send(prologue(slot))
    walk = (
        _walk(transport, slot)
        if requests is None and not fast
        else _walk_fast(transport, requests or bulk_fast.iter_requests(), slot)
    )
    values: dict[str, int] = dict(_refuse_filler(walk, slot))
    values.update(MCC_CONSTANTS)
    for name in template_keys:
        if name not in LEADING_KEYS:
            values.setdefault(name, 0)

    result: dict[str, int | str] = {"device": DEVICE_NAME, "version": version}
    result.update(values)
    return result
