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
def analysis_dir() -> Path:
    """Format spec and the hardware-confirmed project descriptions."""
    return REPO_ROOT / "analysis"


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
    """The sample's bytes exactly as MCC wrote them.

    Session-scoped: these are 3.5 MB apiece and read by two dozen tests.
    ``bytes`` are immutable, so sharing one across tests cannot leak.
    """
    path = project_files_dir / sample_name
    assert path.is_file(), f"missing sample project: {path}"
    return path.read_bytes()


@pytest.fixture(scope="session")
def _parsed_samples() -> dict[str, dict[str, int | str]]:
    """Backing store for :func:`load_sample`. Never handed to a test."""
    return {}


@pytest.fixture
def load_sample(
    _parsed_samples: dict[str, dict[str, int | str]], project_files_dir: Path
) -> Callable[[str], dict[str, int | str]]:
    """Parse a sample once per session, returning a fresh copy each call.

    Parsing costs 25 ms and copying the result costs 0.4 ms. The copy is not an
    optimisation detail but the safety property: tests mutate what they are
    given -- injecting a ``version`` key, editing a pitch -- and a shared dict
    would carry that into whatever ran next.
    """

    def load(name: str) -> dict[str, int | str]:
        if name not in _parsed_samples:
            _parsed_samples[name] = lenient_json.load_path(project_files_dir / name)
        return dict(_parsed_samples[name])

    return load
