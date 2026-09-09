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

#: Each gate reads before what it settles: the data state settles whole patterns, so it
#: comes before the existence array, which settles pool chunks. Everything else follows.
GATE_RANK: Final = {DATA_STATE: 0, MELODIC_GATE: 1}

#: What each address holds in a pattern the data state says is empty, keyed by parameter
#: and how many indices it takes -- the arity is what separates the control track's step
#: arrays from the note pools, and no parameter settles at two arities. The per-pattern
#: scalars are absent: those are settings, editable on a pattern that holds no note at all.
#: 96 is the skip mask's "all four sequences".
DATA_STATE_GATED: Final = {
    (90, 2): 0,
    (91, 2): 0,
    (92, 2): 0,
    (93, 2): 0,
    (94, 2): 0,
    (95, 2): 0,
    (96, 2): 15,
    (50, 3): EMPTY,
    (54, 3): EMPTY,
    (109, 3): EMPTY,
    (110, 3): EMPTY,
    (111, 3): EMPTY,
    (112, 3): EMPTY,
    (113, 3): EMPTY,
    (117, 3): 60,
    (118, 3): 7,
    (119, 3): 100,
    (120, 3): 49,
    (121, 3): 100,
}

#: Pool arrays no per-chunk gate settles, so walking across their chunks costs nothing.
#: The melodic pool is absent deliberately: its existence array skips empty chunks
#: outright, and a request coalesced across them would fetch what the gate had dropped.
#: A walk passing a chunk rolls into the next one, and stops at the outer index (spec 7.8).
ROLLED_OVER: Final = frozenset({53, 54, 117, 118, 119, 120, 121})


def rolled(request: ReadRequest) -> bool:
    """Whether this request addresses a pool the device walks across its chunks."""
    return request.param in ROLLED_OVER and len(request.indices) == 3


def flat(indices: tuple[int, ...]) -> int:
    """A pool address as one 1-based position across the chunks of its outer index."""
    _, middle, last = indices
    return (middle - 1) * constants.MAX_STEPS + last


def unflat(outer: int, position: int) -> tuple[int, int, int]:
    """The inverse of ``flat``: a position back to ``(outer, middle, last)``."""
    middle, last = divmod(position - 1, constants.MAX_STEPS)
    return outer, middle + 1, last + 1


def data_state_fill(request: ReadRequest) -> int | None:
    """What this address holds in a pattern parameter 40 says is empty, or ``None``
    where parameter 40 settles nothing for it."""
    fill = DATA_STATE_GATED.get((request.param, len(request.indices)))
    if fill is None or len(request.indices) != 3:
        return fill
    # Track 1's phantom fourth chunk is zero-filled where the live chunks hold the default (spec 4).
    return 0 if request.indices[1] > constants.POOL_SLOTS else fill


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
        head = request.indices[:1] if rolled(request) else request.indices[:-1]
        run_key = (request.item, request.param, head)
        run = runs.get(run_key)
        if run is None:
            run = runs[run_key] = []
            order.append(run)
        run.append(request)

    for run in _gate_first(order):
        yield from _join(run, max_count)


def _gate_first(order: list[list[ReadRequest]]) -> Iterator[list[ReadRequest]]:
    """Each gate ahead of what it settles, order otherwise kept -- a stable sort, so the
    runs sharing a rank keep the order MCC asked in."""
    yield from sorted(order, key=lambda run: GATE_RANK.get(run[0].param, len(GATE_RANK)))


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

    # A rolled-over pool counts across its chunks; every other run walks its last index.
    # Both are constant across a run, which is what the run key was built from.
    is_rolled = rolled(first)
    outer, head = first.indices[0], first.indices[:-1]

    def position(indices: tuple[int, ...]) -> int:
        return flat(indices) if is_rolled else indices[-1]

    def rebuild(at: int) -> tuple[int, ...]:
        return unflat(outer, at) if is_rolled else (*head, at)

    # By index, not by the order MCC asked in: it reads 121_83's fifth scene
    # ahead of the other four, and a run is a range whatever order it arrived.
    ordered = sorted(run, key=lambda request: position(request.indices))
    start = position(ordered[0].indices)
    total = 0
    for request in ordered:
        assert request.count is not None
        if position(request.indices) != start + total:
            raise ValueError(
                f"{first.item}_{first.param} run breaks at position "
                f"{position(request.indices)}, expected {start + total}"
            )
        total += request.count

    for offset in range(0, total, max_count):
        yield ReadRequest(
            item=first.item,
            param=first.param,
            indices=rebuild(start + offset),
            count=min(max_count, total - offset),
        )
