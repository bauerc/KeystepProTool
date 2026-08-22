"""The drum note pool has holes, and the melodic note list does not."""

import pytest

from ksp import constants
from ksp.model import NoteKind
from ksp.reader import load

PROJECTS = (
    "Default.KeyStepPro",
    "initial_project.KeyStepPro",
    "project_5.KeyStepPro",
    "project_9.KeyStepPro",
    "user_empty_project.KeyStepPro",
)


@pytest.fixture(scope="module")
def initial_project(project_files_dir):  # type: ignore[no-untyped-def]
    return load(project_files_dir / "initial_project.KeyStepPro")


def _drum_notes(project, pattern_number: int):  # type: ignore[no-untyped-def]
    pattern = project.tracks[0].patterns[pattern_number - 1]
    return [n for n in pattern.notes if n.kind is NoteKind.DRUM]


@pytest.mark.parametrize(("pattern", "expected"), [(5, 42), (9, 49)])
def test_patterns_with_holes_read_their_whole_pool(  # type: ignore[no-untyped-def]
    initial_project, pattern: int, expected: int
) -> None:
    """Pattern 5 read 27 of 42 before the fix, and pattern 9 read 21 of 49."""
    assert len(_drum_notes(initial_project, pattern)) == expected


def test_pattern_5_recovers_the_lane_12_and_lane_17_runs(initial_project) -> None:  # type: ignore[no-untyped-def]
    """The specific notes finding 4 identified, so a regression is legible."""
    notes = _drum_notes(initial_project, 5)
    for lane in (12, 17):
        in_lane = [n for n in notes if n.pitch == lane]
        assert sorted(n.step for n in in_lane) == [5, 13, 21, 29, 37, 45, 53, 57, 61]
        # Every one is flagged, which is what makes them live rather than stale.
        assert all(n.active for n in in_lane)
        assert max(n.index for n in in_lane) > 28, "these are the entries past the hole"


def test_pattern_9_recovers_the_lane_7_and_lane_19_runs(initial_project) -> None:  # type: ignore[no-untyped-def]
    notes = _drum_notes(initial_project, 9)
    lane_7 = [n for n in notes if n.pitch == 7]
    lane_19 = [n for n in notes if n.pitch == 19]
    assert sorted(n.step for n in lane_7) == [36, 40, 41, 42, 43, 44, 45, 46, 47, 48]
    assert sorted(n.step for n in lane_19) == [33, 36, 40, 44, 48]
    assert all(n.active for n in lane_7 + lane_19)


def test_the_false_alarms_are_gone(initial_project) -> None:  # type: ignore[no-untyped-def]
    """Both warning classes the truncated scan produced."""
    warnings = [w for p in initial_project.tracks[0].patterns for w in p.warnings]
    assert not any("after the end of the note list" in w for w in warnings)
    assert not any("flagged active but hold no note" in w for w in warnings)
    assert any("disabled note(s), step turned off" in w for w in warnings)


@pytest.mark.parametrize("name", PROJECTS)
def test_every_flagged_drum_step_has_a_pooled_note(  # type: ignore[no-untyped-def]
    project_files_dir, load_sample, name: str
) -> None:
    """Finding 5's invariant: `52` is a subset of the pool, never a superset."""
    raw = load_sample(name)
    project = load(project_files_dir / name)
    for pattern in project.tracks[0].patterns:
        pooled = {(n.pitch, n.step) for n in pattern.notes if n.kind is NoteKind.DRUM}
        flagged = _decode_flags(raw, pattern.number)
        assert flagged <= pooled, (
            f"{name} pattern {pattern.number}: flagged without a note {sorted(flagged - pooled)}"
        )


