"""Step-active decoding, and the notes it stops the export from inventing.

The device plays the step-active flags, not the note pool: capture D1 toggled
a drum step off without deleting its note, the pooled entry survived
byte-for-byte, and the step did not sound. See
``analysis/Hardware_Test_Protocol.md`` tier 4.

The captures themselves are not in the repository (``project_files/captures/``
is gitignored), so the hardware result is pinned here through the committed
``initial_project``, which contains the same situation in real user material,
plus direct tests of the packing arithmetic.
"""

from dataclasses import replace

import pytest

from ksp import constants
from ksp.diagnostics import Code
from ksp.midi_export import ExportOptions, render_pattern
from ksp.model import Note, NoteKind
from ksp.reader import _check_step_active, load

# --- The parameter 52 packing ---------------------------------------------
#
# Flattened [lane][part], lane-major, 7 bits per entry, 10 entries per lane.
# Worked through by hand from D1/D3 and cross-checked on initial_project.


@pytest.mark.parametrize(
    ("lane", "step", "expected"),
    [
        # Lane 0 starts at flat 0, so its first entry is i2=1, i3=1.
        (0, 0, (1, 1, 0)),
        (0, 4, (1, 1, 4)),
        (0, 6, (1, 1, 6)),
        # Step 7 rolls into the lane's second part, not a second bit-width.
        (0, 7, (1, 2, 0)),
        (0, 63, (1, 10, 0)),
        # Lane 1 begins 10 entries later.
        (1, 0, (1, 11, 0)),
        # Lane 6 sits at flat 60..69, which straddles the 64-entry chunk edge.
        (6, 27, (1, 64, 6)),
        (6, 28, (2, 1, 0)),
        # The last lane stays inside the four chunks the file provides:
        # flat = 23*10 + 9 = 239, i.e. chunk 4 entry 48.
        (23, 63, (4, 48, 0)),
    ],
)
def test_drum_step_active_indices(lane: int, step: int, expected: tuple[int, int, int]) -> None:
    assert constants.drum_step_active_indices(lane, step) == expected


def test_drum_step_active_indices_are_unique() -> None:
    """No two (lane, step) pairs may share a bit, or flags would collide."""
    seen = {
        constants.drum_step_active_indices(lane, step)
        for lane in range(constants.DRUM_LANE_COUNT)
        for step in range(constants.MAX_STEPS)
    }
    assert len(seen) == constants.DRUM_LANE_COUNT * constants.MAX_STEPS


def test_drum_step_active_stays_within_the_file_arrays() -> None:
    """Every bit must land in an index the file actually has."""
    for lane in range(constants.DRUM_LANE_COUNT):
        for step in range(constants.MAX_STEPS):
            i2, i3, bit = constants.drum_step_active_indices(lane, step)
            assert 1 <= i2 <= constants.SLOTS_BY_ITEM[constants.DRUM_TRACK_ITEM_ID]
            assert 1 <= i3 <= constants.MAX_STEPS
            assert 0 <= bit < constants.DRUM_STEP_ACTIVE_BITS_PER_ENTRY


# --- The decode, against real user material -------------------------------


@pytest.fixture(scope="module")
def initial_project(project_files_dir):  # type: ignore[no-untyped-def]
    return load(project_files_dir / "initial_project.KeyStepPro")


def _drum_notes(project, pattern_number: int):  # type: ignore[no-untyped-def]
    pattern = project.tracks[0].patterns[pattern_number - 1]
    return [n for n in pattern.notes if n.kind is NoteKind.DRUM]


def test_pattern_1_lane_0_is_fully_flagged(initial_project) -> None:  # type: ignore[no-untyped-def]
    """The kick on steps 1, 5, 9, 13 is what `52` reads 17, 34 for.

    Under the superseded 8-bits-per-entry reading this decoded to steps
    1, 5, 10, 14 and disagreed with the pool -- which is what flagged the
    packing as wrong in the first place.
    """
    lane_0 = [n for n in _drum_notes(initial_project, 1) if n.pitch == 0]
    assert sorted(n.step for n in lane_0) == [1, 5, 9, 13]
    assert all(n.active for n in lane_0)


