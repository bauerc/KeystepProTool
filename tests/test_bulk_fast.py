"""The efficient read plan against the addresses MCC's plan covers.

``bulk_fast`` may send whatever frames it likes; what it may not do is come back
with a different project. So the tests here answer both walks out of the same
device model -- a tape's own values, served at any address and any count, the
way the hardware would -- and require the two dicts to be equal.

The tapes only ever recorded ``count`` 16, so a merged request has no captured
reply to replay. The model is what makes the comparison possible without the
device; spec section 7.7 is where the count limits it honours come from.
"""

from collections.abc import Callable
from pathlib import Path

import pytest

from ksp import bulk_fast, bulk_plan, bulk_read, lenient_json, sysex
from ksp.sysex import ReadRequest

TAPES = ("recall_tape.txt", "recall_project_2_tape.txt")
ADDRESSED = 117783

#: What each tape costs to read: MCC's 8,951, then the merged plan, then the
#: merged plan with the pool gate applied. Project 2 carries fewer notes.
EXPECTED_REQUESTS = {"recall_tape.txt": 1007, "recall_project_2_tape.txt": 976}

Loader = Callable[[str], dict[str, int | str]]


def decode_request(frame: bytes) -> ReadRequest:
    body = frame[6:-1]
    if body[0] == sysex.CMD_SCALAR:
        return ReadRequest(item=body[3], param=body[2], indices=(), count=None)
    count = body[3]
    return ReadRequest(
        item=body[4], param=body[2], indices=tuple(body[5 : 5 + count]), count=body[5 + count]
    )


def build_reply(request: ReadRequest, values: tuple[int, ...]) -> bytes:
    if request.count is None:
        body = (sysex.CMD_SCALAR_REPLY, sysex.SUBCOMMAND, request.param, request.item, *values)
    else:
        body = (
            sysex.CMD_READ_REPLY,
            sysex.SUBCOMMAND,
            request.param,
            len(request.indices),
            request.item,
            *request.indices,
            request.count,
            *values,
        )
    return sysex.HEADER + bytes(body) + bytes((sysex.END,))


class DeviceModel:
    """Answers any address from a tape's values, at any count the device allows.

    Raw bytes in, raw bytes out -- the 0xFF sentinel included, so the reader's
    correction of it is exercised rather than bypassed.
    """

    def __init__(self, values: dict[str, int]) -> None:
        self._values = values
        self.asked: list[ReadRequest] = []

    def exchange(self, frame: bytes) -> bytes:
        request = decode_request(frame)
        self.asked.append(request)
        names = bulk_read.keys_for(request)
        missing = [name for name in names if name not in self._values]
        if missing:
            raise LookupError(f"tape holds no value for {missing[0]}")
        return build_reply(request, tuple(self._values[name] for name in names))


def tape_values(path: Path) -> dict[str, int]:
    """Every address the tape delivered, as the device sent it."""
    values: dict[str, int] = {}
    for line in path.read_text().splitlines():
        sent, received = line.split()
        request, payload = sysex.parse_reply(bytes.fromhex(received))
        assert request == decode_request(bytes.fromhex(sent))
        for name, value in zip(bulk_read.keys_for(request), payload, strict=True):
            values[name] = value
    return values


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


def test_every_request_is_one_the_device_answers() -> None:
    """A count above 100 comes back clamped and would read as a desync; four
    indices draw no reply at all. Spec section 7.7."""
    for request in bulk_fast.iter_requests():
        sysex.build_read_request(request)
        if request.count is not None:
            assert 1 <= len(request.indices) <= 3
            assert 0 < request.count <= sysex.MAX_READ_COUNT


def test_no_run_in_the_plan_is_longer_than_a_single_request() -> None:
    """The extent binds before the protocol does: the longest contiguous run in
    PLAN is a 64-entry pool chunk, well inside the 100 the device honours."""
    assert max(r.count or 0 for r in bulk_fast.iter_requests()) == 64


def test_the_existence_array_is_read_before_the_notes_it_gates() -> None:
    """Without this the gate has nothing to consult -- MCC's leaf order puts 50
    after the parameters it settles."""
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
    """Tape 1 is MCC recalling initial_project, so the fast walk owes the file
    itself -- not merely agreement with the other walk."""
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
    """A dead drum entry reads 127 in some patterns and the default row in
    others, so nothing derives it. Gating it the way 50 gates the melodic set
    would silently replace real bytes."""
    bulk_read.read_raw(device, template_keys, fast=True)
    drum_pool = {
        request
        for request in bulk_fast.iter_requests()
        if request.param in range(117, 122) and len(request.indices) == 3
    }

    assert drum_pool
    assert drum_pool <= set(device.asked)
