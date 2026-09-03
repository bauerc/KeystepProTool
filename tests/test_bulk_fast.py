"""The efficient read plan against the addresses MCC's plan covers."""

import sys
from collections.abc import Callable
from pathlib import Path

import pytest

from conftest import DeviceModel, tape_values
from ksp import bulk_fast, bulk_plan, bulk_read, lenient_json, sysex
from ksp.sysex import ReadRequest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))

import gen_bulk_fast_fixture
import gen_bulk_read_walk_fixture

TAPES = ("recall_tape.txt", "recall_project_2_tape.txt")
ADDRESSED = 117783

#: What each tape costs to read: MCC's 8,951, then the merged plan, then the
#: merged plan with the pool gate applied. Project 2 carries fewer notes.
EXPECTED_REQUESTS = {"recall_tape.txt": 1007, "recall_project_2_tape.txt": 976}

Loader = Callable[[str], dict[str, int | str]]


@pytest.fixture(params=TAPES)
def tape_name(request: pytest.FixtureRequest) -> str:
    return str(request.param)


@pytest.fixture
def device(tape_name: str, fixtures_dir: Path) -> DeviceModel:
    return DeviceModel(tape_values(fixtures_dir / tape_name))


@pytest.fixture
def template_keys(load_sample: Loader) -> list[str]:
    return list(load_sample("Default.KeyStepPro"))


def addresses(requests: list[ReadRequest]) -> list[str]:
    return [name for request in requests for name in bulk_read.keys_for(request)]


def test_the_fast_plan_covers_exactly_what_mcc_covers() -> None:
    """The whole contract. Fewer frames, not fewer addresses."""
    mcc = addresses(list(bulk_plan.iter_requests()))
    fast = addresses(list(bulk_fast.iter_requests()))

    assert set(fast) == set(mcc)
    assert len(fast) == len(mcc) == ADDRESSED
    assert len(set(fast)) == ADDRESSED


def test_the_fast_plan_declares_its_own_length() -> None:
    assert len(list(bulk_fast.iter_requests())) == bulk_fast.REQUEST_COUNT == 2044


def test_the_swift_port_is_held_to_this_plan(fixtures_dir: Path) -> None:
    """KSPKit transcribes the table separately (ADR 0003), so the fixture is what binds the two
    cores. Regenerate it with ``uv run python tools/gen_bulk_fast_fixture.py``."""
    assert gen_bulk_fast_fixture.render() == (fixtures_dir / "bulk_fast_requests.txt").read_text()


def test_the_swift_port_is_held_to_this_walk(fixtures_dir: Path) -> None:
    """Agreeing on 1,007 requests is not agreeing on which 1,007, and only the gate decides that.
    Regenerate it with ``uv run python tools/gen_bulk_read_walk_fixture.py``."""
    walk = (fixtures_dir / "bulk_read_walk.txt").read_text()

    assert gen_bulk_read_walk_fixture.render() == walk
    assert len(walk.splitlines()) == EXPECTED_REQUESTS["recall_tape.txt"]


def test_every_request_is_one_the_device_answers() -> None:
    """A count above 100 comes back clamped and would read as a desync; four indices draw no reply
    at all.
    """
    for request in bulk_fast.iter_requests():
        sysex.build_read_request(request)
        if request.count is not None:
            assert 1 <= len(request.indices) <= 3
            assert 0 < request.count <= sysex.MAX_READ_COUNT


def test_no_run_in_the_plan_is_longer_than_a_single_request() -> None:
    """The extent binds before the protocol does: the longest contiguous run in PLAN is a 64-entry
    pool chunk, well inside the 100 the device honours.
    """
    assert max(r.count or 0 for r in bulk_fast.iter_requests()) == 64


def test_the_existence_array_is_read_before_the_notes_it_gates() -> None:
    """Without this the gate has nothing to consult -- MCC's leaf order puts 50 after the parameters
    it settles.
    """
    seen_gate: set[tuple[int, int, int]] = set()
    for request in bulk_fast.iter_requests():
        if request.count is None or len(request.indices) != 3:
            continue
        pattern, slot, _ = request.indices
        if request.param == bulk_fast.MELODIC_GATE:
            seen_gate.add((request.item, pattern, slot))
        elif request.param in bulk_fast.MELODIC_GATED:
            assert (request.item, pattern, slot) in seen_gate


def test_the_fast_read_reconstructs_what_mcc_reads(
    device: DeviceModel, tape_name: str, fixtures_dir: Path, template_keys: list[str]
) -> None:
    """The proof, and it needs no hardware: both walks, one device, one result."""
    slow = bulk_read.read_raw(DeviceModel(tape_values(fixtures_dir / tape_name)), template_keys)
    fast = bulk_read.read_raw(device, template_keys, fast=True)

    assert fast == slow