def test_pattern_1_lane_17_is_only_half_flagged(initial_project) -> None:  # type: ignore[no-untyped-def]
    """Eight pooled notes, four of them silent.

    This is the D1 situation in material nobody authored for a test: the
    pool holds every other step, the flags hold only half of those, and the
    device plays the flags.
    """
    lane_17 = [n for n in _drum_notes(initial_project, 1) if n.pitch == 17]
    assert sorted(n.step for n in lane_17) == [1, 3, 5, 7, 9, 11, 13, 15]
    assert sorted(n.step for n in lane_17 if n.active) == [3, 7, 13, 15]


def test_pattern_3_holds_wholly_unflagged_lanes(initial_project) -> None:  # type: ignore[no-untyped-def]
    """Lanes 0 and 19 have notes and no flags at all -- none of them sound."""
    notes = _drum_notes(initial_project, 3)
    for lane in (0, 19):
        in_lane = [n for n in notes if n.pitch == lane]
        assert in_lane, f"lane {lane} should hold pooled notes"
        assert not any(n.active for n in in_lane)

    # Lane 7 in the same pattern is fully flagged, so this is not a pattern
    # where the decode simply failed.
    lane_7 = [n for n in notes if n.pitch == 7]
    assert lane_7 and all(n.active for n in lane_7)


def test_reader_warns_about_disabled_notes(initial_project) -> None:  # type: ignore[no-untyped-def]
    pattern = initial_project.tracks[0].patterns[2]
    assert any("disabled note(s), step turned off" in w for w in pattern.warnings)


def test_melodic_notes_are_flagged(initial_project) -> None:  # type: ignore[no-untyped-def]
    """`48` and the melodic pool agree everywhere we have data."""
    pattern = initial_project.tracks[0].patterns[0]
    seq = [n for n in pattern.notes if n.kind is NoteKind.SEQ]
    assert seq and all(n.active for n in seq)


def test_empty_project_has_no_flags(project_files_dir) -> None:  # type: ignore[no-untyped-def]
    project = load(project_files_dir / "user_empty_project.KeyStepPro")
    assert not any(pattern.notes for track in project.tracks for pattern in track.patterns)


# --- The export consequence -----------------------------------------------


def test_export_omits_disabled_notes_by_default(initial_project) -> None:  # type: ignore[no-untyped-def]
    pattern = initial_project.tracks[0].patterns[2]
    rendering = render_pattern(pattern, track_number=1, kind=NoteKind.DRUM)

    pooled = [n for n in pattern.notes if n.kind is NoteKind.DRUM]
    audible = [n for n in pooled if n.active]
    assert len(audible) < len(pooled), "this pattern is the interesting case"
    assert len(rendering.notes) == len(audible)
    assert any("were not exported" in w for w in rendering.warnings)


def test_include_disabled_restores_them(initial_project) -> None:  # type: ignore[no-untyped-def]
    pattern = initial_project.tracks[0].patterns[2]
    options = ExportOptions(include_disabled=True)
    rendering = render_pattern(pattern, track_number=1, kind=NoteKind.DRUM, options=options)

    pooled = [n for n in pattern.notes if n.kind is NoteKind.DRUM]
    assert len(rendering.notes) == len(pooled)
    # The reader still reports that these notes are disabled; what must not
    # appear is the export saying it dropped them.
    assert not any("were not exported" in w for w in rendering.warnings)


def test_a_disabled_note_does_not_stretch_the_pattern(initial_project) -> None:  # type: ignore[no-untyped-def]
    """An omitted note must not widen the rendering it was omitted from.

    Otherwise a pattern ends with silence whose length is set by a note the
    device never plays.
    """
    pattern = initial_project.tracks[0].patterns[2]
    notes = tuple(
        replace(n, step=constants.MAX_STEPS, active=False) if i == 0 else n
        for i, n in enumerate(pattern.notes)
    )
    stretched = replace(pattern, notes=notes)

    default = render_pattern(stretched, track_number=1, kind=NoteKind.DRUM)
    including = render_pattern(
        stretched, track_number=1, kind=NoteKind.DRUM, options=ExportOptions(include_disabled=True)
    )
    assert default.length_ticks < including.length_ticks


# --- Past the last step is the other way to be disabled --------------------


