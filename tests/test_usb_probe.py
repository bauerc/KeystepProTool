"""The probe harness, as far as it goes without a device.

These probes cannot be exercised in CI -- what they do is talk to hardware. What
can be held here is that they are wired up, that the addresses they ask for are
the ones the design names, and that the pass/fail rules they apply are the ones
Phase 2 states -- so none of that is discovered with the device already out on
the desk.
"""

import sys
from functools import partial
from pathlib import Path

import pytest

from conftest import DeviceModel, build_reply, decode_request, tape_values
from ksp import bulk_fast, bulk_read, constants, sysex
from ksp.keys import item_for_track
from ksp_cli.usb_transport import TransportError

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))

import usb_probe


@pytest.mark.parametrize(
    "name", ["identity", "scalar", "throughput", "prologue", "sentinel", "phase2", "slots"]
)
def test_every_probe_is_reachable_from_the_command_line(name: str) -> None:
    args = usb_probe.build_parser().parse_args([name])
    assert args.probe == name
    assert name in usb_probe.PROBES


def test_the_handshake_flags_default_to_sending_both() -> None:
    """H1.4 is the only probe that turns them off, and it does so per variant."""
    args = usb_probe.build_parser().parse_args(["scalar"])
    assert not args.no_identity
    assert not args.no_prologue


def test_the_scalar_probe_asks_for_the_frame_the_capture_holds() -> None:
    """Frame 13, the first read of MCC's own plan."""
    assert sysex.build_read_request(usb_probe.SCALAR).hex() == "f000206b7f4201012578f7"


def test_the_throughput_probe_asks_for_a_pitch_chunk() -> None:
    """124_109_1_1_1, count 16 -- the request H1.3 re-issues at 64."""
    assert (
        sysex.build_read_request(usb_probe.THROUGHPUT).hex() == "f000206b7f420b016d037c01010110f7"
    )


def test_the_sentinel_probe_addresses_the_pattern_default_pitch() -> None:
    """One index, count 1: the same shape ``bulk_plan`` uses for 123_117_<pat>,
    which is where every 0xFF in the capture sits."""
    request = sysex.ReadRequest(
        item=usb_probe.SENTINEL_ITEM, param=usb_probe.SENTINEL_PARAM, indices=(1,), count=1
    )
    assert sysex.build_read_request(request).hex() == "f000206b7f420b0175017b0101f7"
    assert list(usb_probe.PATTERNS) == list(range(1, 17))


def test_the_slot_defaults_to_one_and_is_settable() -> None:
    """Byte 7 is the project (spec 7.4). Every Phase 1 probe sent 1; H4.1 is why
    it has to be nameable."""
    assert usb_probe.build_parser().parse_args(["scalar"]).slot == sysex.DEFAULT_SLOT
    assert usb_probe.build_parser().parse_args(["--slot", "4", "scalar"]).slot == 4


def test_every_option_sits_before_the_subcommand() -> None:
    """The whole command line, as the protocol document prints it.

    Options split either side of the subcommand is how you get "unrecognized
    arguments: --slot 2" with the device already on the desk, so the exact
    invocation the ledger tells an operator to type is pinned here.
    """
    args = usb_probe.build_parser().parse_args(
        [
            "--save", "frames.jsonl",
            "--slot", "2",
            "--other-slot", "3",
            "--track", "1",
            "--pattern", "1",
            "--steps", "1,5,9,13",
            "--pitches", "60,64,67,72",
            "--midi-out", "h2_4.mid",
            "phase2",
        ]
    )  # fmt: skip

    assert (args.probe, args.slot, args.other_slot) == ("phase2", 2, 3)
    assert (args.track, args.pattern) == (1, 1)
    assert usb_probe.int_list(args.steps) == [1, 5, 9, 13]
    assert usb_probe.int_list(args.pitches) == [60, 64, 67, 72]
    assert args.midi_out == Path("h2_4.mid")


@pytest.mark.parametrize(
    ("param", "frame"),
    [
        (50, "f000206b7f420b0132037b01010140f7"),  # the existence array
        (109, "f000206b7f420b016d037b01010140f7"),  # pitches
        (110, "f000206b7f420b016e037b01010140f7"),  # gates
        (48, "f000206b7f420b0130037b01010140f7"),  # step active
    ],
)
def test_phase_2_asks_for_the_addresses_the_design_names(param: int, frame: str) -> None:
    """Track 1, pattern 1, chunk 1, all 64 entries in one request."""
    assert sysex.build_read_request(usb_probe.chunk(123, param, 1)).hex() == frame


