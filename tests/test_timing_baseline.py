"""The timing baseline every hardware capture is measured against.

Swing has never been set in any sample project and time shift appears only in
``project_5``'s documented ramp. That makes the corpus a known-neutral floor:
these tests pin it, so the first capture that moves a timing parameter shows up
unmistakably in a diff instead of blending into noise nobody characterised.

They also hold the no-guessing rule for the unmeasured constants -- the same
discipline ``decode_gate`` already enforces.
"""

import sys
from collections.abc import Callable
from pathlib import Path

import pytest

from ksp import constants
from ksp.reader import load

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))

import reduce_timing
import timing_diff

PROJECTS = (
    "Default.KeyStepPro",
    "user_empty_project.KeyStepPro",
    "project_5.KeyStepPro",
    "project_9.KeyStepPro",
    "initial_project.KeyStepPro",
)

# project_5 track 3 pattern 1, note ordinal -> displayed shift. From
# analysis/project_5_description.txt, confirmed on the hardware display.
PROJECT_5_SEQ_RAMP = {1: 1, 2: 2, 3: 3, 4: 4, 5: -1, 6: -2, 7: -3, 8: -4, 10: 2}


@pytest.fixture(params=PROJECTS)
def project_path(request: pytest.FixtureRequest, project_files_dir: Path) -> Path:
    return project_files_dir / str(request.param)


def test_global_swing_is_neutral(
    project_path: Path, load_sample: Callable[[str], dict[str, int | str]]
) -> None:
    """74 reads 50% -- straight -- in every sample project."""
    raw = load_sample(project_path.name)
    assert raw[f"{constants.ITEM_PROJECT}_{constants.P_GLOBAL_SWING}"] == 50


def test_pattern_swing_is_neutral(
    project_path: Path, load_sample: Callable[[str], dict[str, int | str]]
) -> None:
    """97 and 114 read 25 -- zero offset -- in every pattern of every track."""
    raw = load_sample(project_path.name)
    for item in constants.TRACK_ITEM_IDS:
        for param in (constants.P_SEQ_SWING, constants.P_DRUM_SWING):
            for pattern in range(1, constants.PATTERNS_PER_TRACK + 1):
                stored = raw.get(f"{item}_{param}_{pattern}")
                if stored is None:  # 114 exists on Track 1 only
                    continue
                assert stored == constants.SWING_OFFSET, f"{item}_{param}_{pattern}"


def test_only_project_5_has_a_time_shift(project_path: Path) -> None:
    """Every note sits at the centre, except project_5's documented ramp."""
    project = load(project_path)
    shifted = [n for t in project.tracks for p in t.patterns for n in p.notes if n.time_shift]
    if project_path.name == "project_5.KeyStepPro":
        assert shifted, "project_5 carries the ramp the spec documents"
    else:
        assert not shifted, f"unexpected time shift in {project_path.name}"


def test_project_5_ramp_decodes_as_documented(project_files_dir: Path) -> None:
    project = load(project_files_dir / "project_5.KeyStepPro")
    track3 = next(t for t in project.tracks if t.number == 3)
    pattern1 = next(p for p in track3.patterns if p.number == 1)
    ramp = {n.index: n.time_shift for n in pattern1.notes if n.time_shift}
    assert ramp == PROJECT_5_SEQ_RAMP


def test_drum_shift_matches_the_confirmed_display(project_files_dir: Path) -> None:
    """Both kicks were re-read on the device 2026-08-05 (T6.1): -1 and +1."""
    project = load(project_files_dir / "project_5.KeyStepPro")
    track1 = next(t for t in project.tracks if t.number == 1)
    pattern1 = next(p for p in track1.patterns if p.number == 1)
    shifts = [n.time_shift for n in pattern1.notes if n.kind.value == "drum"]
    assert shifts == [-1, 1]


def test_unmeasured_constants_refuse_to_guess() -> None:
    assert constants.TIME_SHIFT_UNIT is None
    assert constants.TIME_SHIFT_RANGE is None
    assert constants.time_shift_fraction(4) is None


def test_timing_diff_finds_no_change_between_a_file_and_itself(
    project_files_dir: Path,
) -> None:
    path = project_files_dir / "project_5.KeyStepPro"
    lines = list(timing_diff.diff(path, path))
    assert any("no timing parameter changed" in line for line in lines)


def test_timing_diff_isolates_the_drum_shift(project_files_dir: Path) -> None:
    """Default -> project_5 differs in exactly the two drum shift keys.

    The melodic ramp is not listed because those notes do not exist in
    Default at all, so every one of its keys moves from the 127 sentinel --
    note-list length, not a timing change.
    """
    lines = list(
        timing_diff.diff(
            project_files_dir / "Default.KeyStepPro",
            project_files_dir / "project_5.KeyStepPro",
        )
    )
    changed = [line for line in lines[1:] if "->" in line]
    assert len(changed) == 2
    assert all("123_120_1_1_" in line for line in changed)


def test_reduce_timing_recovers_a_known_offset(tmp_path: Path) -> None:
    """A synthetic recording with a planted offset reduces to that offset.

    Trusting the reduction before it is pointed at hardware data: if this
    cannot recover an offset it wrote itself, no measurement from it means
    anything.
    """
    mido = pytest.importorskip("mido")

    ppq = 480
    step = 480  # one beat
    offset = 37  # ticks the test channel lands late

    midi = mido.MidiFile(ticks_per_beat=ppq)
    track = mido.MidiTrack()
    midi.tracks.append(track)
    track.append(mido.MetaMessage("set_tempo", tempo=mido.bpm2tempo(120), time=0))

    # Interleave reference (channel 3) and test (channel 1) note-ons.
    events: list[tuple[int, int]] = []
    for beat in range(8):
        events.append((beat * step, 3))
        events.append((beat * step + offset, 1))
    events.sort()

    previous = 0
    for tick, channel in events:
        track.append(
            mido.Message("note_on", note=60, velocity=100, channel=channel, time=tick - previous)
        )
        previous = tick

    path = tmp_path / "synthetic.mid"
    midi.save(str(path))

    onsets, read_ppq, bpm = reduce_timing.read_onsets(path)
    assert read_ppq == ppq
    assert bpm == pytest.approx(120)

    pairings = reduce_timing.pair_onsets(onsets, ref_channel=3, test_channel=1, window=240)
    assert len(pairings) == 8
    assert {p.offset_ticks for p in pairings} == {offset}