def test_notes_past_the_last_step_are_dropped_by_default(initial_project) -> None:  # type: ignore[no-untyped-def]
    """initial_project Track 1 pattern 9 is 48 steps and holds notes to 63.

    The user shortened the pattern, which is how the device disables a step.
    Exporting those notes anyway would put material in the MIDI that the
    hardware does not play, which is the same mistake as ignoring the
    step-active flag.
    """
    pattern = initial_project.tracks[0].patterns[8]
    last = pattern.drum_step_count
    assert last == 48, "the fixture must still be the shortened pattern"
    assert any(n.step > last for n in pattern.notes_of(NoteKind.DRUM)), (
        "and still hold notes past it"
    )

    rendering = render_pattern(pattern, track_number=1, kind=NoteKind.DRUM)
    ticks_per_step = ExportOptions().ticks_per_step
    assert all(n.tick // ticks_per_step < last for n in rendering.notes)
    # The pattern is its declared length, not stretched to reach a note that
    # does not sound.
    assert rendering.length_ticks == last * ticks_per_step
    assert any("past the last step of 48" in w for w in rendering.warnings)
    assert any("--include-disabled" in w for w in rendering.warnings)


def test_include_disabled_restores_notes_past_the_last_step(initial_project) -> None:  # type: ignore[no-untyped-def]
    """One flag covers both ways of being disabled."""
    pattern = initial_project.tracks[0].patterns[8]
    options = ExportOptions(include_disabled=True)
    rendering = render_pattern(pattern, track_number=1, kind=NoteKind.DRUM, options=options)

    pooled = pattern.notes_of(NoteKind.DRUM)
    assert len(rendering.notes) == len(pooled)
    # Widened so the recovered notes land where the file puts them.
    assert rendering.length_ticks > pattern.drum_step_count * options.ticks_per_step
    assert any("--include-disabled is set" in w for w in rendering.warnings)


def test_a_pattern_within_its_length_is_untouched(project_files_dir) -> None:  # type: ignore[no-untyped-def]
    """The filter must not fire on the hardware-confirmed reference project."""
    project = load(project_files_dir / "project_5.KeyStepPro")
    pattern = project.tracks[0].patterns[0]
    rendering = render_pattern(pattern, track_number=1, kind=NoteKind.DRUM)
    assert len(rendering.notes) == len(pattern.notes_of(NoteKind.DRUM))
    assert not any("past the last step" in w for w in rendering.warnings)


# --- The flag-without-note cross-check -------------------------------------
#
# Every flagged step having a pooled note is an invariant, so no sample project
# produces this diagnostic and the corpus alone leaves the scan's non-empty
# result untested. These build the violation directly.


def _seq_note(step: int, index: int = 1) -> Note:
    """A minimal audible melodic note at *step*, which is 1-based."""
    return Note(
        kind=NoteKind.SEQ,
        slot=1,
        index=index,
        step=step,
        pitch=60,
        velocity=100,
        gate_raw=0,
        gate=1.0,
        time_shift=0,
        randomness=0,
        skip=(),
    )


def test_a_flagged_step_backed_by_a_note_is_not_reported() -> None:
    """``active`` is 0-based and ``Note.step`` is 1-based -- the check has to
    bridge that, so an off-by-one here would invent orphans for every step."""
    notes = [_seq_note(1), _seq_note(5, index=2)]
    diagnostics = _check_step_active(1, notes, frozenset({0, 4}), kind=NoteKind.SEQ)

    assert not [d for d in diagnostics if d.code is Code.FLAG_WITHOUT_NOTE]


def test_flags_without_notes_are_reported_in_sorted_step_order() -> None:
    """The scan is |active| + |notes| work, not |active| * |notes| -- the set of
    held steps is built once rather than per flagged step."""
    notes = [_seq_note(1)]
    diagnostics = _check_step_active(1, notes, frozenset({0, 8, 3}), kind=NoteKind.SEQ)

    reported = [d for d in diagnostics if d.code is Code.FLAG_WITHOUT_NOTE]
    assert len(reported) == 1
    assert "step(s) [4, 9]" in reported[0].detail
    assert reported[0].subjects == 2


def test_no_flags_at_all_reports_nothing() -> None:
    notes = [_seq_note(1)]
    diagnostics = _check_step_active(1, notes, frozenset(), kind=NoteKind.SEQ)

    assert not [d for d in diagnostics if d.code is Code.FLAG_WITHOUT_NOTE]
