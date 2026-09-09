"""The addresses ``bulk_plan`` lists, in as few requests as the device allows (spec 7.8)."""

from collections.abc import Iterable, Iterator
from itertools import product
from typing import Final

from ksp import constants
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

#: The firmware's own per-pattern flag, and the value meaning the pattern holds notes.
#: It latches upward and never back down, so only "not 3" settles anything (spec 3.3).
DATA_STATE: Final = 40
HAS_DATA: Final = 3

#: Note-indexed pool arrays an unflagged pattern settles, and the row each holds there.
#: The step-indexed and per-pattern scalars are absent: those are settings, editable
#: on a pattern that holds no note at all.
PATTERN_GATED: Final = {
    50: EMPTY,
    54: EMPTY,
    109: EMPTY,
    110: EMPTY,
    111: EMPTY,
    112: EMPTY,
    113: EMPTY,
    117: 60,
    118: 7,
    119: 100,
    120: 49,
    121: 100,
}

#: Pool arrays no per-chunk gate settles, so walking across their chunks costs nothing.
#: The melodic pool is absent deliberately: its existence array skips empty chunks
#: outright, and a request coalesced across them would fetch what the gate had dropped.
ROLLED_OVER: Final = frozenset({53, 54, 117, 118, 119, 120, 121})

#: Entries per middle index in a pool. A walk passing this rolls into the next chunk,
#: and stops at the outer index (spec 7.8).
POOL_CHUNK: Final = constants.MAX_STEPS


def flat(indices: tuple[int, ...]) -> int:
    """A pool address as one 1-based position across the chunks of its outer index."""
    _, middle, last = indices
    return (middle - 1) * POOL_CHUNK + last


def unflat(outer: int, position: int) -> tuple[int, int, int]:
    """The inverse of ``flat``: a position back to ``(outer, middle, last)``."""
    middle, last = divmod(position - 1, POOL_CHUNK)
    return outer, middle + 1, last + 1


def rolls_over(request: ReadRequest) -> bool:
    """Whether this request's walk carries past the end of its own chunk."""
    return (
        request.count is not None
        and len(request.indices) == 3
        and request.indices[-1] + request.count - 1 > POOL_CHUNK
    )


#: Track 1's phantom fourth chunk is zero-filled where the live chunks hold the default (spec 4).
PHANTOM_FILL: Final = 0


def pattern_fill(param: int, slot: int) -> int:
    """What a pooled parameter holds in a pattern parameter 40 says is empty."""
    return PHANTOM_FILL if slot > constants.POOL_SLOTS else PATTERN_GATED[param]


#: Requests this plan expands to, against bulk_plan's 8,951.
REQUEST_COUNT: Final = 3399

#: What one pattern of one track costs: 75 pattern reads plus the index-less scalars.
PATTERN_REQUEST_COUNT: Final = 108


def iter_requests(max_count: int = MAX_READ_COUNT) -> Iterator[ReadRequest]:
    """Every address bulk_plan reads, in as few requests as the device allows.
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
    """Whether a request fills any key belonging to ``pattern``."""
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
        # A rolled-over param keys on the outer index alone, so its chunks join one run.
        head = (
            request.indices[:1]
            if request.param in ROLLED_OVER and len(request.indices) == 3
            else request.indices[:-1]
        )
        run_key = (request.item, request.param, head)
        run = runs.get(run_key)
        if run is None:
            run = runs[run_key] = []
            order.append(run)
        run.append(request)

    for run in _gate_first(order):
        yield from _join(run, max_count)


def _gate_first(order: list[list[ReadRequest]]) -> Iterator[list[ReadRequest]]:
    """Each gate ahead of what it settles, order otherwise kept: the data state settles whole
    patterns, so it comes before the existence array, which settles pool chunks."""
    ranked = {DATA_STATE: 0, MELODIC_GATE: 1}
    for rank in (0, 1):
        yield from (run for run in order if ranked.get(run[0].param) == rank)
    yield from (run for run in order if run[0].param not in ranked)


def _join(run: list[ReadRequest], max_count: int) -> Iterator[ReadRequest]:
    first = run[0]
    if first.count is None:
        yield first
        return

    # A lone index is not a range axis: the device answers a walk over one with index 1's
    # value repeated, so the per-pattern scalars stay one request each (spec 7.8).
    if len(first.indices) == 1:
        yield from sorted(run, key=lambda request: request.indices[-1])
        return

    if first.param in ROLLED_OVER and len(first.indices) == 3:
        yield from _join_rolled(run, max_count)
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


def _join_rolled(run: list[ReadRequest], max_count: int) -> Iterator[ReadRequest]:
    """Join a run whose chunks the device walks through, flattening the middle index."""
    ordered = sorted(run, key=lambda request: flat(request.indices))
    outer = ordered[0].indices[0]
    start = flat(ordered[0].indices)
    total = 0
    for request in ordered:
        assert request.count is not None
        if flat(request.indices) != start + total:
            raise ValueError(
                f"{request.item}_{request.param} run breaks at {request.indices}, "
                f"expected position {start + total}"
            )
        total += request.count

    for offset in range(0, total, max_count):
        yield ReadRequest(
            item=ordered[0].item,
            param=ordered[0].param,
            indices=unflat(outer, start + offset),
            count=min(max_count, total - offset),
        )
