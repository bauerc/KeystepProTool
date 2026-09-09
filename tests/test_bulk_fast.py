"""The efficient read plan against the addresses MCC's plan covers."""

import sys
from collections.abc import Callable
from pathlib import Path

import pytest

from conftest import DeviceModel, tape_values
from ksp import bulk_fast, bulk_plan, bulk_read, lenient_json, sysex
from ksp.keys import key
from ksp.sysex import ReadRequest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))

import gen_bulk_fast_fixture
import gen_bulk_read_walk_fixture

TAPES = ("recall_tape.txt", "recall_project_2_tape.txt")
ADDRESSED = 117783

#: What each tape costs to read: MCC's 8,951, then the merged plan, then the merged plan
#: with both gates applied. Project 2 carries fewer notes, and the data state settles whole
#: patterns, so it gains the more of the two.
EXPECTED_REQUESTS = {"recall_tape.txt": 2169, "recall_project_2_tape.txt": 1979}

Loader = Callable[[str], dict[str, int | str]]


@pytest.fixture(params=TAPES)
def tape_name(request: pytest.FixtureRequest) -> str:
    return str(request.param)


@pytest.fixture
def tape(tape_name: str, fixtures_dir: Path) -> dict[str, int]:
    return tape_values(fixtures_dir / tape_name)


@pytest.fixture
def device(tape: dict[str, int]) -> DeviceModel:
    return DeviceModel(tape)


@pytest.fixture
def recall_device(fixtures_dir: Path) -> DeviceModel:
    return DeviceModel(tape_values(fixtures_dir / "recall_tape.txt"))


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
    assert len(list(bulk_fast.iter_requests())) == bulk_fast.REQUEST_COUNT == 3399


def test_the_swift_port_is_held_to_this_plan(fixtures_dir: Path) -> None:
    """KSPKit transcribes the table separately (ADR 0003), so the fixture is what binds the two
    cores. Regenerate it with ``uv run python tools/gen_bulk_fast_fixture.py``."""
    assert gen_bulk_fast_fixture.render() == (fixtures_dir / "bulk_fast_requests.txt").read_text()


def test_the_swift_port_is_held_to_this_walk(fixtures_dir: Path) -> None:
    """Agreeing on 2,474 requests is not agreeing on which 2,474, and only the gate decides that.
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


def test_no_run_over_a_lone_index_is_read_as_a_range() -> None:
    """The device answers a range read over a lone index with the first entry repeated, so a
    per-pattern scalar coalesced into a 16-entry range reads pattern 1 sixteen times.
    """
    for request in bulk_fast.iter_requests():
        if request.count is not None and len(request.indices) == 1:
            assert request.count == 1, f"{request.item}_{request.param} walks a lone index"


def test_the_protocol_binds_a_run_before_the_extent_does() -> None:
    """It was the other way round while a run stopped at its own 64-entry chunk. Rolling over
    joins three of them, so the 100 the device honours is what cuts a run now.
    """
    assert max(r.count or 0 for r in bulk_fast.iter_requests()) == sysex.MAX_READ_COUNT == 100


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
    recall_device: DeviceModel, project_files_dir: Path, template_keys: list[str]
) -> None:
    """Tape 1 is MCC recalling initial_project, so the fast walk owes the file itself -- not merely
    agreement with the other walk.
    """
    replayed = bulk_read.read_raw(recall_device, template_keys, fast=True)

    assert replayed == lenient_json.load_path(project_files_dir / "initial_project.KeyStepPro")


def test_the_gate_saves_the_requests_it_claims(
    device: DeviceModel, tape_name: str, template_keys: list[str]
) -> None:
    bulk_read.read_raw(device, template_keys, fast=True)

    assert len(device.asked) == EXPECTED_REQUESTS[tape_name]
    assert len(device.asked) < bulk_plan.REQUEST_COUNT / 3


def test_the_drum_pool_is_never_derived_in_a_pattern_that_holds_data(
    device: DeviceModel, tape: dict[str, int], template_keys: list[str]
) -> None:
    """A dead drum entry reads 127 in some patterns and the default row in others, so no
    existence array derives it. Parameter 40 is the one thing that settles one, and only where
    the pattern holds no note at all -- so every pattern that holds data is still asked in full.
    """
    bulk_read.read_raw(device, template_keys, fast=True)
    drum_pool = {
        request
        for request in bulk_fast.iter_requests()
        if request.param in range(117, 122)
        and len(request.indices) == 3
        and tape[key(123, bulk_fast.DATA_STATE, request.indices[0])] == bulk_fast.HAS_DATA
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
    # Nothing but this pattern's own keys and the index-less track scalars.
    assert not {name for name in subset if pattern_of(name) not in (None, pattern)}


def test_the_pattern_walk_reads_the_scalars_that_make_a_pattern_play() -> None:
    """Step count, swing, pattern bits and data state are per-pattern scalars, and each is its
    own request.
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

    assert len(requests) == bulk_fast.PATTERN_REQUEST_COUNT == 108
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


