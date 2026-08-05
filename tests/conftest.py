"""Shared path fixtures.

Tests resolve repository data through these rather than hardcoding paths, so
that moving sample files is a one-line change here.
"""

from collections.abc import Callable
from pathlib import Path

import pytest

from ksp import lenient_json

REPO_ROOT = Path(__file__).resolve().parent.parent

#: Every sample project checked in, in the order they appear on disk. Both the
#: byte-level invariants and the M3 round-trip parametrise over all of them.
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
    """Resolve a capture by name, or skip.

    Skipping rather than failing keeps ``-m hardware`` runnable on a fresh
    clone: the file is genuinely absent there, and failing would conflate "not
    captured yet" with "the capture disagrees". The protocol's checkbox is what
    records that a capture was taken -- a green run is not.
    """

    def resolve(name: str) -> Path:
        path = captures_dir / name
        if not path.is_file():
            pytest.skip(f"no {name}; see analysis/Hardware_Test_Protocol.md")
        return path

    return resolve


@pytest.fixture(scope="session")
def fixtures_dir() -> Path:
    """Expected-value fixtures, stored as data so a future Swift port can
    consume the identical files. See ROADMAP.md M1."""
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
    """MCC's bytes minus the comma before the closing brace -- the M3 target.

    Protocol test T6.2 showed MCC does not need that comma, so the writer omits
    it and its output is strict JSON. Every other byte must still match, which
    is what the round-trip tests compare against. Asserting the comma is there
    to begin with keeps a mangled sample from silently becoming the baseline.
    """
    assert data.endswith(b",\n}"), "sample does not end with MCC's trailing comma"
    return data[:-3] + b"\n}"


@pytest.fixture(scope="session")
def sample_bytes_strict(sample_bytes: bytes) -> bytes:
    """The sample as this writer emits it. See :func:`without_trailing_comma`."""
    return without_trailing_comma(sample_bytes)


@pytest.fixture(scope="session")
def _parsed_samples() -> dict[str, dict[str, int | str]]:
    return {}


@pytest.fixture
def load_sample(
    _parsed_samples: dict[str, dict[str, int | str]], project_files_dir: Path
) -> Callable[[str], dict[str, int | str]]:
    """Parse a sample once per session, returning a fresh copy each call.

    The copy is the point: tests mutate what they are given.
    """

    def load(name: str) -> dict[str, int | str]:
        if name not in _parsed_samples:
            _parsed_samples[name] = lenient_json.load_path(project_files_dir / name)
        return dict(_parsed_samples[name])

    return load


def load_tape(fixtures_dir: Path) -> list[tuple[bytes, bytes]]:
    """The captured exchange as ``(request, reply)`` frame pairs, in order.

    Tracked on purpose: the raw capture is gitignored, so a test bound to it
    would skip silently in every worktree and on every fresh clone.
    """
    pairs = []
    for line in (fixtures_dir / "recall_tape.txt").read_text().splitlines():
        request, reply = line.split()
        pairs.append((bytes.fromhex(request), bytes.fromhex(reply)))
    return pairs


class ReplayTransport:
    """Answers out of a captured exchange, keyed by the request frame.

    Keyed rather than sequential, so a plan that asks for the right things in
    the wrong order still resolves -- and ``asked`` is what proves the order.
    """

    def __init__(self, pairs: list[tuple[bytes, bytes]]) -> None:
        self._replies = dict(pairs)
        self.asked: list[bytes] = []

    def exchange(self, request: bytes) -> bytes:
        self.asked.append(request)
        try:
            return self._replies[request]
        except KeyError:
            raise LookupError(f"no captured reply for {request.hex()}") from None


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
