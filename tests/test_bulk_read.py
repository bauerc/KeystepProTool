"""Reading a project off the wire, replayed from a captured exchange."""

from collections.abc import Callable
from pathlib import Path

import pytest

from conftest import ReplayTransport
from ksp import bulk_plan, bulk_read, lenient_json, reader, sysex

TRANSACTIONS = 8951
ADDRESSED = 117783
ZERO_FILLED = 35712
TOTAL_KEYS = 153497

FIRST_REQUEST = "f000206b7f4201012578f7"
FIRST_REPLY = "f000206b7f420201257803f7"

Build = Callable[..., ReplayTransport]
Loader = Callable[[str], dict[str, int | str]]


def test_the_tape_holds_every_captured_transaction(fixtures_dir: Path) -> None:
    """A short tape means a truncated capture, and every downstream count is then wrong in a way the
    reconstruction test would report as a diff.
    """
    lines = (fixtures_dir / "recall_tape.txt").read_text().splitlines()
    assert len(lines) == TRANSACTIONS
    assert all(len(line.split()) == 2 for line in lines)
    assert lines[0].split() == [FIRST_REQUEST, FIRST_REPLY]


@pytest.fixture
def template_keys(load_sample: Loader) -> list[str]:
    """The file's full key set, which the plan does not address all of."""
    return list(load_sample("Default.KeyStepPro"))


@pytest.fixture
def replayed(replay_transport: Build, template_keys: list[str]) -> dict[str, int | str]:
    return bulk_read.read_raw(replay_transport(), template_keys)


def test_the_replay_reconstructs_the_project_exactly(
    replayed: dict[str, int | str], project_files_dir: Path
) -> None:
    """153,497 of 153,497."""
    truth = lenient_json.load_path(project_files_dir / "initial_project.KeyStepPro")
    assert replayed == truth


def test_every_unaddressed_key_is_zero_filled(
    replayed: dict[str, int | str], load_sample: Loader
) -> None:
    """The plan asks for the logical extent; the rest of the rectangle is zero in every corpus file
    and is filled from the template rather than fetched.
    """
    addressed = {n for r in bulk_plan.iter_requests() for n in bulk_read.keys_for(r)}
    template = {k for k in load_sample("Default.KeyStepPro") if k not in lenient_json.LEADING_KEYS}
    unaddressed = template - addressed

    assert len(addressed) == ADDRESSED
    assert len(unaddressed) == ZERO_FILLED
    assert all(replayed[k] == 0 for k in unaddressed)
    assert len(replayed) == TOTAL_KEYS


def test_the_unset_sentinel_becomes_what_mcc_stores(
    replayed: dict[str, int | str],
) -> None:
    """The device sends 0xFF for an uninitialised pattern default pitch."""
    unset = [k for k, v in replayed.items() if v == sysex.UNSET_IN_FILE]
    assert unset == [f"123_117_{pattern}" for pattern in range(1, 14)]


def test_the_mcc_side_constants_are_not_taken_from_the_wire(
    replayed: dict[str, int | str],
) -> None:
    """These read 0 from hardware but are 127 in all six corpus files, including the factory
    default, which never came off a device.
    """
    assert all(replayed[k] == value for k, value in bulk_read.MCC_CONSTANTS.items())


def test_the_plan_is_walked_in_the_order_mcc_used(
    replay_transport: Build,
    template_keys: list[str],
    recall_tape: list[tuple[bytes, bytes]],
) -> None:
    transport = replay_transport()
    bulk_read.read_raw(transport, template_keys)

    assert transport.asked == [request for request, _ in recall_tape]


def test_a_device_that_answers_the_wrong_address_is_refused(
    replay_transport: Build,
    template_keys: list[str],
    recall_tape: list[tuple[bytes, bytes]],
) -> None:
    """The reply echoes the request header, so a desynchronised stream is detectable -- and silently
    accepting it would write values under the wrong keys.
    """
    first, _ = recall_tape[0]
    _, other_reply = recall_tape[1]
    transport = replay_transport([(first, other_reply), *recall_tape[1:]])

    with pytest.raises(ValueError, match="answered"):
        bulk_read.read_raw(transport, template_keys)