def test_phase_2_addresses_the_track_it_was_given() -> None:
    """Track 2 is item 124. Reading track 1's item for a note programmed on
    track 2 would fail the probe for a reason that is not the read path."""
    assert usb_probe.chunk(item_for_track(2), 50, 1).item == 124


@pytest.mark.parametrize(
    ("text", "expected"),
    [("1,5,9,13", [1, 5, 9, 13]), ("60", [60]), (" 1 , 5 ", [1, 5])],
)
def test_an_expectation_list_parses(text: str, expected: list[int]) -> None:
    assert usb_probe.int_list(text) == expected


@pytest.mark.parametrize("text", ["", "1,x", "1,,5"])
def test_a_malformed_expectation_list_is_refused(text: str) -> None:
    with pytest.raises(ValueError):
        usb_probe.int_list(text)


# Four notes on steps 1/5/9/13: ordinals 1-4 hold the 0-based step, the rest are
# empty. 50 is note-indexed, 48 is step-indexed -- that is the trap this checks.
POOL = (0, 4, 8, 12) + (127,) * 60
PITCHES = (60, 64, 67, 72) + (127,) * 60
ACTIVE = tuple(1 if step in (1, 5, 9, 13) else 0 for step in range(1, 65))
EMPTY = bulk_fast.EMPTY
STEPS = [1, 5, 9, 13]


def test_the_pool_check_passes_on_what_h2_1_builds() -> None:
    verdict = usb_probe.check_pool(POOL, PITCHES, STEPS, [60, 64, 67, 72])
    assert verdict.passed
    assert not verdict.faults


def test_the_pool_check_catches_a_note_on_the_wrong_step() -> None:
    wrong = (0, 5, 8, 12) + (127,) * 60
    verdict = usb_probe.check_pool(wrong, PITCHES, STEPS, [60, 64, 67, 72])
    assert not verdict.passed
    assert any("step" in fault for fault in verdict.faults)


def test_the_pool_check_catches_a_wrong_pitch() -> None:
    wrong = (60, 64, 67, 71) + (127,) * 60
    verdict = usb_probe.check_pool(POOL, wrong, STEPS, [60, 64, 67, 72])
    assert not verdict.passed
    assert any("pitch" in fault for fault in verdict.faults)


def test_the_pool_check_says_so_when_chunk_one_is_full() -> None:
    """64 live entries means the pattern may continue into chunk 2, which H2.2
    does not read -- reporting that as "64 notes, panel has 4" would send the
    operator looking for a read bug that is really a chunk boundary."""
    full = tuple(range(64))
    verdict = usb_probe.check_pool(full, (60,) * 64, STEPS, [60, 64, 67, 72])
    assert not verdict.passed
    assert any("chunk 2" in fault for fault in verdict.faults)


def test_the_pool_check_catches_a_note_too_many() -> None:
    """A fifth live ordinal is the panel and the read disagreeing about how much
    is there, which is exactly what H2.2 exists to catch."""
    extra = (0, 4, 8, 12, 16) + (127,) * 59
    verdict = usb_probe.check_pool(extra, PITCHES, STEPS, [60, 64, 67, 72])
    assert not verdict.passed


def test_the_step_active_check_passes_on_what_h2_1_builds() -> None:
    verdict = usb_probe.check_step_active(ACTIVE, STEPS)
    assert verdict.passed
    assert not verdict.faults


def test_the_step_active_check_catches_a_stray_bit() -> None:
    stray = tuple(1 if step in (1, 5, 9, 13, 14) else 0 for step in range(1, 65))
    verdict = usb_probe.check_step_active(stray, STEPS)
    assert not verdict.passed
    assert any("14" in fault for fault in verdict.faults)


def test_the_step_active_check_catches_a_missing_bit() -> None:
    missing = tuple(1 if step in (1, 5, 9) else 0 for step in range(1, 65))
    verdict = usb_probe.check_step_active(missing, STEPS)
    assert not verdict.passed
    assert any("13" in fault for fault in verdict.faults)


