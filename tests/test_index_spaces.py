"""Invariants for the index spaces MCC's ``bulkOperation`` descriptors declare.

The spec was originally written from ``KeyStepPro.json`` -> ``fields[]``, which
names parameters but says nothing about their *shape*. ``bulkOperation`` gives
the shape: for every parameter it declares which index ranges are addressable
and what each index means. Reading it corrected five claims, and these tests
pin each correction to the sample files so it cannot silently regress.

Every assertion here reads ``project_files/*.KeyStepPro`` directly rather than
going through the reader, so a reader bug cannot make them pass.
"""

from pathlib import Path
from typing import Any

import pytest

from ksp import constants, lenient_json
from ksp.model import NoteKind
from ksp.reader import load

SAMPLES = ("Default", "user_empty_project", "project_5", "project_9", "initial_project")

#: The two hardware-confirmed projects. Everywhere else the drum flags are a
#: strict subset of the pool (finding 5); here they match it exactly.
CONFIRMED = ("project_5", "project_9")


@pytest.fixture(scope="module")
def raw_projects(project_files_dir: Path) -> dict[str, dict[str, Any]]:
    return {
        name: lenient_json.load_path(project_files_dir / f"{name}.KeyStepPro") for name in SAMPLES
    }


def melodic_steps(raw: dict[str, Any], item: int, pattern: int) -> set[int]:
    """Steps carrying a melodic note, unioned over the three poly slots."""
    steps: set[int] = set()
    for slot in range(1, constants.SLOTS_PER_PATTERN + 1):
        for i in range(1, constants.MAX_STEPS + 1):
            value = raw.get(f"{item}_{constants.P_SEQ_NOTE_STEP}_{pattern}_{slot}_{i}")
            if value is None or value == constants.SENTINEL:
                break  # the melodic list is compacted, so a sentinel ends it
            steps.add(value + 1)
    return steps


def drum_pool(raw: dict[str, Any], pattern: int) -> dict[int, set[int]]:
    """Lane -> steps from the drum note pool, scanning past holes."""
    pool: dict[int, set[int]] = {}
    item = constants.DRUM_TRACK_ITEM_ID
    for slot in range(1, constants.SLOTS_PER_PATTERN + 1):
        for i in range(1, constants.MAX_STEPS + 1):
            step = raw.get(f"{item}_{constants.P_DRUM_NOTE_STEP}_{pattern}_{slot}_{i}")
            if step is None or step == constants.SENTINEL:
                continue  # a hole, not a terminator
            lane = raw[f"{item}_{constants.P_DRUM_PITCH}_{pattern}_{slot}_{i}"]
            pool.setdefault(lane, set()).add(step + 1)
    return pool


def drum_flags(raw: dict[str, Any], pattern: int) -> dict[int, set[int]]:
    """Lane -> steps from parameter 52, decoded via the flat 240-entry layout."""
    flags: dict[int, set[int]] = {}
    item = constants.DRUM_TRACK_ITEM_ID
    for n in range(constants.DRUM_STEP_ACTIVE_ENTRIES):
        slot, index = divmod(n, constants.MAX_STEPS)
        value = raw.get(f"{item}_{constants.P_DRUM_STEP_ACTIVE}_{pattern}_{slot + 1}_{index + 1}")
        if not value:
            continue
        lane, part = divmod(n, constants.DRUM_PARTS_PER_LANE)
        for bit in range(constants.DRUM_STEPS_PER_PART):
            if value >> bit & 1:
                flags.setdefault(lane, set()).add(part * constants.DRUM_STEPS_PER_PART + bit + 1)
    return flags