#: A well-formed reply carrying the 0x7f filler. Nothing at the protocol level is wrong
#: with it, which is exactly the danger.
REFUSED_SLOT_REPLY = "f000206b7f42020325787ff7"


def refusal_at(slot: int) -> bytes:
    """The captured refusal, re-addressed so it answers a request for ``slot``."""
    frame = bytearray.fromhex(REFUSED_SLOT_REPLY)
    frame[7] = slot
    return bytes(frame)


def test_a_slot_the_device_will_not_serve_is_refused(
    replay_transport: Build,
    template_keys: list[str],
    recall_tape: list[tuple[bytes, bytes]],
) -> None:
    """Some slots answer a read with filler rather than a project (observed 2026-08-14; which slots
    and why is not established).
    """
    first, _ = recall_tape[0]
    transport = replay_transport([(first, refusal_at(1)), *recall_tape[1:]])

    with pytest.raises(ValueError, match="not returning slot 1"):
        bulk_read.read_raw(transport, template_keys)


def test_the_echoed_slot_is_checked_before_the_payload(
    replay_transport: Build,
    template_keys: list[str],
    recall_tape: list[tuple[bytes, bytes]],
) -> None:
    """The device's real refusal echoes the slot it was asked about, so a reply naming a slot nobody
    asked for is a different fault and says so.
    """
    first, _ = recall_tape[0]
    transport = replay_transport([(first, bytes.fromhex(REFUSED_SLOT_REPLY)), *recall_tape[1:]])

    with pytest.raises(ValueError, match="answered slot 3"):
        bulk_read.read_raw(transport, template_keys)


def test_the_guard_reads_the_frames_the_device_actually_sent() -> None:
    """The refusal above is hardware evidence, not a description of it: 120_37 came back 0x7f, which
    no corpus project holds.
    """
    request, values = sysex.parse_reply(bytes.fromhex(REFUSED_SLOT_REPLY))

    assert bulk_read.keys_for(request) == [bulk_read.SLOT_PROBE]
    assert values == (bulk_read.FILLER,)
    assert sysex.parse_slot(bytes.fromhex(REFUSED_SLOT_REPLY)) == 3


def test_the_slot_is_selected_before_anything_is_read(
    replay_transport: Build, template_keys: list[str]
) -> None:
    """``05 <slot>`` is what chooses the project; byte 7 then agrees with it."""
    transport = replay_transport()
    bulk_read.read_raw(transport, template_keys, slot=1)

    assert transport.sent == [sysex.prologue(1)]


def test_the_prologue_names_the_slot_that_was_asked_for(
    replay_transport: Build, template_keys: list[str], recall_tape: list[tuple[bytes, bytes]]
) -> None:
    """Selecting slot 1 while reading slot 4 would read the wrong project."""
    probe = sysex.ReadRequest(item=120, param=37, indices=(), count=None)
    at_four = (sysex.build_read_request(probe, 4), refusal_at(4))
    transport = replay_transport([*recall_tape, at_four])

    with pytest.raises(ValueError, match="not returning slot 4"):
        bulk_read.read_raw(transport, template_keys, slot=4)

    assert transport.sent == [sysex.prologue(4)]


def test_a_real_slot_probe_value_passes_the_guard(
    replayed: dict[str, int | str],
) -> None:
    """0-3 is the corpus range for 120_37, so the guard cannot fire on a project the device is
    genuinely serving.
    """
    assert replayed[bulk_read.SLOT_PROBE] != bulk_read.FILLER


def test_the_result_decodes_through_the_existing_reader(
    replayed: dict[str, int | str],
) -> None:
    """The point of the whole exercise: the hardware becomes a second producer of the dict
    lenient_json already produces, and nothing downstream changes.
    """
    project = reader.read_project(replayed, source_name="replay")
    assert len(project.tracks) == 4
