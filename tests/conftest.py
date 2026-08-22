"""Shared path fixtures."""

import json
from collections.abc import Callable
from pathlib import Path

import pytest

from ksp import bulk_read, lenient_json, sysex
from ksp.sysex import ReadRequest
from ksp_cli.usb_transport import TransportError

REPO_ROOT = Path(__file__).resolve().parent.parent

#: Every sample project checked in, in the order they appear on disk.
SAMPLE_NAMES = [
    "Default.KeyStepPro",
    "baseline.KeyStepPro",
    "initial_project.KeyStepPro",
    "project_5.KeyStepPro",
    "project_9.KeyStepPro",
    "user_empty_project.KeyStepPro",
]


@pytest.fixture(scope="session")
def repo_root() -> Path:
    """Repository root."""
    return REPO_ROOT


@pytest.fixture(scope="session")
def project_files_dir() -> Path:
    """Sample ``.KeyStepPro`` projects exported from real hardware."""
    return REPO_ROOT / "project_files"


@pytest.fixture(scope="session")
def simple_clip(project_files_dir: Path) -> Path:
    """16 monophonic 1/16 notes on a clean grid. M5's conversion fixture."""
    return project_files_dir / "test_file_simple.mid"


@pytest.fixture(scope="session")
def m6_song(project_files_dir: Path) -> Path:
    """M6's conversion fixture: four note-bearing tracks of real material."""
    return project_files_dir / "m6-test-file.mid"


@pytest.fixture(scope="session")
def chord_clip(project_files_dir: Path) -> Path:
    """The same length of material with three-note chords in it."""
    return project_files_dir / "test_file.mid"


@pytest.fixture(scope="session")
def analysis_dir() -> Path:
    """Format spec and the hardware-confirmed project descriptions."""
    return REPO_ROOT / "analysis"


@pytest.fixture(scope="session")
def captures_dir() -> Path:
    """Hardware captures. Gitignored, so present only on the operator's machine."""
    return REPO_ROOT / "project_files" / "captures"


@pytest.fixture
def require_capture(captures_dir: Path) -> Callable[[str], Path]:
    """Resolve a capture by name, or skip."""

    def resolve(name: str) -> Path:
        path = captures_dir / name
        if not path.is_file():
            pytest.skip(f"no {name}; see analysis/Hardware_Test_Protocol.md")
        return path

    return resolve


@pytest.fixture(scope="session")
def fixtures_dir() -> Path:
    """Expected-value fixtures, stored as data so a future Swift port can consume the identical
    files.
    """
    return Path(__file__).resolve().parent / "fixtures"


@pytest.fixture(params=SAMPLE_NAMES, scope="session")
def sample_name(request: pytest.FixtureRequest) -> str:
    """Each sample project in turn."""
    return str(request.param)


@pytest.fixture(scope="session")
def sample_bytes(sample_name: str, project_files_dir: Path) -> bytes:
    """The sample's bytes exactly as MCC wrote them."""
    path = project_files_dir / sample_name
    assert path.is_file(), f"missing sample project: {path}"
    return path.read_bytes()


def without_trailing_comma(data: bytes) -> bytes:
    """MCC's bytes minus the comma before the closing brace -- the M3 target."""
    assert data.endswith(b",\n}"), "sample does not end with MCC's trailing comma"
    return data[:-3] + b"\n}"


@pytest.fixture(scope="session")
def _parsed_samples() -> dict[str, dict[str, int | str]]:
    return {}


@pytest.fixture
def load_sample(
    _parsed_samples: dict[str, dict[str, int | str]], project_files_dir: Path
) -> Callable[[str], dict[str, int | str]]:
    """Parse a sample once per session, returning a fresh copy each call."""

    def load(name: str) -> dict[str, int | str]:
        if name not in _parsed_samples:
            _parsed_samples[name] = lenient_json.load_path(project_files_dir / name)
        return dict(_parsed_samples[name])

    return load


def load_tape(fixtures_dir: Path) -> list[tuple[bytes, bytes]]:
    """The captured exchange as ``(request, reply)`` frame pairs, in order."""
    pairs = []
    for line in (fixtures_dir / "recall_tape.txt").read_text().splitlines():
        request, reply = line.split()
        pairs.append((bytes.fromhex(request), bytes.fromhex(reply)))
    return pairs


