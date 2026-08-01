"""``GATE_TABLE`` against the hardware transcription it came from.

``GATE_TABLE`` enumerates 128 entries from five run lengths rather than listing
them, so these tests check that rule reproduces every transcribed row. The file
holds the device's 2-decimal rendering, so the comparison rounds the exact
binary fraction the same way (half to even: 0.625 shows as 0.62).
"""

from itertools import pairwise
from pathlib import Path

import pytest

from ksp import constants

LADDER_FILE = "gate_ladder.txt"

#: Entries known independently of the transcription -- six from the sample
#: projects, stored 36 from capture D25-gate-capture. A ladder shifted by a
#: detent would still look self-consistent, but would not reproduce these.
CROSS_CHECK_POINTS = {7: 0.5, 11: 1.0, 19: 2.0, 27: 3.0, 29: 3.5, 31: 4.0, 36: 5.25}


def read_ladder(analysis_dir: Path) -> list[tuple[str, str]]:
    """Parse into ``[(display, provenance)]``, one row per detent."""
    rows = []
    for raw in (analysis_dir / LADDER_FILE).read_text().splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            display, provenance = line.split()
            rows.append((display, provenance))
    return rows


@pytest.fixture(scope="module")
def ladder(analysis_dir: Path) -> list[tuple[str, str]]:
    return read_ladder(analysis_dir)


def test_the_ladder_covers_every_legal_stored_value() -> None:
    """0-127 with no holes. A hole would silently become a default gate."""
    assert sorted(constants.GATE_TABLE) == list(range(128))


def test_the_ladder_spans_the_encoder_range(ladder: list[tuple[str, str]]) -> None:
    """0.0625 to 64 steps. The exact closure on 127 count-verifies the
    enumerated upper detents."""
    assert constants.GATE_TABLE[0] == 0.0625
    assert constants.GATE_TABLE[127] == 64.0
    assert len(ladder) == 128


def test_the_ladder_is_strictly_increasing() -> None:
    lengths = [constants.GATE_TABLE[stored] for stored in range(128)]
    assert all(a < b for a, b in pairwise(lengths))


def test_every_transcribed_detent_matches_the_table(ladder: list[tuple[str, str]]) -> None:
    """The whole point: stored = detent index - 1, for all 128 rungs."""
    mismatches = [
        (stored, displayed, constants.GATE_TABLE[stored])
        for stored, (displayed, _) in enumerate(ladder)
        if round(constants.GATE_TABLE[stored], 2) != float(displayed)
    ]
    assert not mismatches


@pytest.mark.parametrize(("stored", "expected"), sorted(CROSS_CHECK_POINTS.items()))
def test_the_cross_check_points_hold(stored: int, expected: float) -> None:
    assert constants.GATE_TABLE[stored] == expected


def test_no_rung_is_still_derived(ladder: list[tuple[str, str]]) -> None:
    """Every rung is read off the device or enumerated from the increment rule;
    D25-gate-capture closed the last derived one."""
    assert {provenance for _, provenance in ladder} == {"measured", "enumerated"}


def test_the_cross_check_points_are_all_measured(ladder: list[tuple[str, str]]) -> None:
    """A cross-check point resting on an enumerated rung would be circular."""
    provenance = [prov for _, prov in ladder]
    assert all(provenance[stored] == "measured" for stored in CROSS_CHECK_POINTS)