def test_a_pattern_holding_no_data_is_not_asked_for_its_note_pool(
    recall_device: DeviceModel, template_keys: list[str]
) -> None:
    """Parameter 40 is the firmware's own "this pattern holds notes" flag. Track 4 holds none in
    any pattern of this tape, so every pooled note parameter in it is the empty row already.
    """
    bulk_read.read_raw(recall_device, template_keys, fast=True)

    asked = {
        request.indices[0]
        for request in recall_device.asked
        if request.count is not None
        and request.item == 126
        and (request.param, len(request.indices)) in bulk_fast.DATA_STATE_GATED
    }

    assert asked == set()


def test_the_data_state_is_read_before_the_pool_it_settles() -> None:
    """Without this the gate has nothing to consult and every pattern is asked in full. It comes
    before the existence array too: a whole pattern settles more than a chunk does.
    """
    seen_state: set[tuple[int, int]] = set()
    for request in bulk_fast.iter_requests():
        if request.count is None:
            continue
        if request.param == bulk_fast.DATA_STATE and len(request.indices) == 1:
            seen_state.add((request.item, request.indices[0]))
        elif (request.param, len(request.indices)) in bulk_fast.DATA_STATE_GATED:
            assert (request.item, request.indices[0]) in seen_state


def test_a_pool_walk_rolls_over_into_the_next_chunk() -> None:
    """The device walks a count past the end of one middle index into the next, within the same
    outer index, so track 1's three 64-entry chunks are two requests rather than three.
    """
    requests = [
        (request.indices, request.count)
        for request in bulk_fast.iter_requests()
        if request.item == 123
        and request.param == 117
        and len(request.indices) == 3
        and request.indices[0] == 1
    ]

    assert requests == [((1, 1, 1), 100), ((1, 2, 37), 92)]


def test_a_rolled_over_request_names_the_keys_it_actually_fills() -> None:
    """Its last index runs past the chunk length and carries into the next chunk, so the flat
    keys are not the naive ``last + offset``.
    """
    rolled = ReadRequest(item=123, param=117, indices=(1, 1, 1), count=100)

    names = bulk_read.keys_for(rolled)

    assert names[0] == "123_117_1_1_1"
    assert names[63] == "123_117_1_1_64"
    assert names[64] == "123_117_1_2_1"
    assert names[99] == "123_117_1_2_36"


def test_nothing_a_chunk_gate_settles_is_rolled_over() -> None:
    """The two compete: the existence array skips an empty chunk outright, and a request
    coalesced across that chunk would fetch it back. Rolling over is for the pool no chunk
    gate reaches.
    """
    assert not bulk_fast.ROLLED_OVER & bulk_fast.MELODIC_GATED
    assert bulk_fast.MELODIC_GATE not in bulk_fast.ROLLED_OVER


def test_a_pattern_holding_no_data_is_not_asked_for_its_control_lanes(
    recall_device: DeviceModel, template_keys: list[str]
) -> None:
    """The control track carries the same data state as any other, and its five CC lanes hold a
    value per step. No pattern of this tape holds data, so none of the lanes needs asking.
    """
    bulk_read.read_raw(recall_device, template_keys, fast=True)

    lanes = [
        request
        for request in recall_device.asked
        if request.item == 122 and len(request.indices) == 2
    ]

    assert lanes == []
