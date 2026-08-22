"""M4 -- the first write that reaches the device."""

from collections.abc import Callable
from pathlib import Path

import pytest

from ksp import constants, lenient_json, mutate
from ksp.keys import key

Loader = Callable[[str], dict[str, int | str]]

TRACK_2_ITEM = 124
TRACK_3_ITEM = 125

PLACE_CANDIDATE = "M4-place.KeyStepPro"
PLACE_READBACK = "M4-place-readback.KeyStepPro"
PITCH_CANDIDATE = "M4-pitch.KeyStepPro"
PITCH_READBACK = "M4-pitch-readback.KeyStepPro"

#: Candidate A. Two notes identical but for one bit: step 1 is flagged and must sound,
#: step 5 is not and must not. Does the device honour a flag we wrote into its file?
PLACED_NOTES = ((1, 60, True), (5, 60, False))

#: Candidate B. project_5 Track 3 note 5 is C#2 on the device's display, with ordinals
#: 6-8 sharing that pitch as a control against off-by-one addressing.
PITCH_NOTE = 5
PITCH_FROM = 49
PITCH_TO = 61


def _place_candidate(base: dict[str, int | str]) -> dict[str, int | str]:
    project = base
    for step, pitch, activate in PLACED_NOTES:
        project = mutate.place_note(
            project, track=2, pattern=1, step=step, pitch=pitch, activate=activate
        )
    return project


@pytest.mark.hardware
def test_write_the_m4_candidates(load_sample: Loader, captures_dir: Path) -> None:
    """Generate both files for the session. Run this before going to the device."""
    captures_dir.mkdir(parents=True, exist_ok=True)

    base = load_sample("baseline.KeyStepPro")
    place = _place_candidate(base)
    # 6 note keys each, one step-active flag for the note that gets one, and
    # the pattern's data-state latch.
    assert len(_changed(base, place)) == 14

    source = load_sample("project_5.KeyStepPro")
    pitch = mutate.set_pitch(source, track=3, pattern=1, note=PITCH_NOTE, pitch=PITCH_TO)
    assert _changed(source, pitch) == {
        mutate.pitch_key(track=3, pattern=1, note=PITCH_NOTE): (PITCH_FROM, PITCH_TO)
    }

    for name, data in ((PLACE_CANDIDATE, place), (PITCH_CANDIDATE, pitch)):
        path = captures_dir / name
        lenient_json.dump_path(data, path)
        # These get copied into MCC's Templates directory, so pin the mode rather than
        # leaving MCC's read to whatever the operator's umask was.
        path.chmod(0o644)

    print(f"\nwrote {PLACE_CANDIDATE} and {PITCH_CANDIDATE} to {captures_dir}")
    print(
        'cp project_files/captures/M4-*.KeyStepPro "/Library/Arturia/MIDI Control '
        'Center/Templates/KeyStepPro/"'
    )


@pytest.mark.hardware
def test_the_device_kept_the_placed_notes(
    require_capture: Callable[[str], Path], load_sample: Loader
) -> None:
    """M4.1. Both notes survive the round trip, and only one carries a flag."""
    readback = lenient_json.load_path(require_capture(PLACE_READBACK))

    for ordinal, (step, pitch, activate) in enumerate(PLACED_NOTES, start=1):
        assert readback[key(TRACK_2_ITEM, constants.P_SEQ_NOTE_STEP, 1, 1, ordinal)] == step - 1
        assert readback[key(TRACK_2_ITEM, constants.P_SEQ_PITCH, 1, 1, ordinal)] == pitch
        flag = readback[key(TRACK_2_ITEM, constants.P_SEQ_STEP_ACTIVE, 1, 1, step)]
        assert flag == int(activate), f"step {step} step-active is {flag}"

    assert readback[key(TRACK_2_ITEM, constants.P_PATTERN_DATA_STATE, 1)] == (
        constants.PATTERN_HAS_DATA
    )
    _report(_place_candidate(load_sample("baseline.KeyStepPro")), readback, PLACE_READBACK)


@pytest.mark.hardware
def test_the_device_kept_the_edited_pitch(
    require_capture: Callable[[str], Path], load_sample: Loader
) -> None:
    """M4.2. The value landed on the note we addressed, not on a neighbour."""
    readback = lenient_json.load_path(require_capture(PITCH_READBACK))

    assert readback[mutate.pitch_key(track=3, pattern=1, note=PITCH_NOTE)] == PITCH_TO
    neighbours = [readback[key(TRACK_3_ITEM, constants.P_SEQ_PITCH, 1, 1, i)] for i in range(6, 9)]
    assert neighbours == [PITCH_FROM] * 3, "the edit moved a neighbouring ordinal"

    assert readback[key(TRACK_3_ITEM, constants.P_SEQ_NOTE_STEP, 1, 1, PITCH_NOTE)] == 4
    assert readback[key(TRACK_3_ITEM, constants.P_SEQ_STEP_ACTIVE, 1, 1, 5)] == 1

    source = mutate.set_pitch(
        load_sample("project_5.KeyStepPro"), track=3, pattern=1, note=PITCH_NOTE, pitch=PITCH_TO
    )
    _report(source, readback, PITCH_READBACK)


def _changed(
    before: dict[str, int | str], after: dict[str, int | str]
) -> dict[str, tuple[object, object]]:
    return {k: (before.get(k), after[k]) for k in after if before.get(k) != after[k]}


def _report(candidate: dict[str, int | str], readback: dict[str, int | str], name: str) -> None:
    """Print what a device round trip cost, for the protocol's ledger."""
    diff = _changed(candidate, readback)
    print(f"\n{name}: {len(diff)} keys differ from the candidate")
    for k, (before, after) in sorted(diff.items()):
        print(f"  {k:24s} {before!r:>8} -> {after!r}")