def test_the_replayed_project_still_matches_its_file(
    fixtures_dir: Path, project_files_dir: Path, template_keys: list[str]
) -> None:
    """Tape 1 is MCC recalling initial_project, so the fast walk owes the file itself -- not merely
    agreement with the other walk.
    """
    device = DeviceModel(tape_values(fixtures_dir / "recall_tape.txt"))
    replayed = bulk_read.read_raw(device, template_keys, fast=True)

    assert replayed == lenient_json.load_path(project_files_dir / "initial_project.KeyStepPro")


def test_the_gate_saves_the_requests_it_claims(
    device: DeviceModel, tape_name: str, template_keys: list[str]
) -> None:
    bulk_read.read_raw(device, template_keys, fast=True)

    assert len(device.asked) == EXPECTED_REQUESTS[tape_name]
    assert len(device.asked) < bulk_plan.REQUEST_COUNT / 8


def test_the_drum_pool_is_never_skipped(device: DeviceModel, template_keys: list[str]) -> None:
    """A dead drum entry reads 127 in some patterns and the default row in others, so nothing
    derives it.
    """
    bulk_read.read_raw(device, template_keys, fast=True)
    drum_pool = {
        request
        for request in bulk_fast.iter_requests()
        if request.param in range(117, 122) and len(request.indices) == 3
    }

    assert drum_pool
    assert drum_pool <= set(device.asked)


def pattern_of(name: str) -> int | None:
    """The pattern a track key belongs to, read off the key itself."""
    parts = name.split("_")
    return int(parts[2]) if len(parts) > 2 else None


@pytest.mark.parametrize("pattern", [1, 5, 16])
def test_the_pattern_walk_covers_every_key_of_that_pattern(pattern: int) -> None:
    """H2.4 reads one pattern of one track, and must not quietly drop a key the full walk would have
    filled for it.
    """
    whole = addresses(list(bulk_fast.iter_requests()))
    subset = set(addresses(list(bulk_fast.iter_pattern_requests(123, pattern))))
    owed = {name for name in whole if name.startswith("123_") and pattern_of(name) == pattern}

    assert owed <= subset
    # The per-pattern scalars ride in one 16-entry range, so neighbouring patterns come
    # along; no other track's pattern data may. The index-less track scalars are kept.
    assert not {
        name
        for name in subset
        if name.startswith(("124_", "125_", "126_")) and pattern_of(name) is not None
    }


def test_the_pattern_walk_reads_the_scalars_that_make_a_pattern_play() -> None:
    """Step count, swing, pattern bits and data state are per-pattern scalars that bulk_fast
    coalesces into one range at index 1.
    """
    for pattern in (1, 5, 16):
        names = set(addresses(list(bulk_fast.iter_pattern_requests(123, pattern))))
        assert {
            f"123_40_{pattern}",
            f"123_97_{pattern}",
            f"123_98_{pattern}",
            f"123_99_{pattern}",
            f"123_100_{pattern}",
        } <= names


def test_the_pattern_walk_carries_the_index_less_scalars() -> None:
    """Tempo lives in 120_70/71/72 and has no pattern index, so a walk that kept only indexed
    requests would export the pattern at the wrong speed.
    """
    names = set(addresses(list(bulk_fast.iter_pattern_requests(123, 1))))

    assert {"120_70", "120_71", "120_72"} <= names
    assert "123_40_1" in names  # the pattern's own data state


def test_the_pattern_walk_is_a_fraction_of_the_whole() -> None:
    requests = list(bulk_fast.iter_pattern_requests(123, 1))

    assert len(requests) == bulk_fast.PATTERN_REQUEST_COUNT == 115
    assert len(requests) < bulk_fast.REQUEST_COUNT / 16


def test_the_pattern_walk_still_reads_the_gate_before_the_notes() -> None:
    """Filtering must not disturb the order _already_answered depends on."""
    seen_gate = False
    for request in bulk_fast.iter_pattern_requests(123, 1):
        if request.count is None or len(request.indices) != 3:
            continue
        if request.param == bulk_fast.MELODIC_GATE:
            seen_gate = True
        elif request.param in bulk_fast.MELODIC_GATED:
            assert seen_gate


def test_a_pattern_read_agrees_with_the_whole_project(
    device: DeviceModel, tape_name: str, fixtures_dir: Path, template_keys: list[str]
) -> None:
    """Same device, same keys: reading one pattern must give the values a full read gives, or H2.4
    proves nothing about H3.1.
    """
    whole = bulk_read.read_raw(
        DeviceModel(tape_values(fixtures_dir / tape_name)), template_keys, fast=True
    )
    part = bulk_read.read_raw(
        device, template_keys, requests=bulk_fast.iter_pattern_requests(123, 1)
    )
    covered = set(addresses(list(bulk_fast.iter_pattern_requests(123, 1))))

    assert {name: part[name] for name in covered} == {name: whole[name] for name in covered}
    assert set(part) == set(whole)


def test_the_slot_reaches_every_frame(device: DeviceModel, template_keys: list[str]) -> None:
    """Byte 7 is the project (spec 7.4)."""
    bulk_read.read_raw(device, template_keys, fast=True, slot=2)

    assert device.slots == {2}
