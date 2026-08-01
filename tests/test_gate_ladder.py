"""``GATE_TABLE`` against the hardware transcription it was derived from.

``constants.GATE_TABLE`` enumerates 128 entries from five run lengths rather
than listing them, which is compact but puts a rule between the code and the
measurement. These tests close that gap: they read
``analysis/gate_display_sweep.txt`` -- values transcribed off the device
display and unregenerable without it -- and check the enumeration reproduces
every one.

The file records the device's 2-decimal rendering, not the exact quantity, so
the comparison rounds the exact binary fraction the same way the display does
(half to even: 0.625 shows as 0.62, 0.875 as 0.88).
"""

from itertools import pairwise
from pathlib import Path

import pytest

from ksp import constants

SWEEP_FILE = "gate_display_sweep.txt"

#: The six points that were known before the sweep, from the projects
#: themselves. They are the cross-check from a different direction: a table
#: built off the sweep alone could be shifted by a detent and still look
#: self-consistent, but not while it still reproduces these.
PRE_SWEEP_POINTS = {7: 0.5, 11: 1.0, 19: 2.0, 27: 3.0, 29: 3.5, 31: 4.0}

#: Stored 36 was the sweep's one derived rung -- that note had been over-turned
#: by a detent, so its display was transcribed but its stored pairing was
#: positional. Capture D25-gate-capture closed it: one note at display 5.25,
#: storing 124_110_1_1_1 = 36. Same role as the points above, from a capture
#: taken after the sweep rather than before it.
POST_SWEEP_POINTS = {36: 5.25}


def read_sweep(analysis_dir: Path) -> dict[str, list[str]]:
    """Parse the sweep into ``{"melodic": [...], "drum": [...]}``.

    Section header opens a list; every following non-comment, non-blank line
    is one displayed value in detent order.
    """
    sections: dict[str, list[str]] = {}
    current: list[str] | None = None
    for raw in (analysis_dir / SWEEP_FILE).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line in ("melodic", "drum"):
            current = sections.setdefault(line, [])
        elif current is not None:
            current.append(line)
    return sections


@pytest.fixture(scope="module")
def sweep(analysis_dir: Path) -> dict[str, list[str]]:
    return read_sweep(analysis_dir)


def test_the_ladder_covers_every_legal_stored_value() -> None:
    """0-127 with no holes. A hole would silently become a default gate."""
    assert sorted(constants.GATE_TABLE) == list(range(128))


def test_the_ladder_spans_the_encoder_range(sweep: dict[str, list[str]]) -> None:
    """0.0625 to 64 steps, closing exactly on stored 127 -- the closure is what
    count-verifies the enumerated upper detents."""
    assert constants.GATE_TABLE[0] == 0.0625
    assert constants.GATE_TABLE[127] == 64.0
    assert len(sweep["melodic"]) == 128


def test_the_ladder_is_strictly_increasing() -> None:
    lengths = [constants.GATE_TABLE[stored] for stored in range(128)]
    assert all(a < b for a, b in pairwise(lengths))


def test_every_transcribed_detent_matches_the_table(sweep: dict[str, list[str]]) -> None:
    """The whole point: stored = detent index - 1, for all 128 rungs."""
    mismatches = [
        (stored, displayed, constants.GATE_TABLE[stored])
        for stored, displayed in enumerate(sweep["melodic"])
        if round(constants.GATE_TABLE[stored], 2) != float(displayed)
    ]
    assert not mismatches


@pytest.mark.parametrize(("stored", "expected"), sorted(PRE_SWEEP_POINTS.items()))
def test_the_points_known_before_the_sweep_still_hold(stored: int, expected: float) -> None:
    assert constants.GATE_TABLE[stored] == expected


@pytest.mark.parametrize(("stored", "expected"), sorted(POST_SWEEP_POINTS.items()))
def test_the_points_measured_after_the_sweep_hold(stored: int, expected: float) -> None:
    assert constants.GATE_TABLE[stored] == expected


def test_the_drum_ladder_is_the_melodic_one(sweep: dict[str, list[str]]) -> None:
    """T2.3 spot-checked five drum detents and found no divergence, so the
    section is empty by design. If a future capture fills it, this fails and
    the drum gate needs its own table -- which ``reader`` currently assumes it
    does not (``118`` decodes through ``decode_gate`` like ``110``)."""
    assert sweep.get("drum", []) == []