class TestPolySlots:
    """Finding 2: every track has three poly slots, Track 1 included."""

    @pytest.mark.parametrize("name", SAMPLES)
    def test_tracks_2_to_4_have_no_fourth_slot_at_all(
        self, raw_projects: dict[str, Any], name: str
    ) -> None:
        """The keys simply do not exist, which is the strongest form of proof."""
        raw = raw_projects[name]
        for item in (124, 125, 126):
            assert f"{item}_{constants.P_SEQ_NOTE_STEP}_1_4_1" not in raw

    @pytest.mark.parametrize("name", SAMPLES)
    def test_track_1_slot_4_exists_but_holds_no_note_data(
        self, raw_projects: dict[str, Any], name: str
    ) -> None:
        """Item 123 is dimensioned 16x4x64 so parameter 52 has room (finding 3).

        Every other parameter inherits that shape, so slot 4 of the note
        parameters is space nothing writes to -- which is why it is uniformly
        zero rather than sentinel-filled. It was never a fourth poly voice.
        """
        raw = raw_projects[name]
        for param in (constants.P_SEQ_NOTE_STEP, constants.P_DRUM_NOTE_STEP):
            values = {
                raw.get(f"{constants.DRUM_TRACK_ITEM_ID}_{param}_{p}_4_{i}")
                for p in range(1, constants.PATTERNS_PER_TRACK + 1)
                for i in range(1, constants.MAX_STEPS + 1)
            }
            assert values == {0}, f"{name} param {param}"

    def test_the_slot_count_is_uniform(self) -> None:
        assert constants.SLOTS_PER_PATTERN == 3


class TestStepActiveIsPerPattern:
    """Finding 1: 48 and 49 are indexed at slot 1 only; slots 2-4 are padding."""

    @pytest.mark.parametrize("name", SAMPLES)
    def test_slots_2_to_4_are_uniformly_zero(self, raw_projects: dict[str, Any], name: str) -> None:
        raw = raw_projects[name]
        values = {
            raw.get(f"{item}_{param}_{p}_{slot}_{i}")
            for item in constants.TRACK_ITEM_IDS
            for param in (constants.P_SEQ_STEP_ACTIVE, constants.P_SEQ_STEP_SKIP)
            for p in range(1, constants.PATTERNS_PER_TRACK + 1)
            for slot in (2, 3, 4)
            for i in range(1, constants.MAX_STEPS + 1)
        }
        assert values <= {0, None}, name

    @pytest.mark.parametrize("name", SAMPLES)
    def test_slot_1_flags_equal_the_union_of_note_steps(
        self, raw_projects: dict[str, Any], name: str
    ) -> None:
        """320 patterns across the corpus agree exactly, with no exceptions.

        Comparing 48 against a *single slot* is what produced the phantom
        step-active warnings on ``initial_project`` Track 3 pattern 3: the
        pattern uses three slots and no one of them holds every flagged step.
        """
        raw = raw_projects[name]
        for item in constants.TRACK_ITEM_IDS:
            for pattern in range(1, constants.PATTERNS_PER_TRACK + 1):
                flags = {
                    i
                    for i in range(1, constants.MAX_STEPS + 1)
                    if raw.get(f"{item}_{constants.P_SEQ_STEP_ACTIVE}_{pattern}_1_{i}") == 1
                }
                assert flags == melodic_steps(raw, item, pattern), f"{name} item {item} p{pattern}"