class FakeDevice:
    """A ``UsbMidiTransport`` whose slots are the two tapes, for the smoke test.

    Anything else times out, which is also how the device behaves when byte 7
    names a slot it will not answer for.
    """

    def __init__(
        self,
        slots: dict[int, DeviceModel],
        timeout_ms: int = 1000,
        filler: set[int] | None = None,
    ) -> None:
        self.slots = slots
        self.filler = filler or set()
        self.sent: list[bytes] = []

    def __enter__(self) -> "FakeDevice":
        return self

    def __exit__(self, *_: object) -> None:
        return None

    def send(self, frame: bytes) -> None:
        self.sent.append(frame)

    def exchange(self, frame: bytes) -> bytes:
        if frame == sysex.IDENTITY_REQUEST:
            return bytes.fromhex("f07e7f060200206b0200090025140502f7")
        slot = sysex.parse_slot(frame)
        if slot in self.filler:
            # The shape the device really sent: well formed, right slot, 0x7f.
            request = decode_request(frame)
            count = request.count or 1
            return build_reply(request, (bulk_read.FILLER,) * count, slot)
        model = self.slots.get(slot)
        if model is None:
            raise TransportError(f"no reply for slot {slot}")
        return model.exchange(frame)


def test_phase_2_runs_end_to_end_against_a_modelled_device(
    fixtures_dir: Path, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The operator gets one hardware run, so every line of the probe has to have
    been executed before the device is on the desk -- the export and the H4.1
    comparison included, not just the frames.

    The two tapes stand in for two slots, so H4.1's "the answers differ" branch
    is the one taken. The H2.x verdicts are FAIL here: the tape is
    ``initial_project``, not the scratch pattern H2.1 builds.
    """
    slots = {
        1: DeviceModel(tape_values(fixtures_dir / "recall_tape.txt")),
        2: DeviceModel(tape_values(fixtures_dir / "recall_project_2_tape.txt")),
    }
    monkeypatch.setattr(usb_probe, "UsbMidiTransport", partial(FakeDevice, slots))
    destination = tmp_path / "h2_4.mid"

    code = usb_probe.main(
        [
            "--save",
            str(tmp_path / "frames.jsonl"),
            "--other-slot",
            "2",
            "--midi-out",
            str(destination),
            "phase2",
        ]
    )

    assert code == 0
    assert destination.is_file()
    # H2.2's three arrays, H2.3's one, H4.1's scalar, and the walk -- which sends
    # no more than it plans, because the pool gate skips what it has settled.
    assert 5 < len(slots[1].asked) <= bulk_fast.PATTERN_REQUEST_COUNT + 5
    # H4.1 against the other slot: one scalar and the two arrays it compares.
    assert len(slots[2].asked) == 3
    assert slots[1].slots == {1} and slots[2].slots == {2}


def test_the_smoke_run_reports_the_verdicts_it_reached(
    fixtures_dir: Path,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A probe that printed nothing useful would still exit 0."""
    slots = {
        1: DeviceModel(tape_values(fixtures_dir / "recall_tape.txt")),
        2: DeviceModel(tape_values(fixtures_dir / "recall_project_2_tape.txt")),
    }
    monkeypatch.setattr(usb_probe, "UsbMidiTransport", partial(FakeDevice, slots))

    usb_probe.main(["--other-slot", "2", "phase2"])
    out = capsys.readouterr().out

    assert "H2.2  FAIL" in out  # the tape is not the scratch pattern
    assert "H2.3  FAIL" in out
    assert "H2.4 confirms if" in out
    assert "returns a different project" in out  # the two tapes differ
    assert "slot  0: no reply for slot 0" in out


def test_the_sweep_covers_all_sixteen_slots_by_default() -> None:
    args = usb_probe.build_parser().parse_args(["slots"])
    assert (args.first_slot, args.last_slot) == (1, 16)


def test_the_sweep_names_pitches_the_way_the_device_does() -> None:
    """The panel shows middle C as C3, and the whole point of the marker notes is
    that the table can be compared against it without converting anything."""
    assert constants.note_name(60) == "C3"
    assert constants.note_name(62) == "D3"
    assert constants.note_name(64) == "E3"


def test_the_sweep_runs_over_a_modelled_device(
    fixtures_dir: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """Slot 1 answers, slot 2 is the filler case, the rest do not reply at all --
    every branch of the table, before the device is on the desk."""
    slots = {1: DeviceModel(tape_values(fixtures_dir / "recall_tape.txt"))}
    monkeypatch.setattr(usb_probe, "UsbMidiTransport", partial(FakeDevice, slots, filler={2}))

    assert usb_probe.main(["--first-slot", "1", "--last-slot", "3", "slots"]) == 0
    out = capsys.readouterr().out

    assert "FILLER" in out and "no reply" in out
    assert "1 answered, 1 filler" in out


def test_the_sweep_selects_every_slot_before_reading_it(
    fixtures_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The bug that wasted a hardware run: one prologue was sent for the default
    slot and byte 7 varied under it, so only that project ever answered. Each
    slot must get its own ``05 <slot>`` first."""
    device = FakeDevice(
        {n: DeviceModel(tape_values(fixtures_dir / "recall_tape.txt")) for n in range(1, 4)}
    )
    monkeypatch.setattr(usb_probe, "UsbMidiTransport", lambda **_: device)

    usb_probe.main(["--first-slot", "1", "--last-slot", "3", "slots"])

    prologues = [sysex.parse_slot(f) for f in device.sent if f[6] == sysex.CMD_PROLOGUE]
    assert prologues == [1, 1, 2, 3]  # the transport's own, then one per slot


def test_h4_1_selects_the_other_slot_before_comparing(
    fixtures_dir: Path, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Same bug in the H4.1 section: reading --other-slot without selecting it
    measures the harness, not the device."""
    slots = {
        1: DeviceModel(tape_values(fixtures_dir / "recall_tape.txt")),
        2: DeviceModel(tape_values(fixtures_dir / "recall_project_2_tape.txt")),
    }
    device = FakeDevice(slots)
    monkeypatch.setattr(usb_probe, "UsbMidiTransport", lambda **_: device)

    usb_probe.main(["--other-slot", "2", "phase2"])

    prologues = [sysex.parse_slot(f) for f in device.sent if f[6] == sysex.CMD_PROLOGUE]
    assert prologues[0] == 1  # the slot being read
    assert 2 in prologues  # the other slot, before it is read
    assert prologues[-1] == 1  # and back, so the device is left where it was


def test_the_sweep_reports_the_marker_note_it_found(
    fixtures_dir: Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """A slot identifies itself by the pitch on step 1, printed as a note name.

    The tape's track 1 pattern 1 holds a note at ordinal 1, so this exercises the
    decode rather than the empty branch.
    """
    values = tape_values(fixtures_dir / "recall_tape.txt")
    monkeypatch.setattr(
        usb_probe, "UsbMidiTransport", partial(FakeDevice, {1: DeviceModel(values)})
    )

    usb_probe.main(["--first-slot", "1", "--last-slot", "1", "slots"])
    out = capsys.readouterr().out

    pitch = values["123_109_1_1_1"]
    assert f"{pitch:>5}  {constants.note_name(pitch):>5}" in out


def test_the_sweep_says_so_when_a_slot_holds_no_note(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """An answering slot with an empty pool is not the same as a filler slot, and
    conflating them is how a missing marker reads as a protocol failure."""
    empty = DeviceModel({f"123_{param}_1_1_1": EMPTY for param in (50, 109)} | {"120_37": 3})
    monkeypatch.setattr(usb_probe, "UsbMidiTransport", partial(FakeDevice, {1: empty}))

    usb_probe.main(["--first-slot", "1", "--last-slot", "1", "slots"])
    out = capsys.readouterr().out

    assert "no note in the pool" in out
    assert "1 answered, 0 filler" in out


def test_ordinals_are_reported_one_based_and_steps_too() -> None:
    """50 holds the 0-based step; a probe that printed it raw would send the
    operator hunting for a note on step 0."""
    assert usb_probe.live_notes(POOL, PITCHES, (10,) * 64) == [
        (1, 1, 60, 10),
        (2, 5, 64, 10),
        (3, 9, 67, 10),
        (4, 13, 72, 10),
    ]
