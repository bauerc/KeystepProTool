"""``ksp-pull`` end to end, against a modelled device."""

from pathlib import Path

import pytest

from conftest import DeviceModel, FakeDevice, tape_values, without_trailing_comma
from ksp import lenient_json, reader, sysex
from ksp_cli import app, pull
from ksp_cli.loading import default_template
from ksp_cli.pull import main
from ksp_cli.usb_transport import TransportError


def _template_values() -> dict[str, int]:
    """The factory default's parameters -- a saved project that holds no notes."""
    raw = lenient_json.load_path(default_template())
    return {name: value for name, value in raw.items() if isinstance(value, int)}


@pytest.fixture
def device(fixtures_dir: Path) -> FakeDevice:
    """Slot 1 is the initial_project tape, slot 2 the project 2 recall."""
    return FakeDevice(
        {
            1: DeviceModel(tape_values(fixtures_dir / "recall_tape.txt")),
            2: DeviceModel(tape_values(fixtures_dir / "recall_project_2_tape.txt")),
        }
    )


@pytest.fixture
def attached(monkeypatch: pytest.MonkeyPatch, device: FakeDevice) -> FakeDevice:
    """The command's transport, with the device standing in for the hardware."""
    monkeypatch.setattr(pull, "UsbMidiTransport", lambda **_: device)
    return device


class _Clock:
    """A clock that moves only when a step is charged for its cost."""

    def __init__(self, monkeypatch: pytest.MonkeyPatch) -> None:
        self.now = 0.0
        self._monkeypatch = monkeypatch
        monkeypatch.setattr(pull, "monotonic", self)

    def __call__(self) -> float:
        return self.now

    def charge(self, name: str, seconds: float) -> None:
        """Make ``pull``'s *name* cost *seconds* on this clock."""
        inner = getattr(pull, name)

        def timed(*args: object, **kwargs: object) -> object:
            result = inner(*args, **kwargs)
            self.now += seconds
            return result

        self._monkeypatch.setattr(pull, name, timed)


def test_the_dump_is_byte_identical_to_mcc_s_export(
    attached: FakeDevice, tmp_path: Path, project_files_dir: Path
) -> None:
    """H3.2's byte-diff, over the capture rather than over the device."""
    written = tmp_path / "pulled.KeyStepPro"

    assert main([str(written)]) == 0

    expected = project_files_dir / "initial_project.KeyStepPro"
    assert written.read_bytes() == without_trailing_comma(expected.read_bytes())