class TestDrumStepActive:
    """Finding 3: parameter 52 is a flat 240-entry lane-major bitmask."""

    def test_geometry_matches_the_descriptors(self) -> None:
        """24 lanes x 10 parts x 7 bits = 240 entries covering 70 steps."""
        assert constants.DRUM_STEP_ACTIVE_ENTRIES == 240
        assert constants.DRUM_LANE_COUNT * constants.DRUM_PARTS_PER_LANE == 240
        assert constants.DRUM_PARTS_PER_LANE * constants.DRUM_STEPS_PER_PART >= constants.MAX_STEPS

    def test_the_worked_example_decodes(self, raw_projects: dict[str, Any]) -> None:
        """``initial_project`` pattern 1 stores 17, 34 for lane 0 parts 0 and 1.

        17 = 0b0010001 -> bits 0, 4 -> steps 1, 5.
        34 = 0b0100010 -> bits 1, 5 -> steps 9, 13.

        Read as a per-slot 8-steps-per-index array -- the previous, wrong
        reading -- these values were unexplainable, which is why 52 was
        recorded as undecoded and blocking M5.
        """
        raw = raw_projects["initial_project"]
        assert raw[f"{constants.DRUM_TRACK_ITEM_ID}_{constants.P_DRUM_STEP_ACTIVE}_1_1_1"] == 17
        assert raw[f"{constants.DRUM_TRACK_ITEM_ID}_{constants.P_DRUM_STEP_ACTIVE}_1_1_2"] == 34
        assert drum_flags(raw, 1)[0] == {1, 5, 9, 13}

    def test_a_high_lane_lands_where_the_flat_index_says(
        self, raw_projects: dict[str, Any]
    ) -> None:
        """Lane 17's parts are entries 171-180, i.e. slot 3 indices 43-52.

        Spilling across the slot index is the whole reason the values looked
        scattered under the old reading.
        """
        for lane, part, expected in ((17, 0, (3, 43)), (0, 0, (1, 1)), (23, 9, (4, 48))):
            assert constants.drum_step_active_address(lane, part) == expected

    @pytest.mark.parametrize("name", SAMPLES)
    def test_flags_are_a_subset_of_the_pool(self, raw_projects: dict[str, Any], name: str) -> None:
        """Finding 5's invariant: nothing sounds that has no note behind it.

        The converse is false -- pooled notes routinely carry no flag -- which
        is what makes 52 the play/don't-play state and the pool the storage
        the device keeps when a step is toggled off. A file violating this
        would mean the model is wrong, so it is asserted rather than assumed.
        """
        raw = raw_projects[name]
        for pattern in range(1, constants.PATTERNS_PER_TRACK + 1):
            pool = drum_pool(raw, pattern)
            for lane, steps in drum_flags(raw, pattern).items():
                assert steps <= pool.get(lane, set()), f"{name} p{pattern} lane {lane}"

    @pytest.mark.parametrize("name", CONFIRMED)
    def test_flags_equal_the_pool_on_the_confirmed_projects(
        self, raw_projects: dict[str, Any], name: str
    ) -> None:
        """Where the hardware description says what plays, the two agree exactly."""
        raw = raw_projects[name]
        for pattern in range(1, constants.PATTERNS_PER_TRACK + 1):
            pool = {lane: steps for lane, steps in drum_pool(raw, pattern).items() if steps}
            assert drum_flags(raw, pattern) == pool, f"{name} p{pattern}"


class TestNoteListScanRules:
    """Finding 4: the melodic list is compacted; the drum array is a pool."""

    @pytest.mark.parametrize("name", SAMPLES)
    def test_no_melodic_slot_holds_data_after_an_interior_sentinel(
        self, raw_projects: dict[str, Any], name: str
    ) -> None:
        """This is what licenses the melodic scan to stop at the first 127."""
        raw = raw_projects[name]
        for item in constants.TRACK_ITEM_IDS:
            for pattern in range(1, constants.PATTERNS_PER_TRACK + 1):
                for slot in range(1, constants.SLOTS_PER_PATTERN + 1):
                    seen_sentinel = False
                    for i in range(1, constants.MAX_STEPS + 1):
                        value = raw.get(f"{item}_{constants.P_SEQ_NOTE_STEP}_{pattern}_{slot}_{i}")
                        if value == constants.SENTINEL:
                            seen_sentinel = True
                        elif seen_sentinel and value is not None:
                            pytest.fail(f"{name} item {item} p{pattern} slot {slot} index {i}")

    def test_the_drum_pool_does_hold_data_after_a_sentinel(
        self, raw_projects: dict[str, Any]
    ) -> None:
        """The mirror image, and the reason the two scans cannot share a rule.

        ``initial_project`` pattern 5 slot 1 has sentinels at entries 28-29
        with real lane-12 notes at 30-34 behind them. Parameter 52 flags
        exactly those steps on that lane, which is what proves they are live
        user data rather than leftovers.
        """
        raw = raw_projects["initial_project"]
        item = constants.DRUM_TRACK_ITEM_ID
        assert raw[f"{item}_{constants.P_DRUM_NOTE_STEP}_5_1_28"] == constants.SENTINEL
        assert raw[f"{item}_{constants.P_DRUM_NOTE_STEP}_5_1_30"] == 20
        assert raw[f"{item}_{constants.P_DRUM_PITCH}_5_1_30"] == 12
        assert {21, 29, 37, 45, 53} <= drum_flags(raw, 5)[12]