def _decode_flags(raw, pattern: int) -> set[tuple[int, int]]:  # type: ignore[no-untyped-def]
    """Unpack `52` straight from the file, independently of the reader."""
    item_id = constants.DRUM_TRACK_ITEM_ID
    flagged: set[tuple[int, int]] = set()
    for lane in range(constants.DRUM_LANE_COUNT):
        for step in range(constants.MAX_STEPS):
            slot, index, bit = constants.drum_step_active_indices(lane, step)
            value = raw.get(f"{item_id}_{constants.P_DRUM_STEP_ACTIVE}_{pattern}_{slot}_{index}")
            if value is not None and value >> bit & 1:
                flagged.add((lane, step + 1))
    return flagged


@pytest.mark.parametrize("name", PROJECTS)
def test_no_melodic_slot_holds_data_after_a_sentinel(load_sample, name: str) -> None:  # type: ignore[no-untyped-def]
    """Why the melodic scan may keep stopping at the first ``127``."""
    raw = load_sample(name)
    for item_id in constants.TRACK_ITEM_IDS:
        for pattern in range(1, constants.PATTERNS_PER_TRACK + 1):
            for slot in range(1, constants.SLOTS_BY_ITEM[item_id] + 1):
                seen_sentinel = False
                for index in range(1, constants.MAX_STEPS + 1):
                    key = f"{item_id}_{constants.P_SEQ_NOTE_STEP}_{pattern}_{slot}_{index}"
                    value = raw.get(key)
                    if value is None:
                        break
                    if value == constants.SENTINEL:
                        seen_sentinel = True
                    elif seen_sentinel:
                        pytest.fail(f"{name}: {key} = {value} sits after a sentinel")


def test_the_drum_pool_really_does_hold_holes(load_sample) -> None:  # type: ignore[no-untyped-def]
    """The other half of the asymmetry, asserted directly."""
    raw = load_sample("initial_project.KeyStepPro")
    item_id = constants.DRUM_TRACK_ITEM_ID
    holes = 0
    for pattern in (5, 9):
        seen_sentinel = False
        for index in range(1, constants.MAX_STEPS + 1):
            value = raw.get(f"{item_id}_{constants.P_DRUM_NOTE_STEP}_{pattern}_1_{index}")
            if value == constants.SENTINEL:
                seen_sentinel = True
            elif seen_sentinel and value is not None:
                holes += 1
    assert holes, "initial_project patterns 5 and 9 are the corpus's only holed pools"


#: Every concrete key/value the spec quotes in section 4's "Why a note might not play"
#: table, so an edit to either side cannot leave the spec quoting values that do not exist.
SPEC_EXAMPLES = {
    "initial_project.KeyStepPro": {
        # Row 1: a hole, with live notes either side of it.
        "123_54_9_1_21": 42,
        "123_54_9_1_22": 127,
        "123_54_9_1_25": 44,
        # Row 2: lane 0 step 5 off, lane 0 step 9 on.
        "123_52_9_1_1": 0,
        "123_52_9_1_2": 2,
        # Row 3: 48 steps declared, a note at step 57.
        "123_115_9": 47,
        "123_54_9_1_45": 56,
    },
    "project_5.KeyStepPro": {
        # Row 5: a mask of {16, 48}, against the "always" default.
        "125_49_1_1_5": 5,
        "125_49_1_1_1": 15,
        # Row 6: randomness below the fresh-note default of 100.
        "125_113_1_1_1": 10,
    },
}


@pytest.mark.parametrize("name", sorted(SPEC_EXAMPLES))
def test_the_spec_quotes_values_the_files_actually_hold(load_sample, name: str) -> None:  # type: ignore[no-untyped-def]
    raw = load_sample(name)
    for key, expected in SPEC_EXAMPLES[name].items():
        assert raw.get(key) == expected, f"spec section 4 says {key} = {expected}"


def test_the_specs_worked_bit_arithmetic_lands_on_the_key_it_claims() -> None:
    """Section 4 walks lane 0, 0-based step 4 through to `123_52_9_1_1` bit 4."""
    assert constants.drum_step_active_indices(0, 4) == (1, 1, 4)
