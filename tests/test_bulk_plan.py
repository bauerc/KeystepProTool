"""The generated read plan against the request stream MCC actually sent.

``bulk_plan.PLAN`` is transcribed from Arturia's own ``bulkOperation``
descriptor, so what is worth testing is that walking it reproduces MCC's 8,951
requests byte-for-byte and in order. A regeneration that changes behaviour
fails here rather than on the device.
"""

from pathlib import Path

from ksp import bulk_plan, sysex


def tape_requests(fixtures_dir: Path) -> list[str]:
    lines = (fixtures_dir / "recall_tape.txt").read_text().splitlines()
    return [line.split()[0] for line in lines]


def test_the_plan_reproduces_every_captured_request(fixtures_dir: Path) -> None:
    generated = [sysex.build_read_request(r).hex() for r in bulk_plan.iter_requests()]
    assert generated == tape_requests(fixtures_dir)


def test_the_plan_declares_its_own_length() -> None:
    assert len(list(bulk_plan.iter_requests())) == bulk_plan.REQUEST_COUNT == 8951


def test_the_note_pool_is_addressed_as_three_chunks() -> None:
    """50 and 109-113 use idx2 in {1,2,3} -- the 192-event pool, not a voice
    count. A fourth chunk would address track 1's slot 4, which nothing does.
    See spec section 4."""
    slots = {r.indices[1] for r in bulk_plan.iter_requests() if r.param == 50}
    assert slots == {1, 2, 3}


def test_step_active_and_step_skip_are_read_from_slot_one_only() -> None:
    """The vendor template fixes the middle index of 48 and 49 at 1, which is
    why they are pattern-wide rather than per-slot. Spec section 4 says this for
    48; it holds for 49 too."""
    slots = {r.indices[1] for r in bulk_plan.iter_requests() if r.param in (48, 49)}
    assert slots == {1}


def test_the_drum_step_active_array_covers_two_hundred_and_forty_entries() -> None:
    """24 lanes x 10 parts, packed lane-major. Chunks 1-3 run to 64 and chunk 4
    stops at 48, which is where 240 comes from."""
    per_pattern = sum(r.count or 0 for r in bulk_plan.iter_requests() if r.param == 52) / 16
    assert per_pattern == 240


def test_the_unaddressed_keys_are_left_alone() -> None:
    """The plan addresses the logical extent, not the dense rectangle. Asking
    for the rest would cost 693 requests to retrieve 35,712 zeros."""
    addressed = sum(r.count or 1 for r in bulk_plan.iter_requests())
    assert addressed == 117783
