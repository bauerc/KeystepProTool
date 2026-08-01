"""``GATE_TABLE`` against the hardware transcription it was derived from.

``constants.GATE_TABLE`` enumerates 128 entries from five run lengths rather
than listing them, which is compact but puts a rule between the code and the
measurement. These tests close that gap: they read ``analysis/gate_ladder.txt``
-- values transcribed off the device display and unregenerable without it --
and check the enumeration reproduces every one.

The file records the device's 2-decimal rendering, not the exact quantity, so
the comparison rounds the exact binary fraction the same way the display does
(half to even: 0.625 shows as 0.62, 0.875 as 0.88).
"""

from itertools import pairwise
from pathlib import Path

import pytest

from ksp import constants

LADDER_FILE = "gate_ladder.txt"

#: Points known from somewhere other than the ladder transcription -- the
#: cross-check from a different direction. A table built off the sweep alone
#: could be shifted by a detent and still look self-consistent, but not while it
#: still reproduces these. Six came from the sample projects before the sweep;
#: stored 36 came after it, from capture D25-gate-capture -- one note at display
#: 5.25 storing ``124_110_1_1_1`` = 36 -- which closed the ladder's last derived
#: rung.
CROSS_CHECK_POINTS = {7: 0.5, 11: 1.0, 19: 2.0, 27: 3.0, 29: 3.5, 31: 4.0, 36: 5.25}


def read_ladder(analysis_dir: Path) -> dict[str, list[tuple[str, str]]]:
    """Parse into ``{"melodic": [(display, provenance), ...], "drum": [...]}``.

    Section header opens a list; every following non-comment, non-blank line is
    one detent, in order.
    """
    sections: dict[str, list[tuple[str, str]]] = {}
    current: list[tuple[str, str]] | None = None
    for raw in (analysis_dir / LADDER_FILE).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line in ("melodic", "drum"):
            current = sections.setdefault(line, [])
        elif current is not None:
            display, provenance = line.split()
            current.append((display, provenance))
    return sections


@pytest.fixture(scope="module")
def ladder(analysis_dir: Path) -> dict[str, list[tuple[str, str]]]:
    return read_ladder(analysis_dir)


def test_the_ladder_covers_every_legal_stored_value() -> None:
    """0-127 with no holes. A hole would silently become a default gate."""
    assert sorted(constants.GATE_TABLE) == list(range(128))


def test_the_ladder_spans_the_encoder_range(ladder: dict[str, list[tuple[str, str]]]) -> None:
    """0.0625 to 64 steps, closing exactly on stored 127 -- the closure is what
    count-verifies the enumerated upper detents."""
    assert constants.GATE_TABLE[0] == 0.0625
    assert constants.GATE_TABLE[127] == 64.0
    assert len(ladder["melodic"]) == 128


def test_the_ladder_is_strictly_increasing() -> None:
    lengths = [constants.GATE_TABLE[stored] for stored in range(128)]
    assert all(a < b for a, b in pairwise(lengths))


def test_every_transcribed_detent_matches_the_table(
    ladder: dict[str, list[tuple[str, str]]],
) -> None:
    """The whole point: stored = detent index - 1, for all 128 rungs."""
    mismatches = [
        (stored, displayed, constants.GATE_TABLE[stored])
        for stored, (displayed, _) in enumerate(ladder["melodic"])
        if round(constants.GATE_TABLE[stored], 2) != float(displayed)
    ]
    assert not mismatches


@pytest.mark.parametrize(("stored", "expected"), sorted(CROSS_CHECK_POINTS.items()))
def test_the_cross_check_points_hold(stored: int, expected: float) -> None:
    assert constants.GATE_TABLE[stored] == expected


def test_no_rung_is_still_derived(ladder: dict[str, list[tuple[str, str]]]) -> None:
    """Every rung is either read off the device or enumerated from the increment
    rule. D25-gate-capture closed the last derived one (stored 36); a rung
    reappearing as "derived" means a capture regressed."""
    assert {provenance for _, provenance in ladder["melodic"]} == {"measured", "enumerated"}


def test_the_cross_check_points_are_all_measured(
    ladder: dict[str, list[tuple[str, str]]],
) -> None:
    """The constant and the file must not disagree about what was measured -- a
    cross-check point resting on an enumerated rung would be circular."""
    provenance = [prov for _, prov in ladder["melodic"]]
    assert all(provenance[stored] == "measured" for stored in CROSS_CHECK_POINTS)


def test_the_drum_ladder_is_the_melodic_one(ladder: dict[str, list[tuple[str, str]]]) -> None:
    """T2.3 spot-checked five drum detents and found no divergence, so the
    section is empty by design. If a future capture fills it, this fails and
    the drum gate needs its own table -- which ``reader`` currently assumes it
    does not (``118`` decodes through ``decode_gate`` like ``110``)."""
    assert ladder.get("drum", []) == []