class ReplayTransport:
    """Answers out of a captured exchange, keyed by the request frame."""

    def __init__(self, pairs: list[tuple[bytes, bytes]]) -> None:
        self._replies = dict(pairs)
        self.asked: list[bytes] = []
        self.sent: list[bytes] = []

    def send(self, frame: bytes) -> None:
        """The prologue, which the device never answers."""
        self.sent.append(frame)

    def exchange(self, request: bytes) -> bytes:
        self.asked.append(request)
        try:
            return self._replies[request]
        except KeyError:
            raise LookupError(f"no captured reply for {request.hex()}") from None


def decode_request(frame: bytes) -> ReadRequest:
    body = frame[6:-1]
    if body[0] == sysex.CMD_SCALAR:
        return ReadRequest(item=body[3], param=body[2], indices=(), count=None)
    count = body[3]
    return ReadRequest(
        item=body[4], param=body[2], indices=tuple(body[5 : 5 + count]), count=body[5 + count]
    )


def build_reply(
    request: ReadRequest, values: tuple[int, ...], slot: int = sysex.DEFAULT_SLOT
) -> bytes:
    if request.count is None:
        body = (sysex.CMD_SCALAR_REPLY, slot, request.param, request.item, *values)
    else:
        body = (
            sysex.CMD_READ_REPLY,
            slot,
            request.param,
            len(request.indices),
            request.item,
            *request.indices,
            request.count,
            *values,
        )
    return sysex.HEADER + bytes(body) + bytes((sysex.END,))


def tape_values(path: Path) -> dict[str, int]:
    """Every address a tape delivered, as the device sent it."""
    values: dict[str, int] = {}
    for line in path.read_text().splitlines():
        sent, received = line.split()
        request, payload = sysex.parse_reply(bytes.fromhex(received))
        assert request == decode_request(bytes.fromhex(sent))
        for name, value in zip(bulk_read.keys_for(request), payload, strict=True):
            values[name] = value
    return values


class DeviceModel:
    """Answers any address from a tape's values, at any count the device allows."""

    def __init__(self, values: dict[str, int]) -> None:
        self._values = values
        self.asked: list[ReadRequest] = []
        self.slots: set[int] = set()
        self.sent: list[bytes] = []

    def send(self, frame: bytes) -> None:
        """The prologue, which the device never answers."""
        self.sent.append(frame)

    def exchange(self, frame: bytes) -> bytes:
        request = decode_request(frame)
        self.asked.append(request)
        self.slots.add(sysex.parse_slot(frame))
        names = bulk_read.keys_for(request)
        missing = [name for name in names if name not in self._values]
        if missing:
            raise LookupError(f"tape holds no value for {missing[0]}")
        # Echo the slot asked about, so bulk_read's check of it is exercised.
        return build_reply(
            request, tuple(self._values[name] for name in names), sysex.parse_slot(frame)
        )


class FakeDevice:
    """A ``UsbMidiTransport`` whose slots are tapes, for the probes and the pull."""

    def __init__(
        self,
        slots: dict[int, "DeviceModel"],
        filler: set[int] | None = None,
        # Stands in for the real transport, so it takes its tuning and ignores it.
        **_: object,
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


@pytest.fixture(scope="session")
def recall_tape(fixtures_dir: Path) -> list[tuple[bytes, bytes]]:
    return load_tape(fixtures_dir)


@pytest.fixture
def replay_transport(
    recall_tape: list[tuple[bytes, bytes]],
) -> Callable[..., ReplayTransport]:
    """Build a transport over the tape, or over a doctored copy of it."""

    def build(pairs: list[tuple[bytes, bytes]] | None = None) -> ReplayTransport:
        return ReplayTransport(recall_tape if pairs is None else pairs)

    return build


@pytest.fixture(scope="session")
def identity_reply(repo_root: Path) -> bytes:
    """Frame 9 of the capture, the device's answer to the identity request."""
    capture = repo_root / "usb_midi_investigation" / "sysex_until_project_1_track_1_pattern_1.jsonl"
    for line in capture.read_text().splitlines():
        frame = json.loads(line)
        if frame["frame_number"] == 9:
            return bytes.fromhex(frame["sysex_hex"])
    raise AssertionError(f"no frame 9 in {capture}")