def test_the_walk_asks_for_64_values_at_a_time(
    attached: FakeDevice, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """H3.1 asks for the coalesced walk, not MCC's 8,951 count-1 reads."""
    written = tmp_path / "pulled.KeyStepPro"
    assert main([str(written)]) == 0

    counts = [request.count for request in attached.slots[1].asked if request.count is not None]
    assert max(counts) == 64
    # The gated walk's own figure for this tape, which test_bulk_fast pins too.
    assert len(attached.slots[1].asked) == 1007
    # And the summary reports the walk, not the walk plus the identity request:
    # 1,007 is the number spec 7.8 states and an operator compares a run against.
    assert "1007 requests" in capsys.readouterr().out


def test_the_mcc_plan_reads_the_same_project_in_far_more_requests(
    attached: FakeDevice, tmp_path: Path, project_files_dir: Path
) -> None:
    """The two walks are alternatives, not different answers."""
    written = tmp_path / "slow.KeyStepPro"

    assert main([str(written), "--mcc-plan"]) == 0

    expected = project_files_dir / "initial_project.KeyStepPro"
    assert written.read_bytes() == without_trailing_comma(expected.read_bytes())
    assert len(attached.slots[1].asked) == 8951


def test_the_slot_is_chosen_without_touching_the_panel(
    attached: FakeDevice, tmp_path: Path
) -> None:
    """``--slot`` sends the prologue that selects the project (H4.1)."""
    written = tmp_path / "two.KeyStepPro"

    assert main([str(written), "--slot", "2"]) == 0

    assert attached.sent == [sysex.prologue(2)]
    assert attached.slots[2].asked
    assert not attached.slots[1].asked


def test_the_version_comes_off_the_wire(attached: FakeDevice, tmp_path: Path) -> None:
    """No read address carries it, so the identity request is not optional."""
    written = tmp_path / "pulled.KeyStepPro"
    assert main([str(written)]) == 0

    assert lenient_json.load_path(written)["version"] == "2.5.20"


def test_no_identity_falls_back_without_asking(
    monkeypatch: pytest.MonkeyPatch, device: FakeDevice, tmp_path: Path
) -> None:
    asked: list[bytes] = []
    exchange = device.exchange

    def watched(frame: bytes) -> bytes:
        asked.append(frame)
        return exchange(frame)

    monkeypatch.setattr(device, "exchange", watched)
    monkeypatch.setattr(pull, "UsbMidiTransport", lambda **_: device)

    written = tmp_path / "pulled.KeyStepPro"
    assert main([str(written), "--no-identity"]) == 0

    assert sysex.IDENTITY_REQUEST not in asked
    assert lenient_json.load_path(written)["version"] == "2.5.20"


def test_the_result_is_a_project_the_rest_of_the_tool_can_read(
    attached: FakeDevice, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    written = tmp_path / "pulled.KeyStepPro"
    assert main([str(written)]) == 0

    project = reader.load(written)
    assert project.tempo_bpm == 132
    assert project.diagnostics.entries == ()
    assert "read slot 1" in capsys.readouterr().out


def test_the_summary_times_the_whole_run_not_just_the_read(
    attached: FakeDevice,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The total has to include the template parse and the write."""
    clock = _Clock(monkeypatch)
    clock.charge("load_template", 5.0)
    clock.charge("read_raw", 2.0)
    clock.charge("dump_path", 3.0)

    written = tmp_path / "pulled.KeyStepPro"
    assert main([str(written)]) == 0

    out = capsys.readouterr().out
    # Only the read is at the device; the parse before it and the write after it
    # are the other 8 s, and a clock started later would drop them.
    assert "read slot 1 in 2.0 s" in out
    assert "  10.0 s total, 2.0 s of it at the device" in out


def test_an_existing_file_is_not_overwritten_without_force(
    attached: FakeDevice, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """And the device is never opened: the check is worth more before the read."""
    written = tmp_path / "pulled.KeyStepPro"
    written.write_text("mine")

    assert main([str(written)]) == 1

    assert "already exists" in capsys.readouterr().err
    assert written.read_text() == "mine"
    assert not attached.slots[1].asked

    assert main([str(written), "--force"]) == 0
    assert written.read_text() != "mine"


def test_a_slot_with_nothing_saved_in_it_is_refused(
    monkeypatch: pytest.MonkeyPatch,
    fixtures_dir: Path,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Filler parses as a valid empty project, so it has to be caught here."""
    empty = FakeDevice({3: DeviceModel(tape_values(fixtures_dir / "recall_tape.txt"))}, filler={3})
    monkeypatch.setattr(pull, "UsbMidiTransport", lambda **_: empty)

    written = tmp_path / "pulled.KeyStepPro"
    assert main([str(written), "--slot", "3"]) == 1

    assert "slot 3" in capsys.readouterr().err
    assert not written.exists()


def test_a_device_that_is_not_there_fails_with_its_own_message(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    def refuse(**_: object) -> FakeDevice:
        raise TransportError("no KeyStep Pro at 0x1c75:0x0218")

    monkeypatch.setattr(pull, "UsbMidiTransport", refuse)

    assert main([str(tmp_path / "pulled.KeyStepPro")]) == 1
    assert "no KeyStep Pro" in capsys.readouterr().err


def test_a_slot_outside_the_sixteen_is_a_usage_error(attached: FakeDevice, tmp_path: Path) -> None:
    assert main([str(tmp_path / "pulled.KeyStepPro"), "--slot", "17"]) == 2


def test_an_unreadable_template_stops_before_the_device(
    attached: FakeDevice, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    missing = tmp_path / "nowhere.KeyStepPro"

    assert main([str(tmp_path / "pulled.KeyStepPro"), "--template", str(missing)]) == 1

    assert "template" in capsys.readouterr().err
    assert not attached.slots[1].asked


def test_ksp_pull_is_the_same_command_either_way(attached: FakeDevice, tmp_path: Path) -> None:
    direct = tmp_path / "direct.KeyStepPro"
    umbrella = tmp_path / "umbrella.KeyStepPro"

    assert main([str(direct)]) == 0
    assert app.main(["ksp-pull", str(umbrella)]) == 0

    assert direct.read_bytes() == umbrella.read_bytes()


def test_also_midi_writes_the_project_and_its_midi_from_one_read(
    attached: FakeDevice, tmp_path: Path
) -> None:
    written = tmp_path / "pulled.KeyStepPro"

    assert main([str(written), "--also-midi"]) == 0

    assert written.exists()
    assert written.with_suffix(".mid").exists()
    assert len(attached.slots[1].asked) == 1007


def test_the_exported_midi_is_the_file_ksp2midi_would_have_written(
    attached: FakeDevice, tmp_path: Path
) -> None:
    """--also-midi composes the two commands; it does not export differently."""
    composed = tmp_path / "composed.KeyStepPro"
    assert main([str(composed), "--also-midi"]) == 0

    separate = tmp_path / "separate.mid"
    assert app.main(["ksp2midi", str(composed), "-o", str(separate)]) == 0

    assert composed.with_suffix(".mid").read_bytes() == separate.read_bytes()


def test_also_midi_names_both_files_in_the_summary(
    attached: FakeDevice, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    written = tmp_path / "pulled.KeyStepPro"
    assert main([str(written), "--also-midi"]) == 0

    out = capsys.readouterr().out
    assert f"wrote {written}" in out
    assert f"wrote {written.with_suffix('.mid')}" in out
    assert "note(s) from pattern(s)" in out


def test_an_existing_midi_stops_the_read_the_way_an_existing_project_does(
    attached: FakeDevice, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """Both destinations are checked before the device is touched, and --force covers both."""
    written = tmp_path / "pulled.KeyStepPro"
    midi = written.with_suffix(".mid")
    midi.write_bytes(b"mine")

    assert main([str(written), "--also-midi"]) == 1

    assert str(midi) in capsys.readouterr().err
    assert not written.exists()
    assert midi.read_bytes() == b"mine"
    assert not attached.slots[1].asked

    assert main([str(written), "--also-midi", "--force"]) == 0
    assert midi.read_bytes() != b"mine"


def test_a_project_with_no_notes_keeps_the_pull_and_refuses_the_midi(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    """The read is worth keeping; a MIDI file with nothing in it would look like success."""
    silent = FakeDevice({1: DeviceModel(_template_values())})
    monkeypatch.setattr(pull, "UsbMidiTransport", lambda **_: silent)

    written = tmp_path / "silent.KeyStepPro"
    assert main([str(written), "--also-midi"]) == 1

    assert "no pattern holds notes" in capsys.readouterr().err
    assert written.exists()
    assert not written.with_suffix(".mid").exists()