class TestTheReaderAgrees:
    """The same invariants, now through the reader that consumes them."""

    def test_recovered_drum_notes_appear(self, project_files_dir: Path) -> None:
        """43 real user notes that the compacted-list scan used to discard.

        Pattern 5 loses 15 and pattern 9 loses 28 -- exactly the counts the
        old "value(s) after the end of the note list were ignored" warnings
        reported while dropping them.
        """
        project = load(project_files_dir / "initial_project.KeyStepPro")
        for pattern, expected in ((5, 42), (9, 49)):
            drums = project.track(1).pattern(pattern).notes_of(NoteKind.DRUM)
            assert len(drums) == expected, pattern

        # Both lanes run a straight eighth-note figure across the whole 64
        # steps. Under the old scan it stopped dead at step 13, because the
        # sentinels at entries 28-29 cut the list in half.
        full = [5, 13, 21, 29, 37, 45, 53, 57, 61]
        pattern_5 = project.track(1).pattern(5).notes_of(NoteKind.DRUM)
        assert sorted(n.step for n in pattern_5 if n.pitch == 12) == full
        assert sorted(n.step for n in pattern_5 if n.pitch == 17) == full
        # And 52 flags every one of them, which is what makes them live.
        assert all(n.active for n in pattern_5 if n.pitch in (12, 17))

    def test_the_spurious_warnings_are_gone(self, project_files_dir: Path) -> None:
        """Both classes of warning were the reader misreading its own indices.

        The step-active ones came from comparing 48 per slot; the trailing
        ones came from treating the drum pool as a compacted list. Neither
        described anything wrong with the file.
        """
        project = load(project_files_dir / "initial_project.KeyStepPro")
        spurious = [
            w
            for track in project.tracks
            for pattern in track.patterns
            for w in pattern.warnings
            if "step-active flags disagree" in w or "after the end of the note list" in w
        ]
        assert spurious == []

    def test_notes_carry_their_step_active_state(self, project_files_dir: Path) -> None:
        """Pooled-but-unflagged notes are reported, not filtered.

        Finding 5 says 52 decides what sounds, but that is inferred from file
        state rather than confirmed on the device (test D1). Until it is, the
        reader surfaces the flag per note and lets the caller decide.
        """
        project = load(project_files_dir / "initial_project.KeyStepPro")
        drums = project.track(1).pattern(3).notes_of(NoteKind.DRUM)
        assert any(not n.active for n in drums), "expected pooled notes with no flag"

        confirmed = load(project_files_dir / "project_5.KeyStepPro")
        kicks = confirmed.track(1).pattern(1).notes_of(NoteKind.DRUM)
        assert [n.step for n in kicks] == [1, 5]
        assert all(n.active for n in kicks)

    def test_melodic_notes_are_active_by_construction(self, project_files_dir: Path) -> None:
        """48 is the union of the note steps, so every melodic note is flagged."""
        project = load(project_files_dir / "project_5.KeyStepPro")
        melodic = project.track(3).pattern(1).notes_of(NoteKind.SEQ)
        assert melodic and all(n.active for n in melodic)
