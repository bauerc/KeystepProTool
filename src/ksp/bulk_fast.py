"""The addresses ``bulk_plan`` lists, in as few requests as the device allows (spec 7.8)."""

from collections.abc import Iterable, Iterator
from itertools import product
from typing import Final

from ksp.bulk_plan import IDX, PLAN, Leaf
from ksp.sysex import MAX_READ_COUNT, ReadRequest

#: Marks an empty note-pool entry. Also a legal pitch and velocity, which is why
#: only paramId 50 (or 54) may be read as existence (spec 3).
EMPTY: Final = 127

#: The melodic existence array, and the per-note parameters it gates. Entry n of
#: each is the same note ordinal, so an all-EMPTY chunk of 50 settles all of them.
MELODIC_GATE: Final = 50
MELODIC_GATED: Final = frozenset({109, 110, 111, 112, 113})

#: The drum pair (54 gating 117-121) is deliberately absent: the drum array is a
#: pool with holes, so a dead entry keeps whatever was there and cannot be derived.

#: Requests this plan expands to, against bulk_plan's 8,951.
REQUEST_COUNT: Final = 2044

#: What one pattern of one track costs: 75 pattern reads plus the index-less scalars.
PATTERN_REQUEST_COUNT: Final = 115


def iter_requests(max_count: int = MAX_READ_COUNT) -> Iterator[ReadRequest]:
    """Every address bulk_plan reads, coalesced into the fewest requests.
    MCC's order, but with the existence array ahead of the parameters it gates."""
    for low, high, leaves in PLAN:
        requests = (request for index in range(low, high + 1) for request in _expand(index, leaves))
        yield from _coalesce(requests, max_count)


def iter_pattern_requests(item: int, pattern: int) -> Iterator[ReadRequest]:
    """The requests covering one pattern of one track, in ``iter_requests``' order.
    The index-less scalars come too: tempo carries no pattern index."""
    for request in iter_requests():
        if request.count is None or (request.item == item and _covers(request, pattern)):
            yield request


def _covers(request: ReadRequest, pattern: int) -> bool:
    """Whether a request fills any key belonging to ``pattern``. Not simply
    ``indices[0] == pattern``: a coalesced per-pattern scalar is one range at index 1."""
    assert request.count is not None
    if len(request.indices) == 1:
        return request.indices[0] <= pattern < request.indices[0] + request.count
    return request.indices[0] == pattern


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
    A run is one ``(item, param, fixed indices)``; only the last index walks."""
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
