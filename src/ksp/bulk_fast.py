"""The addresses ``bulk_plan`` lists, in as few requests as the device allows.

``bulk_plan`` reproduces MIDI Control Center's stream byte-for-byte and that
parity is evidence -- it is what the captured tapes are checked against -- so it
does not change. MCC is simply not efficient. It never sends a ``count`` above
16 although the device honours 100 (spec 7.7), and it reads note-pool chunks the
existence array has already reported empty.

This module derives the efficient walk from the same ``PLAN``. It changes which
frames go on the wire, never which addresses are covered: ``iter_requests`` here
fills exactly the keys ``bulk_plan.iter_requests`` does. 8,951 requests become
2,044, and the gate ``bulk_read`` applies to them takes a real project to about
1,000 -- some 36 s to 4 s at the measured 4.047 ms per request.

This module is hand-written; ``bulk_plan`` is generated and would lose it.
"""

from collections.abc import Iterable, Iterator
from itertools import product
from typing import Final

from ksp.bulk_plan import IDX, PLAN, Leaf
from ksp.sysex import MAX_READ_COUNT, ReadRequest

#: Marks an empty note-pool entry. Also a legal pitch and velocity, which is why
#: only paramId 50 (or 54) may be read as existence -- see spec section 3.
EMPTY: Final = 127

#: The melodic existence array, and the per-note parameters it gates. Entry n of
#: each is the same note ordinal, so an all-EMPTY chunk of 50 means every one of
#: these reads EMPTY. Both device tapes agree without exception: 59,415 and
#: 61,120 such values, all 127.
MELODIC_GATE: Final = 50
MELODIC_GATED: Final = frozenset({109, 110, 111, 112, 113})

#: The drum pair (54 gating 117-121) is deliberately absent. Dead drum entries
#: read 127 in some patterns and the default row 60/7/100/49/100 in others,
#: within one project -- the drum array is a pool with holes, so a dead entry
#: keeps whatever was there. Nothing derives them; they must be fetched.

#: Requests this plan expands to, against bulk_plan's 8,951.
REQUEST_COUNT: Final = 2044


def iter_requests(max_count: int = MAX_READ_COUNT) -> Iterator[ReadRequest]:
    """Every address bulk_plan reads, coalesced into the fewest requests.

    Runs are gathered over a whole PLAN group, not one index of it. MCC's
    per-pattern scalars each walk the group index itself -- sixteen count-1 reads
    of 122_90 are one 16-entry range -- and only a group-wide view sees that.

    Ordering follows MCC's, with one departure: the existence array is emitted
    before the parameters it gates, which MCC's leaf order puts it after. Reads
    are addressed and idempotent, so order is free.
    """
    for low, high, leaves in PLAN:
        requests = (request for index in range(low, high + 1) for request in _expand(index, leaves))
        yield from _coalesce(requests, max_count)


def _expand(index: int, leaves: Iterable[Leaf]) -> Iterator[ReadRequest]:
    """One group index of PLAN, in bulk_plan's order."""
    for item, params, dims, count in leaves:
        if count is None:
            for param in params:
                yield ReadRequest(item=item, param=param, indices=(), count=None)
            continue
        resolved = [tuple(index if v == IDX else v for v in dim) for dim in dims]
        for param in params:
            for combination in product(*resolved):
                yield ReadRequest(item=item, param=param, indices=combination, count=count)


def _coalesce(requests: Iterable[ReadRequest], max_count: int) -> Iterator[ReadRequest]:
    """Join each run over the walking index into requests of up to max_count.

    A run is one ``(item, param, fixed indices)``; only the last index walks. The
    first request of a run holds its place in the emission order.
    """
    runs: dict[tuple[int, int, tuple[int, ...]], list[ReadRequest]] = {}
    order: list[list[ReadRequest]] = []
    for request in requests:
        if request.count is None:
            order.append([request])
            continue
        run_key = (request.item, request.param, request.indices[:-1])
        run = runs.get(run_key)
        if run is None:
            run = runs[run_key] = []
            order.append(run)
        run.append(request)

    for run in _gate_first(order):
        yield from _join(run, max_count)


def _gate_first(order: list[list[ReadRequest]]) -> Iterator[list[ReadRequest]]:
    """The existence array ahead of the notes it gates, order otherwise kept."""
    gate = [run for run in order if run[0].param == MELODIC_GATE]
    yield from gate
    yield from (run for run in order if run[0].param != MELODIC_GATE)


def _join(run: list[ReadRequest], max_count: int) -> Iterator[ReadRequest]:
    first = run[0]
    if first.count is None:
        yield first
        return

    # By index, not by the order MCC asked in: it reads 121_83's fifth scene
    # ahead of the other four, and a run is a range whatever order it arrived.
    ordered = sorted(run, key=lambda request: request.indices[-1])
    start = ordered[0].indices[-1]
    total = 0
    for request in ordered:
        assert request.count is not None
        if request.indices[-1] != start + total:
            raise ValueError(
                f"{first.item}_{first.param} run breaks at index {request.indices[-1]}, "
                f"expected {start + total}"
            )
        total += request.count

    head = ordered[0].indices[:-1]
    for offset in range(0, total, max_count):
        yield ReadRequest(
            item=first.item,
            param=first.param,
            indices=(*head, start + offset),
            count=min(max_count, total - offset),
        )
